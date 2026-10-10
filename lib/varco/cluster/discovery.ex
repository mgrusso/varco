defmodule Varco.Cluster.Discovery do
  @moduledoc """
  Configures automatic BEAM node clustering using `libcluster`.

  Supports Kubernetes DNS, Multicast Gossip, and local EPMD topologies.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    strategy =
      System.get_env("VARCO_CLUSTER_STRATEGY", "none")
      |> String.downcase()
      |> String.trim()

    topologies = build_topologies(strategy)

    children =
      if topologies != [] do
        [{Cluster.Supervisor, [topologies, [name: Varco.ClusterSupervisor]]}]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_topologies("kubernetes") do
    service = System.get_env("VARCO_K8S_SERVICE_NAME", "varco-headless")
    app_name = System.get_env("VARCO_K8S_APP_NAME", "varco")

    [
      k8s: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [
          service: service,
          application_name: app_name,
          polling_interval: 5_000
        ]
      ]
    ]
  end

  defp build_topologies("gossip") do
    [
      gossip: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: 45892,
          if_addr: "0.0.0.0",
          multicast_addr: "230.1.1.251",
          broadcast_only: true
        ]
      ]
    ]
  end

  defp build_topologies("epmd") do
    [
      epmd: [
        strategy: Cluster.Strategy.Epmd,
        config: [
          hosts:
            System.get_env("VARCO_CLUSTER_HOSTS", "127.0.0.1")
            |> String.split(",")
            |> Enum.map(&String.to_atom(String.trim(&1)))
        ]
      ]
    ]
  end

  defp build_topologies(_none), do: []
end
