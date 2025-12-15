defmodule MimoWeb.Plugs.RateLimiter do
  @moduledoc """
  Simple rate limiting plug using ETS for request counting.

  Limits requests per IP address to prevent DoS attacks.
  Default: 60 requests per minute per IP.

  Configure via:
    config :mimo_mcp, :rate_limit_requests, 60
    config :mimo_mcp, :rate_limit_window_ms, 60_000
    config :mimo_mcp, :trust_proxy_headers, false  # SECURITY: Only enable behind trusted reverse proxy
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
        try do
          Mimo.EtsSafe.ensure_table(@table_name, [
            :set,
            :public,
            :named_table,
            read_concurrency: true
          ])
        rescue
          # Concurrent requests may race to create the same named table.
          ArgumentError ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp check_rate_limit(client_ip, limit, window_ms) do
    now = System.monotonic_time(:millisecond)
    # Window bucket
    key = {client_ip, div(now, window_ms)}

    try do
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
    rescue
      # If the ETS table isn't ready yet (e.g. early boot / race), create it and retry once.
      ArgumentError ->
        ensure_table_exists()

        case :ets.lookup(@table_name, key) do
          [] ->
            :ets.insert(@table_name, {key, 1, now})
            cleanup_old_entries(now, window_ms)
            {:ok, 1}

          [{^key, count, _started}] when count < limit ->
            :ets.update_counter(@table_name, key, {2, 1})
            {:ok, count + 1}

          [{^key, count, started}] when count >= limit ->
            window_end = started + window_ms
            retry_after = max(0, window_end - now)
            {:error, :rate_limited, retry_after}
        end
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

  # SECURITY: Only trust X-Forwarded-For if explicitly configured
  # Attacker can spoof this header to bypass rate limiting
  defp get_client_ip(conn) do
    trust_proxy = Application.get_env(:mimo_mcp, :trust_proxy_headers, false)

    if trust_proxy do
      get_forwarded_ip(conn) || get_direct_ip(conn)
    else
      get_direct_ip(conn)
    end
  end

  defp get_forwarded_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        # Take first IP (original client) from comma-separated list
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()
        |> validate_ip_format()

      [] ->
        nil
    end
  end

  defp get_direct_ip(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  # Basic IP format validation to prevent header injection
  defp validate_ip_format(ip_str) do
    # Only accept valid-looking IPv4 or IPv6 addresses
    cond do
      Regex.match?(~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, ip_str) -> ip_str
      Regex.match?(~r/^[a-fA-F0-9:]+$/, ip_str) -> ip_str
      true -> nil
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
end
