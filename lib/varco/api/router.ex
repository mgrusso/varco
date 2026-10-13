defmodule Varco.API.Router do
  @moduledoc """
  Declarative REST Management API and embedded Real-Time Dashboard router.

  Provides full runtime control over routes, certificates, upstream health,
  and cluster state with zero restarts required.
  """

  use Plug.Router

  alias Varco.Routing.{Route, Table, HealthChecker}
  alias Varco.TLS.CertificateStore
  alias Varco.Cluster.Sync
  alias Varco.Dashboard.HTML

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json", "text/json"],
    json_decoder: Jason
  )

  plug(:authenticate_admin)
  plug(:dispatch)

  # Dashboard & Root Redirect
  get "/" do
    conn
    |> put_resp_header("location", "/dashboard")
    |> send_resp(302, "")
  end

  get "/dashboard" do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_content_type("text/html")
    |> send_resp(200, HTML.render())
  end

  # CORS Preflight
  options _ do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
    |> send_resp(204, "")
  end

  # Health & Ping
  get "/api/v1/ping" do
    json(conn, 200, %{status: "ok", service: "varco"})
  end

  # Prometheus Exposition Format Metrics
  get "/metrics" do
    routes_count = length(Table.list_routes())
    certs_count = length(CertificateStore.list_certificates())
    beam_memory = :erlang.memory(:total)
    beam_procs = :erlang.system_info(:process_count)
    beam_schedulers = :erlang.system_info(:schedulers_online)
    uptime = :erlang.element(1, :erlang.statistics(:wall_clock)) |> div(1000)

    body = """
    # HELP varco_active_routes_count Number of currently active reverse proxy routes
    # TYPE varco_active_routes_count gauge
    varco_active_routes_count #{routes_count}

    # HELP varco_active_certificates_count Number of TLS certificates currently managed
    # TYPE varco_active_certificates_count gauge
    varco_active_certificates_count #{certs_count}

    # HELP varco_beam_memory_bytes Total BEAM VM allocated memory in bytes
    # TYPE varco_beam_memory_bytes gauge
    varco_beam_memory_bytes #{beam_memory}

    # HELP varco_beam_processes Total number of active Erlang processes
    # TYPE varco_beam_processes gauge
    varco_beam_processes #{beam_procs}

    # HELP varco_beam_schedulers Number of online Erlang schedulers
    # TYPE varco_beam_schedulers gauge
    varco_beam_schedulers #{beam_schedulers}

    # HELP varco_uptime_seconds Total uptime in seconds
    # TYPE varco_uptime_seconds counter
    varco_uptime_seconds #{uptime}
    """

    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, body)
  end

  # Routes Endpoints
  get "/api/v1/routes" do
    routes =
      Table.list_routes()
      |> Enum.map(&route_to_map/1)

    json(conn, 200, routes)
  end

  post "/api/v1/routes" do
    case conn.body_params do
      %{} = params when map_size(params) > 0 ->
        case Table.add_route(params) do
          {:ok, %Route{} = route} ->
            Sync.broadcast_route_upsert(route)
            json(conn, 201, route_to_map(route))

          {:error, reason} ->
            json(conn, 400, %{error: "invalid_route", details: inspect(reason)})
        end

      _ ->
        json(conn, 400, %{error: "missing_json_body"})
    end
  end

  get "/api/v1/routes/:id" do
    case Table.get_route(id) do
      {:ok, %Route{} = route} ->
        json(conn, 200, route_to_map(route))

      {:error, :not_found} ->
        json(conn, 404, %{error: "route_not_found", id: id})
    end
  end

  delete "/api/v1/routes/:id" do
    case Table.remove_route(id) do
      :ok ->
        Sync.broadcast_route_delete(id)
        json(conn, 200, %{status: "deleted", id: id})

      {:error, :not_found} ->
        json(conn, 404, %{error: "route_not_found", id: id})
    end
  end

  # Certificates Endpoints
  get "/api/v1/certificates" do
    certs = CertificateStore.list_certificates()
    json(conn, 200, certs)
  end

  post "/api/v1/certificates" do
    with %{"cert" => cert_pem, "key" => key_pem} <- conn.body_params,
         domains = Map.get(conn.body_params, "domains"),
         {:ok, meta} <- CertificateStore.add_custom_certificate(cert_pem, key_pem, domains) do
      json(conn, 201, %{status: "imported", metadata: meta})
    else
      {:error, reason} ->
        json(conn, 400, %{error: "certificate_import_failed", details: inspect(reason)})

      _ ->
        json(conn, 400, %{error: "missing_cert_or_key_pem"})
    end
  end

  get "/api/v1/certificates/ca" do
    case CertificateStore.export_ca_pem() do
      {:ok, pem} ->
        conn
        |> put_resp_content_type("application/x-x509-ca-cert")
        |> put_resp_header("content-disposition", "attachment; filename=\"varco-root-ca.crt\"")
        |> send_resp(200, pem)

      {:error, reason} ->
        json(conn, 500, %{error: "ca_export_failed", details: inspect(reason)})
    end
  end

  # Upstreams Health
  get "/api/v1/upstreams" do
    health_list = HealthChecker.list_health()
    json(conn, 200, health_list)
  end

  # Cluster Status
  get "/api/v1/cluster" do
    status = Sync.status()
    json(conn, 200, status)
  end

  # Observability & Metrics
  get "/api/v1/metrics" do
    metrics = %{
      node: Node.self(),
      uptime_seconds: :erlang.element(1, :erlang.statistics(:wall_clock)) |> div(1000),
      beam_memory_bytes: :erlang.memory(:total),
      beam_processes: :erlang.system_info(:process_count),
      beam_schedulers: :erlang.system_info(:schedulers_online),
      active_routes_count: length(Table.list_routes()),
      active_certificates_count: length(CertificateStore.list_certificates())
    }

    json(conn, 200, metrics)
  end

  match _ do
    json(conn, 404, %{error: "endpoint_not_found", path: conn.request_path})
  end

  # Response Helpers

  defp json(conn, status, data) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp route_to_map(%Route{} = r) do
    %{
      id: r.id,
      hosts: r.hosts,
      path: r.path,
      path_type: r.path_type,
      upstreams: r.upstreams,
      strip_path: r.strip_path,
      tls: r.tls,
      load_balancer: r.load_balancer,
      metadata: r.metadata
    }
  end

  defp authenticate_admin(conn, _opts) do
    cond do
      conn.request_path in ["/api/v1/ping", "/metrics"] ->
        conn

      conn.method == "OPTIONS" ->
        conn

      true ->
        token = System.get_env("VARCO_ADMIN_TOKEN")
        password = System.get_env("VARCO_ADMIN_PASSWORD")
        user = System.get_env("VARCO_ADMIN_USER", "admin")

        if (token && token != "") || (password && password != "") do
          if authorized?(conn, token, user, password) do
            conn
          else
            conn
            |> put_resp_header("www-authenticate", "Basic realm=\"Varco Admin\"")
            |> put_resp_header("access-control-allow-origin", "*")
            |> put_resp_content_type("application/json")
            |> send_resp(
              401,
              Jason.encode!(%{
                error: "unauthorized",
                message: "Valid Bearer token or Basic auth required"
              })
            )
            |> halt()
          end
        else
          conn
        end
    end
  end

  defp authorized?(conn, token, user, password) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> req_token | _] when is_binary(token) and token != "" ->
        Plug.Crypto.secure_compare(req_token, token)

      ["Basic " <> encoded | _] when is_binary(password) and password != "" ->
        case Base.decode64(encoded, ignore: :whitespace) do
          {:ok, decoded} ->
            case String.split(decoded, ":", parts: 2) do
              [u, p] ->
                Plug.Crypto.secure_compare(u, user) and Plug.Crypto.secure_compare(p, password)

              _ ->
                false
            end

          _ ->
            false
        end

      _ ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["token"] do
          req_token
          when is_binary(req_token) and req_token != "" and is_binary(token) and token != "" ->
            Plug.Crypto.secure_compare(req_token, token)

          _ ->
            false
        end
    end
  end
end
