defmodule Varco.Discovery.Static do
  @moduledoc """
  Static file configuration provider for Varco.

  Loads routes and TLS definitions from declarative YAML (`varco.yaml`) or JSON (`varco.json`) files.
  """

  require Logger
  alias Varco.Routing.{Route, Table}
  alias Varco.Cluster.Sync

  @doc """
  Loads and applies configuration from a file path (supports .yaml, .yml, .json).
  """
  @spec load_file(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load_file(path) do
    if File.exists?(path) do
      content = File.read!(path)

      format =
        cond do
          String.ends_with?(path, [".yaml", ".yml"]) -> :yaml
          String.ends_with?(path, ".json") -> :json
          true -> :yaml
        end

      load_string(content, format)
    else
      {:error, :file_not_found}
    end
  end

  @doc """
  Parses a YAML or JSON configuration string and registers routes.
  """
  @spec load_string(String.t(), :yaml | :json) :: {:ok, non_neg_integer()} | {:error, term()}
  def load_string(content, format) do
    parsed_result =
      case format do
        :yaml -> YamlElixir.read_from_string(content)
        :json -> Jason.decode(content)
      end

    case parsed_result do
      {:ok, %{"routes" => routes_list}} when is_list(routes_list) ->
        count = load_routes(routes_list)
        {:ok, count}

      {:ok, %{routes: routes_list}} when is_list(routes_list) ->
        count = load_routes(routes_list)
        {:ok, count}

      {:ok, _} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_routes(routes_list) do
    loaded =
      for raw_route <- routes_list do
        case Route.new(raw_route) do
          {:ok, route} ->
            Table.add_route(route)
            Sync.broadcast_route_upsert(route)
            1

          {:error, reason} ->
            Logger.warning("Failed to parse static route: #{inspect(reason)}")
            0
        end
      end

    Enum.sum(loaded)
  end
end
