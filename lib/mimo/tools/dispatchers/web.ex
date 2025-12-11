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

    case operation do
      # Content Retrieval
      "fetch" ->
        dispatch_fetch(args)

      "extract" ->
        dispatch_web_extract(args)

      "parse" ->
        dispatch_web_parse(args)

      # Search operations
      "search" ->
        dispatch_search(args)

      "code_search" ->
        dispatch_search(Map.put(args, "operation", "code"))

      "image_search" ->
        dispatch_search(Map.put(args, "operation", "images"))

      # Blink operations (HTTP-level browser emulation)
      "blink" ->
        dispatch_blink(args)

      "blink_analyze" ->
        dispatch_blink(Map.put(args, "operation", "analyze"))

      "blink_smart" ->
        dispatch_blink(Map.put(args, "operation", "smart"))

      # Browser operations (Full Puppeteer)
      "browser" ->
        dispatch_browser(args)

      "screenshot" ->
        dispatch_browser(Map.put(args, "operation", "screenshot"))

      "pdf" ->
        dispatch_browser(Map.put(args, "operation", "pdf"))

      "evaluate" ->
        dispatch_browser(Map.put(args, "operation", "evaluate"))

      "interact" ->
        dispatch_browser(Map.put(args, "operation", "interact"))

      "test" ->
        dispatch_browser(Map.put(args, "operation", "test"))

      # Vision & Accessibility
      "vision" ->
        dispatch_vision(args)

      "sonar" ->
        dispatch_sonar(args)

      # Unknown operation
      _ ->
        {:error,
         "Unknown web operation: #{operation}. Valid operations: fetch, extract, parse, search, code_search, image_search, blink, blink_analyze, blink_smart, browser, screenshot, pdf, evaluate, interact, test, vision, sonar"}
    end
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
           model: "nvidia/nemotron-nano-12b-v2-vl:free",
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
             note: "Images analyzed with NVIDIA vision for non-vision AI agents"
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
    op = args["operation"] || "fetch"
    browser_input = args["browser"] || "chrome"

    browser =
      case browser_input do
        "chrome" ->
          :chrome_136

        "firefox" ->
          :firefox_135

        "safari" ->
          :safari_18

        "random" ->
          Enum.random([:chrome_136, :firefox_135, :safari_18])

        other when is_atom(other) ->
          if other in Helpers.allowed_browser_profiles(), do: other, else: :chrome_136

        other when is_binary(other) ->
          Helpers.safe_to_atom(other, Helpers.allowed_browser_profiles()) || :chrome_136

        _ ->
          :chrome_136
      end

    layer = args["layer"] || 1
    max_retries = args["max_retries"] || 3
    format = args["format"] || "raw"

    if is_nil(url) or url == "" do
      {:error, "URL is required"}
    else
      case op do
        "fetch" ->
          dispatch_blink_fetch(url, browser, layer, format, browser_input)

        "analyze" ->
          case Mimo.Skills.Blink.analyze_protection(url) do
            {:ok, analysis} -> {:ok, analysis}
            {:error, reason} -> {:error, "Protection analysis failed: #{inspect(reason)}"}
          end

        "smart" ->
          dispatch_blink_smart(url, browser, max_retries, format, browser_input)

        _ ->
          {:error, "Unknown blink operation: #{op}"}
      end
    end
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
    op = args["operation"] || "fetch"
    profile = args["profile"] || "chrome"
    # Validate timeout (default 60s, max 5min)
    timeout = InputValidation.validate_timeout(args["timeout"], default: 60_000, max: 300_000)
    force_browser = Map.get(args, "force_browser", false)

    if is_nil(url) or url == "" do
      {:error, "URL is required"}
    else
      opts = [
        profile: profile,
        timeout: timeout,
        wait_for_selector: args["wait_for_selector"],
        wait_for_challenge: Map.get(args, "wait_for_challenge", true),
        force_browser: force_browser
      ]

      case op do
        "fetch" ->
          Mimo.Skills.Browser.fetch(url, opts)

        "screenshot" ->
          screenshot_opts =
            opts ++
              [
                full_page: Map.get(args, "full_page", true),
                type: args["type"] || "png",
                quality: args["quality"] || 80,
                selector: args["selector"]
              ]

          Mimo.Skills.Browser.screenshot(url, screenshot_opts)

        "pdf" ->
          pdf_opts =
            opts ++
              [
                format: args["format"] || "A4",
                print_background: Map.get(args, "print_background", true),
                margin: args["margin"]
              ]

          Mimo.Skills.Browser.pdf(url, pdf_opts)

        "evaluate" ->
          script = args["script"]

          if is_nil(script) or script == "" do
            {:error, "Script is required for evaluate operation"}
          else
            Mimo.Skills.Browser.evaluate(url, script, opts)
          end

        "interact" ->
          actions = args["actions"] || ""

          if actions == "" or actions == [] do
            {:error, "Actions list is required for interact operation"}
          else
            normalized_actions = normalize_browser_actions(actions)
            Mimo.Skills.Browser.interact(url, normalized_actions, opts)
          end

        "test" ->
          tests = args["tests"] || ""

          if tests == "" or tests == [] do
            {:error, "Tests list is required for test operation"}
          else
            normalized_tests = normalize_browser_tests(tests)
            Mimo.Skills.Browser.test(url, normalized_tests, opts)
          end

        _ ->
          {:error, "Unknown browser operation: #{op}"}
      end
    end
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
          {:ok, %{analysis: analysis, model: "nvidia/nemotron-nano-12b-v2-vl:free"}}

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
                 model: "nvidia/nemotron-nano-12b-v2-vl:free"
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
      case Mimo.Skills.Network.fetch_html(url) do
        {:ok, html} ->
          case Mimo.Skills.Network.extract_content(html) do
            {:ok, content} ->
              result = %{
                url: url,
                title: content.title,
                content: content.content,
                description: content.description,
                author: content.author,
                date: content.date,
                word_count: content.word_count
              }

              if include_structured do
                case Mimo.Skills.Network.extract_structured_data(html) do
                  {:ok, structured} ->
                    {:ok, Map.merge(result, %{structured_data: structured})}

                  _ ->
                    {:ok, result}
                end
              else
                {:ok, result}
              end

            {:error, reason} ->
              {:error, "Content extraction failed: #{reason}"}
          end

        {:error, reason} ->
          {:error, "Failed to fetch URL: #{reason}"}
      end
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
