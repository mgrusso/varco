defmodule Varco.Discovery.Kubernetes do
  @moduledoc """
  Kubernetes Ingress Controller for Varco.

  Watches and synchronizes Kubernetes `Ingress` resources (`networking.k8s.io/v1`) with
  `ingressClassName: varco` and dynamically synchronizes routes into `Varco.Routing.Table`.

  Also integrates with cert-manager by synchronizing Kubernetes TLS Secrets (`kubernetes.io/tls`)
  referenced by Ingress `spec.tls[*].secretName` into `Varco.TLS.CertificateStore`.
  """

  use GenServer
  require Logger

  alias Varco.Routing.{Route, Table}
  alias Varco.TLS.CertificateStore
  alias Varco.Cluster.Sync

  @ingress_class "varco"
  @default_interval 10_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers an immediate synchronization cycle with the Kubernetes API.
  """
  @spec sync_once() :: {:ok, map()} | {:error, term()}
  def sync_once do
    GenServer.call(__MODULE__, :sync_once, 30_000)
  end

  @doc """
  Returns the current operational status of the Kubernetes Ingress Controller.
  """
  @spec get_status() :: map()
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Pure translator: maps a Kubernetes Ingress JSON resource map into a list of `%Route{}` structs.
  Returns `{:ok, [Route.t()]}` or `:ignore`.
  """
  @spec ingress_to_routes(map(), String.t()) :: {:ok, [Route.t()]} | :ignore
  def ingress_to_routes(ingress, expected_ingress_class \\ @ingress_class) when is_map(ingress) do
    if matches_ingress_class?(ingress, expected_ingress_class) do
      metadata = Map.get(ingress, "metadata", %{})
      spec = Map.get(ingress, "spec", %{})

      namespace = Map.get(metadata, "namespace", "default")
      name = Map.get(metadata, "name", "ingress")
      annotations = Map.get(metadata, "annotations", %{})

      tls_hosts = extract_tls_hosts(spec)

      strip_path = Map.get(annotations, "varco.io/strip-path", "false") == "true"

      lb_policy =
        if Map.get(annotations, "varco.io/load-balancer") == "random",
          do: :random,
          else: :round_robin

      scheme = Map.get(annotations, "varco.io/upstream-scheme", "http")

      timeout =
        case Map.get(annotations, "varco.io/proxy-timeout") ||
               Map.get(annotations, "varco.io/timeout") do
          nil ->
            300_000

          "infinity" ->
            :infinity

          val ->
            case Integer.parse(val) do
              {ms, ""} when ms > 0 -> ms
              _ -> 300_000
            end
        end

      rules = Map.get(spec, "rules", [])

      routes =
        for {rule, rule_idx} <- Enum.with_index(rules),
            host = Map.get(rule, "host"),
            paths = get_in(rule, ["http", "paths"]) || [],
            {path_obj, path_idx} <- Enum.with_index(paths) do
          path = Map.get(path_obj, "path", "/")
          path_type = if Map.get(path_obj, "pathType") == "Exact", do: :exact, else: :prefix

          service_name = get_in(path_obj, ["backend", "service", "name"])

          port = parse_port(path_obj)

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
              timeout: timeout,
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

  @doc """
  Extracts all TLS secret references from an Ingress resource map.
  Returns a list of `%{namespace: String.t(), secret_name: String.t(), hosts: [String.t()]}`.
  """
  @spec extract_tls_secrets(map()) :: [
          %{namespace: String.t(), secret_name: String.t(), hosts: [String.t()]}
        ]
  def extract_tls_secrets(ingress) when is_map(ingress) do
    namespace = get_in(ingress, ["metadata", "namespace"]) || "default"
    tls_items = get_in(ingress, ["spec", "tls"]) || []

    Enum.flat_map(tls_items, fn item ->
      case Map.get(item, "secretName") || Map.get(item, :secretName) do
        name when is_binary(name) and name != "" ->
          hosts = Map.get(item, "hosts") || Map.get(item, :hosts) || []
          [%{namespace: namespace, secret_name: name, hosts: hosts}]

        _ ->
          []
      end
    end)
  end

  def extract_tls_secrets(_), do: []

  # Helpers

  defp parse_port(path_obj) do
    case get_in(path_obj, ["backend", "service", "port", "number"]) do
      num when is_integer(num) and num > 0 ->
        num

      _ ->
        case get_in(path_obj, ["backend", "service", "port", "name"]) do
          "http" ->
            80

          "https" ->
            443

          name when is_binary(name) ->
            case Integer.parse(name) do
              {num, ""} when num > 0 -> num
              _ -> 80
            end

          _ ->
            80
        end
    end
  end

  defp matches_ingress_class?(ingress, expected_ingress_class) do
    spec_class = get_in(ingress, ["spec", "ingressClassName"])
    annotation_class = get_in(ingress, ["metadata", "annotations", "kubernetes.io/ingress.class"])

    cond do
      spec_class == expected_ingress_class -> true
      annotation_class == expected_ingress_class -> true
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
    api_url = Keyword.get(opts, :api_url, default_api_url())
    token = Keyword.get(opts, :token, default_token())
    ca_cert_path = Keyword.get(opts, :ca_cert_path, default_ca_cert_path())

    insecure_skip_tls_verify =
      Keyword.get(opts, :insecure_skip_tls_verify, default_insecure_skip_verify?())

    ingress_class = Keyword.get(opts, :ingress_class, @ingress_class)

    state = %{
      enabled: enabled,
      interval: interval,
      api_url: api_url,
      token: token,
      ca_cert_path: ca_cert_path,
      insecure_skip_tls_verify: insecure_skip_tls_verify,
      ingress_class: ingress_class,
      last_sync: nil,
      last_error: nil
    }

    if enabled do
      Logger.info(
        "Varco Kubernetes Ingress Controller discovery enabled (API: #{api_url}, class: #{ingress_class})"
      )

      Process.send_after(self(), :sync_ingresses, 500)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:sync_once, _from, state) do
    case perform_sync(state) do
      {:ok, result, new_state} ->
        {:reply, {:ok, result}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      enabled: state.enabled,
      api_url: state.api_url,
      ingress_class: state.ingress_class,
      interval: state.interval,
      last_sync: state.last_sync,
      last_error: state.last_error
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:sync_ingresses, state) do
    new_state =
      if state.enabled do
        case perform_sync(state) do
          {:ok, _result, s} -> s
          {:error, _reason, s} -> s
        end
      else
        state
      end

    if new_state.enabled do
      Process.send_after(self(), :sync_ingresses, new_state.interval)
    end

    {:noreply, new_state}
  end

  # Synchronization Implementation

  @doc """
  Executes a single synchronization cycle against the Kubernetes API.
  Synchronizes matching Ingress resources into routes and TLS secrets into CertificateStore.
  """
  def perform_sync(state) do
    url = "#{state.api_url}/apis/networking.k8s.io/v1/ingresses"

    case k8s_get(url, state) do
      {:ok, 200, %{"items" => items}} ->
        # 1. Filter matching Ingresses and translate to routes
        matching_ingresses =
          Enum.filter(items, &matches_ingress_class?(&1, state.ingress_class))

        new_routes =
          Enum.flat_map(matching_ingresses, fn ing ->
            case ingress_to_routes(ing, state.ingress_class) do
              {:ok, routes} -> routes
              _ -> []
            end
          end)

        # 2. Sync referenced TLS secrets (cert-manager support)
        synced_secrets = sync_tls_secrets(matching_ingresses, state)

        # 3. Synchronize routes into Table (add new/updated, remove stale)
        existing_k8s_routes =
          Table.list_routes()
          |> Enum.filter(fn r -> get_in(r.metadata, ["discovery"]) == "kubernetes" end)

        new_route_ids = MapSet.new(Enum.map(new_routes, & &1.id))

        # Remove deleted routes
        for old_route <- existing_k8s_routes do
          unless MapSet.member?(new_route_ids, old_route.id) do
            Table.remove_route(old_route.id)
            Logger.info("Removed stale Kubernetes route #{old_route.id}")
          end
        end

        # Add or update routes
        for route <- new_routes do
          Table.add_route(route)
          Sync.broadcast_route_upsert(route)
        end

        Logger.debug(
          "Kubernetes sync complete: #{length(new_routes)} routes active, #{length(synced_secrets)} TLS secrets synced"
        )

        new_state = %{state | last_sync: DateTime.utc_now(), last_error: nil}

        {:ok,
         %{
           routes_count: length(new_routes),
           tls_secrets_count: length(synced_secrets)
         }, new_state}

      {:ok, status, body} ->
        err = "Kubernetes API responded with status #{status}: #{inspect(body)}"
        Logger.error(err)
        {:error, err, %{state | last_error: err}}

      {:error, reason} ->
        err = "Failed to connect to Kubernetes API: #{inspect(reason)}"
        Logger.error(err)
        {:error, reason, %{state | last_error: inspect(reason)}}
    end
  end

  defp sync_tls_secrets(ingresses, state) do
    secrets_to_fetch =
      ingresses
      |> Enum.flat_map(&extract_tls_secrets/1)
      |> Enum.uniq_by(&{&1.namespace, &1.secret_name})

    for secret <- secrets_to_fetch do
      sync_single_secret(secret, state)
    end
    |> Enum.filter(&match?({:ok, _}, &1))
  end

  defp sync_single_secret(secret, state) do
    url = "#{state.api_url}/api/v1/namespaces/#{secret.namespace}/secrets/#{secret.secret_name}"

    case k8s_get(url, state) do
      {:ok, 200, secret_body} ->
        data = Map.get(secret_body, "data", %{})
        crt_b64 = Map.get(data, "tls.crt")
        key_b64 = Map.get(data, "tls.key")

        if crt_b64 && key_b64 do
          with {:ok, cert_pem} <- Base.decode64(crt_b64, ignore: :whitespace),
               {:ok, key_pem} <- Base.decode64(key_b64, ignore: :whitespace),
               {:ok, meta} <-
                 CertificateStore.add_custom_certificate(cert_pem, key_pem, secret.hosts) do
            Logger.info(
              "Synchronized K8s TLS secret #{secret.namespace}/#{secret.secret_name} for domains #{inspect(meta.domains)}"
            )

            {:ok, secret.secret_name}
          else
            {:error, reason} ->
              Logger.warning(
                "Failed to decode/install K8s TLS secret #{secret.namespace}/#{secret.secret_name}: #{inspect(reason)}"
              )

              {:error, reason}
          end
        else
          Logger.warning(
            "K8s Secret #{secret.namespace}/#{secret.secret_name} is missing tls.crt or tls.key data"
          )

          {:error, :missing_tls_keys}
        end

      {:ok, 404, _} ->
        Logger.debug(
          "K8s TLS secret #{secret.namespace}/#{secret.secret_name} not found yet (cert-manager pending?)"
        )

        {:error, :not_found}

      {:ok, status, _} ->
        Logger.warning(
          "Error fetching K8s TLS secret #{secret.namespace}/#{secret.secret_name} (status #{status})"
        )

        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning(
          "Failed to connect to K8s API for secret #{secret.namespace}/#{secret.secret_name}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp k8s_get(url, state) do
    headers = [
      {"authorization", "Bearer " <> (state.token || "")},
      {"accept", "application/json"}
    ]

    connect_opts =
      cond do
        state.insecure_skip_tls_verify ->
          [transport_opts: [verify: :verify_none]]

        state.ca_cert_path && File.exists?(state.ca_cert_path) ->
          [transport_opts: [cacertfile: state.ca_cert_path]]

        true ->
          []
      end

    case Req.get(url,
           headers: headers,
           connect_options: connect_opts,
           retry: false,
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} ->
        parsed_body =
          if is_binary(body) do
            case Jason.decode(body) do
              {:ok, decoded} -> decoded
              _ -> body
            end
          else
            body
          end

        {:ok, status, parsed_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Environment and In-Cluster Detection

  def in_kubernetes? do
    File.exists?("/var/run/secrets/kubernetes.io/serviceaccount/token") or
      System.get_env("KUBERNETES_SERVICE_HOST") != nil or
      System.get_env("KUBERNETES_API_URL") != nil
  end

  defp default_api_url do
    System.get_env("KUBERNETES_API_URL") ||
      if host = System.get_env("KUBERNETES_SERVICE_HOST") do
        port = System.get_env("KUBERNETES_SERVICE_PORT", "443")
        "https://#{host}:#{port}"
      else
        "https://kubernetes.default.svc"
      end
  end

  defp default_token do
    System.get_env("KUBERNETES_TOKEN") ||
      (
        token_path =
          System.get_env(
            "KUBERNETES_TOKEN_PATH",
            "/var/run/secrets/kubernetes.io/serviceaccount/token"
          )

        if File.exists?(token_path) do
          token_path |> File.read!() |> String.trim()
        else
          nil
        end
      )
  end

  defp default_ca_cert_path do
    System.get_env("KUBERNETES_CA_PATH", "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
  end

  defp default_insecure_skip_verify? do
    System.get_env("KUBERNETES_INSECURE_SKIP_TLS_VERIFY") in ["true", "1"]
  end
end
