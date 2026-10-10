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
