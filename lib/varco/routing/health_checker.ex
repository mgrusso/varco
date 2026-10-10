defmodule Varco.Routing.HealthChecker do
  @moduledoc """
  Monitors the health of configured upstream backends.

  Runs periodic health probes against active upstream targets and records
  health status in a lock-free ETS table for the load balancer.
  """

  use GenServer
  alias Varco.Routing.Table

  @table :varco_upstream_health
  @default_interval 10_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns whether an upstream URL is healthy.
  Defaults to true if no health data exists yet.
  """
  @spec healthy?(String.t()) :: boolean()
  def healthy?(upstream_url) when is_binary(upstream_url) do
    case :ets.lookup(@table, upstream_url) do
      [{^upstream_url, :unhealthy, _timestamp}] -> false
      _ -> true
    end
  catch
    _, _ -> true
  end

  @doc """
  Manually marks an upstream as healthy or unhealthy.
  """
  def set_health(upstream_url, status) when status in [:healthy, :unhealthy] do
    :ets.insert(@table, {upstream_url, status, System.system_time(:second)})
    :ok
  end

  @doc """
  Lists the health status of all recorded upstreams.
  """
  def list_health do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {upstream, status, timestamp} ->
      %{upstream: upstream, status: status, checked_at: timestamp}
    end)
  catch
    _, _ -> []
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    interval = Keyword.get(opts, :interval, @default_interval)
    enabled = Keyword.get(opts, :enabled, true)

    if enabled and interval > 0 do
      Process.send_after(self(), :check_health, interval)
    end

    {:ok, %{interval: interval, enabled: enabled}}
  end

  @impl true
  def handle_info(:check_health, state) do
    check_all_upstreams()

    if state.enabled and state.interval > 0 do
      Process.send_after(self(), :check_health, state.interval)
    end

    {:noreply, state}
  end

  # Internal Helpers

  defp check_all_upstreams do
    upstreams =
      Table.list_routes()
      |> Enum.flat_map(& &1.upstreams)
      |> Enum.uniq()

    for upstream <- upstreams do
      Task.start(fn ->
        status = probe_upstream(upstream)
        set_health(upstream, status)
      end)
    end
  end

  defp probe_upstream(upstream_url) do
    uri = URI.parse(upstream_url)
    host = uri.host || "127.0.0.1"
    port = uri.port || (if uri.scheme == "https", do: 443, else: 80)

    # Fast TCP probe with 1.5s timeout
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 1500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :healthy

      {:error, _reason} ->
        :unhealthy
    end
  rescue
    _ -> :unhealthy
  end
end
