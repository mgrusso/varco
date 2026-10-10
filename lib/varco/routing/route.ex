defmodule Varco.Routing.Route do
  @moduledoc """
  Defines a Varco reverse proxy route configuration.

  A route maps an incoming HTTP/HTTPS request (by Host header and Path)
  to one or more upstream backend servers with load balancing and TLS policies.
  """

  @enforce_keys [:id, :upstreams]
  defstruct id: nil,
            hosts: [],
            path: "/",
            path_type: :prefix,
            upstreams: [],
            strip_path: false,
            tls: true,
            load_balancer: :round_robin,
            request_headers: [],
            response_headers: [],
            metadata: %{}

  @type t :: %__MODULE__{
          id: String.t(),
          hosts: [String.t()],
          path: String.t(),
          path_type: :prefix | :exact,
          upstreams: [String.t()],
          strip_path: boolean(),
          tls: boolean(),
          load_balancer: :round_robin | :random,
          request_headers: [{String.t(), String.t()}],
          response_headers: [{String.t(), String.t()}],
          metadata: map()
        }

  @doc """
  Constructs and normalizes a new Route struct from a map or keyword list.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Enum.into(%{}) |> new()

  def new(%{} = attrs) do
    id = get_string(attrs, :id) || get_string(attrs, "id") || generate_id()

    upstreams =
      get_list(attrs, :upstreams) ||
        get_list(attrs, "upstreams") ||
        (case get_string(attrs, :upstream) || get_string(attrs, "upstream") do
           nil -> []
           single -> [single]
         end)

    if upstreams == [] do
      {:error, :missing_upstreams}
    else
      hosts = normalize_hosts(attrs)
      path = get_string(attrs, :path) || get_string(attrs, "path") || "/"
      path = if String.starts_with?(path, "/"), do: path, else: "/" <> path

      path_type =
        case get_val(attrs, :path_type) || get_val(attrs, "path_type") do
          "exact" -> :exact
          :exact -> :exact
          _ -> :prefix
        end

      strip_path = get_bool(attrs, :strip_path, false)
      tls = get_bool(attrs, :tls, true)

      load_balancer =
        case get_val(attrs, :load_balancer) || get_val(attrs, "load_balancer") do
          "random" -> :random
          :random -> :random
          _ -> :round_robin
        end

      normalized_upstreams = Enum.map(upstreams, &normalize_upstream_url/1)

      route = %__MODULE__{
        id: to_string(id),
        hosts: hosts,
        path: path,
        path_type: path_type,
        upstreams: normalized_upstreams,
        strip_path: strip_path,
        tls: tls,
        load_balancer: load_balancer,
        request_headers: get_headers(attrs, :request_headers),
        response_headers: get_headers(attrs, :response_headers),
        metadata: get_map(attrs, :metadata)
      }

      {:ok, route}
    end
  end

  defp normalize_hosts(attrs) do
    raw =
      get_list(attrs, :hosts) ||
        get_list(attrs, "hosts") ||
        (case get_string(attrs, :host) || get_string(attrs, "host") do
           nil -> []
           single -> [single]
         end)

    raw
    |> Enum.map(&String.downcase(to_string(&1)))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_upstream_url(url) when is_binary(url) do
    url = String.trim(url)

    if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
      url
    else
      "http://" <> url
    end
  end

  defp get_string(map, key) do
    case Map.get(map, key) do
      val when is_binary(val) and val != "" -> String.trim(val)
      val when is_atom(val) and val != nil -> Atom.to_string(val)
      _ -> nil
    end
  end

  defp get_list(map, key) do
    case Map.get(map, key) do
      list when is_list(list) -> list
      val when is_binary(val) -> String.split(val, ",") |> Enum.map(&String.trim/1)
      _ -> nil
    end
  end

  defp get_bool(map, key, default) do
    val =
      cond do
        Map.has_key?(map, key) -> Map.get(map, key)
        Map.has_key?(map, to_string(key)) -> Map.get(map, to_string(key))
        true -> default
      end

    case val do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp get_val(map, key), do: Map.get(map, key)

  defp get_headers(map, key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      list when is_list(list) ->
        Enum.map(list, fn
          {k, v} -> {to_string(k), to_string(v)}
          %{key: k, value: v} -> {to_string(k), to_string(v)}
          %{"key" => k, "value" => v} -> {to_string(k), to_string(v)}
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      map when is_map(map) ->
        Enum.map(map, fn {k, v} -> {to_string(k), to_string(v)} end)

      _ ->
        []
    end
  end

  defp get_map(map, key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp generate_id do
    "route-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end
end
