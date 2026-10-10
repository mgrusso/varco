# Varco Live End-to-End Smoke Test
# Exercises public HTTP, HTTPS with dynamic SNI, REST API, Dashboard, and Upstream Proxying

defmodule Varco.SmokeTest do

  # 1. Target Backend App Server
  defmodule BackendApp do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      resp = %{
        message: "Hello from backend upstream!",
        path: conn.request_path,
        method: conn.method,
        received_headers: %{
          "x-forwarded-for" => List.first(get_req_header(conn, "x-forwarded-for")),
          "x-forwarded-proto" => List.first(get_req_header(conn, "x-forwarded-proto")),
          "x-forwarded-host" => List.first(get_req_header(conn, "x-forwarded-host"))
        },
        echo_body: body
      }

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("x-backend-version", "1.0.0")
      |> send_resp(200, Jason.encode!(resp))
    end
  end

  def run do
    IO.puts("\n=== [1/7] Booting Mock Backend Upstream on port 7777 ===")
    {:ok, _backend} = Bandit.start_link(plug: BackendApp, port: 7777)
    IO.puts("-> Backend listening on http://127.0.0.1:7777")
    IO.puts("\n=== [2/7] Varco Public Listeners & Admin API (Running via Application) ===")
    http_port = 8080
    https_port = 8443
    admin_port = 9000
    IO.puts("-> Varco HTTP: #{http_port}, HTTPS: #{https_port}, Admin API: #{admin_port}")
    # Give sockets 100ms to bind
    Process.sleep(150)

    IO.puts("\n=== [3/7] Verifying Admin REST API & Dashboard ===")
    {:ok, ping_resp} = Req.get("http://127.0.0.1:#{admin_port}/api/v1/ping")
    assert(ping_resp.status == 200, "Admin API ping responded with 200")
    assert(ping_resp.body["status"] == "ok", "Admin API ping returned ok status")

    {:ok, dash_resp} = Req.get("http://127.0.0.1:#{admin_port}/dashboard")
    assert(dash_resp.status == 200, "Dashboard responded with 200")
    assert(String.contains?(dash_resp.body, "VARCO"), "Dashboard contains Varco title")

    {:ok, ca_resp} = Req.get("http://127.0.0.1:#{admin_port}/api/v1/certificates/ca")
    assert(ca_resp.status == 200, "CA Export responded with 200")
    assert(String.starts_with?(ca_resp.body, "-----BEGIN CERTIFICATE-----"), "CA is valid PEM")

    IO.puts("\n=== [4/7] Dynamically Registering Route via REST API ===")
    route_payload = %{
      "id" => "smoke-route",
      "hosts" => ["api.smoke.test"],
      "path" => "/api",
      "upstreams" => ["http://127.0.0.1:7777"],
      "tls" => true,
      "response_headers" => [
        %{"key" => "x-varco-gateway", "value" => "active"}
      ]
    }

    {:ok, create_resp} = Req.post("http://127.0.0.1:#{admin_port}/api/v1/routes", json: route_payload)
    assert(create_resp.status == 201, "Route created with 201 status")
    assert(create_resp.body["id"] == "smoke-route", "Route ID confirmed")

    IO.puts("\n=== [5/7] Testing Automatic HTTPS Redirect on HTTP port 8880 ===")
    # Plain HTTP request with Host: api.smoke.test to port 8880 should trigger 308
    {:ok, redirect_resp} = Req.get("http://127.0.0.1:#{http_port}/api/data",
      headers: [{"host", "api.smoke.test"}],
      redirect: false
    )
    assert(redirect_resp.status == 308, "HTTP request redirected with 308 Permanent Redirect")
    loc = List.first(redirect_resp.headers["location"] || [])
    assert(String.starts_with?(loc, "https://api.smoke.test"), "Location points to https")

    IO.puts("\n=== [6/7] Testing Zero-Config HTTPS with Dynamic SNI on port 8843 ===")
    # Connect directly via Erlang :ssl to verify dynamic SNI certificate generation
    {:ok, ssl_client} = :ssl.connect(~c"127.0.0.1", https_port, [
      :binary,
      active: false,
      server_name_indication: ~c"api.smoke.test",
      verify: :verify_none
    ], 3000)

    {:ok, peercert} = :ssl.peercert(ssl_client)
    {:ok, cert_struct} = X509.Certificate.from_der(peercert)
    domains = Varco.TLS.CA.extract_domains(cert_struct)
    IO.puts("-> Negotiated TLS certificate Subject Alternative Names: #{inspect(domains)}")
    assert("api.smoke.test" in domains, "Certificate dynamically issued for requested SNI domain")

    # Send HTTP/1.1 request through TLS socket
    http_req = "GET /api/v1/status HTTP/1.1\r\nHost: api.smoke.test\r\nConnection: close\r\n\r\n"
    :ok = :ssl.send(ssl_client, http_req)
    ssl_response_data = recv_all_ssl(ssl_client)
    :ssl.close(ssl_client)

    assert(String.contains?(ssl_response_data, "200 OK"), "Proxied HTTPS response status is 200 OK")
    assert(String.contains?(ssl_response_data, "Hello from backend upstream!"), "Received backend body")
    assert(String.contains?(ssl_response_data, "x-varco-gateway: active"), "Custom response header injected")

    IO.puts("\n=== [7/7] Testing ACME HTTP-01 Challenge Interception ===")
    Varco.TLS.ACME.register_challenge("smoke-token-xyz", "auth-token-abc.thumbprint", "api.smoke.test")
    {:ok, acme_resp} = Req.get("http://127.0.0.1:#{http_port}/.well-known/acme-challenge/smoke-token-xyz",
      headers: [{"host", "api.smoke.test"}],
      redirect: false
    )
    assert(acme_resp.status == 200, "ACME challenge answered with 200 OK")
    assert(acme_resp.body == "auth-token-abc.thumbprint", "ACME key authorization verified")

    IO.puts("\n=======================================================")
    IO.puts("🎉 ALL 7 SMOKE TEST SUITES PASSED FLAWLESSLY!")
    IO.puts("=======================================================\n")
  end

  defp assert(true, msg), do: IO.puts("  ✓ PASS: #{msg}")
  defp assert(false, msg), do: raise("  ✗ FAIL: #{msg}")
  defp recv_all_ssl(client, acc \\ []) do
    case :ssl.recv(client, 0, 1000) do
      {:ok, data} -> recv_all_ssl(client, [data | acc])
      {:error, _} -> Enum.reverse(acc) |> IO.iodata_to_binary()
    end
  end
end

Varco.SmokeTest.run()
