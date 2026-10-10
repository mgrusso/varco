defmodule Varco.Routing.Table do
  @moduledoc """
  High-performance, concurrency-optimized routing table for Varco.

  Maintains proxy routes in an ETS table with `read_concurrency: true`,
  providing lock-free route resolution for every incoming request.
  """

  use GenServer
  require Logger
  alias Varco.Routing.Route

  @table :varco_routes

  # Client API

  @doc """
  Starts the Routing Table GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers or updates a route.
  Accepts either a `%Route{}` struct or a map of attributes.
  """
  @spec add_route(Route.t() | map() | keyword()) :: {:ok, Route.t()} | {:error, term()}
  def add_route(%Route{} = route) do
    GenServer.call(__MODULE__, {:add_route, route})
  end

  def add_route(attrs) when is_map(attrs) or is_list(attrs) do
    case Route.new(attrs) do
      {:ok, route} -> add_route(route)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes a route by ID.
  """
  @spec remove_route(String.t()) :: :ok | {:error, :not_found}
  def remove_route(route_id) when is_binary(route_id) do
    GenServer.call(__MODULE__, {:remove_route, route_id})
  end

  @doc """
  Retrieves a route by its ID.
  """
  @spec get_route(String.t()) :: {:ok, Route.t()} | {:error, :not_found}
  def get_route(route_id) when is_binary(route_id) do
    case :ets.lookup(@table, route_id) do
      [{^route_id, route}] -> {:ok, route}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists all active routes currently configured.
  """
  @spec list_routes() :: [Route.t()]
  def list_routes do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, route} -> route end)
  end

  @doc """
  Clears all routes from the table.
  """
  def clear_routes do
    GenServer.call(__MODULE__, :clear_routes)
  end

  @doc """
  Matches an incoming request by Host and Path to the best route.
  Returns `%Route{}` or `nil`.

  Sorting rules (most specific to least specific):
  1. Longest matching path prefix.
  2. Exact host match over wildcard host match.
  3. Wildcard host match over catch-all (empty hosts).
  """
  @spec match_request(String.t(), String.t()) :: Route.t() | nil
  def match_request(host, path) when is_binary(host) and is_binary(path) do
    normalized_host = host |> String.downcase() |> clean_host_port()
    routes = list_routes()

    routes
    |> Enum.filter(&route_matches?(&1, normalized_host, path))
    |> Enum.sort_by(&route_specificity(&1, normalized_host), :desc)
    |> List.first()
  end

  def match_request(_host, _path), do: nil

  # Matching Helpers

  defp clean_host_port(host) do
    case String.split(host, ":", parts: 2) do
      [h, _port] -> h
      [h] -> h
    end
  end

  defp route_matches?(%Route{} = route, host, path) do
    host_match?(route.hosts, host) and path_match?(route, path)
  end

  defp host_match?([], _host), do: true

  defp host_match?(hosts, host) when is_list(hosts) do
    Enum.any?(hosts, fn pattern ->
      cond do
        pattern == host ->
          true

        String.starts_with?(pattern, "*.") ->
          suffix = String.replace_prefix(pattern, "*.", "")

          case String.split(host, ".", parts: 2) do
            [_prefix, host_suffix] -> host_suffix == suffix
            _ -> false
          end

        true ->
          false
      end
    end)
  end

  defp path_match?(%Route{path_type: :exact, path: route_path}, path) do
    path == route_path
  end

  defp path_match?(%Route{path_type: :prefix, path: route_path}, path) do
    cond do
      route_path == "/" ->
        true

      path == route_path ->
        true

      String.starts_with?(path, route_path <> "/") ->
        true

      true ->
        false
    end
  end

  # Returns a tuple score for sorting by specificity
  defp route_specificity(%Route{} = route, host) do
    host_score =
      cond do
        route.hosts == [] -> 0
        Enum.any?(route.hosts, &(&1 == host)) -> 2
        true -> 1
      end

    path_length = String.length(route.path)

    {path_length, host_score}
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_route, %Route{} = route}, _from, state) do
    :ets.insert(@table, {route.id, route})
    Logger.info("Added route #{route.id} for hosts: #{inspect(route.hosts)} path: #{route.path}")
    {:reply, {:ok, route}, state}
  end

  @impl true
  def handle_call({:remove_route, route_id}, _from, state) do
    case :ets.lookup(@table, route_id) do
      [{^route_id, _}] ->
        :ets.delete(@table, route_id)
        Logger.info("Removed route #{route_id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:clear_routes, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
