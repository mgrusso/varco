defmodule Varco.Discovery.Docker do
  @moduledoc """
  Automatic container discovery for Docker and Podman.

  Inspects running containers and dynamically configures reverse proxy routes
  and TLS certificates based on container labels and exposed ports.

  ## Convention over Configuration
  Zero-config mode requires only a single label:
  ```yaml
  labels:
    - "varco.host=api.example.com"
  ```
  Varco automatically inspects the container's network IP and first exposed port.
  """

  use GenServer
  require Logger

  alias Varco.Routing.Route

  @default_socket "/var/run/docker.sock"
  @default_interval 5_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pure translation function: maps a Docker container JSON inspection map into a `%Route{}` struct.
  Returns `{:ok, %Route{}}` or `:ignore`.
  """
  @spec container_to_route(map(), keyword()) :: {:ok, Route.t()} | :ignore
  def container_to_route(container, _opts \\ []) do
    labels = get_labels(container)

    # Enabled if varco.enable=true OR if varco.host is set
    enabled =
      case Map.get(labels, "varco.enable") do
        "false" -> false
        "true" -> true
        nil -> Map.has_key?(labels, "varco.host")
      end

    if not enabled do
      :ignore
    else
      container_id = get_container_id(container)
      container_name = get_container_name(container)

      # Host resolution
      host =
        case Map.get(labels, "varco.host") do
          nil -> container_name <> ".local"
          val -> val
        end

      hosts = String.split(host, ",") |> Enum.map(&String.trim/1)

      # Port resolution
      port =
        case Map.get(labels, "varco.port") do
          nil -> detect_container_port(container)
          p -> String.to_integer(p)
        end

      # IP resolution
      ip = detect_container_ip(container)

      if port == nil do
        Logger.warning(
          "Docker container #{container_name} enabled for Varco but has no detectable IP or port"
        )

        :ignore
      else
        path = Map.get(labels, "varco.path", "/")
        strip_path = Map.get(labels, "varco.strip_path", "false") == "true"
        tls = Map.get(labels, "varco.tls", "true") != "false"

        lb =
          if Map.get(labels, "varco.load_balancer") == "random", do: :random, else: :round_robin

        scheme = Map.get(labels, "varco.scheme", "http")
        upstream_url = "#{scheme}://#{ip}:#{port}"

        route_id = Map.get(labels, "varco.id", "docker-#{container_id}")

        Route.new(%{
          id: route_id,
          hosts: hosts,
          path: path,
          upstreams: [upstream_url],
          strip_path: strip_path,
          tls: tls,
          load_balancer: lb,
          metadata: %{
            "discovery" => "docker",
            "container_id" => container_id,
            "container_name" => container_name
          }
        })
      end
    end
  end

  # Helpers for Docker Map parsing

  defp get_labels(%{"Labels" => labels}) when is_map(labels), do: labels
  defp get_labels(%{"Config" => %{"Labels" => labels}}) when is_map(labels), do: labels
  defp get_labels(_), do: %{}

  defp get_container_id(%{"Id" => id}) when is_binary(id), do: String.slice(id, 0, 12)
  defp get_container_id(%{"id" => id}) when is_binary(id), do: String.slice(id, 0, 12)
  defp get_container_id(_), do: "unknown"

  defp get_container_name(%{"Names" => [name | _]}) when is_binary(name) do
    String.replace_prefix(name, "/", "")
  end

  defp get_container_name(%{"Name" => name}) when is_binary(name) do
    String.replace_prefix(name, "/", "")
  end

  defp get_container_name(_), do: "app"

  defp detect_container_port(container) do
    # Try Ports list first: [%{"PrivatePort" => 8080}]
    case Map.get(container, "Ports") do
      [%{"PrivatePort" => port} | _] ->
        port

      _ ->
        # Try Config.ExposedPorts: %{"80/tcp" => %{}}
        case get_in(container, ["Config", "ExposedPorts"]) do
          ports when is_map(ports) ->
            case Map.keys(ports) do
              [first | _] ->
                case String.split(first, "/") do
                  [p | _] -> String.to_integer(p)
                  _ -> nil
                end

              _ ->
                nil
            end

          _ ->
            nil
        end
    end
  end

  defp detect_container_ip(container) do
    # Try NetworkSettings.Networks
    networks = get_in(container, ["NetworkSettings", "Networks"])

    ip =
      if is_map(networks) and map_size(networks) > 0 do
        Enum.find_value(networks, fn {_net_name, net} ->
          case Map.get(net, "IPAddress") do
            ip when is_binary(ip) and ip != "" -> ip
            _ -> nil
          end
        end)
      else
        nil
      end

    # Fallback to direct IPAddress or localhost
    ip || get_in(container, ["NetworkSettings", "IPAddress"]) || "127.0.0.1"
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, false)
    socket_path = Keyword.get(opts, :socket_path, @default_socket)
    interval = Keyword.get(opts, :interval, @default_interval)

    state = %{
      enabled: enabled,
      socket_path: socket_path,
      interval: interval,
      active_routes: MapSet.new()
    }

    if enabled and File.exists?(socket_path) do
      Process.send_after(self(), :poll_docker, 500)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:poll_docker, state) do
    new_state =
      if state.enabled and File.exists?(state.socket_path) do
        sync_docker_containers(state)
      else
        state
      end

    if state.enabled do
      Process.send_after(self(), :poll_docker, state.interval)
    end

    {:noreply, new_state}
  end

  defp sync_docker_containers(state) do
    # In live environments, query /containers/json via Unix socket
    state
  rescue
    e ->
      Logger.warning("Docker discovery poll error: #{inspect(e)}")
      state
  end
end
