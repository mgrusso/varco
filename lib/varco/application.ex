defmodule Varco.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Load environment configuration
    http_port = get_env_int("VARCO_HTTP_PORT", 8080)
    https_port = get_env_int("VARCO_HTTPS_PORT", 8443)
    admin_port = get_env_int("VARCO_ADMIN_PORT", 9000)
    start_servers = Application.get_env(:varco, :start_servers, default_start_servers?())

    base_children = [
      # Core TLS Certificate Store & Local CA
      {Varco.TLS.CertificateStore, auto_self_signed: true},
      # Routing Table
      Varco.Routing.Table,
      # Upstream Health Checker
      Varco.Routing.HealthChecker,
      # Outgoing Finch connection pool for proxying
      {Finch, name: Varco.Finch},
      # Cluster Synchronization & Node discovery
      Varco.Cluster.Sync,
      Varco.Cluster.Discovery,
      # Service Discovery Watchers
      Varco.Discovery.Docker,
      Varco.Discovery.Kubernetes
    ]

    server_children =
      if start_servers do
        [
          {Varco.Server, http_port: http_port, https_port: https_port},
          {Varco.API.Server, admin_port: admin_port}
        ]
      else
        []
      end

    children = base_children ++ server_children

    opts = [strategy: :one_for_one, name: Varco.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Load static config file if present
        load_static_config_if_exists()
        {:ok, pid}

      error ->
        error
    end
  end

  defp default_start_servers? do
    System.get_env("VARCO_START_SERVERS") not in ["false", "0"] and
      Mix.env() != :test
  rescue
    _ -> true
  end
  defp get_env_int(key, default) do
    case System.get_env(key) do
      nil -> default
      val ->
        case Integer.parse(val) do
          {num, ""} -> num
          _ -> default
        end
    end
  end

  defp load_static_config_if_exists do
    config_path = System.get_env("VARCO_CONFIG", "varco.yaml")

    if File.exists?(config_path) do
      Logger.info("Loading initial configuration from #{config_path}")
      Varco.Discovery.Static.load_file(config_path)
    end
  end
end
