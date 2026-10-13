defmodule Varco.Proxy.WebSocketHandler do
  @moduledoc """
  Bridges client WebSocket connections (handled by Bandit) with upstream WebSocket servers
  using Mint.WebSocket.

  Implements the `WebSock` behaviour to enable transparent, low-latency, bidirectional
  WebSocket proxying for web applications like Authentik, Livebook, Grafana, and generic WS endpoints.
  """

  @behaviour WebSock
  require Logger

  @impl WebSock
  def init(state) do
    {:ok, state}
  end

  @impl WebSock
  def handle_in({msg, opcode: opcode}, state) do
    frame =
      case opcode do
        :text -> {:text, msg}
        :binary -> {:binary, msg}
      end

    case Mint.WebSocket.encode(state.ws, frame) do
      {:ok, ws, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, ws: ws}}

          {:error, conn, reason} ->
            Logger.warning("Error streaming frame to upstream WebSocket: #{inspect(reason)}")
            {:stop, reason, %{state | conn: conn, ws: ws}}
        end

      {:error, ws, reason} ->
        Logger.warning("Error encoding frame to upstream WebSocket: #{inspect(reason)}")
        {:stop, reason, %{state | ws: ws}}
    end
  end

  @impl WebSock
  def handle_control({msg, opcode: opcode}, state) do
    frame =
      case opcode do
        :ping -> {:ping, msg}
        :pong -> {:pong, msg}
      end

    case Mint.WebSocket.encode(state.ws, frame) do
      {:ok, ws, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, ws: ws}}

          {:error, conn, reason} ->
            {:stop, reason, %{state | conn: conn, ws: ws}}
        end

      {:error, ws, reason} ->
        {:stop, reason, %{state | ws: ws}}
    end
  end

  @impl WebSock
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, entries} ->
        {ws, pushes, should_close} = process_mint_entries(state.ws, state.ref, entries)
        new_state = %{state | conn: conn, ws: ws}

        cond do
          should_close ->
            {:stop, :normal, new_state}

          pushes != [] ->
            {:push, pushes, new_state}

          true ->
            {:ok, new_state}
        end

      {:error, _conn, reason, _} ->
        {:stop, reason, state}

      :unknown ->
        {:ok, state}
    end
  end

  @impl WebSock
  def terminate(_reason, state) do
    if Map.get(state, :conn) do
      Mint.HTTP.close(state.conn)
    end

    :ok
  end

  # Helpers

  defp process_mint_entries(ws, ref, entries) do
    Enum.reduce(entries, {ws, [], false}, fn
      {:data, ^ref, data}, {current_ws, acc_pushes, _} ->
        case Mint.WebSocket.decode(current_ws, data) do
          {:ok, next_ws, frames} ->
            {converted, is_close} = convert_frames(frames)
            {next_ws, acc_pushes ++ converted, is_close}

          {:error, next_ws, _reason} ->
            {next_ws, acc_pushes, true}
        end

      {:done, ^ref}, {current_ws, acc_pushes, _} ->
        {current_ws, acc_pushes, true}

      {:error, ^ref, _reason}, {current_ws, acc_pushes, _} ->
        {current_ws, acc_pushes, true}

      _other, acc ->
        acc
    end)
  end

  defp convert_frames(frames) do
    Enum.reduce(frames, {[], false}, fn
      {:text, text}, {acc, close?} ->
        {acc ++ [{:text, text}], close?}

      {:binary, bin}, {acc, close?} ->
        {acc ++ [{:binary, bin}], close?}

      {:ping, data}, {acc, close?} ->
        {acc ++ [{:ping, data}], close?}

      :ping, {acc, close?} ->
        {acc ++ [:ping], close?}

      {:pong, data}, {acc, close?} ->
        {acc ++ [{:pong, data}], close?}

      :pong, {acc, close?} ->
        {acc ++ [:pong], close?}

      {:close, code, reason}, {acc, _} ->
        detail = if code, do: {code, reason || ""}, else: nil
        close_frame = if detail, do: {:close, code, reason || ""}, else: {:close, 1000, ""}
        {acc ++ [close_frame], true}
    end)
  end
end
