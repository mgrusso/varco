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
end
