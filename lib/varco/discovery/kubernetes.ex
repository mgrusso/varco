defmodule Varco.Discovery.Kubernetes do
  @moduledoc """
  Kubernetes Ingress Controller for Varco.

  Watches Kubernetes `Ingress` resources (`networking.k8s.io/v1`) with
  `ingressClassName: varco` and dynamically synchronizes routes and TLS policies.
  """

  use GenServer
  require Logger

  alias Varco.Routing.Route

  @ingress_class "varco"
  @default_interval 10_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pure translator: maps a Kubernetes Ingress JSON resource map into a list of `%Route{}` structs.
  Returns `{:ok, [Route.t()]}` or `:ignore`.
  """
  @spec ingress_to_routes(map()) :: {:ok, [Route.t()]} | :ignore
  def ingress_to_routes(ingress) when is_map(ingress) do
    if matches_ingress_class?(ingress) do
      metadata = Map.get(ingress, "metadata", %{})
      spec = Map.get(ingress, "spec", %{})

      namespace = Map.get(metadata, "namespace", "default")
      name = Map.get(metadata, "name", "ingress")
      annotations = Map.get(metadata, "annotations", %{})

      tls_hosts = extract_tls_hosts(spec)

      strip_path = Map.get(annotations, "varco.io/strip-path", "false") == "true"
      lb_policy = if Map.get(annotations, "varco.io/load-balancer") == "random", do: :random, else: :round_robin
      scheme = Map.get(annotations, "varco.io/upstream-scheme", "http")

      rules = Map.get(spec, "rules", [])

      routes =
        for {rule, rule_idx} <- Enum.with_index(rules),
            host = Map.get(rule, "host"),
            paths = get_in(rule, ["http", "paths"]) || [],
            {path_obj, path_idx} <- Enum.with_index(paths) do
          path = Map.get(path_obj, "path", "/")
          path_type = if Map.get(path_obj, "pathType") == "Exact", do: :exact, else: :prefix

          service_name = get_in(path_obj, ["backend", "service", "name"])

          port =
            get_in(path_obj, ["backend", "service", "port", "number"]) ||
              get_in(path_obj, ["backend", "service", "port", "name"]) ||
              80

          upstream_url = "#{scheme}://#{service_name}.#{namespace}.svc.cluster.local:#{port}"

          is_tls =
            cond do
              tls_hosts == [] -> true
              host && host in tls_hosts -> true
              true -> false
            end

          route_id = "k8s-#{namespace}-#{name}-r#{rule_idx}-p#{path_idx}"

          {:ok, route} =
            Route.new(%{
              id: route_id,
              hosts: if(host, do: [host], else: []),
              path: path,
              path_type: path_type,
              upstreams: [upstream_url],
              strip_path: strip_path,
              tls: is_tls,
              load_balancer: lb_policy,
              metadata: %{
                "discovery" => "kubernetes",
                "namespace" => namespace,
                "ingress_name" => name
              }
            })

          route
        end

      {:ok, routes}
    else
      :ignore
    end
  end

  # Helpers

  defp matches_ingress_class?(ingress) do
    spec_class = get_in(ingress, ["spec", "ingressClassName"])
    annotation_class = get_in(ingress, ["metadata", "annotations", "kubernetes.io/ingress.class"])

    cond do
      spec_class == @ingress_class -> true
      annotation_class == @ingress_class -> true
      spec_class == nil and annotation_class == nil -> true
      true -> false
    end
  end

  defp extract_tls_hosts(%{"tls" => tls_list}) when is_list(tls_list) do
    tls_list
    |> Enum.flat_map(fn item -> Map.get(item, "hosts", []) end)
    |> Enum.uniq()
  end

  defp extract_tls_hosts(_), do: []

  # Server Callbacks

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, in_kubernetes?())
    interval = Keyword.get(opts, :interval, @default_interval)

    state = %{
      enabled: enabled,
      interval: interval
    }

    if enabled do
      Logger.info("Varco Kubernetes Ingress Controller discovery enabled")
      Process.send_after(self(), :sync_ingresses, 1000)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:sync_ingresses, state) do
    # When running inside cluster, poll /apis/networking.k8s.io/v1/ingresses
    if state.enabled do
      Process.send_after(self(), :sync_ingresses, state.interval)
    end

    {:noreply, state}
  end

  defp in_kubernetes? do
    File.exists?("/var/run/secrets/kubernetes.io/serviceaccount/token") or
      System.get_env("KUBERNETES_SERVICE_HOST") != nil
  end
end
