defmodule Varco.ClusterTest do
  use ExUnit.Case, async: false
  alias Varco.Cluster.Sync
  alias Varco.Routing.{Route, Table}
  alias Varco.TLS.CertificateStore

  setup do
    Table.clear_routes()
    :ok
  end

  test "returns cluster status" do
    status = Sync.status()
    assert Map.has_key?(status, :current_node)
    assert Map.has_key?(status, :peers)
    assert Map.has_key?(status, :node_count)
  end

  test "syncs route upsert and deletion locally and across pg members" do
    route = %Route{
      id: "cluster-synced-route",
      hosts: ["sync.local"],
      path: "/app",
      upstreams: ["http://127.0.0.1:8080"]
    }

    Sync.broadcast_route_upsert(route)
    assert {:ok, fetched} = Table.get_route("cluster-synced-route")
    assert fetched.hosts == ["sync.local"]

    Sync.broadcast_route_delete("cluster-synced-route")
    assert Table.get_route("cluster-synced-route") == {:error, :not_found}
  end

  test "syncs ACME HTTP-01 challenge across cluster" do
    token = "cluster-test-token"
    auth = "cluster-auth-key"

    Sync.broadcast_acme_challenge(token, auth, "cluster.example.com")
    assert CertificateStore.get_acme_challenge(token) == {:ok, auth}
  end
end
