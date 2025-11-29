defmodule Mimo.Skills.Network do
  @moduledoc """
  Production-ready HTTP client using Req.

  Native replacement for fetch MCP server and http_request tool.
  Provides multiple output formats: raw, text, JSON, HTML, Markdown.
  Web search via DuckDuckGo scraping (no API key required).
  """

  @default_timeout 10_000
  @search_timeout 15_000
  @user_agent "Mimo/2.4"
  @default_headers [{"accept", "application/json, text/html, */*"}]

  # ==========================================================================
  # Core Fetch
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
  # Fetch Formats
  # ==========================================================================

  @doc "Fetch URL and return as plain text."
  def fetch_txt(url) when is_binary(url) do
    case fetch(url) do
      {:ok, %{body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{body: body}} -> {:ok, inspect(body)}
      error -> error
    end
  end

  @doc "Fetch URL and return raw HTML."
  def fetch_html(url) when is_binary(url) do
    case fetch(url, headers: [{"accept", "text/html"}]) do
      {:ok, %{body: body}} -> {:ok, body}
      error -> error
    end
  end

  @doc "Fetch URL and return parsed JSON."
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

  @doc "Fetch URL and convert HTML to Markdown."
  def fetch_markdown(url) when is_binary(url) do
    case fetch_html(url) do
      {:ok, html} -> {:ok, Mimo.Skills.Web.parse(html)}
      error -> error
    end
  end

  # ==========================================================================
  # Native Web Search (no API key required)
  # ==========================================================================

  @doc """
  Search the web using DuckDuckGo Instant Answer API.
  No API key required - fully native.

  ## Options
    - `:num_results` - Max results to return (default 10)
  """
  def web_search(query, opts \\ []) when is_binary(query) do
    num_results = Keyword.get(opts, :num_results, 10)
    encoded_query = URI.encode(query)

    # Use DuckDuckGo Instant Answer API (no CAPTCHA, returns JSON)
    url = "https://api.duckduckgo.com/?q=#{encoded_query}&format=json&no_html=1&skip_disambig=0"

    req_opts = [
      receive_timeout: @search_timeout,
      redirect: true,
      max_redirects: 3
    ]

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, parse_ddg_api_results(data, num_results)}
          {:error, _} -> {:ok, []}
        end

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        # Req may auto-decode JSON
        {:ok, parse_ddg_api_results(body, num_results)}

      {:ok, %{status: status}} ->
        {:error, "DuckDuckGo API returned status #{status}"}

      {:error, error} ->
        {:error, "Search failed: #{inspect(error)}"}
    end
  end

  defp parse_ddg_api_results(data, max_results) do
    results = []

    # Abstract result (main answer)
    results =
      if data["AbstractURL"] && data["AbstractURL"] != "" do
        [
          %{
            title: data["Heading"] || "DuckDuckGo Result",
            url: data["AbstractURL"],
            snippet: data["AbstractText"] || data["Abstract"] || ""
          }
          | results
        ]
      else
        results
      end

    # Related topics
    related =
      (data["RelatedTopics"] || [])
      |> Enum.flat_map(fn item ->
        case item do
          %{"Topics" => topics} when is_list(topics) ->
            # Nested category
            Enum.map(topics, &parse_ddg_topic/1)

          topic when is_map(topic) ->
            [parse_ddg_topic(topic)]

          _ ->
            []
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Direct results (if any)
    direct =
      (data["Results"] || [])
      |> Enum.map(fn r ->
        %{
          title: r["Text"] || "Result",
          url: r["FirstURL"] || "",
          snippet: ""
        }
      end)
      |> Enum.reject(fn r -> r.url == "" end)

    (results ++ direct ++ related)
    |> Enum.take(max_results)
  end

  defp parse_ddg_topic(%{"FirstURL" => url, "Text" => text}) when is_binary(url) and url != "" do
    # Extract title from text (before the description)
    {title, snippet} =
      case String.split(text, " ", parts: 2) do
        [t] -> {t, ""}
        [t, s] -> {t, s}
      end

    # Better parsing - text format is "Title Description..."
    %{
      title: title,
      url: url,
      snippet: snippet
    }
  end

  defp parse_ddg_topic(_), do: nil

  @doc "Search for code-related content."
  def code_search(query, opts \\ []) when is_binary(query) do
    code_query = "#{query} programming code example"
    web_search(code_query, opts)
  end

  # Legacy aliases for compatibility
  def exa_web_search(query, opts \\ []), do: web_search(query, opts)
  def exa_code_context(query, opts \\ []), do: code_search(query, opts)

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
