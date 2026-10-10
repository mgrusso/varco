defmodule Varco.RoutingAndProxyTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Varco.Routing.{Route, Table, LoadBalancer}
  alias Varco.Proxy.Handler

  # Mock Upstream Plug
  defmodule MockUpstream do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.request_path do
        "/echo" ->
          {:ok, body, conn} = read_body(conn)

          conn
          |> put_resp_header("x-upstream-header", "custom-value")
          |> put_resp_header("x-received-xff", List.first(get_req_header(conn, "x-forwarded-for")) || "none")
          |> send_resp(200, "Upstream body: #{body}")

        "/api/data" ->
          conn |> send_resp(200, ~s({"status":"ok"}))

        _ ->
          conn |> send_resp(200, "Hello from #{conn.request_path}")
      end
    end
  end

  setup_all do
    # Start Mock Upstream Bandit server on random port
    {:ok, upstream_pid} = Bandit.start_link(plug: MockUpstream, port: 0)
    listener_pid = ThousandIsland.Server.listener_pid(upstream_pid)
    {_, upstream_port} = ThousandIsland.Listener.listener_info(listener_pid)

    upstream_url = "http://127.0.0.1:#{upstream_port}"
    %{upstream_url: upstream_url, upstream_port: upstream_port}
  end

  setup do
    Table.clear_routes()
    :ok
  end

  test "route matching logic: exact, wildcard, and path prefix priority" do
    {:ok, _} =
      Table.add_route(%{
        id: "root-route",
        host: "example.com",
        path: "/",
        upstreams: ["http://127.0.0.1:4000"]
      })

    {:ok, _} =
      Table.add_route(%{
        id: "api-route",
        host: "example.com",
        path: "/api",
        upstreams: ["http://127.0.0.1:4001"]
      })

    {:ok, _} =
      Table.add_route(%{
        id: "wildcard-route",
        host: "*.example.com",
        path: "/",
        upstreams: ["http://127.0.0.1:4002"]
      })

    # Longest prefix match on example.com
    assert Table.match_request("example.com", "/api/v1/users").id == "api-route"
    assert Table.match_request("example.com", "/dashboard").id == "root-route"

    # Wildcard host match
    assert Table.match_request("sub.example.com", "/test").id == "wildcard-route"

    # Unmatched
    assert Table.match_request("otherdomain.org", "/test") == nil
  end

  test "load balancer round robin cycles across upstreams" do
    route = %Route{
      id: "lb-test",
      upstreams: ["http://127.0.0.1:4001", "http://127.0.0.1:4002", "http://127.0.0.1:4003"],
      load_balancer: :round_robin
    }

    {:ok, u1} = LoadBalancer.select_upstream(route)
    {:ok, u2} = LoadBalancer.select_upstream(route)
    {:ok, u3} = LoadBalancer.select_upstream(route)
    {:ok, u4} = LoadBalancer.select_upstream(route)

    assert [u1, u2, u3] == route.upstreams
    assert u4 == u1
  end

  test "end-to-end proxy forward with headers and body streaming", %{upstream_url: upstream_url} do
    {:ok, _route} =
      Table.add_route(%{
        id: "test-proxy-route",
        host: "app.local",
        path: "/echo",
        upstreams: [upstream_url],
        tls: false,
        response_headers: [{"x-varco-proxied", "true"}]
      })

    # Simulate client request via Plug.Test
    conn =
      Plug.Test.conn(:post, "/echo", "payload123")
      |> Map.put(:host, "app.local")
      |> put_req_header("x-forwarded-for", "192.168.1.50")
      |> Handler.call([])

    assert conn.status == 200
    assert conn.resp_body == "Upstream body: payload123"
    assert List.first(get_resp_header(conn, "x-varco-proxied")) == "true"
    assert List.first(get_resp_header(conn, "x-upstream-header")) == "custom-value"
    # Verify X-Forwarded-For was chained
    assert List.first(get_resp_header(conn, "x-received-xff")) =~ "192.168.1.50"
  end

  test "path stripping removes route prefix before forwarding", %{upstream_url: upstream_url} do
    {:ok, _route} =
      Table.add_route(%{
        id: "stripped-route",
        host: "api.local",
        path: "/backend",
        strip_path: true,
        upstreams: [upstream_url],
        tls: false
      })

    conn =
      Plug.Test.conn(:get, "/backend/echo", "ping")
      |> Map.put(:host, "api.local")
      |> Handler.call([])

    assert conn.status == 200
    assert conn.resp_body == "Upstream body: ping"
  end

  test "responds with 404 for unconfigured routes" do
    conn =
      Plug.Test.conn(:get, "/nonexistent")
      |> Map.put(:host, "unknown.net")
      |> Handler.call([])

    assert conn.status == 404
    assert conn.resp_body =~ "404 Not Found"
  end

  test "serves ACME HTTP-01 challenge directly" do
    Varco.TLS.ACME.register_challenge("my-secret-token", "key-auth-string-xyz")

    conn =
      Plug.Test.conn(:get, "/.well-known/acme-challenge/my-secret-token")
      |> Handler.call([])

    assert conn.status == 200
    assert conn.resp_body == "key-auth-string-xyz"
  end
end
