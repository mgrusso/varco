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
          proxy_request(conn, route, start_time)
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

  defp forward_to_upstream(conn, route, upstream, start_time) do
    # Prepare target URL and path
    target_path = calculate_target_path(conn.request_path, route)
    query_str = if conn.query_string != "", do: "?" <> conn.query_string, else: ""
    base_upstream = String.trim_trailing(upstream, "/")
    target_url = base_upstream <> target_path <> query_str

    # Prepare Headers
    headers = prepare_upstream_headers(conn, route)

    # Read client request body if present
    {:ok, body, conn} = read_client_body(conn)

    method = String.to_atom(String.downcase(conn.method))
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
        receive_timeout: 30_000
      )

    case result do
      {:ok, %{conn: completed_conn, status: status, bytes: bytes}} ->
        emit_telemetry(start_time, completed_conn, status, route.id, upstream, bytes)
        halt(completed_conn)

      {:error, reason} ->
        Logger.error("Upstream connection error (#{upstream}): #{inspect(reason)}")
        emit_telemetry(start_time, conn, 502, route.id, upstream, 0)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(502, "Bad Gateway: Upstream connection failed")
        |> halt()
    end
  end

  # Helpers

  defp get_request_host(conn) do
    case get_req_header(conn, "host") do
      [h | _] -> h
      [] -> conn.host
    end
  end

  defp should_redirect_to_https?(conn, route) do
    route.tls and conn.scheme == :http
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

  defp read_client_body(conn) do
    case read_body(conn, length: 10_000_000, read_length: 1_000_000) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, chunk, conn} -> read_more_body(conn, [chunk])
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp read_more_body(conn, acc) do
    case read_body(conn, length: 10_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} ->
        full = IO.iodata_to_binary(Enum.reverse([chunk | acc]))
        {:ok, full, conn}

      {:more, chunk, conn} ->
        read_more_body(conn, [chunk | acc])

      {:error, reason} ->
        {:error, reason, conn}
    end
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
