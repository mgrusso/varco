defmodule Varco.Server do
  @moduledoc """
  Manages HTTP and HTTPS listeners for the Varco reverse proxy.

  Leverages Bandit on Thousand Island with pure Elixir concurrency and
  zero-config TLS with dynamic SNI.
  """

  use Supervisor
  require Logger
  alias Varco.Proxy.Handler
  alias Varco.TLS.CertificateStore

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    http_port = Keyword.get(opts, :http_port, 8080)
    https_port = Keyword.get(opts, :https_port, 8443)
    enable_https = Keyword.get(opts, :enable_https, true)
    enable_http = Keyword.get(opts, :enable_http, true)

    children = []

    children =
      if enable_http do
        http_spec =
          {Bandit,
           plug: Handler,
           scheme: :http,
           port: http_port,
           thousand_island_options: [
             num_acceptors: 100
           ]}

        [http_spec | children]
      else
        children
      end

    children =
      if enable_https do
        default_opts = CertificateStore.default_cert_options()

        https_spec =
          {Bandit,
           plug: Handler,
           scheme: :https,
           port: https_port,
           thousand_island_options: [
             num_acceptors: 100,
             transport_options:
               default_opts ++
                 [
                   sni_fun: &CertificateStore.sni_fun/1
                 ]
           ]}

        [https_spec | children]
      else
        children
      end

    Logger.info("Varco listeners configured: HTTP port #{http_port}, HTTPS port #{https_port}")
    Supervisor.init(children, strategy: :one_for_one)
  end
end
