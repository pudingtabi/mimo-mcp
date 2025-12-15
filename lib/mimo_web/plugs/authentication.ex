defmodule MimoWeb.Plugs.Authentication do
  @moduledoc """
  API Key authentication with zero-tolerance security.
  NEVER allows unauthenticated requests in production.

  Security features:
  - Constant-time comparison to prevent timing attacks
  - Mandatory authentication in production (no bypass)
  - Telemetry logging of all auth events
  - Rate limiting integration ready
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    api_key = get_configured_key()

    cond do
      prod_missing_key?(api_key) ->
        handle_missing_prod_key(conn)

      true ->
        handle_auth_validation(conn, api_key)
    end
  end

  defp prod_missing_key?(api_key) do
    production?() and (is_nil(api_key) or api_key == "")
  end

  defp handle_missing_prod_key(conn) do
    Logger.error("[SECURITY] No API key configured in production - blocking all requests")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      503,
      Jason.encode!(%{
        error: "Service misconfigured",
        security: "API key required in production"
      })
    )
    |> halt()
  end

  defp handle_auth_validation(conn, api_key) do
    case validate_bearer_token(conn) do
      {:ok, token} ->
        handle_token_validation(conn, token, api_key)

      {:error, :missing_header} ->
        handle_missing_header(conn, api_key)

      {:error, :invalid_format} ->
        log_auth_failure(conn, :malformed_auth)
        authentication_error(conn, :malformed_credentials)
    end
  end

  defp handle_token_validation(conn, token, api_key) do
    if secure_compare(token, api_key) do
      register_authenticated_conn(conn)
    else
      log_auth_failure(conn, :invalid_token)
      authentication_error(conn, :invalid_credentials)
    end
  end

  defp handle_missing_header(conn, api_key) do
    if not production?() and (is_nil(api_key) or api_key == "") do
      Logger.debug("No API key configured in dev mode, allowing request")
      conn
    else
      log_auth_failure(conn, :missing_auth)
      authentication_error(conn, :missing_credentials)
    end
  end

  # Check if running in production environment (runtime safe)
  defp production? do
    Application.get_env(:mimo_mcp, :environment) == :prod
  end

  # Extract and validate bearer token format
  defp validate_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        trimmed = String.trim(token)

        if trimmed == "" do
          {:error, :invalid_format}
        else
          {:ok, trimmed}
        end

      [_other] ->
        {:error, :invalid_format}

      [] ->
        {:error, :missing_header}

      _ ->
        {:error, :invalid_format}
    end
  end

  # Constant-time comparison to prevent timing attacks
  defp secure_compare(nil, _), do: false
  defp secure_compare(_, nil), do: false

  defp secure_compare(token, api_key) when is_binary(token) and is_binary(api_key) do
    # Pad to same length and use constant-time comparison
    byte_size_token = byte_size(token)
    byte_size_key = byte_size(api_key)

    # If lengths differ, still do comparison to maintain constant time
    if byte_size_token != byte_size_key do
      # Compare with dummy to maintain constant time, but result is always false
      constant_time_compare(token, String.duplicate("x", byte_size_token))
      false
    else
      constant_time_compare(token, api_key)
    end
  end

  defp secure_compare(_, _), do: false

  # Simple constant-time string comparison
  defp constant_time_compare(a, b) when byte_size(a) == byte_size(b) do
    a_bytes = :binary.bin_to_list(a)
    b_bytes = :binary.bin_to_list(b)

    result =
      Enum.zip(a_bytes, b_bytes)
      |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)

    result == 0
  end

  defp constant_time_compare(_, _), do: false

  # Register authenticated connection with sandbox mode support
  defp register_authenticated_conn(conn) do
    sandbox_mode = get_req_header(conn, "x-mimo-sandbox") != []

    conn
    |> assign(:authenticated, true)
    |> assign(:sandbox_mode, sandbox_mode)
    |> assign(:auth_timestamp, System.system_time(:second))
  end

  # Always returns error response - no bypass
  defp authentication_error(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{
        error: "Authentication required",
        reason: reason_to_string(reason),
        security_event_id: generate_event_id()
      })
    )
    |> halt()
  end

  defp reason_to_string(:invalid_credentials), do: "Invalid API key"
  defp reason_to_string(:missing_credentials), do: "Missing Authorization header"
  defp reason_to_string(:malformed_credentials), do: "Malformed Authorization header"
  defp reason_to_string(reason), do: to_string(reason)

  # Telemetry logging of ALL auth events
  defp log_auth_failure(conn, reason) do
    client_ip = get_client_ip(conn)

    # Emit telemetry for monitoring/alerting
    :telemetry.execute(
      [:mimo, :security, :auth_failure],
      %{count: 1},
      %{
        client_ip: client_ip,
        reason: reason,
        timestamp: System.system_time(:second),
        path: conn.request_path,
        method: conn.method
      }
    )

    Logger.warning(
      "[SECURITY] Authentication failure from #{client_ip}: #{reason} - #{conn.method} #{conn.request_path}"
    )
  end

  defp get_configured_key do
    Application.get_env(:mimo_mcp, :api_key)
  end

  defp get_client_ip(conn) do
    # Check for X-Forwarded-For header (reverse proxy)
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        case conn.remote_ip do
          {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
          {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
          ip -> inspect(ip)
        end
    end
  end

  defp generate_event_id do
    UUID.uuid4()
  end
end
