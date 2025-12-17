defmodule Mimo.Tools.Dispatchers.Web do
  @moduledoc """
  Unified Web Operations Dispatcher.

  Consolidates all web-related tools into a single unified interface:

  ## Operations

  ### Content Retrieval
  - `fetch` - URL content retrieval with format options (text/html/json/markdown/raw)
  - `extract` - Clean content extraction from URLs (Readability-style)
  - `parse` - Convert HTML to Markdown

  ### Search
  - `search` - Web search with library-first optimization
  - `code_search` - Code-specific search
  - `image_search` - Image search with optional vision analysis

  ### Browser Automation
  - `blink` - HTTP-level browser emulation (fast, bypasses basic WAF)
  - `blink_analyze` - Analyze URL protection type
  - `blink_smart` - Smart fetch with auto-escalation
  - `browser` - Full Puppeteer fetch (JavaScript execution)
  - `screenshot` - Capture page screenshot
  - `pdf` - Generate PDF from page
  - `evaluate` - Execute JavaScript on page
  - `interact` - UI automation actions
  - `test` - Run browser-based tests

  ### Vision & Accessibility
  - `vision` - Analyze images with AI
  - `sonar` - UI accessibility scanning with optional vision

  ## Usage

      # Via unified tool
      dispatch(%{"operation" => "fetch", "url" => "...", "format" => "markdown"})
      dispatch(%{"operation" => "search", "query" => "...", "type" => "web"})
      dispatch(%{"operation" => "vision", "image" => "...", "prompt" => "..."})

  ## Legacy Support

  Individual dispatch_* functions are preserved for backward compatibility
  but route through the unified dispatcher internally.
  """

  require Logger

  alias Mimo.Tools.Helpers
  alias Mimo.Utils.InputValidation

  # ==========================================================================
  # HELPERS
  # ==========================================================================

  # Get the current vision model name for response messages
  defp vision_model do
    System.get_env("OPENROUTER_VISION_MODEL", "google/gemma-3-27b-it:free")
  end

  # ==========================================================================
  # UNIFIED DISPATCHER
  # ==========================================================================

  @doc """
  Unified web tool dispatcher with operation-based routing.

  ## Operations

  ### Content Retrieval
  - `fetch` - Fetch URL content with format options
  - `extract` - Extract clean content from URL
  - `parse` - Convert HTML to Markdown

  ### Search
  - `search` - Web search (default)
  - `code_search` - Code-specific search
  - `image_search` - Image search with optional analysis

  ### Browser Automation (HTTP-level)
  - `blink` - HTTP-level browser emulation
  - `blink_analyze` - Analyze URL protection
  - `blink_smart` - Smart fetch with auto-escalation

  ### Browser Automation (Full)
  - `browser` - Full Puppeteer fetch
  - `screenshot` - Capture page screenshot
  - `pdf` - Generate PDF from page
  - `evaluate` - Execute JavaScript
  - `interact` - UI automation
  - `test` - Browser-based tests

  ### Vision & Accessibility
  - `vision` - Analyze images
  - `sonar` - UI accessibility scanning
  """
  def dispatch(args) do
    operation = args["operation"] || "fetch"
    do_dispatch(operation, args)
  end

  # ==========================================================================
  # Multi-Head Dispatch by Operation
  # ==========================================================================

  # Content Retrieval
  defp do_dispatch("fetch", args), do: dispatch_fetch(args)
  defp do_dispatch("extract", args), do: dispatch_web_extract(args)
  defp do_dispatch("parse", args), do: dispatch_web_parse(args)

  # Search operations
  defp do_dispatch("search", args), do: dispatch_search(args)
  defp do_dispatch("code_search", args), do: dispatch_search(Map.put(args, "operation", "code"))
  defp do_dispatch("image_search", args), do: dispatch_search(Map.put(args, "operation", "images"))

  # Blink operations (HTTP-level browser emulation)
  defp do_dispatch("blink", args), do: dispatch_blink(args)
  defp do_dispatch("blink_analyze", args), do: dispatch_blink(Map.put(args, "operation", "analyze"))
  defp do_dispatch("blink_smart", args), do: dispatch_blink(Map.put(args, "operation", "smart"))

  # Browser operations (Full Puppeteer)
  defp do_dispatch("browser", args), do: dispatch_browser(args)

  defp do_dispatch("screenshot", args),
    do: dispatch_browser(Map.put(args, "operation", "screenshot"))

  defp do_dispatch("pdf", args), do: dispatch_browser(Map.put(args, "operation", "pdf"))
  defp do_dispatch("evaluate", args), do: dispatch_browser(Map.put(args, "operation", "evaluate"))
  defp do_dispatch("interact", args), do: dispatch_browser(Map.put(args, "operation", "interact"))
  defp do_dispatch("test", args), do: dispatch_browser(Map.put(args, "operation", "test"))

  # Vision & Accessibility
  defp do_dispatch("vision", args), do: dispatch_vision(args)
  defp do_dispatch("sonar", args), do: dispatch_sonar(args)

  # Unknown operation
  defp do_dispatch(op, _args) do
    {:error,
     "Unknown web operation: #{op}. Valid operations: fetch, extract, parse, search, code_search, image_search, blink, blink_analyze, blink_smart, browser, screenshot, pdf, evaluate, interact, test, vision, sonar"}
  end

  # ==========================================================================
  # FETCH DISPATCHER
  # ==========================================================================

  @doc """
  Dispatch fetch operation.
  """
  def dispatch_fetch(args) do
    url = args["url"]
    format = args["format"] || "text"
    analyze_image = args["analyze_image"] || false

    is_image_url = Helpers.image_url?(url)

    if analyze_image or (is_image_url and analyze_image != false) do
      analyze_image_url(url, args)
    else
      fetch_content(url, format, args)
    end
  end

  defp analyze_image_url(url, args) do
    prompt =
      args["prompt"] ||
        "Describe this image in detail, including any text, objects, people, colors, and layout. Be comprehensive so a non-vision AI can understand the image content."

    case Mimo.Brain.LLM.analyze_image(url, prompt, max_tokens: 1500) do
      {:ok, analysis} ->
        {:ok,
         %{
           url: url,
           type: "image",
           analysis: analysis,
           model: vision_model(),
           note: "Image analyzed by vision AI for non-vision agents"
         }}

      {:error, :no_api_key} ->
        {:ok,
         %{
           url: url,
           type: "image",
           analysis: "Vision analysis unavailable (no OPENROUTER_API_KEY). This is an image URL.",
           note: "Set OPENROUTER_API_KEY to enable image analysis"
         }}

      {:error, reason} ->
        {:ok,
         %{
           url: url,
           type: "image",
           analysis: "Vision analysis failed: #{inspect(reason)}",
           note: "Image could not be analyzed"
         }}
    end
  end

  defp fetch_content(url, format, args) do
    # Check for Reddit URLs - try RSS fallback strategy
    if reddit_url?(url) do
      fetch_reddit_content(url, format, args)
    else
      do_fetch_content(url, format, args)
    end
  end

  # Check if URL is a Reddit URL
  defp reddit_url?(url) when is_binary(url) do
    String.contains?(url, "reddit.com") or String.contains?(url, "redd.it")
  end

  defp reddit_url?(_), do: false

  # Fetch Reddit content with RSS fallback strategy
  defp fetch_reddit_content(url, format, args) do
    # First, try to convert URL to RSS endpoint
    rss_url = convert_to_reddit_rss(url)

    if rss_url do
      Logger.info("[Reddit] Using RSS strategy for #{url} -> #{rss_url}")

      case Mimo.Skills.Network.fetch_txt(rss_url) do
        {:ok, rss_content} when is_binary(rss_content) and byte_size(rss_content) > 100 ->
          # Successfully got RSS, parse and format
          parsed = parse_reddit_rss(rss_content, format)

          {:ok,
           %{
             source: "reddit_rss",
             original_url: url,
             rss_url: rss_url,
             content: parsed,
             format: format,
             note: "Fetched via RSS feed (Reddit blocks direct HTML access)"
           }}

        {:ok, _empty} ->
          Logger.info("[Reddit] RSS returned empty, trying direct fetch")
          try_direct_then_fallback(url, format, args)

        {:error, _reason} ->
          Logger.info("[Reddit] RSS failed, trying direct fetch")
          try_direct_then_fallback(url, format, args)
      end
    else
      # Not a subreddit/post URL we can convert, try direct
      try_direct_then_fallback(url, format, args)
    end
  end

  # Convert Reddit URL to RSS endpoint
  defp convert_to_reddit_rss(url) do
    uri = URI.parse(url)

    cond do
      # Subreddit URL: /r/subreddit or /r/subreddit/anything
      Regex.match?(~r|/r/\w+|, uri.path || "") ->
        # Get the subreddit base path
        case Regex.run(~r|(/r/\w+)|, uri.path) do
          [_, subreddit_path] ->
            # Check if it's a specific post or listing
            if Regex.match?(~r|/r/\w+/comments/|, uri.path) do
              # Post URL - add .rss to the post
              "https://www.reddit.com#{uri.path}.rss"
            else
              # Subreddit listing - use /new.rss for freshest content
              "https://www.reddit.com#{subreddit_path}/new.rss"
            end

          nil ->
            nil
        end

      # Homepage or other
      uri.path in [nil, "", "/"] ->
        "https://www.reddit.com/.rss"

      true ->
        nil
    end
  end

  # Parse Reddit RSS/Atom feed into requested format
  defp parse_reddit_rss(rss_content, format) do
    # Extract entries from Atom feed
    entries = extract_rss_entries(rss_content)

    case format do
      "json" ->
        %{
          type: "reddit_feed",
          entries: entries,
          count: length(entries)
        }

      "markdown" ->
        Enum.map_join(entries, "\n", fn entry ->
          """
          ## #{entry.title}

          **Author:** #{entry.author} | **Published:** #{entry.published}

          #{entry.content}

          [Link](#{entry.link})

          ---
          """
        end)

      _ ->
        # text format
        Enum.map_join(entries, "\n---\n", fn entry ->
          """
          === #{entry.title} ===
          Author: #{entry.author}
          Published: #{entry.published}

          #{entry.content}

          Link: #{entry.link}
          """
        end)
    end
  end

  # Extract entries from Atom/RSS feed
  defp extract_rss_entries(rss_content) do
    # Use regex to extract entry elements (simpler than full XML parsing)
    entry_regex = ~r/<entry>(.*?)<\/entry>/s
    title_regex = ~r/<title>(?:<!\[CDATA\[)?(.+?)(?:\]\]>)?<\/title>/s
    link_regex = ~r/<link[^>]*href="([^"]+)"/
    author_regex = ~r/<author>\s*<name>([^<]+)<\/name>/s
    published_regex = ~r/<(?:published|updated)>([^<]+)<\/(?:published|updated)>/
    content_regex = ~r/<content[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?<\/content>/s

    Regex.scan(entry_regex, rss_content)
    |> Enum.take(25)
    |> Enum.map(fn [_, entry_xml] ->
      title =
        case Regex.run(title_regex, entry_xml) do
          [_, t] -> decode_html_entities(String.trim(t))
          _ -> "Untitled"
        end

      link =
        case Regex.run(link_regex, entry_xml) do
          [_, l] -> l
          _ -> ""
        end

      author =
        case Regex.run(author_regex, entry_xml) do
          [_, a] -> a
          _ -> "unknown"
        end

      published =
        case Regex.run(published_regex, entry_xml) do
          [_, p] -> p
          _ -> ""
        end

      content =
        case Regex.run(content_regex, entry_xml) do
          [_, c] ->
            # Strip HTML tags for text content
            c
            |> String.replace(~r/<[^>]+>/, " ")
            |> String.replace(~r/\s+/, " ")
            |> String.trim()
            |> String.slice(0..2000)

          _ ->
            ""
        end

      %{
        title: title,
        link: link,
        author: author,
        published: published,
        content: content
      }
    end)
  end

  # Simple HTML entity decoder (common entities only)
  defp decode_html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&#x27;", "'")
    |> String.replace("&#x2F;", "/")
    |> decode_numeric_entities()
  end

  defp decode_numeric_entities(text) do
    # Decode decimal numeric entities &#123;
    text =
      Regex.replace(~r/&#(\d+);/, text, fn _, code ->
        try do
          <<String.to_integer(code)::utf8>>
        rescue
          _ -> ""
        end
      end)

    # Decode hex numeric entities &#x1F;
    Regex.replace(~r/&#x([0-9a-fA-F]+);/, text, fn _, code ->
      try do
        <<String.to_integer(code, 16)::utf8>>
      rescue
        _ -> ""
      end
    end)
  end

  # Try direct fetch, fall back to error with RSS suggestion
  defp try_direct_then_fallback(url, format, args) do
    case do_fetch_content(url, format, args) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        # If we got blocked (403), provide helpful message
        if String.contains?(inspect(reason), "403") or String.contains?(inspect(reason), "blocked") do
          {:error,
           "Reddit blocked direct access (403). Try using an RSS URL instead: " <>
             "append '.rss' to the URL or use /r/subreddit/.rss format. " <>
             "Original error: #{inspect(reason)}"}
        else
          {:error, reason}
        end
    end
  end

  # Original fetch logic extracted
  defp do_fetch_content(url, format, args) do
    case format do
      "text" ->
        Mimo.Skills.Network.fetch_txt(url)

      "html" ->
        Mimo.Skills.Network.fetch_html(url)

      "json" ->
        Mimo.Skills.Network.fetch_json(url)

      "markdown" ->
        Mimo.Skills.Network.fetch_markdown(url)

      "raw" ->
        method = if args["method"] == "post", do: :post, else: :get
        opts = [method: method]
        # Validate timeout (default 30s, max 5min)
        timeout = InputValidation.validate_timeout(args["timeout"], default: 30_000, max: 300_000)
        opts = Keyword.put(opts, :timeout, timeout)
        opts = if args["json"], do: Keyword.put(opts, :json, args["json"]), else: opts

        opts =
          if args["headers"],
            do: Keyword.put(opts, :headers, Helpers.normalize_headers(args["headers"])),
            else: opts

        Mimo.Skills.Network.fetch(url, opts)

      _ ->
        {:error, "Unknown format: #{format}"}
    end
  end

  # ==========================================================================
  # SEARCH DISPATCHER
  # ==========================================================================

  @doc """
  Dispatch search operation.
  Checks library cache first for package documentation queries before web search.
  """
  def dispatch_search(args) do
    query = args["query"] || ""
    # Normalize operation: "search" and "web" both mean web search
    raw_op = args["operation"] || "web"
    op = if raw_op == "search", do: "web", else: raw_op
    analyze_images = args["analyze_images"] || false
    max_analyze = args["max_analyze"] || 3

    # Check library first for package-related queries (web search only)
    if op == "web" do
      case maybe_check_library_first(query) do
        {:library_hit, package_info} ->
          {:ok,
           %{
             source: "library_cache",
             type: "package_documentation",
             query: query,
             package: package_info,
             note: "Found in library cache - no web search needed"
           }}

        :continue_to_web ->
          perform_web_search(query, args, analyze_images, max_analyze)
      end
    else
      # For code/image searches, proceed directly
      perform_search(op, query, args, analyze_images, max_analyze)
    end
  end

  # Check if query is asking for package documentation
  defp maybe_check_library_first(query) do
    # Detect package documentation patterns
    package_patterns = [
      ~r/(docs?|documentation|api|reference|guide|how to use|tutorial)\s+(?:for\s+)?(\w+[-\w]*)/i,
      ~r/(\w+[-\w]*)\s+(docs?|documentation|api|reference|guide)/i,
      # Single word might be a package name
      ~r/^(\w+[-\w]*)\s*$/
    ]

    Enum.reduce_while(package_patterns, :continue_to_web, fn pattern, _acc ->
      case Regex.run(pattern, query) do
        [_, package_name] when byte_size(package_name) > 2 ->
          check_library_for_package(package_name)

        [_, _keyword, package_name] when byte_size(package_name) > 2 ->
          check_library_for_package(package_name)

        [_, package_name, _keyword] when byte_size(package_name) > 2 ->
          check_library_for_package(package_name)

        _ ->
          {:cont, :continue_to_web}
      end
    end)
  end

  defp check_library_for_package(package_name) do
    # Try all ecosystems in priority order
    ecosystems = [:hex, :npm, :pypi, :crates]

    Enum.reduce_while(ecosystems, :continue_to_web, fn ecosystem, _acc ->
      case Mimo.Library.get_package(package_name, ecosystem) do
        {:ok, package_info} ->
          {:halt, {:library_hit, package_info}}

        {:error, _} ->
          {:cont, :continue_to_web}
      end
    end)
  end

  defp perform_web_search(query, args, _analyze_images, _max_analyze) do
    opts = []

    opts =
      if args["num_results"], do: Keyword.put(opts, :num_results, args["num_results"]), else: opts

    opts =
      if args["backend"] do
        case Helpers.safe_to_atom(args["backend"], Helpers.allowed_search_backends()) do
          nil -> opts
          backend -> Keyword.put(opts, :backend, backend)
        end
      else
        opts
      end

    Mimo.Skills.Network.web_search(query, opts)
  end

  defp perform_search(op, query, args, analyze_images, max_analyze) do
    opts = []

    opts =
      if args["num_results"], do: Keyword.put(opts, :num_results, args["num_results"]), else: opts

    opts =
      if args["backend"] do
        case Helpers.safe_to_atom(args["backend"], Helpers.allowed_search_backends()) do
          nil -> opts
          backend -> Keyword.put(opts, :backend, backend)
        end
      else
        opts
      end

    case op do
      "web" ->
        Mimo.Skills.Network.web_search(query, opts)

      "code" ->
        Mimo.Skills.Network.code_search(query, opts)

      "images" ->
        search_images(query, opts, analyze_images, max_analyze)

      _ ->
        {:error, "Unknown search operation: #{op}"}
    end
  end

  defp search_images(query, opts, analyze_images, max_analyze) do
    search_url = "https://duckduckgo.com/?q=#{URI.encode_www_form(query)}&t=h_&iax=images&ia=images"

    case Mimo.Skills.Network.fetch_html(search_url) do
      {:ok, html} ->
        image_urls = extract_image_urls(html)
        num_results = Keyword.get(opts, :num_results, 10)
        image_urls = Enum.take(image_urls, num_results)

        if analyze_images and length(image_urls) > 0 do
          analyzed = analyze_search_images(image_urls, max_analyze)

          {:ok,
           %{
             query: query,
             type: "image_search",
             total_found: length(image_urls),
             analyzed_count: length(analyzed),
             images: analyzed,
             note: "Images analyzed with AI vision for non-vision agents"
           }}
        else
          {:ok,
           %{
             query: query,
             type: "image_search",
             total_found: length(image_urls),
             images: Enum.map(image_urls, &%{url: &1}),
             note: "Set analyze_images=true to get AI descriptions"
           }}
        end

      {:error, reason} ->
        {:error, "Image search failed: #{inspect(reason)}"}
    end
  end

  defp extract_image_urls(html) do
    ~r/vqd=[\d-]+.*?u=(https?[^&"']+\.(jpg|jpeg|png|gif|webp))/i
    |> Regex.scan(html)
    |> Enum.map(fn [_, url | _] -> URI.decode(url) end)
    |> Enum.uniq()
    |> Enum.filter(&valid_image_url?/1)
  end

  defp valid_image_url?(url) do
    String.starts_with?(url, "http") and
      not String.contains?(url, ["duckduckgo.com", "bing.com", "google.com"])
  end

  defp analyze_search_images(image_urls, max_analyze) do
    image_urls
    |> Enum.take(max_analyze)
    |> Enum.map(fn url ->
      prompt =
        "Describe this image concisely: what it shows, any text visible, colors, and key elements. Keep it under 100 words."

      case Mimo.Brain.LLM.analyze_image(url, prompt, max_tokens: 300) do
        {:ok, analysis} ->
          %{url: url, description: analysis, analyzed: true}

        {:error, _reason} ->
          %{url: url, description: "Analysis unavailable", analyzed: false}
      end
    end)
  end

  # ==========================================================================
  # BLINK DISPATCHER
  # ==========================================================================

  @doc """
  Dispatch blink operation (HTTP-level browser emulation).
  """
  def dispatch_blink(args) do
    url = args["url"]
    raw_op = args["operation"] || "fetch"
    op = if raw_op == "blink", do: "fetch", else: raw_op
    browser_input = args["browser_profile"] || args["browser"] || "chrome"
    browser = resolve_browser_profile(browser_input)

    layer = args["layer"] || 1
    max_retries = args["max_retries"] || 3
    format = args["format"] || "raw"

    do_dispatch_blink(op, url, browser, layer, max_retries, format, browser_input)
  end

  # Browser profile resolution - extracted to reduce complexity
  defp resolve_browser_profile("chrome"), do: :chrome_136
  defp resolve_browser_profile("firefox"), do: :firefox_135
  defp resolve_browser_profile("safari"), do: :safari_18
  defp resolve_browser_profile("random"), do: Enum.random([:chrome_136, :firefox_135, :safari_18])

  defp resolve_browser_profile(other) when is_atom(other) do
    if other in Helpers.allowed_browser_profiles(), do: other, else: :chrome_136
  end

  defp resolve_browser_profile(other) when is_binary(other) do
    Helpers.safe_to_atom(other, Helpers.allowed_browser_profiles()) || :chrome_136
  end

  defp resolve_browser_profile(_), do: :chrome_136

  # Blink operation dispatch - multi-head pattern matching
  defp do_dispatch_blink(_op, url, _browser, _layer, _max_retries, _format, _browser_input)
       when is_nil(url) or url == "" do
    {:error, "URL is required"}
  end

  defp do_dispatch_blink("fetch", url, browser, layer, _max_retries, format, browser_input) do
    dispatch_blink_fetch(url, browser, layer, format, browser_input)
  end

  defp do_dispatch_blink("analyze", url, _browser, _layer, _max_retries, _format, _browser_input) do
    case Mimo.Skills.Blink.analyze_protection(url) do
      {:ok, analysis} -> {:ok, analysis}
      {:error, reason} -> {:error, "Protection analysis failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch_blink("smart", url, browser, _layer, max_retries, format, browser_input) do
    dispatch_blink_smart(url, browser, max_retries, format, browser_input)
  end

  defp do_dispatch_blink(op, _url, _browser, _layer, _max_retries, _format, _browser_input) do
    {:error, "Unknown blink operation: #{op}"}
  end

  defp dispatch_blink_fetch(url, browser, layer, format, browser_input) do
    case Mimo.Skills.Blink.fetch(url, browser: browser, layer: layer) do
      {:ok, response} ->
        handle_blink_response(response, url, format, browser, layer, browser_input)

      {:error, reason} ->
        Logger.info("[Blink] Fetch failed, falling back to browser: #{inspect(reason)}")
        blink_fallback_to_browser(url, format, browser_input)

      {:challenge, challenge_info} ->
        Logger.info(
          "[Blink] Challenge detected (#{inspect(challenge_info.type)}), escalating to browser"
        )

        blink_fallback_to_browser(url, format, browser_input)

      {:blocked, blocked_info} ->
        Logger.info("[Blink] Blocked (#{inspect(blocked_info.reason)}), escalating to browser")
        blink_fallback_to_browser(url, format, browser_input)
    end
  end

  defp dispatch_blink_smart(url, browser, max_retries, format, browser_input) do
    case Mimo.Skills.Blink.smart_fetch(url, max_retries, browser: browser) do
      {:ok, response} ->
        handle_blink_response(response, url, format, browser, "smart", browser_input)

      {:error, reason} ->
        Logger.info("[Blink] Smart fetch failed, falling back to browser: #{inspect(reason)}")
        blink_fallback_to_browser(url, format, browser_input)

      {:challenge, challenge_info} ->
        Logger.info(
          "[Blink] Challenge persists after all layers (#{inspect(challenge_info.type)}), escalating to browser"
        )

        blink_fallback_to_browser(url, format, browser_input)

      {:blocked, blocked_info} ->
        Logger.info(
          "[Blink] Still blocked after retries (#{inspect(blocked_info.reason)}), escalating to browser"
        )

        blink_fallback_to_browser(url, format, browser_input)
    end
  end

  defp handle_blink_response(response, url, format, browser, mode, browser_input) do
    try do
      if String.valid?(response.body) do
        body = format_blink_response(response.body, format)

        {:ok,
         %{
           status: response.status,
           body: body,
           body_size: byte_size(response.body),
           headers: Map.new(response.headers),
           browser: browser,
           mode: mode
         }}
      else
        Logger.info("[Blink] Binary/non-UTF8 response, falling back to browser")
        blink_fallback_to_browser(url, format, browser_input)
      end
    rescue
      e ->
        Logger.info("[Blink] Body encoding error: #{inspect(e)}, falling back to browser")
        blink_fallback_to_browser(url, format, browser_input)
    catch
      kind, reason ->
        Logger.info("[Blink] Caught #{kind}: #{inspect(reason)}, falling back to browser")
        blink_fallback_to_browser(url, format, browser_input)
    end
  end

  defp blink_fallback_to_browser(url, format, browser_profile) do
    Logger.info("[Blink->Browser] Escalating to Puppeteer for #{url}")

    browser_args = %{
      "url" => url,
      "operation" => "fetch",
      "profile" => browser_profile,
      "timeout" => 60_000,
      "wait_for_challenge" => true,
      "force_browser" => true
    }

    case dispatch_browser(browser_args) do
      {:ok, response} ->
        body = format_blink_response(response.body || "", format)

        {:ok,
         %{
           status: response.status,
           body: body,
           body_size: byte_size(body),
           headers: response[:headers] || %{},
           browser: browser_profile,
           mode: "browser_fallback",
           escalated_from: "blink",
           note: "Blink failed, successfully fetched via full browser"
         }}

      {:error, reason} ->
        {:error, "Both blink and browser failed: #{inspect(reason)}"}
    end
  end

  defp format_blink_response(body, format) do
    case format do
      "text" ->
        body
        |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
        |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
        |> String.replace(~r/<[^>]+>/, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      "markdown" ->
        case Mimo.Skills.Web.parse(body) do
          {:ok, md} -> md
          _ -> body
        end

      _ ->
        body
    end
  end

  # ==========================================================================
  # BROWSER DISPATCHER
  # ==========================================================================

  @doc """
  Dispatch browser operation (full Puppeteer automation).
  """
  def dispatch_browser(args) do
    url = args["url"]
    raw_op = args["operation"] || "fetch"
    op = if raw_op == "browser", do: "fetch", else: raw_op
    profile = args["profile"] || "chrome"
    timeout = InputValidation.validate_timeout(args["timeout"], default: 60_000, max: 300_000)
    force_browser = Map.get(args, "force_browser", false)

    opts = [
      profile: profile,
      timeout: timeout,
      wait_for_selector: args["wait_for_selector"],
      wait_for_challenge: Map.get(args, "wait_for_challenge", true),
      force_browser: force_browser
    ]

    do_dispatch_browser(op, url, args, opts)
  end

  # Browser operation dispatch - multi-head pattern matching to reduce complexity
  defp do_dispatch_browser(_op, url, _args, _opts) when is_nil(url) or url == "" do
    {:error, "URL is required"}
  end

  defp do_dispatch_browser("fetch", url, _args, opts) do
    Mimo.Skills.Browser.fetch(url, opts)
  end

  defp do_dispatch_browser("screenshot", url, args, opts) do
    screenshot_opts =
      opts ++
        [
          full_page: Map.get(args, "full_page", true),
          type: args["type"] || "png",
          quality: args["quality"] || 80,
          selector: args["selector"]
        ]

    Mimo.Skills.Browser.screenshot(url, screenshot_opts)
  end

  defp do_dispatch_browser("pdf", url, args, opts) do
    pdf_opts =
      opts ++
        [
          format: args["format"] || "A4",
          print_background: Map.get(args, "print_background", true),
          margin: args["margin"]
        ]

    Mimo.Skills.Browser.pdf(url, pdf_opts)
  end

  defp do_dispatch_browser("evaluate", url, args, opts) do
    script = args["script"]
    do_browser_evaluate(url, script, opts)
  end

  defp do_dispatch_browser("interact", url, args, opts) do
    actions = args["actions"] || ""
    do_browser_interact(url, actions, opts)
  end

  defp do_dispatch_browser("test", url, args, opts) do
    tests = args["tests"] || ""
    do_browser_test(url, tests, opts)
  end

  defp do_dispatch_browser(op, _url, _args, _opts) do
    {:error, "Unknown browser operation: #{op}"}
  end

  # Browser evaluate - extracted for clarity
  defp do_browser_evaluate(_url, script, _opts) when is_nil(script) or script == "" do
    {:error, "Script is required for evaluate operation"}
  end

  defp do_browser_evaluate(url, script, opts) do
    Mimo.Skills.Browser.evaluate(url, script, opts)
  end

  # Browser interact - extracted for clarity
  defp do_browser_interact(_url, actions, _opts) when actions == "" or actions == [] do
    {:error, "Actions list is required for interact operation"}
  end

  defp do_browser_interact(url, actions, opts) do
    normalized_actions = normalize_browser_actions(actions)
    Mimo.Skills.Browser.interact(url, normalized_actions, opts)
  end

  # Browser test - extracted for clarity
  defp do_browser_test(_url, tests, _opts) when tests == "" or tests == [] do
    {:error, "Tests list is required for test operation"}
  end

  defp do_browser_test(url, tests, opts) do
    normalized_tests = normalize_browser_tests(tests)
    Mimo.Skills.Browser.test(url, normalized_tests, opts)
  end

  defp normalize_browser_actions(actions) when is_binary(actions) do
    case Jason.decode(actions) do
      {:ok, list} when is_list(list) -> normalize_browser_actions(list)
      _ -> []
    end
  end

  defp normalize_browser_actions(actions) when is_list(actions) do
    Enum.map(actions, fn action ->
      action
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.new(fn {k, v} -> {Helpers.safe_key_to_atom(k, Helpers.allowed_action_keys()), v} end)
      |> Map.reject(fn {k, _v} ->
        is_atom(k) and String.starts_with?(Atom.to_string(k), "_unknown_")
      end)
    end)
  end

  defp normalize_browser_actions(_), do: []

  defp normalize_browser_tests(tests) when is_binary(tests) do
    case Jason.decode(tests) do
      {:ok, list} when is_list(list) -> normalize_browser_tests(list)
      _ -> []
    end
  end

  defp normalize_browser_tests(tests) when is_list(tests) do
    Enum.map(tests, fn test ->
      test = Map.new(test, fn {k, v} -> {to_string(k), v} end)

      %{
        name: test["name"] || "Unnamed test",
        actions: normalize_browser_actions(test["actions"] || []),
        assertions:
          Enum.map(test["assertions"] || [], fn assertion ->
            assertion
            |> Map.new(fn {k, v} -> {to_string(k), v} end)
            |> Map.new(fn {k, v} ->
              {Helpers.safe_key_to_atom(k, Helpers.allowed_assertion_keys()), v}
            end)
            |> Map.reject(fn {k, _v} ->
              is_atom(k) and String.starts_with?(Atom.to_string(k), "_unknown_")
            end)
          end)
      }
    end)
  end

  defp normalize_browser_tests(_), do: []

  # ==========================================================================
  # VISION DISPATCHER
  # ==========================================================================

  @doc """
  Dispatch vision operation (image analysis).
  """
  def dispatch_vision(args) do
    image = args["image"]

    prompt =
      args["prompt"] ||
        "Describe this image in detail, including any text, UI elements, or notable features."

    max_tokens = args["max_tokens"] || 1000

    if is_nil(image) or image == "" do
      {:error, "Image URL or base64 data is required"}
    else
      case Mimo.Brain.LLM.analyze_image(image, prompt, max_tokens: max_tokens) do
        {:ok, analysis} ->
          {:ok, %{analysis: analysis, model: vision_model()}}

        {:error, :no_api_key} ->
          {:error, "No OpenRouter API key configured. Set OPENROUTER_API_KEY environment variable."}

        {:error, reason} ->
          {:error, "Vision analysis failed: #{inspect(reason)}"}
      end
    end
  end

  # ==========================================================================
  # SONAR DISPATCHER
  # ==========================================================================

  @doc """
  Dispatch sonar operation (UI accessibility scanner).
  """
  def dispatch_sonar(args) do
    use_vision = args["vision"] || false

    prompt =
      args["prompt"] ||
        "Analyze this UI screenshot for accessibility issues, layout problems, text readability, color contrast, and interactive elements. List any potential usability concerns."

    basic_scan =
      case Mimo.Skills.Sonar.scan_ui() do
        {:ok, scan_result} -> scan_result
        {:error, reason} -> "Accessibility scan unavailable: #{inspect(reason)}"
      end

    if use_vision do
      case Mimo.Skills.Sonar.take_screenshot() do
        {:ok, screenshot_base64} ->
          case Mimo.Brain.LLM.analyze_image(screenshot_base64, prompt, max_tokens: 1500) do
            {:ok, vision_analysis} ->
              {:ok,
               %{
                 accessibility_scan: basic_scan,
                 vision_analysis: vision_analysis,
                 model: vision_model()
               }}

            {:error, :no_api_key} ->
              {:ok,
               %{
                 accessibility_scan: basic_scan,
                 vision_analysis: "Vision unavailable: No OPENROUTER_API_KEY configured"
               }}

            {:error, reason} ->
              {:ok,
               %{
                 accessibility_scan: basic_scan,
                 vision_analysis: "Vision analysis failed: #{inspect(reason)}"
               }}
          end

        {:error, reason} ->
          {:ok,
           %{
             accessibility_scan: basic_scan,
             vision_analysis: "Screenshot unavailable: #{inspect(reason)}"
           }}
      end
    else
      {:ok, %{accessibility_scan: basic_scan}}
    end
  end

  # ==========================================================================
  # WEB_EXTRACT DISPATCHER
  # ==========================================================================

  @doc """
  Dispatch web_extract operation (content extraction).
  """
  def dispatch_web_extract(args) do
    url = args["url"]
    include_structured = args["include_structured"] || false

    if is_nil(url) or url == "" do
      {:error, "URL is required"}
    else
      do_extract_content(url, include_structured)
    end
  end

  defp do_extract_content(url, include_structured) do
    with {:ok, html} <- Mimo.Skills.Network.fetch_html(url),
         {:ok, content} <- Mimo.Skills.Network.extract_content(html) do
      result = build_extract_result(url, content)

      if include_structured do
        maybe_add_structured_data(result, html)
      else
        {:ok, result}
      end
    else
      {:error, reason} ->
        {:error, "Content extraction failed: #{inspect(reason)}"}
    end
  end

  defp build_extract_result(url, content) do
    %{
      url: url,
      title: content.title,
      content: content.content,
      description: content.description,
      author: content.author,
      date: content.date,
      word_count: content.word_count
    }
  end

  defp maybe_add_structured_data(result, html) do
    case Mimo.Skills.Network.extract_structured_data(html) do
      {:ok, structured} -> {:ok, Map.merge(result, %{structured_data: structured})}
      _ -> {:ok, result}
    end
  end

  # ==========================================================================
  # WEB_PARSE DISPATCHER
  # ==========================================================================

  @doc """
  Dispatch web_parse operation (HTML to Markdown).
  """
  def dispatch_web_parse(args) do
    {:ok, Mimo.Skills.Web.parse(args["html"] || "")}
  end
end
