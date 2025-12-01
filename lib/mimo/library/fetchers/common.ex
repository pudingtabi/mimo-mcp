defmodule Mimo.Library.Fetchers.Common do
  @moduledoc """
  Common utilities for library fetchers.

  Provides:
  - HTTP request helpers with retry logic
  - Rate limiting support
  - Common error handling
  """

  require Logger

  @default_retries 3
  @base_delay_ms 500
  @max_delay_ms 5000

  # Errors worth retrying
  @retryable_errors [:timeout, :connect_timeout, :econnrefused, :closed, :nxdomain]
  @retryable_statuses [429, 500, 502, 503, 504]

  @doc """
  Make an HTTP GET request with automatic retry on transient failures.

  ## Options
  - `:retries` - Number of retries (default: 3)
  - `:headers` - Additional headers
  - `:timeout` - Request timeout in ms (default: 15000)
  - `:decode_body` - Whether to decode response body (default: true)
  """
  @spec http_get(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def http_get(url, opts \\ []) do
    retries = Keyword.get(opts, :retries, @default_retries)
    headers = Keyword.get(opts, :headers, [])
    timeout = Keyword.get(opts, :timeout, 15_000)
    decode_body = Keyword.get(opts, :decode_body, true)

    req_opts = [
      headers: headers,
      receive_timeout: timeout,
      decode_body: decode_body
    ]

    do_request_with_retry(url, req_opts, retries, 0)
  end

  @doc """
  Make an HTTP GET request expecting JSON response.
  """
  @spec http_get_json(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def http_get_json(url, opts \\ []) do
    headers = [{"Accept", "application/json"}, {"User-Agent", "Mimo/1.0"}]
    opts = Keyword.update(opts, :headers, headers, &(headers ++ &1))

    case http_get(url, opts) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:error, :json_parse_error}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Make an HTTP GET request expecting HTML response.
  """
  @spec http_get_html(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def http_get_html(url, opts \\ []) do
    headers = [{"Accept", "text/html"}, {"User-Agent", "Mimo/1.0"}]
    opts = Keyword.update(opts, :headers, headers, &(headers ++ &1))

    case http_get(url, opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Make an HTTP GET request expecting text/plain response.
  """
  @spec http_get_text(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def http_get_text(url, opts \\ []) do
    headers = [
      {"Accept", "text/plain, application/javascript, application/typescript"},
      {"User-Agent", "Mimo/1.0"}
    ]

    opts = Keyword.update(opts, :headers, headers, &(headers ++ &1))

    case http_get(url, opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Make an HTTP GET request expecting binary response.
  """
  @spec http_get_binary(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def http_get_binary(url, opts \\ []) do
    headers = [{"Accept", "*/*"}, {"User-Agent", "Mimo/1.0"}]
    opts = Keyword.update(opts, :headers, headers, &(headers ++ &1))
    opts = Keyword.put(opts, :decode_body, false)

    case http_get(url, opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _} = error ->
        error
    end
  end

  # Private implementation

  defp do_request_with_retry(url, opts, retries_left, attempt) do
    case Req.get(url, opts) do
      {:ok, %{status: status} = response} when status in @retryable_statuses ->
        if retries_left > 0 do
          delay = calculate_delay(attempt)

          Logger.debug(
            "[Fetcher] Retrying #{url} after #{status} (attempt #{attempt + 1}, delay #{delay}ms)"
          )

          :timer.sleep(delay)
          do_request_with_retry(url, opts, retries_left - 1, attempt + 1)
        else
          {:ok, response}
        end

      {:ok, response} ->
        {:ok, response}

      {:error, %{reason: reason}} when reason in @retryable_errors ->
        if retries_left > 0 do
          delay = calculate_delay(attempt)

          Logger.debug(
            "[Fetcher] Retrying #{url} after #{inspect(reason)} (attempt #{attempt + 1}, delay #{delay}ms)"
          )

          :timer.sleep(delay)
          do_request_with_retry(url, opts, retries_left - 1, attempt + 1)
        else
          {:error, reason}
        end

      {:error, %{reason: reason}} ->
        Logger.warning("[Fetcher] HTTP GET failed for #{url}: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        Logger.warning("[Fetcher] HTTP GET failed for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp calculate_delay(attempt) do
    # Exponential backoff with jitter
    base = @base_delay_ms * :math.pow(2, attempt)
    jitter = :rand.uniform(round(base * 0.3))
    min(round(base + jitter), @max_delay_ms)
  end
end
