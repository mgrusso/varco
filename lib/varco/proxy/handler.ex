defmodule Varco.Proxy.Handler do
  @moduledoc """
  Core reverse proxy request handler and streaming pipeline.

  Implements `Plug` to bridge client requests and backend upstreams with
  sub-millisecond routing, zero-buffering response streaming, and automatic HTTPS redirection.
  """

  @behaviour Plug
  import Plug.Conn
  require Logger

  alias Varco.Routing.{Table, LoadBalancer}
  alias Varco.TLS.ACME

  @hop_by_hop_headers [
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade"
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/.well-known/acme-challenge/" <> token} = conn, _opts) do
    case ACME.get_challenge_response(token) do
      {:ok, key_auth} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, key_auth)
        |> halt()

      :error ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "ACME Challenge Not Found")
        |> halt()
    end
  end

  def call(%Plug.Conn{request_path: "/__varco/ping"} = conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "pong")
    |> halt()
  end

  def call(conn, _opts) do
    start_time = System.monotonic_time()

    # Extract Host and Path
    host = get_request_host(conn)
    path = conn.request_path

    case Table.match_request(host, path) do
      nil ->
        emit_telemetry(start_time, conn, 404, nil, nil)
        render_not_found(conn, host, path)

      route ->
        # Check automatic HTTPS redirect
        if should_redirect_to_https?(conn, route) do
          redirect_to_https(conn, host)
        else
          if websocket_upgrade?(conn) do
            proxy_websocket(conn, route, start_time)
          else
            proxy_request(conn, route, start_time)
          end
        end
    end
  end

  # Proxy Pipeline

  defp proxy_request(conn, route, start_time) do
    case LoadBalancer.select_upstream(route) do
      {:ok, upstream} ->
        forward_to_upstream(conn, route, upstream, start_time)

      {:error, :no_upstreams} ->
        emit_telemetry(start_time, conn, 502, route.id, nil)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(502, "Bad Gateway: No upstreams available for route #{route.id}")
        |> halt()
    end
  end

  defp proxy_websocket(conn, route, start_time) do
    case LoadBalancer.select_upstream(route) do
      {:ok, upstream} ->
        forward_websocket_to_upstream(conn, route, upstream, start_time)

      {:error, :no_upstreams} ->
        emit_telemetry(start_time, conn, 502, route.id, nil)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(502, "Bad Gateway: No upstreams available for route #{route.id}")
        |> halt()
    end
  end

  defp forward_websocket_to_upstream(conn, route, upstream, start_time) do
    upstream_uri = URI.parse(upstream)

    {conn_scheme, ws_scheme, default_port} =
      case upstream_uri.scheme do
        "https" -> {:https, :wss, 443}
        "wss" -> {:https, :wss, 443}
        _ -> {:http, :ws, 80}
      end

    port = upstream_uri.port || default_port
    host = upstream_uri.host || "127.0.0.1"

    target_path = calculate_target_path(conn.request_path, route)
    base_path = upstream_uri.path || ""

    full_path =
      if base_path in ["", "/"], do: target_path, else: Path.join(base_path, target_path)

    query_str = if conn.query_string != "", do: "?" <> conn.query_string, else: ""
    upstream_path = full_path <> query_str

    headers = prepare_websocket_upstream_headers(conn, route, host, port)

    subprotocols =
      case get_req_header(conn, "sec-websocket-protocol") do
        [proto | _] -> String.split(proto, ",") |> Enum.map(&String.trim/1)
        [] -> []
      end

    upgrade_opts = if subprotocols != [], do: [subprotocols: subprotocols], else: []

    connect_opts =
      if conn_scheme == :https do
        [transport_opts: [verify: :verify_none]]
      else
        []
      end

    timeout = route.timeout || 300_000

    with {:ok, mint_conn} <- Mint.HTTP.connect(conn_scheme, host, port, connect_opts),
         {:ok, mint_conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, mint_conn, upstream_path, headers, upgrade_opts) do
      case await_websocket_upgrade(mint_conn, ref, timeout) do
        {:ok, mint_conn, 101, resp_headers} ->
          {:ok, mint_conn, ws} = Mint.WebSocket.new(mint_conn, ref, 101, resp_headers)

          resp_subproto =
            case List.keyfind(resp_headers, "sec-websocket-protocol", 0) do
              {_, val} -> val
              nil -> nil
            end

          conn =
            if resp_subproto do
              put_resp_header(conn, "sec-websocket-protocol", resp_subproto)
            else
              conn
            end

          conn =
            Enum.reduce(route.response_headers, conn, fn {k, v}, c ->
              put_resp_header(c, String.downcase(k), v)
            end)

          emit_telemetry(start_time, conn, 101, route.id, upstream, 0)

          Plug.Conn.upgrade_adapter(
            conn,
            :websocket,
            {Varco.Proxy.WebSocketHandler,
             %{
               conn: mint_conn,
               ref: ref,
               ws: ws,
               route_id: route.id,
               upstream: upstream
             }, []}
          )

        {:ok, mint_conn, status, _resp_headers} ->
          Mint.HTTP.close(mint_conn)
          emit_telemetry(start_time, conn, status, route.id, upstream, 0)

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(status, "Upstream rejected WebSocket upgrade with status #{status}")
          |> halt()

        {:error, reason} ->
          Mint.HTTP.close(mint_conn)

          Logger.error(
            "Failed to upgrade WebSocket with upstream (#{upstream}): #{inspect(reason)}"
          )

          emit_telemetry(start_time, conn, 502, route.id, upstream, 0)

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(502, "Bad Gateway: Upstream WebSocket upgrade failed")
          |> halt()
      end
    else
      {:error, reason} ->
        Logger.error("Failed to connect to upstream WebSocket (#{upstream}): #{inspect(reason)}")
        emit_telemetry(start_time, conn, 502, route.id, upstream, 0)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(502, "Bad Gateway: Upstream connection failed")
        |> halt()
    end
  end

  defp await_websocket_upgrade(mint_conn, ref, timeout, acc_status \\ nil, acc_headers \\ []) do
    receive do
      message ->
        case Mint.WebSocket.stream(mint_conn, message) do
          {:ok, mint_conn, entries} ->
            {status, headers} =
              Enum.reduce(entries, {acc_status, acc_headers}, fn
                {:status, ^ref, s}, {_, h} -> {s, h}
                {:headers, ^ref, h}, {s, existing_h} -> {s, existing_h ++ h}
                _other, acc -> acc
              end)

            if status != nil and headers != [] do
              {:ok, mint_conn, status, headers}
            else
              await_websocket_upgrade(mint_conn, ref, timeout, status, headers)
            end

          {:error, _mint_conn, reason, _} ->
            {:error, reason}

          :unknown ->
            await_websocket_upgrade(mint_conn, ref, timeout, acc_status, acc_headers)
        end
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp forward_to_upstream(conn, route, upstream, start_time) do
    # Prepare target URL and path
    target_path = calculate_target_path(conn.request_path, route)
    query_str = if conn.query_string != "", do: "?" <> conn.query_string, else: ""
    base_upstream = String.trim_trailing(upstream, "/")
    target_url = base_upstream <> target_path <> query_str

    # Prepare Headers
    headers = prepare_upstream_headers(conn, route)

    # Prepare streaming request body (zero buffering in RAM)
    timeout = route.timeout || 300_000
    body = build_request_body(conn, timeout)

    case parse_method(conn.method) do
      {:ok, method} ->
        finch_name = Varco.Finch
        finch_req = Finch.build(method, target_url, headers, body)

        acc_init = %{
          conn: conn,
          status: nil,
          started: false,
          bytes: 0,
          custom_resp_headers: route.response_headers
        }

        result =
          Finch.stream(
            finch_req,
            finch_name,
            acc_init,
            fn
              {:status, status}, acc ->
                %{acc | status: status}

              {:headers, upstream_headers}, acc ->
                cleaned_headers = filter_hop_by_hop(upstream_headers)

                c =
                  Enum.reduce(cleaned_headers, acc.conn, fn {k, v}, current_conn ->
                    put_resp_header(current_conn, String.downcase(k), v)
                  end)

                c =
                  Enum.reduce(acc.custom_resp_headers, c, fn {k, v}, current_conn ->
                    put_resp_header(current_conn, String.downcase(k), v)
                  end)

                # Send chunked header to client
                c = send_chunked(c, acc.status)
                %{acc | conn: c, started: true}

              {:data, chunk}, acc ->
                case chunk(acc.conn, chunk) do
                  {:ok, c} ->
                    %{acc | conn: c, bytes: acc.bytes + byte_size(chunk)}

                  {:error, :closed} ->
                    acc
                end
            end,
            receive_timeout: timeout,
            request_timeout: timeout
          )

        case result do
          {:ok, %{conn: completed_conn, status: status, bytes: bytes}} ->
            completed_conn =
              case Process.delete(:varco_last_conn) do
                %Plug.Conn{adapter: updated_adapter} ->
                  %{completed_conn | adapter: updated_adapter}

                _ ->
                  completed_conn
              end

            emit_telemetry(start_time, completed_conn, status, route.id, upstream, bytes)
            halt(completed_conn)

          {:error, reason, %{conn: error_conn, started: false}} ->
            Process.delete(:varco_last_conn)
            Logger.error("Upstream connection error (#{upstream}): #{inspect(reason)}")
            emit_telemetry(start_time, error_conn, 502, route.id, upstream, 0)

            error_conn
            |> put_resp_content_type("text/plain")
            |> send_resp(502, "Bad Gateway: Upstream connection failed")
            |> halt()

          {:error, reason, %{conn: error_conn, started: true}} ->
            Process.delete(:varco_last_conn)
            Logger.error("Upstream connection error mid-stream (#{upstream}): #{inspect(reason)}")
            emit_telemetry(start_time, error_conn, 502, route.id, upstream, 0)
            halt(error_conn)

          {:error, reason} ->
            Process.delete(:varco_last_conn)
            Logger.error("Upstream connection error (#{upstream}): #{inspect(reason)}")
            emit_telemetry(start_time, conn, 502, route.id, upstream, 0)

            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(502, "Bad Gateway: Upstream connection failed")
            |> halt()
        end

      {:error, :unsupported_method} ->
        emit_telemetry(start_time, conn, 405, route.id, upstream, 0)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(405, "Method Not Allowed")
        |> halt()
    end
  end

  @supported_methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "delete" => :delete,
    "patch" => :patch,
    "head" => :head,
    "options" => :options,
    "trace" => :trace,
    "connect" => :connect
  }

  defp parse_method(method) when is_binary(method) do
    case Map.get(@supported_methods, String.downcase(method)) do
      nil -> {:error, :unsupported_method}
      atom -> {:ok, atom}
    end
  end

  defp parse_method(_), do: {:error, :unsupported_method}

  # Helpers

  defp get_request_host(conn) do
    case get_req_header(conn, "host") do
      [h | _] -> h
      [] -> conn.host
    end
  end

  defp should_redirect_to_https?(conn, route) do
    if route.tls do
      case get_req_header(conn, "x-forwarded-proto") do
        [proto | _] ->
          proto
          |> String.split(",")
          |> List.first()
          |> to_string()
          |> String.trim()
          |> String.downcase() != "https" and conn.scheme == :http

        [] ->
          conn.scheme == :http
      end
    else
      false
    end
  end

  defp redirect_to_https(conn, host) do
    clean_host =
      case String.split(host, ":", parts: 2) do
        [h, _port] -> h
        [h] -> h
      end

    query = if conn.query_string != "", do: "?" <> conn.query_string, else: ""
    dest = "https://#{clean_host}#{conn.request_path}#{query}"

    conn
    |> put_resp_header("location", dest)
    |> send_resp(308, "")
    |> halt()
  end

  defp calculate_target_path(path, %{strip_path: true, path: route_path}) do
    sub_path = String.replace_prefix(path, route_path, "")

    if sub_path == "" or not String.starts_with?(sub_path, "/") do
      "/" <> sub_path
    else
      sub_path
    end
  end

  defp calculate_target_path(path, _route), do: path

  defp prepare_upstream_headers(conn, route) do
    client_ip =
      conn.remote_ip
      |> :inet.ntoa()
      |> to_string()

    cleaned = filter_hop_by_hop(conn.req_headers)

    existing_xff =
      case List.keyfind(cleaned, "x-forwarded-for", 0) do
        {_, val} -> val <> ", " <> client_ip
        nil -> client_ip
      end

    headers =
      cleaned
      |> List.keystore("x-forwarded-for", 0, {"x-forwarded-for", existing_xff})
      |> List.keystore("x-forwarded-proto", 0, {"x-forwarded-proto", to_string(conn.scheme)})
      |> List.keystore("x-forwarded-host", 0, {"x-forwarded-host", get_request_host(conn)})
      |> List.keystore("x-real-ip", 0, {"x-real-ip", client_ip})

    # Add custom route request headers
    Enum.reduce(route.request_headers, headers, fn {k, v}, acc ->
      List.keystore(acc, String.downcase(k), 0, {String.downcase(k), v})
    end)
  end

  defp filter_hop_by_hop(headers) do
    Enum.reject(headers, fn {key, _val} ->
      String.downcase(to_string(key)) in @hop_by_hop_headers
    end)
  end

  defp build_request_body(conn, timeout) do
    if has_request_body?(conn) do
      {:stream, stream_request_body(conn, timeout)}
    else
      nil
    end
  end

  defp has_request_body?(conn) do
    cond do
      match?({Plug.Adapters.Test.Conn, body} when body not in ["", nil], conn.adapter) ->
        true

      conn.method in ["GET", "HEAD"] and get_req_header(conn, "content-length") in [[], ["0"]] and
          get_req_header(conn, "transfer-encoding") == [] ->
        false

      get_req_header(conn, "content-length") not in [[], ["0"]] ->
        true

      get_req_header(conn, "transfer-encoding") != [] ->
        true

      true ->
        false
    end
  end

  defp stream_request_body(conn, timeout) do
    chunk_size = 64 * 1024

    Stream.resource(
      fn -> {:continue, conn} end,
      fn
        {:continue, c} ->
          case read_body(c, length: chunk_size, read_length: chunk_size, read_timeout: timeout) do
            {:ok, "", next_c} ->
              Process.put(:varco_last_conn, next_c)
              {:halt, {:done, next_c}}

            {:ok, chunk, next_c} ->
              Process.put(:varco_last_conn, next_c)
              {[chunk], {:done, next_c}}

            {:more, chunk, next_c} ->
              Process.put(:varco_last_conn, next_c)
              {[chunk], {:continue, next_c}}

            {:error, _reason} ->
              {:halt, {:done, c}}
          end

        {:done, _c} ->
          {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  defp websocket_upgrade?(conn) do
    conn.method == "GET" and
      header_has_token?(conn, "connection", "upgrade") and
      header_has_token?(conn, "upgrade", "websocket")
  end

  defp header_has_token?(conn, header_name, token) do
    case get_req_header(conn, header_name) do
      [] ->
        false

      headers ->
        token_down = String.downcase(token)

        Enum.any?(headers, fn value ->
          value
          |> String.downcase()
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.member?(token_down)
        end)
    end
  end

  defp prepare_websocket_upstream_headers(conn, route, host, port) do
    client_ip =
      conn.remote_ip
      |> :inet.ntoa()
      |> to_string()

    excluded = [
      "connection",
      "upgrade",
      "keep-alive",
      "proxy-authenticate",
      "proxy-authorization",
      "te",
      "trailers",
      "transfer-encoding",
      "sec-websocket-key",
      "sec-websocket-version",
      "sec-websocket-extensions",
      "host"
    ]

    headers =
      conn.req_headers
      |> Enum.reject(fn {k, _v} -> String.downcase(k) in excluded end)

    existing_xff =
      case List.keyfind(headers, "x-forwarded-for", 0) do
        {_, val} -> val <> ", " <> client_ip
        nil -> client_ip
      end

    headers =
      headers
      |> List.keystore("host", 0, {"host", "#{host}:#{port}"})
      |> List.keystore("x-forwarded-for", 0, {"x-forwarded-for", existing_xff})
      |> List.keystore("x-forwarded-proto", 0, {"x-forwarded-proto", to_string(conn.scheme)})
      |> List.keystore("x-forwarded-host", 0, {"x-forwarded-host", get_request_host(conn)})
      |> List.keystore("x-real-ip", 0, {"x-real-ip", client_ip})

    Enum.reduce(route.request_headers, headers, fn {k, v}, acc ->
      List.keystore(acc, String.downcase(k), 0, {String.downcase(k), v})
    end)
  end

  defp render_not_found(conn, host, path) do
    body = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>404 Not Found - Varco</title>
      <style>
        body { font-family: system-ui, -apple-system, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .card { background: #1e293b; padding: 2.5rem; border-radius: 0.75rem; box-shadow: 0 10px 25px rgba(0,0,0,0.5); max-width: 500px; text-align: center; border: 1px solid #334155; }
        h1 { color: #f43f5e; margin-top: 0; font-size: 2rem; }
        code { background: #0f172a; padding: 0.2rem 0.4rem; border-radius: 0.25rem; color: #38bdf8; font-size: 0.9em; }
        p { color: #94a3b8; line-height: 1.6; }
        .logo { font-weight: 800; font-size: 1.1rem; color: #64748b; margin-top: 2rem; letter-spacing: 0.05em; text-transform: uppercase; }
      </style>
    </head>
    <body>
      <div class="card">
        <h1>404 Not Found</h1>
        <p>No Varco route configured for:</p>
        <p><code>#{Plug.HTML.html_escape(host)}#{Plug.HTML.html_escape(path)}</code></p>
        <div class="logo">Varco Reverse Proxy</div>
      </div>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(404, body)
    |> halt()
  end

  defp emit_telemetry(start_time, conn, status, route_id, upstream, bytes \\ 0) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:varco, :proxy, :request],
      %{duration: duration, bytes_sent: bytes},
      %{
        method: conn.method,
        host: get_request_host(conn),
        path: conn.request_path,
        status: status,
        route_id: route_id,
        upstream: upstream
      }
    )
  end
end
