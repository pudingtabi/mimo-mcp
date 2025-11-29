defmodule Mimo.Tools do
  @moduledoc """
  MCP Tool Definitions and dispatcher.

  Consolidated native Elixir tools - fewer tools, more power.
  Each tool handles multiple operations via the 'operation' parameter.

  ## Core Tools (12 total)

  1. `file` - All file operations (read, write, ls, search, info, etc.)
  2. `terminal` - All terminal/process operations
  3. `fetch` - All network operations (text, html, json, markdown)
  4. `think` - All cognitive operations (thought, plan, sequential)
  5. `web_parse` - Convert HTML to Markdown
  6. `search` - Web search via DuckDuckGo, Bing, or Brave (auto-fallback)
  7. `web_extract` - Extract clean content from web pages
  8. `sonar` - UI accessibility scanner
  9. `vision` - Image analysis via vision-capable LLM
  10. `knowledge` - Knowledge graph operations
  11. `blink` - Enhanced web fetch with browser fingerprinting (HTTP-level)
  12. `browser` - Full browser automation with Puppeteer stealth (handles JS challenges)
  """

  @tool_definitions [
    # ==========================================================================
    # FILE - All file operations in one tool
    # ==========================================================================
    %{
      name: "file",
      description:
        "Sandboxed file operations. Operations: read, write, ls, read_lines, insert_after, insert_before, replace_lines, delete_lines, search, replace_string, list_directory, get_info, move, create_directory, read_multiple, list_symbols, read_symbol, search_symbols",
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: [
              "read",
              "write",
              "ls",
              "read_lines",
              "insert_after",
              "insert_before",
              "replace_lines",
              "delete_lines",
              "search",
              "replace_string",
              "list_directory",
              "get_info",
              "move",
              "create_directory",
              "read_multiple",
              "list_symbols",
              "read_symbol",
              "search_symbols"
            ]
          },
          path: %{type: "string", description: "File or directory path"},
          paths: %{type: "array", items: %{type: "string"}, description: "For read_multiple"},
          content: %{type: "string", description: "For write operations"},
          start_line: %{type: "integer"},
          end_line: %{type: "integer"},
          line_number: %{type: "integer"},
          pattern: %{type: "string", description: "For search operations"},
          old_str: %{type: "string"},
          new_str: %{type: "string"},
          destination: %{type: "string", description: "For move operation"},
          depth: %{type: "integer", description: "For list_directory recursion"},
          mode: %{type: "string", enum: ["rewrite", "append"], description: "For write"},
          offset: %{type: "integer", description: "Start line for chunked read (1-indexed)"},
          limit: %{type: "integer", description: "Max lines to read (default 500)"},
          symbol_name: %{type: "string", description: "For read_symbol operation"},
          context_before: %{type: "integer", description: "Lines of context before symbol"},
          context_after: %{type: "integer", description: "Lines of context after symbol"},
          max_results: %{type: "integer", description: "Max results for search operations"}
        },
        required: ["operation"]
      }
    },
    # ==========================================================================
    # TERMINAL - All terminal/process operations
    # ==========================================================================
    %{
      name: "terminal",
      description:
        "Execute commands and manage processes. Operations: execute (default), start_process, read_output, interact, kill, force_kill, list_sessions, list_processes",
      input_schema: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "Command to execute"},
          operation: %{
            type: "string",
            enum: [
              "execute",
              "start_process",
              "read_output",
              "interact",
              "kill",
              "force_kill",
              "list_sessions",
              "list_processes"
            ],
            default: "execute"
          },
          pid: %{type: "integer", description: "Process ID for process operations"},
          input: %{type: "string", description: "Input for interact operation"},
          timeout: %{type: "integer", description: "Timeout in ms"},
          yolo: %{
            type: "boolean",
            description: "YOLO mode: skip confirmation prompts (default false)"
          },
          confirm: %{type: "boolean", description: "Confirm destructive commands (rm, kill, etc.)"}
        },
        required: ["command"]
      }
    },
    # ==========================================================================
    # FETCH - All network operations
    # ==========================================================================
    %{
      name: "fetch",
      description:
        "Fetch URL content. Format: text, html, json, markdown, raw. Supports GET/POST. Can auto-analyze images with NVIDIA vision for non-vision AI agents.",
      input_schema: %{
        type: "object",
        properties: %{
          url: %{type: "string"},
          format: %{
            type: "string",
            enum: ["text", "html", "json", "markdown", "raw"],
            default: "text"
          },
          method: %{type: "string", enum: ["get", "post"], default: "get"},
          json: %{type: "object", description: "JSON body for POST"},
          headers: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{name: %{type: "string"}, value: %{type: "string"}}
            }
          },
          timeout: %{type: "integer"},
          analyze_image: %{
            type: "boolean",
            description:
              "If URL is an image, analyze it with NVIDIA vision and return description (useful for non-vision AI agents)",
            default: false
          }
        },
        required: ["url"]
      }
    },
    # ==========================================================================
    # THINK - All cognitive operations
    # ==========================================================================
    %{
      name: "think",
      description: "Cognitive operations. Operations: thought (default), plan, sequential",
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{type: "string", enum: ["thought", "plan", "sequential"], default: "thought"},
          thought: %{type: "string", description: "The thought or reasoning step"},
          steps: %{type: "array", items: %{type: "string"}, description: "For plan operation"},
          thoughtNumber: %{type: "integer"},
          totalThoughts: %{type: "integer"},
          nextThoughtNeeded: %{type: "boolean"}
        },
        required: ["thought"]
      }
    },
    # ==========================================================================
    # WEB_PARSE - Convert HTML to Markdown
    # ==========================================================================
    %{
      name: "web_parse",
      description: "Converts HTML to Markdown",
      input_schema: %{
        type: "object",
        properties: %{html: %{type: "string"}},
        required: ["html"]
      }
    },
    # ==========================================================================
    # SEARCH - Web search (native, multi-backend, no API key required)
    # ==========================================================================
    %{
      name: "search",
      description:
        "Search the web using DuckDuckGo, Bing, or Brave with automatic fallback. Operations: web (default), code, images. For image search, can auto-analyze results with NVIDIA vision. No API key required.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{type: "string"},
          operation: %{
            type: "string",
            enum: ["web", "code", "images"],
            default: "web",
            description: "Search type: web, code, or images"
          },
          num_results: %{type: "integer", description: "Max results (default 10)"},
          backend: %{
            type: "string",
            enum: ["auto", "duckduckgo", "bing", "brave"],
            default: "auto",
            description: "Search backend (auto tries all with fallback)"
          },
          analyze_images: %{
            type: "boolean",
            default: false,
            description:
              "For image search: analyze top results with NVIDIA vision to describe content (useful for non-vision AI agents)"
          },
          max_analyze: %{
            type: "integer",
            default: 3,
            description: "Maximum number of images to analyze (default 3, to save API calls)"
          }
        },
        required: ["query"]
      }
    },
    # ==========================================================================
    # WEB_EXTRACT - Content extraction from URLs (Phase 2)
    # ==========================================================================
    %{
      name: "web_extract",
      description:
        "Extract clean content from web pages. Uses Readability-style algorithms to remove ads, navigation, and noise. Returns title, main content, and metadata.",
      input_schema: %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "URL to extract content from"},
          include_structured: %{
            type: "boolean",
            default: false,
            description: "Include JSON-LD, OpenGraph, and Twitter Card data"
          }
        },
        required: ["url"]
      }
    },
    # ==========================================================================
    # SONAR - UI accessibility scanner with vision
    # ==========================================================================
    %{
      name: "sonar",
      description:
        "UI Accessibility Scanner with optional vision analysis. Scans UI elements via accessibility APIs (Linux/macOS) and can take screenshots for AI vision analysis using NVIDIA Nemotron.",
      input_schema: %{
        type: "object",
        properties: %{
          vision: %{
            type: "boolean",
            description:
              "If true, takes a screenshot and analyzes it with NVIDIA vision model for UI/accessibility insights",
            default: false
          },
          prompt: %{
            type: "string",
            description: "Custom prompt for vision analysis (only used when vision=true)",
            default:
              "Analyze this UI screenshot for accessibility issues, layout problems, text readability, color contrast, and interactive elements. List any potential usability concerns."
          }
        }
      }
    },
    # ==========================================================================
    # VISION - Image analysis with multimodal LLM
    # ==========================================================================
    %{
      name: "vision",
      description:
        "Analyze images using vision-capable LLM (Mistral). Supports URLs or base64 encoded images. Useful for: describing images, reading text from screenshots, analyzing charts/diagrams, accessibility audits, UI analysis.",
      input_schema: %{
        type: "object",
        properties: %{
          image: %{
            type: "string",
            description: "Image URL (https://...) or base64 encoded image data"
          },
          prompt: %{
            type: "string",
            description:
              "What to analyze. Examples: 'Describe this image', 'Read all text', 'Analyze the UI layout', 'What colors are used?'",
            default:
              "Describe this image in detail, including any text, UI elements, or notable features."
          },
          max_tokens: %{
            type: "integer",
            description: "Maximum response length (default 1000)",
            default: 1000
          }
        },
        required: ["image"]
      }
    },
    # ==========================================================================
    # KNOWLEDGE - Knowledge graph operations
    # ==========================================================================
    %{
      name: "knowledge",
      description: "Knowledge graph. Operations: query (default), teach",
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{type: "string", enum: ["query", "teach"], default: "query"},
          query: %{type: "string", description: "Natural language query"},
          entity: %{type: "string"},
          predicate: %{type: "string"},
          depth: %{type: "integer", default: 3},
          text: %{type: "string", description: "For teach: natural language fact"},
          subject: %{type: "string"},
          object: %{type: "string"},
          source: %{type: "string"}
        },
        required: ["query"]
      }
    },
    # ==========================================================================
    # BLINK - HTTP-level browser emulation (no JS execution)
    # ==========================================================================
    %{
      name: "blink",
      description:
        "HTTP-level browser emulation with realistic headers and TLS fingerprinting. Bypasses basic bot detection (Cloudflare WAF, Akamai). Does NOT execute JavaScript. Use when fetch returns 403/503. For JS challenges (CAPTCHA, Turnstile), use 'browser' tool instead. Operations: fetch, analyze, smart.",
      input_schema: %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "URL to fetch"},
          operation: %{
            type: "string",
            enum: ["fetch", "analyze", "smart"],
            default: "fetch",
            description:
              "fetch: direct bypass, analyze: detect protection type, smart: auto-escalate"
          },
          browser: %{
            type: "string",
            enum: ["chrome", "firefox", "safari", "random"],
            default: "chrome",
            description: "Browser to impersonate"
          },
          layer: %{
            type: "integer",
            default: 1,
            description: "Bypass layer (0: basic headers, 1: fingerprinting, 2: TLS)"
          },
          max_retries: %{
            type: "integer",
            default: 3,
            description: "Max retry attempts with escalating layers"
          },
          format: %{
            type: "string",
            enum: ["raw", "text", "markdown"],
            default: "raw",
            description: "Output format"
          }
        },
        required: ["url"]
      }
    },
    # ==========================================================================
    # BROWSER - Real browser with Puppeteer (executes JavaScript)
    # ==========================================================================
    %{
      name: "browser",
      description:
        "Real browser automation using Puppeteer with stealth mode. Executes JavaScript and solves challenges (Cloudflare Turnstile, CAPTCHA). Slower than blink but handles JS-protected sites. Also useful for UI testing, screenshots, and form automation. Operations: fetch, screenshot, pdf, evaluate, interact, test.",
      input_schema: %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "URL to load"},
          operation: %{
            type: "string",
            enum: ["fetch", "screenshot", "pdf", "evaluate", "interact", "test"],
            default: "fetch",
            description:
              "fetch: full page with JS, screenshot: capture image, pdf: generate PDF, evaluate: run JS, interact: UI actions, test: run test assertions"
          },
          profile: %{
            type: "string",
            enum: ["chrome", "firefox", "safari", "mobile"],
            default: "chrome",
            description: "Browser profile to emulate"
          },
          wait_for_selector: %{
            type: "string",
            description: "CSS selector to wait for before returning"
          },
          wait_for_challenge: %{
            type: "boolean",
            default: true,
            description: "Wait for Cloudflare/challenge pages to resolve"
          },
          timeout: %{
            type: "integer",
            default: 60000,
            description: "Timeout in milliseconds"
          },
          force_browser: %{
            type: "boolean",
            default: false,
            description: "Force full browser (Puppeteer) even for simple sites. Skip Blink."
          },
          full_page: %{
            type: "boolean",
            default: true,
            description: "For screenshot: capture full page"
          },
          format: %{
            type: "string",
            enum: ["A4", "Letter", "Legal", "Tabloid"],
            default: "A4",
            description: "For pdf: page format"
          },
          script: %{
            type: "string",
            description: "For evaluate: JavaScript code to execute"
          },
          actions: %{
            type: "string",
            description:
              "For interact: JSON array of actions. Example: [{\"type\": \"click\", \"selector\": \"#btn\"}, {\"type\": \"type\", \"selector\": \"#input\", \"text\": \"hello\"}]. Action types: click, type, select, wait, scroll, hover, focus, press, screenshot, evaluate, waitForNavigation"
          },
          tests: %{
            type: "string",
            description:
              "For test: JSON array of test cases. Example: [{\"name\": \"Login test\", \"actions\": [{\"type\": \"click\", \"selector\": \"#login\"}], \"assertions\": [{\"type\": \"url\", \"contains\": \"/dashboard\"}]}]"
          }
        },
        required: ["url"]
      }
    }
  ]

  def list_tools, do: @tool_definitions

  def dispatch(tool_name, arguments \\ %{}) do
    case tool_name do
      # Core tools
      "file" ->
        dispatch_file(arguments)

      "terminal" ->
        dispatch_terminal(arguments)

      "fetch" ->
        dispatch_fetch(arguments)

      "think" ->
        dispatch_think(arguments)

      "web_parse" ->
        {:ok, Mimo.Skills.Web.parse(arguments["html"] || "")}

      "search" ->
        dispatch_search(arguments)

      "web_extract" ->
        dispatch_web_extract(arguments)

      "sonar" ->
        dispatch_sonar(arguments)

      "vision" ->
        dispatch_vision(arguments)

      "knowledge" ->
        dispatch_knowledge(arguments)

      "blink" ->
        dispatch_blink(arguments)

      "browser" ->
        dispatch_browser(arguments)

      # Legacy aliases for backward compatibility
      "http_request" ->
        dispatch_fetch(Map.put(arguments, "format", "raw"))

      "plan" ->
        dispatch_think(Map.merge(arguments, %{"operation" => "plan", "thought" => "plan"}))

      "consult_graph" ->
        dispatch_knowledge(Map.put(arguments, "operation", "query"))

      "teach_mimo" ->
        dispatch_knowledge(Map.put(arguments, "operation", "teach"))

      _ ->
        {:error,
         "Unknown tool: #{tool_name}. Available: file, terminal, fetch, think, web_parse, search, web_extract, sonar, vision, knowledge"}
    end
  end

  # ==========================================================================
  # FILE DISPATCHER
  # ==========================================================================
  defp dispatch_file(%{"operation" => op} = args) do
    path = args["path"] || "."

    case op do
      "read" ->
        opts = []
        opts = if args["offset"], do: Keyword.put(opts, :offset, args["offset"]), else: opts
        opts = if args["limit"], do: Keyword.put(opts, :limit, args["limit"]), else: opts
        Mimo.Skills.FileOps.read(path, opts)

      "write" ->
        content = args["content"] || ""
        mode = if args["mode"] == "append", do: :append, else: :rewrite
        Mimo.Skills.FileOps.write(path, content, mode: mode)

      "ls" ->
        Mimo.Skills.FileOps.ls(path)

      "read_lines" ->
        start_line = args["start_line"] || 1
        end_line = args["end_line"] || -1
        Mimo.Skills.FileOps.read_lines(path, start_line, end_line)

      "insert_after" ->
        Mimo.Skills.FileOps.insert_after_line(path, args["line_number"] || 0, args["content"] || "")

      "insert_before" ->
        Mimo.Skills.FileOps.insert_before_line(
          path,
          args["line_number"] || 1,
          args["content"] || ""
        )

      "replace_lines" ->
        start_line = args["start_line"] || 1
        end_line = args["end_line"] || start_line
        Mimo.Skills.FileOps.replace_lines(path, start_line, end_line, args["content"] || "")

      "delete_lines" ->
        start_line = args["start_line"] || 1
        end_line = args["end_line"] || start_line
        Mimo.Skills.FileOps.delete_lines(path, start_line, end_line)

      "search" ->
        opts = [max_results: args["max_results"] || 50]
        Mimo.Skills.FileOps.search(path, args["pattern"] || "", opts)

      "replace_string" ->
        Mimo.Skills.FileOps.replace_string(path, args["old_str"] || "", args["new_str"] || "")

      "list_directory" ->
        Mimo.Skills.FileOps.list_directory(path, depth: args["depth"] || 1)

      "get_info" ->
        Mimo.Skills.FileOps.get_info(path)

      "move" ->
        Mimo.Skills.FileOps.move(path, args["destination"] || "")

      "create_directory" ->
        Mimo.Skills.FileOps.create_directory(path)

      "read_multiple" ->
        Mimo.Skills.FileOps.read_multiple(args["paths"] || [])

      "list_symbols" ->
        Mimo.Skills.FileOps.list_symbols(path)

      "read_symbol" ->
        opts = []

        opts =
          if args["context_before"],
            do: Keyword.put(opts, :context_before, args["context_before"]),
            else: opts

        opts =
          if args["context_after"],
            do: Keyword.put(opts, :context_after, args["context_after"]),
            else: opts

        Mimo.Skills.FileOps.read_symbol(path, args["symbol_name"] || "", opts)

      "search_symbols" ->
        opts = [max_results: args["max_results"] || 50]
        Mimo.Skills.FileOps.search_symbols(path, args["pattern"] || "", opts)

      _ ->
        {:error, "Unknown file operation: #{op}"}
    end
  end

  defp dispatch_file(_), do: {:error, "Operation required"}

  # ==========================================================================
  # TERMINAL DISPATCHER
  # ==========================================================================
  defp dispatch_terminal(args) do
    op = args["operation"] || "execute"
    command = args["command"] || ""

    case op do
      "execute" ->
        timeout = args["timeout"] || 30_000
        yolo = Map.get(args, "yolo", false)
        confirm = Map.get(args, "confirm", false) || yolo

        {:ok,
         Mimo.Skills.Terminal.execute(command,
           timeout: timeout,
           yolo: yolo,
           confirm: confirm
         )}

      "start_process" ->
        Mimo.Skills.Terminal.start_process(command, timeout_ms: args["timeout"] || 5000)

      "read_output" ->
        Mimo.Skills.Terminal.read_process_output(args["pid"], timeout_ms: args["timeout"] || 1000)

      "interact" ->
        Mimo.Skills.Terminal.interact_with_process(args["pid"], args["input"] || "")

      "kill" ->
        Mimo.Skills.Terminal.kill_process(args["pid"])

      "force_kill" ->
        Mimo.Skills.Terminal.force_terminate(args["pid"])

      "list_sessions" ->
        Mimo.Skills.Terminal.list_sessions()

      "list_processes" ->
        Mimo.Skills.Terminal.list_processes()

      _ ->
        {:error, "Unknown terminal operation: #{op}"}
    end
  end

  # ==========================================================================
  # FETCH DISPATCHER
  # ==========================================================================
  defp dispatch_fetch(args) do
    url = args["url"]
    format = args["format"] || "text"
    analyze_image = args["analyze_image"] || false

    # Check if URL looks like an image
    is_image_url = is_image_url?(url)

    # Auto-analyze images when requested or when format suggests image
    if analyze_image or (is_image_url and analyze_image != false) do
      analyze_image_url(url, args)
    else
      fetch_content(url, format, args)
    end
  end

  defp is_image_url?(url) when is_binary(url) do
    lower_url = String.downcase(url)

    String.ends_with?(lower_url, [".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg"]) or
      String.contains?(lower_url, ["/image/", "/img/", "/photo/", "/picture/"]) or
      String.contains?(lower_url, ["imgur.com", "i.redd.it", "pbs.twimg.com"])
  end

  defp is_image_url?(_), do: false

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
        # Fallback to just returning the URL
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
        opts = if args["timeout"], do: Keyword.put(opts, :timeout, args["timeout"]), else: opts
        opts = if args["json"], do: Keyword.put(opts, :json, args["json"]), else: opts

        opts =
          if args["headers"],
            do: Keyword.put(opts, :headers, normalize_headers(args["headers"])),
            else: opts

        Mimo.Skills.Network.fetch(url, opts)

      _ ->
        {:error, "Unknown format: #{format}"}
    end
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      %{"name" => n, "value" => v} -> {n, v}
      {n, v} -> {n, v}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_headers(_), do: []

  # ==========================================================================
  # THINK DISPATCHER
  # ==========================================================================
  defp dispatch_think(args) do
    op = args["operation"] || "thought"

    case op do
      "thought" ->
        Mimo.Skills.Cognition.think(args["thought"] || "")

      "plan" ->
        Mimo.Skills.Cognition.plan(args["steps"] || [])

      "sequential" ->
        Mimo.Skills.Cognition.sequential_thinking(%{
          "thought" => args["thought"] || "",
          "thoughtNumber" => args["thoughtNumber"] || 1,
          "totalThoughts" => args["totalThoughts"] || 1,
          "nextThoughtNeeded" => args["nextThoughtNeeded"] || false
        })

      _ ->
        {:error, "Unknown think operation: #{op}"}
    end
  end

  # ==========================================================================
  # SEARCH DISPATCHER - Multi-backend web search
  # ==========================================================================
  defp dispatch_search(args) do
    query = args["query"] || ""
    op = args["operation"] || "web"
    analyze_images = args["analyze_images"] || false
    max_analyze = args["max_analyze"] || 3

    # Build options
    opts = []

    opts =
      if args["num_results"], do: Keyword.put(opts, :num_results, args["num_results"]), else: opts

    opts =
      if args["backend"],
        do: Keyword.put(opts, :backend, String.to_atom(args["backend"])),
        else: opts

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
    # Use DuckDuckGo image search
    search_url =
      "https://duckduckgo.com/?q=#{URI.encode_www_form(query)}&t=h_&iax=images&ia=images"

    case Mimo.Skills.Network.fetch_html(search_url) do
      {:ok, html} ->
        # Extract image URLs from search results
        image_urls = extract_image_urls(html)
        num_results = Keyword.get(opts, :num_results, 10)
        image_urls = Enum.take(image_urls, num_results)

        if analyze_images and length(image_urls) > 0 do
          # Analyze top images with vision
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
    # Extract image URLs from DuckDuckGo image search results
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
  # KNOWLEDGE DISPATCHER
  # ==========================================================================
  defp dispatch_knowledge(args) do
    op = args["operation"] || "query"

    case op do
      "query" -> dispatch_consult_graph(args)
      "teach" -> dispatch_teach_mimo(args)
      _ -> {:error, "Unknown knowledge operation: #{op}"}
    end
  end

  defp dispatch_consult_graph(args) do
    alias Mimo.SemanticStore.{Query, Resolver}
    query = args["query"]
    entity = args["entity"]
    predicate = args["predicate"]
    depth = args["depth"] || 3

    cond do
      entity && predicate ->
        case Query.transitive_closure(entity, "entity", predicate, max_depth: depth) do
          results when is_list(results) ->
            formatted =
              Enum.map(results, &%{id: &1.id, type: &1.type, depth: &1.depth, path: &1.path})

            {:ok, %{results: formatted, count: length(results)}}

          error ->
            error
        end

      query ->
        case Resolver.resolve_entity(query, :auto) do
          {:ok, entity_id} ->
            {:ok, %{entity: entity_id, relationships: Query.get_relationships(entity_id, "entity")}}

          {:error, :ambiguous, candidates} ->
            {:ok, %{ambiguous: true, candidates: candidates}}
        end

      true ->
        {:error, "Query or entity+predicate required"}
    end
  end

  defp dispatch_teach_mimo(args) do
    alias Mimo.SemanticStore.Ingestor
    text = args["text"]
    subject = args["subject"]
    predicate = args["predicate"]
    object = args["object"]
    source = args["source"] || "user_input"

    cond do
      subject && predicate && object ->
        case Ingestor.ingest_triple(
               %{subject: subject, predicate: predicate, object: object},
               source
             ) do
          {:ok, id} -> {:ok, %{status: "learned", triple_id: id}}
          error -> error
        end

      text ->
        case Ingestor.ingest_text(text, source) do
          {:ok, count} -> {:ok, %{status: "learned", triples_created: count}}
          error -> error
        end

      true ->
        {:error, "Text or subject+predicate+object required"}
    end
  end

  # ==========================================================================
  # SONAR DISPATCHER - UI accessibility scanner with vision
  # ==========================================================================

  defp dispatch_sonar(args) do
    use_vision = args["vision"] || false

    prompt =
      args["prompt"] ||
        "Analyze this UI screenshot for accessibility issues, layout problems, text readability, color contrast, and interactive elements. List any potential usability concerns."

    # First, get basic accessibility scan
    basic_scan =
      case Mimo.Skills.Sonar.scan_ui() do
        {:ok, scan_result} -> scan_result
        {:error, reason} -> "Accessibility scan unavailable: #{inspect(reason)}"
      end

    if use_vision do
      # Take screenshot and analyze with vision
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
  # VISION DISPATCHER - Image analysis with multimodal LLM
  # ==========================================================================

  defp dispatch_vision(args) do
    image = args["image"]

    prompt =
      args["prompt"] ||
        "Describe this image in detail, including any text, UI elements, or notable features."

    max_tokens = args["max_tokens"] || 1000

    cond do
      is_nil(image) or image == "" ->
        {:error, "Image URL or base64 data is required"}

      true ->
        case Mimo.Brain.LLM.analyze_image(image, prompt, max_tokens: max_tokens) do
          {:ok, analysis} ->
            {:ok, %{analysis: analysis, model: "nvidia/nemotron-nano-12b-v2-vl:free"}}

          {:error, :no_api_key} ->
            {:error,
             "No OpenRouter API key configured. Set OPENROUTER_API_KEY environment variable."}

          {:error, reason} ->
            {:error, "Vision analysis failed: #{inspect(reason)}"}
        end
    end
  end

  # ==========================================================================
  # WEB_EXTRACT DISPATCHER - Content extraction from URLs
  # ==========================================================================

  defp dispatch_web_extract(args) do
    url = args["url"]
    include_structured = args["include_structured"] || false

    cond do
      is_nil(url) or url == "" ->
        {:error, "URL is required"}

      true ->
        # Fetch the HTML first
        case Mimo.Skills.Network.fetch_html(url) do
          {:ok, html} ->
            # Extract content
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

                # Optionally include structured data
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
  # BLINK DISPATCHER - Enhanced web retrieval with browser profiles
  # ==========================================================================

  defp dispatch_blink(args) do
    url = args["url"]
    op = args["operation"] || "fetch"
    browser_input = args["browser"] || "chrome"
    # Map user-friendly names to actual profile names
    browser =
      case browser_input do
        "chrome" -> :chrome_136
        "firefox" -> :firefox_135
        "safari" -> :safari_18
        "random" -> Enum.random([:chrome_136, :firefox_135, :safari_18])
        other when is_atom(other) -> other
        other -> String.to_atom(other)
      end

    layer = args["layer"] || 1
    max_retries = args["max_retries"] || 3
    format = args["format"] || "raw"

    cond do
      is_nil(url) or url == "" ->
        {:error, "URL is required"}

      true ->
        case op do
          "fetch" ->
            case Mimo.Skills.Blink.fetch(url, browser: browser, layer: layer) do
              {:ok, response} ->
                body = format_blink_response(response.body, format)

                {:ok,
                 %{
                   status: response.status,
                   body: body,
                   body_size: byte_size(response.body),
                   headers: Map.new(response.headers),
                   browser: browser,
                   layer: layer
                 }}

              {:error, reason} ->
                {:error, "Blink fetch failed: #{inspect(reason)}"}
            end

          "analyze" ->
            case Mimo.Skills.Blink.analyze_protection(url) do
              {:ok, analysis} ->
                {:ok, analysis}

              {:error, reason} ->
                {:error, "Protection analysis failed: #{inspect(reason)}"}
            end

          "smart" ->
            case Mimo.Skills.Blink.smart_fetch(url, max_retries, browser: browser) do
              {:ok, response} ->
                body = format_blink_response(response.body, format)

                {:ok,
                 %{
                   status: response.status,
                   body: body,
                   body_size: byte_size(response.body),
                   headers: Map.new(response.headers),
                   browser: browser,
                   mode: "smart"
                 }}

              {:error, reason} ->
                {:error, "Smart fetch failed: #{inspect(reason)}"}
            end

          _ ->
            {:error, "Unknown blink operation: #{op}"}
        end
    end
  end

  defp format_blink_response(body, format) do
    case format do
      "text" ->
        # Strip HTML tags for plain text
        body
        |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
        |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
        |> String.replace(~r/<[^>]+>/, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      "markdown" ->
        # Convert to markdown using existing web_parse
        case Mimo.Skills.Web.parse(body) do
          {:ok, md} -> md
          _ -> body
        end

      _ ->
        # raw - return as-is
        body
    end
  end

  # ==========================================================================
  # BROWSER DISPATCHER - Full browser automation with Puppeteer
  # ==========================================================================

  defp dispatch_browser(args) do
    url = args["url"]
    op = args["operation"] || "fetch"
    profile = args["profile"] || "chrome"
    timeout = args["timeout"] || 60_000
    force_browser = Map.get(args, "force_browser", false)

    cond do
      is_nil(url) or url == "" ->
        {:error, "URL is required"}

      true ->
        # Build common options
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
              # Convert string keys to atoms for actions
              normalized_actions = normalize_browser_actions(actions)
              Mimo.Skills.Browser.interact(url, normalized_actions, opts)
            end

          "test" ->
            tests = args["tests"] || ""

            if tests == "" or tests == [] do
              {:error, "Tests list is required for test operation"}
            else
              # Normalize test format
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
      |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
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
            |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
          end)
      }
    end)
  end

  defp normalize_browser_tests(_), do: []
end
