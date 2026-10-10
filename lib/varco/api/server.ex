defmodule Varco.API.Server do
  @moduledoc """
  Supervises the dedicated administrative HTTP server for Varco's REST API and Dashboard.
  """

  use Supervisor
  require Logger
  alias Varco.API.Router

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    admin_port = Keyword.get(opts, :admin_port, 9000)
    enabled = Keyword.get(opts, :enabled, true)

    children =
      if enabled do
        [
          {Bandit,
           plug: Router,
           scheme: :http,
           port: admin_port,
           thousand_island_options: [
             num_acceptors: 20
           ]}
        ]
      else
        []
      end

    Logger.info("Varco Admin API & Dashboard configured on port #{admin_port}")
    Supervisor.init(children, strategy: :one_for_one)
  end
end
