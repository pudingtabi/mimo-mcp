defmodule Mimo.Skills.Network do
  @moduledoc """
  Production-ready HTTP client using Req.

  Native replacement for fetch MCP server and http_request tool.
  Provides multiple output formats: raw, text, JSON, HTML, Markdown.
  Web search via multi-backend scraping (DuckDuckGo, Bing, Brave) - no API key required.
  AI-powered content extraction for clean text from messy HTML.
  """

  @default_timeout 10_000
  @search_timeout 15_000
  @default_headers [{"accept", "application/json, text/html, */*"}]

  # User-Agent rotation for better bot evasion
  @user_agents [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  ]

  defp random_user_agent, do: Enum.random(@user_agents)

  # ==========================================================================
  # Core Fetch
  # ==========================================================================

  def fetch(url, opts \\ []) when is_binary(url) do
    merged_opts =
      Keyword.merge(
        [timeout: @default_timeout],
        opts
      )

    method = Keyword.get(merged_opts, :method, :get)
    timeout = Keyword.get(merged_opts, :timeout, @default_timeout)
    user_agent = Keyword.get(merged_opts, :user_agent, random_user_agent())
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
  Search the web using multi-backend scraping (DuckDuckGo, Bing, Brave).
  No API key required - fully native.
  Automatically falls back between search engines.

  ## Options
    - `:num_results` - Max results to return (default 10)
    - `:backend` - Force specific backend (:duckduckgo, :bing, :brave, or :auto)
  """
  def web_search(query, opts \\ []) when is_binary(query) do
    num_results = Keyword.get(opts, :num_results, 10)
    backend = Keyword.get(opts, :backend, :auto)

    case backend do
      :auto -> smart_search(query, num_results)
      :duckduckgo -> scrape_ddg_html(query, num_results)
      :bing -> scrape_bing_html(query, num_results)
      :brave -> scrape_brave_html(query, num_results)
      _ -> smart_search(query, num_results)
    end
  end

  # Smart search with automatic fallback between backends
  defp smart_search(query, num_results) do
    backends = [
      {:duckduckgo, &scrape_ddg_html/2},
      {:bing, &scrape_bing_html/2},
      {:brave, &scrape_brave_html/2}
    ]

    Enum.reduce_while(backends, {:ok, []}, fn {_name, search_fn}, _acc ->
      case search_fn.(query, num_results) do
        {:ok, results} when results != [] ->
          {:halt, {:ok, results}}

        _ ->
          # Log fallback for debugging
          # IO.puts("[Search] #{name} failed, trying next backend...")
          {:cont, {:ok, []}}
      end
    end)
  end

  # Scrape DuckDuckGo HTML results (works for all queries including images)
  defp scrape_ddg_html(query, num_results) do
    encoded_query = URI.encode(query)
    url = "https://html.duckduckgo.com/html/?q=#{encoded_query}"

    req_opts = [
      receive_timeout: @search_timeout,
      redirect: true,
      max_redirects: 5,
      headers: [
        {"user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"},
        {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
        {"accept-language", "en-US,en;q=0.5"}
      ]
    ]

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, parse_ddg_html_results(body, num_results)}

      {:ok, %{status: status}} ->
        {:error, "DuckDuckGo HTML returned status #{status}"}

      {:error, error} ->
        {:error, "HTML search failed: #{inspect(error)}"}
    end
  end

  # Parse DuckDuckGo HTML search results
  defp parse_ddg_html_results(html, max_results) do
    # Parse HTML with Floki
    case Floki.parse_document(html) do
      {:ok, doc} ->
        # Find all result links - DuckDuckGo uses .result__a for result links
        doc
        |> Floki.find(".result")
        |> Enum.map(&extract_ddg_result/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(max_results)

      {:error, _} ->
        []
    end
  end

  # Extract a single DDG result from HTML element
  defp extract_ddg_result(result_el) do
    # Get the title and URL from result__a link
    case Floki.find(result_el, ".result__a") do
      [link | _] ->
        title = Floki.text(link) |> String.trim()
        href = Floki.attribute(link, "href") |> List.first() || ""
        
        # DDG wraps URLs - extract actual URL from redirect
        url = extract_ddg_url(href)
        
        # Get snippet from result__snippet
        snippet =
          case Floki.find(result_el, ".result__snippet") do
            [snippet_el | _] -> Floki.text(snippet_el) |> String.trim()
            _ -> ""
          end

        if url != "" and title != "" do
          %{title: title, url: url, snippet: snippet}
        else
          nil
        end

      _ ->
        nil
    end
  end

  # Extract actual URL from DDG redirect URL
  defp extract_ddg_url(href) when is_binary(href) do
    cond do
      # DDG uses //duckduckgo.com/l/?uddg=URL format
      String.contains?(href, "uddg=") ->
        case URI.decode_query(URI.parse(href).query || "") do
          %{"uddg" => url} -> url
          _ -> href
        end

      # Direct URL
      String.starts_with?(href, "http") ->
        href

      # Relative URL starting with //
      String.starts_with?(href, "//") ->
        "https:" <> href

      true ->
        ""
    end
  end

  defp extract_ddg_url(_), do: ""

  # ==========================================================================
  # Bing Search Backend
  # ==========================================================================

  defp scrape_bing_html(query, num_results) do
    encoded_query = URI.encode(query)
    url = "https://www.bing.com/search?q=#{encoded_query}&count=#{num_results}"

    req_opts = [
      receive_timeout: @search_timeout,
      redirect: true,
      max_redirects: 5,
      headers: [
        {"user-agent", random_user_agent()},
        {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
        {"accept-language", "en-US,en;q=0.5"}
      ]
    ]

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, parse_bing_html_results(body, num_results)}

      {:ok, %{status: status}} ->
        {:error, "Bing returned status #{status}"}

      {:error, error} ->
        {:error, "Bing search failed: #{inspect(error)}"}
    end
  end

  defp parse_bing_html_results(html, max_results) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        # Bing uses .b_algo for organic results
        doc
        |> Floki.find(".b_algo")
        |> Enum.map(&extract_bing_result/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(max_results)

      {:error, _} ->
        []
    end
  end

  defp extract_bing_result(result_el) do
    # Get title and URL from h2 > a
    case Floki.find(result_el, "h2 a") do
      [link | _] ->
        title = Floki.text(link) |> String.trim()
        url = Floki.attribute(link, "href") |> List.first() || ""

        # Get snippet from .b_caption p
        snippet =
          case Floki.find(result_el, ".b_caption p") do
            [snippet_el | _] -> Floki.text(snippet_el) |> String.trim()
            _ -> ""
          end

        if url != "" and title != "" and String.starts_with?(url, "http") do
          %{title: title, url: url, snippet: snippet}
        else
          nil
        end

      _ ->
        nil
    end
  end

  # ==========================================================================
  # Brave Search Backend
  # ==========================================================================

  defp scrape_brave_html(query, num_results) do
    encoded_query = URI.encode(query)
    url = "https://search.brave.com/search?q=#{encoded_query}&source=web"

    req_opts = [
      receive_timeout: @search_timeout,
      redirect: true,
      max_redirects: 5,
      headers: [
        {"user-agent", random_user_agent()},
        {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
        {"accept-language", "en-US,en;q=0.5"}
      ]
    ]

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, parse_brave_html_results(body, num_results)}

      {:ok, %{status: status}} ->
        {:error, "Brave returned status #{status}"}

      {:error, error} ->
        {:error, "Brave search failed: #{inspect(error)}"}
    end
  end

  defp parse_brave_html_results(html, max_results) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        # Brave uses different selectors
        doc
        |> Floki.find("[data-type='web'] .snippet")
        |> Enum.map(&extract_brave_result/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(max_results)
        |> case do
          [] ->
            # Fallback: try alternative selectors
            doc
            |> Floki.find(".result")
            |> Enum.map(&extract_brave_result_alt/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.take(max_results)

          results ->
            results
        end

      {:error, _} ->
        []
    end
  end

  defp extract_brave_result(result_el) do
    case Floki.find(result_el, "a.heading-serpresult") do
      [link | _] ->
        title = Floki.text(link) |> String.trim()
        url = Floki.attribute(link, "href") |> List.first() || ""

        snippet =
          case Floki.find(result_el, ".snippet-description") do
            [snippet_el | _] -> Floki.text(snippet_el) |> String.trim()
            _ -> ""
          end

        if url != "" and title != "" do
          %{title: title, url: url, snippet: snippet}
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp extract_brave_result_alt(result_el) do
    case Floki.find(result_el, "a") do
      [link | _] ->
        title = Floki.text(link) |> String.trim()
        url = Floki.attribute(link, "href") |> List.first() || ""

        if url != "" and title != "" and String.starts_with?(url, "http") do
          %{title: title, url: url, snippet: ""}
        else
          nil
        end

      _ ->
        nil
    end
  end

  # ==========================================================================
  # Content Extraction
  # ==========================================================================

  @doc """
  Extract clean content from HTML using Readability-style algorithms.
  Removes ads, navigation, scripts, and other noise.
  Returns structured content with title, text, and metadata.
  """
  def extract_content(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        # Remove noise elements
        cleaned =
          doc
          |> Floki.filter_out("script, style, nav, footer, header, aside, noscript, iframe")
          |> Floki.filter_out(".ad, .ads, .advertisement, .sidebar, .menu, .nav, .footer, .header")
          |> Floki.filter_out("[class*='cookie'], [class*='popup'], [class*='modal']")

        # Extract metadata
        title = extract_title(doc)
        description = extract_meta(doc, "description")
        author = extract_meta(doc, "author")
        date = extract_date(doc)

        # Extract main content (try multiple strategies)
        main_content =
          extract_article(cleaned) ||
            extract_main(cleaned) ||
            extract_body_text(cleaned)

        {:ok,
         %{
           title: title,
           content: main_content,
           description: description,
           author: author,
           date: date,
           word_count: count_words(main_content)
         }}

      {:error, _} ->
        {:error, "Failed to parse HTML"}
    end
  end

  defp extract_title(doc) do
    # Try og:title first, then <title>, then h1
    extract_meta(doc, "og:title") ||
      (doc |> Floki.find("title") |> Floki.text() |> String.trim()) ||
      (doc |> Floki.find("h1") |> List.first() |> Floki.text() |> String.trim()) ||
      ""
  end

  defp extract_meta(doc, name) do
    # Try both property and name attributes
    meta =
      doc
      |> Floki.find("meta[property='#{name}'], meta[name='#{name}'], meta[property='og:#{name}']")
      |> List.first()

    if meta do
      Floki.attribute(meta, "content") |> List.first() || ""
    else
      nil
    end
  end

  defp extract_date(doc) do
    # Try various date meta tags and elements
    extract_meta(doc, "article:published_time") ||
      extract_meta(doc, "date") ||
      extract_meta(doc, "pubdate") ||
      (doc |> Floki.find("time[datetime]") |> List.first() |> extract_datetime()) ||
      nil
  end

  defp extract_datetime(nil), do: nil

  defp extract_datetime(el) do
    Floki.attribute(el, "datetime") |> List.first()
  end

  defp extract_article(doc) do
    # Try <article> tag first
    case Floki.find(doc, "article") do
      [article | _] ->
        article
        |> Floki.text()
        |> clean_text()

      _ ->
        nil
    end
  end

  defp extract_main(doc) do
    # Try <main> or common content IDs
    case Floki.find(doc, "main, #content, #main, .content, .article-body, .post-content") do
      [main | _] ->
        main
        |> Floki.text()
        |> clean_text()

      _ ->
        nil
    end
  end

  defp extract_body_text(doc) do
    # Last resort: extract all paragraph text
    doc
    |> Floki.find("p")
    |> Enum.map(&Floki.text/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 50))
    |> Enum.join("\n\n")
  end

  defp clean_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\n\s*\n+/, "\n\n")
    |> String.trim()
  end

  defp clean_text(_), do: ""

  defp count_words(text) when is_binary(text) do
    text |> String.split(~r/\s+/) |> length()
  end

  defp count_words(_), do: 0

  @doc """
  Extract structured data (JSON-LD, OpenGraph) from HTML.
  Returns machine-readable metadata when available.
  """
  def extract_structured_data(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        # Extract JSON-LD
        json_ld =
          doc
          |> Floki.find("script[type='application/ld+json']")
          |> Enum.map(fn el ->
            el |> Floki.text() |> String.trim() |> safe_json_decode()
          end)
          |> Enum.reject(&is_nil/1)

        # Extract OpenGraph
        og_data =
          doc
          |> Floki.find("meta[property^='og:']")
          |> Enum.map(fn el ->
            prop =
              Floki.attribute(el, "property")
              |> List.first()
              |> String.replace("og:", "")

            content = Floki.attribute(el, "content") |> List.first()
            {prop, content}
          end)
          |> Map.new()

        # Extract Twitter Card
        twitter_data =
          doc
          |> Floki.find("meta[name^='twitter:']")
          |> Enum.map(fn el ->
            name =
              Floki.attribute(el, "name")
              |> List.first()
              |> String.replace("twitter:", "")

            content = Floki.attribute(el, "content") |> List.first()
            {name, content}
          end)
          |> Map.new()

        {:ok,
         %{
           json_ld: json_ld,
           opengraph: og_data,
           twitter: twitter_data
         }}

      {:error, _} ->
        {:error, "Failed to parse HTML"}
    end
  end

  defp safe_json_decode(text) do
    case Jason.decode(text) do
      {:ok, data} -> data
      {:error, _} -> nil
    end
  end

  # Fetch from DuckDuckGo Instant Answer API (for factual queries)
  defp fetch_ddg_instant_answer(query, num_results) do
    encoded_query = URI.encode(query)
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
        {:ok, parse_ddg_api_results(body, num_results)}

      _ ->
        {:ok, []}
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
    {title, snippet} =
      case String.split(text, " - ", parts: 2) do
        [t, s] -> {String.trim(t), String.trim(s)}
        [t] -> {String.trim(t), ""}
      end

    %{title: title, url: url, snippet: snippet}
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
