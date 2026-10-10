defmodule Varco.Routing.LoadBalancer do
  @moduledoc """
  Balances traffic across healthy upstream backend targets.

  Supports Round-Robin and Random algorithms with lock-free atomic counters
  and automatic health check integration.
  """

  alias Varco.Routing.Route
  alias Varco.Routing.HealthChecker

  @lb_counters :varco_lb_counters

  @doc """
  Initializes load balancer tables.
  """
  def init_table do
    if :ets.info(@lb_counters) == :undefined do
      :ets.new(@lb_counters, [:set, :public, :named_table, write_concurrency: true])
    end

    :ok
  end

  @doc """
  Selects the next target upstream URL for a route.
  """
  @spec select_upstream(Route.t()) :: {:ok, String.t()} | {:error, :no_upstreams}
  def select_upstream(%Route{upstreams: []}), do: {:error, :no_upstreams}

  def select_upstream(%Route{upstreams: [single]}), do: {:ok, single}

  def select_upstream(%Route{id: id, upstreams: upstreams, load_balancer: policy}) do
    # Filter healthy upstreams
    healthy =
      Enum.filter(upstreams, fn u ->
        HealthChecker.healthy?(u)
      end)

    # Graceful fallback: if all marked unhealthy, try all
    candidates = if healthy == [], do: upstreams, else: healthy

    selected =
      case policy do
        :random ->
          Enum.random(candidates)

        :round_robin ->
          round_robin_select(id, candidates)

        _ ->
          round_robin_select(id, candidates)
      end

    {:ok, selected}
  end

  defp round_robin_select(route_id, candidates) do
    count = length(candidates)

    idx =
      try do
        :ets.update_counter(@lb_counters, route_id, {2, 1}, {route_id, -1})
      catch
        _, _ ->
          init_table()
          :ets.update_counter(@lb_counters, route_id, {2, 1}, {route_id, -1})
      end

    Enum.at(candidates, rem(abs(idx), count))
  end
end
