defmodule Varco.APITest do
  use ExUnit.Case, async: false
  alias Varco.API.Router
  alias Varco.Routing.Table

  setup do
    Table.clear_routes()
    :ok
  end

  test "serves embedded dashboard HTML" do
    conn =
      Plug.Test.conn(:get, "/dashboard")
      |> Router.call([])

    assert conn.status == 200
    assert conn.resp_body =~ "Varco"
    assert conn.resp_body =~ "Reverse Proxy Dashboard"
  end

  test "redirects root path to /dashboard" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Router.call([])

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/dashboard"]
  end

  test "supports CORS preflight OPTIONS requests and sets CORS headers on JSON endpoints" do
    conn =
      Plug.Test.conn(:options, "/api/v1/routes")
      |> Router.call([])

    assert conn.status == 204
    assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["*"]

    conn_get =
      Plug.Test.conn(:get, "/api/v1/routes")
      |> Router.call([])

    assert conn_get.status == 200
    assert Plug.Conn.get_resp_header(conn_get, "access-control-allow-origin") == ["*"]
  end

  test "serves ping health check" do
    conn =
      Plug.Test.conn(:get, "/api/v1/ping")
      |> Router.call([])

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "ok"
  end

  test "manages routes via REST API" do
    # Create route
    payload = %{
      "id" => "api-v1-service",
      "host" => "api.company.com",
      "path" => "/v1",
      "upstreams" => ["http://127.0.0.1:4000"],
      "tls" => true
    }

    conn =
      Plug.Test.conn(:post, "/api/v1/routes", Jason.encode!(payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 201
    created = Jason.decode!(conn.resp_body)
    assert created["id"] == "api-v1-service"
    assert created["hosts"] == ["api.company.com"]

    # List routes
    conn =
      Plug.Test.conn(:get, "/api/v1/routes")
      |> Router.call([])

    assert conn.status == 200
    routes = Jason.decode!(conn.resp_body)
    assert length(routes) == 1

    # Get single route
    conn =
      Plug.Test.conn(:get, "/api/v1/routes/api-v1-service")
      |> Router.call([])

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["path"] == "/v1"

    # Delete route
    conn =
      Plug.Test.conn(:delete, "/api/v1/routes/api-v1-service")
      |> Router.call([])

    assert conn.status == 200

    # Verify deleted
    conn =
      Plug.Test.conn(:get, "/api/v1/routes/api-v1-service")
      |> Router.call([])

    assert conn.status == 404
  end

  test "exports Root CA and lists certificates" do
    # Export CA
    conn =
      Plug.Test.conn(:get, "/api/v1/certificates/ca")
      |> Router.call([])

    assert conn.status == 200
    assert conn.resp_body =~ "-----BEGIN CERTIFICATE-----"

    # List certificates
    conn =
      Plug.Test.conn(:get, "/api/v1/certificates")
      |> Router.call([])

    assert conn.status == 200
    certs = Jason.decode!(conn.resp_body)
    assert is_list(certs)
  end

  test "returns BEAM metrics and cluster status" do
    # Metrics
    conn =
      Plug.Test.conn(:get, "/api/v1/metrics")
      |> Router.call([])

    assert conn.status == 200
    metrics = Jason.decode!(conn.resp_body)
    assert Map.has_key?(metrics, "beam_memory_bytes")
    assert Map.has_key?(metrics, "beam_schedulers")

    # Cluster
    conn =
      Plug.Test.conn(:get, "/api/v1/cluster")
      |> Router.call([])

    assert conn.status == 200
    cluster = Jason.decode!(conn.resp_body)
    assert Map.has_key?(cluster, "node_count")
  end

  test "serves Prometheus format metrics on /metrics" do
    conn =
      Plug.Test.conn(:get, "/metrics")
      |> Router.call([])

    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "content-type") == [
             "text/plain; version=0.0.4; charset=utf-8"
           ]

    assert conn.resp_body =~ "varco_active_routes_count"
    assert conn.resp_body =~ "varco_beam_memory_bytes"
    assert conn.resp_body =~ "varco_uptime_seconds"
  end

  test "enforces Admin Authentication when VARCO_ADMIN_TOKEN or VARCO_ADMIN_PASSWORD is set" do
    System.put_env("VARCO_ADMIN_TOKEN", "secret-test-token")

    # Unauthorized request without header
    conn_unauth =
      Plug.Test.conn(:get, "/api/v1/routes")
      |> Router.call([])

    assert conn_unauth.status == 401
    assert Jason.decode!(conn_unauth.resp_body)["error"] == "unauthorized"

    # Authorized request with Bearer token
    conn_auth =
      Plug.Test.conn(:get, "/api/v1/routes")
      |> Plug.Conn.put_req_header("authorization", "Bearer secret-test-token")
      |> Router.call([])

    assert conn_auth.status == 200

    # Health ping remains unauthenticated
    conn_ping =
      Plug.Test.conn(:get, "/api/v1/ping")
      |> Router.call([])

    assert conn_ping.status == 200
  after
    System.delete_env("VARCO_ADMIN_TOKEN")
  end
end
