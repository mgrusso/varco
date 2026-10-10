defmodule Varco.Cluster.Sync do
  @moduledoc """
  Manages distributed cluster synchronization across BEAM nodes.

  Leverages Erlang `:pg` process groups to broadcast route updates,
  ACME challenge tokens, and perform zero-touch state hydration when nodes join.
  """

  use GenServer
  require Logger

  alias Varco.Routing.{Route, Table}
  alias Varco.TLS.CertificateStore

  @pg_group :varco_sync_nodes

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Broadcasts a route update across all connected BEAM nodes in the cluster.
  """
  def broadcast_route_upsert(%Route{} = route) do
    broadcast({:route_upsert, route})
  end

  @doc """
  Broadcasts a route deletion across all connected BEAM nodes in the cluster.
  """
  def broadcast_route_delete(route_id) when is_binary(route_id) do
    broadcast({:route_delete, route_id})
  end

  @doc """
  Broadcasts an ACME HTTP-01 challenge token across the cluster.
  Enables any node in the cluster to answer Let's Encrypt challenges.
  """
  def broadcast_acme_challenge(token, key_auth, domain \\ nil) do
    broadcast({:acme_challenge, token, key_auth, domain})
  end

  @doc """
  Lists all connected peer nodes in the cluster.
  """
  def cluster_nodes do
    Node.list()
  end

  @doc """
  Returns the current cluster membership and health overview.
  """
  def status do
    %{
      current_node: Node.self(),
      peers: Node.list(),
      node_count: length(Node.list()) + 1,
      is_clustered: Node.list() != []
    }
  end

  defp broadcast(msg) do
    # Local dispatch
    handle_broadcast_message(msg)

    # Remote dispatch to all peers in the pg group
    pids = :pg.get_members(@pg_group)

    for pid <- pids, node(pid) != Node.self() do
      send(pid, {:cluster_event, msg})
    end

    :ok
  catch
    _, _ -> :ok
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Ensure :pg is started (standard in OTP 23+)
    try do
      :pg.start_link()
    catch
      _, _ -> :ok
    end

    :pg.join(@pg_group, self())

    # Monitor node connect/disconnect events
    :net_kernel.monitor_nodes(true)

    # Request snapshot from any existing peer if clustered
    hydrate_from_cluster()

    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Cluster peer connected: #{inspect(node)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("Cluster peer disconnected: #{inspect(node)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:cluster_event, msg}, state) do
    handle_broadcast_message(msg)
    {:noreply, state}
  end

  @impl true
  def handle_info({:request_snapshot, from_pid}, state) do
    routes = Table.list_routes()
    send(from_pid, {:snapshot_data, routes})
    {:noreply, state}
  end

  @impl true
  def handle_info({:snapshot_data, routes}, state) do
    Logger.info("Received cluster state snapshot with #{length(routes)} routes")

    for %Route{} = r <- routes do
      Table.add_route(r)
    end

    {:noreply, state}
  end

  # Internal Helpers

  defp handle_broadcast_message({:route_upsert, %Route{} = route}) do
    # Direct ETS insert to avoid redundant broadcast loops
    :ets.insert(:varco_routes, {route.id, route})
  end

  defp handle_broadcast_message({:route_delete, route_id}) do
    :ets.delete(:varco_routes, route_id)
  end

  defp handle_broadcast_message({:acme_challenge, token, key_auth, domain}) do
    CertificateStore.put_acme_challenge(token, key_auth, domain)
  end

  defp handle_broadcast_message(_), do: :ok

  defp hydrate_from_cluster do
    case Node.list() do
      [peer | _] ->
        pids = :pg.get_members(@pg_group)
        peer_pid = Enum.find(pids, fn pid -> node(pid) == peer end)

        if peer_pid do
          send(peer_pid, {:request_snapshot, self()})
        end

      [] ->
        :ok
    end
  end
end
