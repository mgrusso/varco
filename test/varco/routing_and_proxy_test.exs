defmodule Varco.RoutingAndProxyTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Varco.Routing.{Route, Table, LoadBalancer}
  alias Varco.Proxy.Handler

  # Mock Upstream Plug
  # Mock WebSocket Upstream Handler
  defmodule MockWebSocketUpstream do
    @behaviour WebSock

    def init(opts), do: {:ok, opts}

    def handle_in({msg, opcode: :text}, state) do
      {:push, {:text, "echo:" <> msg}, state}
    end

    def handle_in({msg, opcode: :binary}, state) do
      {:push, {:binary, "bin:" <> msg}, state}
    end

    def handle_control({msg, opcode: :ping}, state) do
      {:push, {:pong, msg}, state}
    end

    def handle_control(_other, state), do: {:ok, state}

    def handle_info(_msg, state), do: {:ok, state}

    def terminate(_reason, _state), do: :ok
  end

  # Mock Upstream Plug
  defmodule MockUpstream do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.request_path do
        "/ws" ->
          Plug.Conn.upgrade_adapter(conn, :websocket, {MockWebSocketUpstream, [], []})

        "/upload-large" ->
          {total_bytes, next_conn} = read_all_bytes(conn, 0)
          next_conn |> send_resp(200, "Received bytes: #{total_bytes}")

        "/slow" ->
          Process.sleep(200)
          conn |> send_resp(200, "Slow response")

        "/echo" ->
          {:ok, body, conn} = read_body(conn)

          conn
          |> put_resp_header("x-upstream-header", "custom-value")
          |> put_resp_header(
            "x-received-xff",
            List.first(get_req_header(conn, "x-forwarded-for")) || "none"
          )
          |> send_resp(200, "Upstream body: #{body}")

        "/api/data" ->
          conn |> send_resp(200, ~s({"status":"ok"}))

        _ ->
          conn |> send_resp(200, "Hello from #{conn.request_path}")
      end
    end

    defp read_all_bytes(conn, acc) do
      case read_body(conn, length: 1_000_000, read_length: 100_000) do
        {:ok, chunk, next_conn} -> {acc + byte_size(chunk), next_conn}
        {:more, chunk, next_conn} -> read_all_bytes(next_conn, acc + byte_size(chunk))
      end
    end
  end

  setup_all do
    # Start Mock Upstream Bandit server on random port
    {:ok, upstream_pid} = Bandit.start_link(plug: MockUpstream, port: 0)
    listener_pid = ThousandIsland.Server.listener_pid(upstream_pid)
    {_, upstream_port} = ThousandIsland.Listener.listener_info(listener_pid)

    upstream_url = "http://127.0.0.1:#{upstream_port}"

    # Start real Proxy Bandit listener for TCP socket tests
    {:ok, proxy_pid} = Bandit.start_link(plug: Handler, port: 0)
    proxy_listener = ThousandIsland.Server.listener_pid(proxy_pid)
    {_, proxy_port} = ThousandIsland.Listener.listener_info(proxy_listener)

    %{upstream_url: upstream_url, upstream_port: upstream_port, proxy_port: proxy_port}
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

  test "streams large request bodies without 10MB buffering limit", %{
    upstream_url: upstream_url,
    proxy_port: proxy_port
  } do
    {:ok, _route} =
      Table.add_route(%{
        id: "upload-route",
        host: "upload.local",
        path: "/upload-large",
        upstreams: [upstream_url],
        tls: false
      })

    # 11 MB payload (exceeds former 10 MB buffer limit)
    eleven_mb = 11 * 1024 * 1024
    chunk = :binary.copy("A", 1024 * 1024)
    large_payload_stream = Stream.repeatedly(fn -> chunk end) |> Stream.take(11)

    resp =
      Req.post!(
        "http://127.0.0.1:#{proxy_port}/upload-large",
        headers: [{"host", "upload.local"}],
        body: large_payload_stream,
        receive_timeout: 30_000
      )

    assert resp.status == 200
    assert resp.body == "Received bytes: #{eleven_mb}"
  end

  test "honors configurable route timeout", %{upstream_url: upstream_url} do
    {:ok, _route} =
      Table.add_route(%{
        id: "timeout-route",
        host: "timeout.local",
        path: "/slow",
        upstreams: [upstream_url],
        tls: false,
        timeout: 50
      })

    # Upstream sleeps 200ms, route timeout is 50ms -> returns 502 Bad Gateway
    conn =
      Plug.Test.conn(:get, "/slow")
      |> Map.put(:host, "timeout.local")
      |> Handler.call([])

    assert conn.status == 502
    assert conn.resp_body =~ "Bad Gateway"
  end

  test "end-to-end WebSocket proxying with bidirectional message and control frames", %{
    upstream_url: upstream_url,
    proxy_port: proxy_port
  } do
    {:ok, _route} =
      Table.add_route(%{
        id: "ws-proxy-route",
        host: "ws.local",
        path: "/ws",
        upstreams: [upstream_url],
        tls: false
      })

    # Connect to Varco proxy listener via Mint WebSocket
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", proxy_port)

    {:ok, conn, ref} =
      Mint.WebSocket.upgrade(:ws, conn, "/ws", [
        {"host", "ws.local"},
        {"origin", "http://ws.local"}
      ])

    # Await 101 Switching Protocols from Varco
    receive do
      msg ->
        {:ok, conn, [{:status, ^ref, 101}, {:headers, ^ref, headers}, {:done, ^ref}]} =
          Mint.WebSocket.stream(conn, msg)

        assert List.keyfind(headers, "upgrade", 0) == {"upgrade", "websocket"}
        {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, 101, headers)

        # 1. Test Text Frame
        {:ok, ws, text_data} = Mint.WebSocket.encode(ws, {:text, "Hello WebSocket!"})
        {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, text_data)

        receive do
          text_resp_msg ->
            {:ok, conn, [{:data, ^ref, raw_text_data}]} =
              Mint.WebSocket.stream(conn, text_resp_msg)

            {:ok, ws, [{:text, text}]} = Mint.WebSocket.decode(ws, raw_text_data)
            assert text == "echo:Hello WebSocket!"

            # 2. Test Binary Frame
            bin_payload = <<0, 1, 2, 3, 255>>
            {:ok, ws, bin_data} = Mint.WebSocket.encode(ws, {:binary, bin_payload})
            {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, bin_data)

            receive do
              bin_resp_msg ->
                {:ok, conn, [{:data, ^ref, raw_bin_data}]} =
                  Mint.WebSocket.stream(conn, bin_resp_msg)

                {:ok, ws, [{:binary, received_bin}]} = Mint.WebSocket.decode(ws, raw_bin_data)
                assert received_bin == "bin:" <> bin_payload

                # 3. Test Ping / Pong Control Frame
                {:ok, ws, ping_data} = Mint.WebSocket.encode(ws, {:ping, "ping-payload"})
                {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, ping_data)

                receive do
                  pong_msg ->
                    {:ok, conn, [{:data, ^ref, raw_pong_data}]} =
                      Mint.WebSocket.stream(conn, pong_msg)

                    {:ok, ws, frames} = Mint.WebSocket.decode(ws, raw_pong_data)

                    assert Enum.any?(frames, fn
                             {:pong, "ping-payload"} -> true
                             :pong -> true
                             _ -> false
                           end)

                    # 4. Clean close
                    {:ok, _ws, close_data} = Mint.WebSocket.encode(ws, :close)
                    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, close_data)
                    Mint.HTTP.close(conn)
                after
                  2000 -> flunk("Timed out waiting for pong from WebSocket proxy")
                end
            after
              2000 -> flunk("Timed out waiting for binary echo from WebSocket proxy")
            end
        after
          2000 -> flunk("Timed out waiting for text echo from WebSocket proxy")
        end
    after
      2000 -> flunk("Timed out waiting for 101 WebSocket upgrade response")
    end
  end
end
