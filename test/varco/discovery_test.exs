defmodule Varco.DiscoveryTest do
  use ExUnit.Case, async: false
  alias Varco.Discovery.{Docker, Kubernetes, Static}
  alias Varco.Routing.Table

  setup do
    Table.clear_routes()
    :ok
  end

  describe "Docker Discovery" do
    test "zero-config translation: infers IP and port from container metadata" do
      container = %{
        "Id" => "c1234567890abcdef",
        "Names" => ["/my-api-service"],
        "Config" => %{
          "Labels" => %{
            "varco.host" => "api.example.com"
          },
          "ExposedPorts" => %{
            "4000/tcp" => %{}
          }
        },
        "NetworkSettings" => %{
          "Networks" => %{
            "bridge" => %{
              "IPAddress" => "172.17.0.4"
            }
          }
        }
      }

      assert {:ok, route} = Docker.container_to_route(container)
      assert route.hosts == ["api.example.com"]
      assert route.upstreams == ["http://172.17.0.4:4000"]
      assert route.tls == true
      assert route.path == "/"
    end

    test "custom labels override path, port, and strip_path" do
      container = %{
        "Id" => "c9876543210fedcba",
        "Names" => ["/web-frontend"],
        "Config" => %{
          "Labels" => %{
            "varco.enable" => "true",
            "varco.host" => "dashboard.local",
            "varco.port" => "8080",
            "varco.path" => "/app",
            "varco.strip_path" => "true",
            "varco.tls" => "false"
          }
        },
        "NetworkSettings" => %{
          "IPAddress" => "10.0.1.20"
        }
      }

      assert {:ok, route} = Docker.container_to_route(container)
      assert route.hosts == ["dashboard.local"]
      assert route.upstreams == ["http://10.0.1.20:8080"]
      assert route.path == "/app"
      assert route.strip_path == true
      assert route.tls == false
    end

    test "ignores containers without varco labels" do
      container = %{
        "Id" => "unrelated123",
        "Names" => ["/redis"],
        "Config" => %{"Labels" => %{}}
      }

      assert Docker.container_to_route(container) == :ignore
    end
  end

  describe "Kubernetes Ingress Discovery" do
    test "translates Ingress spec with rules, paths and TLS" do
      ingress = %{
        "apiVersion" => "networking.k8s.io/v1",
        "kind" => "Ingress",
        "metadata" => %{
          "name" => "shop-ingress",
          "namespace" => "production",
          "annotations" => %{
            "varco.io/strip-path" => "true"
          }
        },
        "spec" => %{
          "ingressClassName" => "varco",
          "tls" => [
            %{"hosts" => ["shop.domain.tld"]}
          ],
          "rules" => [
            %{
              "host" => "shop.domain.tld",
              "http" => %{
                "paths" => [
                  %{
                    "path" => "/checkout",
                    "pathType" => "Prefix",
                    "backend" => %{
                      "service" => %{
                        "name" => "checkout-svc",
                        "port" => %{"number" => 8080}
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      assert {:ok, [route]} = Kubernetes.ingress_to_routes(ingress)
      assert route.hosts == ["shop.domain.tld"]
      assert route.path == "/checkout"
      assert route.upstreams == ["http://checkout-svc.production.svc.cluster.local:8080"]
      assert route.strip_path == true
      assert route.tls == true
    end

    test "ignores Ingress with different ingressClassName" do
      ingress = %{
        "spec" => %{"ingressClassName" => "traefik"}
      }

      assert Kubernetes.ingress_to_routes(ingress) == :ignore
    end

    test "parses annotations for timeouts and named service ports" do
      ingress = %{
        "metadata" => %{
          "name" => "timeout-ingress",
          "namespace" => "default",
          "annotations" => %{
            "varco.io/proxy-timeout" => "600000"
          }
        },
        "spec" => %{
          "ingressClassName" => "varco",
          "rules" => [
            %{
              "host" => "timeout.domain.tld",
              "http" => %{
                "paths" => [
                  %{
                    "path" => "/upload",
                    "backend" => %{
                      "service" => %{
                        "name" => "upload-svc",
                        "port" => %{"name" => "http"}
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      assert {:ok, [route]} = Kubernetes.ingress_to_routes(ingress)
      assert route.timeout == 600_000
      assert route.upstreams == ["http://upload-svc.default.svc.cluster.local:80"]
    end

    test "parses nginx proxy-read-timeout annotation as fallback" do
      ingress = %{
        "metadata" => %{
          "annotations" => %{
            "nginx.ingress.kubernetes.io/proxy-read-timeout" => "3600"
          }
        },
        "spec" => %{
          "ingressClassName" => "varco",
          "rules" => [
            %{
              "host" => "s3.domain.tld",
              "http" => %{
                "paths" => [
                  %{
                    "path" => "/",
                    "backend" => %{
                      "service" => %{
                        "name" => "s3-svc",
                        "port" => %{"number" => 9000}
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      assert {:ok, [route]} = Kubernetes.ingress_to_routes(ingress)
      assert route.timeout == 3_600_000
    end

    test "supports multi-class matching e.g. nginx,varco and wildcard *" do
      ingress_nginx = %{
        "spec" => %{
          "ingressClassName" => "nginx",
          "rules" => [
            %{
              "host" => "nginx-app.local",
              "http" => %{
                "paths" => [
                  %{
                    "path" => "/",
                    "backend" => %{
                      "service" => %{
                        "name" => "app-svc",
                        "port" => %{"number" => 80}
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      # Matches when expected is "nginx,varco"
      assert {:ok, [route]} = Kubernetes.ingress_to_routes(ingress_nginx, "nginx,varco")
      assert route.hosts == ["nginx-app.local"]

      # Matches wildcard "*"
      assert {:ok, [_]} = Kubernetes.ingress_to_routes(ingress_nginx, "*")
    end

    test "extracts TLS secret references from Ingress spec" do
      ingress = %{
        "metadata" => %{"namespace" => "staging"},
        "spec" => %{
          "tls" => [
            %{"hosts" => ["app.staging.tld"], "secretName" => "app-cert-secret"},
            %{"hosts" => ["api.staging.tld"]}
          ]
        }
      }

      secrets = Kubernetes.extract_tls_secrets(ingress)
      assert length(secrets) == 1

      assert List.first(secrets) == %{
               namespace: "staging",
               secret_name: "app-cert-secret",
               hosts: ["app.staging.tld"]
             }
    end

    test "synchronizes Ingresses from K8s API and loads cert-manager TLS Secrets" do
      alias Varco.TLS.{CA, CertificateStore}

      {:ok, {ca_cert, ca_key}} = CA.generate_root_ca()
      {:ok, {srv_cert, srv_key}} = CA.issue_server_cert(ca_cert, ca_key, "k8s-synced.example.com")
      cert_pem = CA.to_pem(srv_cert)
      key_pem = CA.to_pem(srv_key)

      ingress_data = %{
        "apiVersion" => "networking.k8s.io/v1",
        "kind" => "IngressList",
        "items" => [
          %{
            "apiVersion" => "networking.k8s.io/v1",
            "kind" => "Ingress",
            "metadata" => %{
              "name" => "web-ingress",
              "namespace" => "production"
            },
            "spec" => %{
              "ingressClassName" => "varco",
              "tls" => [
                %{
                  "hosts" => ["k8s-synced.example.com"],
                  "secretName" => "web-tls-secret"
                }
              ],
              "rules" => [
                %{
                  "host" => "k8s-synced.example.com",
                  "http" => %{
                    "paths" => [
                      %{
                        "path" => "/app",
                        "backend" => %{
                          "service" => %{
                            "name" => "web-service",
                            "port" => %{"number" => 8080}
                          }
                        }
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }

      secret_data = %{
        "apiVersion" => "v1",
        "kind" => "Secret",
        "type" => "kubernetes.io/tls",
        "metadata" => %{
          "name" => "web-tls-secret",
          "namespace" => "production"
        },
        "data" => %{
          "tls.crt" => Base.encode64(cert_pem),
          "tls.key" => Base.encode64(key_pem)
        }
      }

      # Mock K8s API server using Bandit
      {:ok, k8s_mock} =
        Bandit.start_link(
          plug: fn conn, _opts ->
            case conn.request_path do
              "/apis/networking.k8s.io/v1/ingresses" ->
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(200, Jason.encode!(ingress_data))

              "/api/v1/namespaces/production/secrets/web-tls-secret" ->
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(200, Jason.encode!(secret_data))

              _ ->
                conn |> Plug.Conn.send_resp(404, "Not Found")
            end
          end,
          port: 0
        )

      listener = ThousandIsland.Server.listener_pid(k8s_mock)
      {_, mock_port} = ThousandIsland.Listener.listener_info(listener)

      sync_state = %{
        enabled: true,
        api_url: "http://127.0.0.1:#{mock_port}",
        token: "mock-k8s-bearer-token",
        ca_cert_path: nil,
        insecure_skip_tls_verify: true,
        ingress_class: "varco",
        interval: 10_000,
        last_sync: nil,
        last_error: nil
      }

      assert {:ok, result, _new_state} = Kubernetes.perform_sync(sync_state)
      assert result.routes_count == 1
      assert result.tls_secrets_count == 1

      # Verify route was installed in Table
      route = Table.match_request("k8s-synced.example.com", "/app")
      assert route != nil
      assert route.id == "k8s-production-web-ingress-r0-p0"
      assert route.upstreams == ["http://web-service.production.svc.cluster.local:8080"]

      # Verify TLS secret was installed in CertificateStore
      cert_info = CertificateStore.lookup_cert("k8s-synced.example.com")
      assert cert_info != nil
      assert "k8s-synced.example.com" in cert_info.domains
      assert cert_info.type == :custom
    end
  end

  describe "Static File / String Discovery" do
    test "loads routes from YAML" do
      yaml = """
      routes:
        - id: static-api
          host: static.example.com
          path: /api
          upstreams:
            - http://127.0.0.1:5000
          tls: true
      """

      assert {:ok, 1} = Static.load_string(yaml, :yaml)
      assert {:ok, route} = Table.get_route("static-api")
      assert route.hosts == ["static.example.com"]
      assert route.upstreams == ["http://127.0.0.1:5000"]
    end
  end
end
