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
  @persistent_key :varco_compiled_routes
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
  Checks if a host matches at least one configured route, wildcard, or catch-all.
  Runs in sub-microsecond time.
  """
  @spec host_configured?(String.t()) :: boolean()
  def host_configured?(host) when is_binary(host) do
    normalized_host = host |> String.downcase() |> clean_host_port()
    compiled = :persistent_term.get(@persistent_key, %{exact: %{}, wildcards: [], catchall: []})

    Map.has_key?(compiled.exact, normalized_host) or
      Enum.any?(compiled.wildcards, fn {suffix, _route} ->
        case String.split(normalized_host, ".", parts: 2) do
          [_prefix, host_suffix] when host_suffix == suffix -> true
          _ -> false
        end
      end) or
      compiled.catchall != []
  end

  def host_configured?(_), do: false

  @doc """
  Matches an incoming request by Host and Path to the best route using
  the lock-free compiled route index. Returns `%Route{}` or `nil`.
  """
  @spec match_request(String.t(), String.t()) :: Route.t() | nil
  def match_request(host, path) when is_binary(host) and is_binary(path) do
    normalized_host = host |> String.downcase() |> clean_host_port()
    compiled = :persistent_term.get(@persistent_key, %{exact: %{}, wildcards: [], catchall: []})

    # 1. Exact host candidates
    exact_candidates = Map.get(compiled.exact, normalized_host, [])

    # 2. Wildcard candidates matching normalized_host
    wildcard_candidates =
      Enum.flat_map(compiled.wildcards, fn {suffix, route} ->
        case String.split(normalized_host, ".", parts: 2) do
          [_prefix, host_suffix] when host_suffix == suffix -> [route]
          _ -> []
        end
      end)

    # 3. Match path in order of precedence: exact hosts -> wildcards -> catchall
    find_matching_path(exact_candidates, path) ||
      find_matching_path(wildcard_candidates, path) ||
      find_matching_path(compiled.catchall, path)
  end

  def match_request(_host, _path), do: nil

  defp find_matching_path(candidates, path) do
    Enum.find(candidates, &path_match?(&1, path))
  end

  # Matching Helpers

  defp clean_host_port(host) do
    case String.split(host, ":", parts: 2) do
      [h, _port] -> h
      [h] -> h
    end
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

  @impl true
  def init(_opts) do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    recompile_index()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_route, %Route{} = route}, _from, state) do
    :ets.insert(@table, {route.id, route})
    recompile_index()
    Logger.info("Added route #{route.id} for hosts: #{inspect(route.hosts)} path: #{route.path}")
    {:reply, {:ok, route}, state}
  end

  @impl true
  def handle_call({:remove_route, route_id}, _from, state) do
    case :ets.lookup(@table, route_id) do
      [{^route_id, _}] ->
        :ets.delete(@table, route_id)
        recompile_index()
        Logger.info("Removed route #{route_id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:clear_routes, _from, state) do
    :ets.delete_all_objects(@table)
    recompile_index()
    {:reply, :ok, state}
  end

  defp recompile_index do
    routes =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, r} -> r end)

    # Pre-sort routes by path specificity (exact first, then longest path)
    sorted = Enum.sort_by(routes, &route_specificity_score/1, :desc)

    acc_init = %{exact: %{}, wildcards: [], catchall: []}

    compiled =
      Enum.reduce(sorted, acc_init, fn route, acc ->
        if route.hosts == [] do
          %{acc | catchall: acc.catchall ++ [route]}
        else
          Enum.reduce(route.hosts, acc, fn host_pattern, inner_acc ->
            h_clean = host_pattern |> String.downcase() |> clean_host_port()

            if String.starts_with?(h_clean, "*.") do
              suffix = String.replace_prefix(h_clean, "*.", "")
              %{inner_acc | wildcards: inner_acc.wildcards ++ [{suffix, route}]}
            else
              updated_exact =
                Map.update(inner_acc.exact, h_clean, [route], fn list -> list ++ [route] end)

              %{inner_acc | exact: updated_exact}
            end
          end)
        end
      end)

    :persistent_term.put(@persistent_key, compiled)
  end

  defp route_specificity_score(%Route{} = route) do
    type_score = if route.path_type == :exact, do: 1000, else: 0
    type_score + String.length(route.path)
  end
end
