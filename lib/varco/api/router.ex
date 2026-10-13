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
end
