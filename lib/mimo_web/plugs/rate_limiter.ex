defmodule MimoWeb.Plugs.RateLimiter do
  @moduledoc """
  Simple rate limiting plug using ETS for request counting.

  Limits requests per IP address to prevent DoS attacks.
  Default: 60 requests per minute per IP.

  Configure via:
    config :mimo_mcp, :rate_limit_requests, 60
    config :mimo_mcp, :rate_limit_window_ms, 60_000
  """
  import Plug.Conn
  require Logger

  @default_limit 60
  @default_window_ms 60_000
  @table_name :mimo_rate_limit

  def init(opts), do: opts

  def call(conn, _opts) do
    ensure_table_exists()

    client_ip = get_client_ip(conn)
    limit = Application.get_env(:mimo_mcp, :rate_limit_requests, @default_limit)
    window_ms = Application.get_env(:mimo_mcp, :rate_limit_window_ms, @default_window_ms)

    case check_rate_limit(client_ip, limit, window_ms) do
      {:ok, count} ->
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", to_string(max(0, limit - count)))

      {:error, :rate_limited, retry_after_ms} ->
        Logger.warning("Rate limit exceeded for #{format_ip(client_ip)}")

        conn
        |> put_resp_header("x-ratelimit-limit", to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_header("retry-after", to_string(div(retry_after_ms, 1000)))
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{
          error: "Rate limit exceeded",
          limit: limit,
          window_seconds: div(window_ms, 1000),
          retry_after_seconds: div(retry_after_ms, 1000)
        })
        |> halt()
    end
  end

  @doc """
  Periodic cleanup of stale rate limit entries.
  Called by Telemetry poller to prevent unbounded ETS growth.
  """
  def cleanup_stale_entries do
    if :ets.whereis(@table_name) != :undefined do
      now = System.monotonic_time(:millisecond)
      window_ms = Application.get_env(:mimo_mcp, :rate_limit_window_ms, @default_window_ms)
      cleanup_old_entries(now, window_ms)
    end
  rescue
    # Ignore cleanup errors - table may not exist yet
    _ -> :ok
  end

  defp ensure_table_exists do
    case :ets.whereis(@table_name) do
      :undefined ->
        :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp check_rate_limit(client_ip, limit, window_ms) do
    now = System.monotonic_time(:millisecond)
    # Window bucket
    key = {client_ip, div(now, window_ms)}

    case :ets.lookup(@table_name, key) do
      [] ->
        # First request in this window
        :ets.insert(@table_name, {key, 1, now})
        cleanup_old_entries(now, window_ms)
        {:ok, 1}

      [{^key, count, _started}] when count < limit ->
        # Under limit, increment
        :ets.update_counter(@table_name, key, {2, 1})
        {:ok, count + 1}

      [{^key, count, started}] when count >= limit ->
        # Over limit
        window_end = started + window_ms
        retry_after = max(0, window_end - now)
        {:error, :rate_limited, retry_after}
    end
  end

  defp cleanup_old_entries(now, window_ms) do
    # Cleanup entries older than 2 windows (lazy cleanup)
    cutoff = div(now, window_ms) - 2

    :ets.foldl(
      fn {{_ip, window} = key, _, _}, acc ->
        if window < cutoff do
          :ets.delete(@table_name, key)
        end

        acc
      end,
      :ok,
      @table_name
    )
  rescue
    # Ignore cleanup errors
    _ -> :ok
  end

  defp get_client_ip(conn) do
    # Check X-Forwarded-For header first (for reverse proxy setups)
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        # Fall back to direct connection IP
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
end
