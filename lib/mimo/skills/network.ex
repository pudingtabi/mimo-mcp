defmodule Mimo.Skills.Network do
  @moduledoc """
  Production-ready HTTP client using Req.
  """

  @default_timeout 10_000
  @user_agent "Mimo/2.3"
  @default_headers [{"accept", "application/json, text/html, */*"}]

  def fetch(url, opts \\ []) when is_binary(url) do
    merged_opts =
      Keyword.merge(
        [timeout: @default_timeout, user_agent: @user_agent],
        opts
      )

    method = Keyword.get(merged_opts, :method, :get)
    timeout = Keyword.get(merged_opts, :timeout, @default_timeout)
    user_agent = Keyword.get(merged_opts, :user_agent, @user_agent)
    custom_headers = Keyword.get(merged_opts, :headers, [])

    req_opts = [
      headers: @default_headers ++ custom_headers ++ [{"user-agent", user_agent}],
      finch_options: [pool_timeout: 5000, receive_timeout: timeout],
      retry: :transient,
      retry_delay: :exponential,
      retry_max_attempts: 3,
      decode_body: true,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    req_opts =
      if method == :post && Keyword.has_key?(merged_opts, :json) do
        Keyword.put(req_opts, :json, merged_opts[:json])
      else
        req_opts
      end

    try do
      case execute_request(method, url, req_opts) do
        {:ok, response} -> process_success(response)
        {:error, error} -> process_error(error)
      end
    rescue
      e -> {:error, "Network error: #{Exception.message(e)}"}
    end
  end

  defp execute_request(:get, url, opts), do: Req.get(url, opts)
  defp execute_request(:post, url, opts), do: Req.post(url, opts)
  defp execute_request(method, _url, _opts), do: {:error, "Unsupported method: #{method}"}

  defp process_success(response) do
    headers = Map.new(response.headers, fn {k, v} -> {String.downcase(k), v} end)
    {:ok, %{status: response.status, body: response.body, headers: headers}}
  end

  defp process_error(%{reason: reason, message: message}) do
    msg =
      case reason do
        :timeout -> "Request timed out"
        :nxdomain -> "DNS resolution failed: #{message}"
        :econnrefused -> "Connection refused"
        :ssl_error -> "SSL verification failed"
        _ -> "HTTP error: #{message}"
      end

    {:error, msg}
  end

  defp process_error(error), do: {:error, "HTTP error: #{inspect(error)}"}
end
