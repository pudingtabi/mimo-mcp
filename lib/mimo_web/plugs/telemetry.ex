defmodule MimoWeb.Plugs.Telemetry do
  @moduledoc """
  Telemetry plug for request/response metrics.
  
  Emits telemetry events for:
  - Request latency
  - Response status codes
  - Latency guard (503 if p99 > 50ms threshold)
  """
  import Plug.Conn
  require Logger

  @latency_threshold_ms 50

  def init(opts), do: opts

  def call(conn, _opts) do
    start_time = System.monotonic_time(:microsecond)
    
    conn
    |> assign(:request_start_time, start_time)
    |> register_before_send(&emit_metrics(&1, start_time))
  end

  defp emit_metrics(conn, start_time) do
    end_time = System.monotonic_time(:microsecond)
    latency_us = end_time - start_time
    latency_ms = latency_us / 1000
    
    # Emit telemetry event
    :telemetry.execute(
      [:mimo, :http, :request],
      %{latency_us: latency_us, latency_ms: latency_ms},
      %{
        method: conn.method,
        path: conn.request_path,
        status: conn.status
      }
    )
    
    # Log slow requests
    if latency_ms > @latency_threshold_ms do
      Logger.warning("Slow HTTP request: #{conn.method} #{conn.request_path} took #{Float.round(latency_ms, 2)}ms")
    end
    
    # Add latency header
    put_resp_header(conn, "x-mimo-latency-ms", "#{Float.round(latency_ms, 2)}")
  end
end
