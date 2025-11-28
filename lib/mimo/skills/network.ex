defmodule Mimo.Skills.Network do
  @moduledoc """
  Production-ready HTTP client using Req.

  Native replacement for fetch MCP server and http_request tool.
  Provides multiple output formats: raw, text, JSON, HTML, Markdown.
  """

  @default_timeout 10_000
  @user_agent "Mimo/2.3"
  @default_headers [{"accept", "application/json, text/html, */*"}]

  # ==========================================================================
  # Core Fetch (Original)
  # ==========================================================================

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
      receive_timeout: timeout,
      retry: :transient,
      max_retries: 3,
      decode_body: false
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

  # ==========================================================================
  # Fetch Formats (replaces fetch MCP server)
  # ==========================================================================

  @doc """
  Fetch URL and return as plain text.
  Compatible with fetch_fetch_txt.
  """
  def fetch_txt(url) when is_binary(url) do
    case fetch(url) do
      {:ok, %{body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{body: body}} -> {:ok, inspect(body)}
      error -> error
    end
  end

  @doc """
  Fetch URL and return raw HTML.
  Compatible with fetch_fetch_html.
  """
  def fetch_html(url) when is_binary(url) do
    case fetch(url, headers: [{"accept", "text/html"}]) do
      {:ok, %{body: body}} -> {:ok, body}
      error -> error
    end
  end

  @doc """
  Fetch URL and return parsed JSON.
  Compatible with fetch_fetch_json.
  """
  def fetch_json(url) when is_binary(url) do
    case fetch(url, headers: [{"accept", "application/json"}]) do
      {:ok, %{body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, "Invalid JSON response"}
        end

      {:ok, %{body: body}} when is_map(body) ->
        {:ok, body}

      error ->
        error
    end
  end

  @doc """
  Fetch URL and convert HTML to Markdown.
  Compatible with fetch_fetch_markdown.
  """
  def fetch_markdown(url) when is_binary(url) do
    case fetch_html(url) do
      {:ok, html} -> {:ok, Mimo.Skills.Web.parse(html)}
      error -> error
    end
  end

  # ==========================================================================
  # Exa Search Integration (replaces exa_search MCP server)
  # ==========================================================================

  @exa_api_url "https://api.exa.ai/search"

  @doc """
  Search the web using Exa AI.
  Requires EXA_API_KEY environment variable.
  """
  def exa_web_search(query, opts \\ []) when is_binary(query) do
    api_key = System.get_env("EXA_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, "EXA_API_KEY not configured"}
    else
      num_results = Keyword.get(opts, :num_results, 10)

      body = %{
        query: query,
        numResults: num_results,
        type: "neural",
        useAutoprompt: true,
        contents: %{
          text: true
        }
      }

      headers = [
        {"x-api-key", api_key},
        {"content-type", "application/json"}
      ]

      req_opts = [
        headers: headers,
        json: body,
        receive_timeout: 30_000
      ]

      case Req.post(@exa_api_url, req_opts) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, format_exa_results(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, "Exa API error (#{status}): #{inspect(body)}"}

        {:error, error} ->
          {:error, "Exa API request failed: #{inspect(error)}"}
      end
    end
  end

  @doc """
  Get code context using Exa AI search.
  """
  def exa_code_context(query, opts \\ []) when is_binary(query) do
    # Prefix query to focus on code/documentation
    code_query = "#{query} programming code documentation tutorial"
    exa_web_search(code_query, opts)
  end

  defp format_exa_results(%{"results" => results}) when is_list(results) do
    Enum.map(results, fn result ->
      %{
        title: result["title"],
        url: result["url"],
        text: result["text"],
        score: result["score"]
      }
    end)
  end

  defp format_exa_results(body), do: body

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp execute_request(:get, url, opts), do: Req.get(url, opts)
  defp execute_request(:post, url, opts), do: Req.post(url, opts)
  defp execute_request(:put, url, opts), do: Req.put(url, opts)
  defp execute_request(:delete, url, opts), do: Req.delete(url, opts)
  defp execute_request(method, _url, _opts), do: {:error, "Unsupported method: #{method}"}

  defp process_success(response) do
    headers = Map.new(response.headers, fn {k, v} -> {String.downcase(to_string(k)), v} end)
    {:ok, %{status: response.status, body: response.body, headers: headers}}
  end

  defp process_error(%{reason: reason}) do
    msg =
      case reason do
        :timeout -> "Request timed out"
        :nxdomain -> "DNS resolution failed"
        :econnrefused -> "Connection refused"
        _ -> "HTTP error: #{inspect(reason)}"
      end

    {:error, msg}
  end

  defp process_error(error), do: {:error, "HTTP error: #{inspect(error)}"}
end
