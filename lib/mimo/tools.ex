defmodule Mimo.Tools do
  @moduledoc """
  MCP Tool Definitions and dispatcher.

  Consolidated native Elixir tools - fewer tools, more power.
  Each tool handles multiple operations via the 'operation' parameter.

  ## Core Tools (13 total)

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
  13. `cognitive` - Epistemic uncertainty & meta-cognition (SPEC-024)
  """

  require Logger

  @tool_definitions [
    # ==========================================================================
    # FILE - All file operations in one tool
    # ==========================================================================
    %{
      name: "file",
      description:
        "Sandboxed file operations. Operations: read, write, ls, read_lines, insert_after, insert_before, replace_lines, delete_lines, search, replace_string, edit, list_directory, get_info, move, create_directory, read_multiple, list_symbols, read_symbol, search_symbols, glob, multi_replace, diff",
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
              "edit",
              "list_directory",
              "get_info",
              "move",
              "create_directory",
              "read_multiple",
              "list_symbols",
              "read_symbol",
              "search_symbols",
              "glob",
              "multi_replace",
              "diff"
            ]
          },
          path: %{type: "string", description: "File or directory path"},
          paths: %{type: "array", items: %{type: "string"}, description: "For read_multiple"},
          content: %{type: "string", description: "For write operations"},
          start_line: %{type: "integer"},
          end_line: %{type: "integer"},
          line_number: %{type: "integer"},
          pattern: %{type: "string", description: "For search/glob operations"},
          old_str: %{type: "string", description: "For replace_string/edit: text to find"},
          new_str: %{type: "string", description: "For replace_string/edit: replacement text"},
          destination: %{type: "string", description: "For move operation"},
          depth: %{type: "integer", description: "For list_directory recursion"},
          mode: %{type: "string", enum: ["rewrite", "append"], description: "For write"},
          offset: %{type: "integer", description: "Start line for chunked read (1-indexed)"},
          limit: %{type: "integer", description: "Max lines to read (default 500)"},
          symbol_name: %{type: "string", description: "For read_symbol operation"},
          context_before: %{type: "integer", description: "Lines of context before symbol"},
          context_after: %{type: "integer", description: "Lines of context after symbol"},
          max_results: %{type: "integer", description: "Max results for search operations"},
          global: %{
            type: "boolean",
            description: "For edit: replace all occurrences (default: false)"
          },
          expected_count: %{
            type: "integer",
            description: "For edit: validate number of replacements"
          },
          dry_run: %{
            type: "boolean",
            description: "For edit: preview without writing (default: false)"
          },
          # New SPEC-027 parameters
          base_path: %{type: "string", description: "Base path for glob operation"},
          exclude: %{
            type: "array",
            items: %{type: "string"},
            description: "Patterns to exclude (for glob)"
          },
          respect_gitignore: %{
            type: "boolean",
            default: true,
            description: "Respect .gitignore patterns (for glob/search)"
          },
          replacements: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                path: %{type: "string"},
                old: %{type: "string"},
                new: %{type: "string"}
              },
              required: ["path", "old", "new"]
            },
            description: "For multi_replace: list of replacements to perform atomically"
          },
          path1: %{type: "string", description: "First file for diff operation"},
          path2: %{type: "string", description: "Second file for diff operation"},
          proposed_content: %{type: "string", description: "Content to diff against file"}
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
          cwd: %{
            type: "string",
            description: "Working directory to execute command in (defaults to MIMO_ROOT)"
          },
          env: %{
            type: "object",
            additionalProperties: %{type: "string"},
            description: "Environment variables to set for command execution"
          },
          shell: %{
            type: "string",
            enum: ["bash", "sh", "zsh", "powershell", "cmd"],
            description: "Shell to use for command execution (default: direct execution)"
          },
          name: %{
            type: "string",
            description: "Name for persistent terminal session (for background processes)"
          },
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
    # KNOWLEDGE - Unified Knowledge Graph (SemanticStore + Synapse)
    # Merged from separate knowledge and graph tools for better orchestration
    # ==========================================================================
    %{
      name: "knowledge",
      description:
        "Unified knowledge graph operations. Combines SemanticStore (triples) and Synapse (graph). Operations: query (search both stores), teach (add facts), traverse (graph walk), explore (structured exploration), node (get node context), path (find path), stats (statistics), link (link code to graph), link_memory (link memory to code), sync_dependencies (sync project deps), neighborhood (get nearby nodes).",
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: [
              "query",
              "teach",
              "traverse",
              "explore",
              "node",
              "path",
              "stats",
              "link",
              "link_memory",
              "sync_dependencies",
              "neighborhood"
            ],
            default: "query",
            description: "Operation to perform"
          },
          # Query/Search parameters
          query: %{type: "string", description: "Natural language query for search"},
          entity: %{type: "string", description: "Entity name for targeted lookup"},
          predicate: %{type: "string", description: "Relationship type filter"},
          depth: %{type: "integer", default: 3, description: "Max traversal depth"},
          # Teach parameters
          text: %{type: "string", description: "For teach: natural language fact to learn"},
          subject: %{type: "string", description: "For teach: subject of triple"},
          object: %{type: "string", description: "For teach: object of triple"},
          source: %{type: "string", description: "Source attribution for facts"},
          # Graph traversal parameters
          node_id: %{type: "string", description: "Node ID for traverse/node operations"},
          node_name: %{type: "string", description: "Node name to search for"},
          node_type: %{
            type: "string",
            enum: ["concept", "file", "function", "module", "external_lib", "memory"],
            description: "Filter by node type"
          },
          from_node: %{type: "string", description: "Source node ID for path operation"},
          to_node: %{type: "string", description: "Target node ID for path operation"},
          max_depth: %{type: "integer", default: 3, description: "Maximum traversal depth"},
          direction: %{
            type: "string",
            enum: ["outgoing", "incoming", "both"],
            default: "outgoing",
            description: "Traversal direction"
          },
          limit: %{type: "integer", default: 20, description: "Maximum results to return"},
          # Link parameters
          path: %{
            type: "string",
            description: "File/directory path for link or sync_dependencies operation"
          },
          # Memory linking parameters (SPEC-025)
          memory_id: %{type: "integer", description: "Memory/engram ID for link_memory operation"},
          # Neighborhood parameters (SPEC-025)
          hops: %{
            type: "integer",
            default: 2,
            description: "Number of hops for neighborhood operation"
          },
          edge_types: %{
            type: "array",
            items: %{type: "string"},
            description: "Filter by edge types"
          },
          node_types: %{
            type: "array",
            items: %{type: "string"},
            description: "Filter by node types"
          }
        },
        required: ["operation"]
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
    },
    # ==========================================================================
    # CODE_SYMBOLS - Code structure analysis (SPEC-021 Living Codebase)
    # ==========================================================================
    %{
      name: "code_symbols",
      description:
        "Analyze code structure using Tree-Sitter. Operations: parse (parse file/source), symbols (list symbols in file/directory), references (find all references), search (search symbols by pattern), definition (find symbol definition), call_graph (get callers and callees). Supports Elixir, Python, JavaScript, TypeScript.",
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: ["parse", "symbols", "references", "search", "definition", "call_graph", "index"],
            default: "symbols",
            description: "Operation to perform"
          },
          path: %{
            type: "string",
            description: "File or directory path to analyze"
          },
          source: %{
            type: "string",
            description: "Source code string (for parse operation without file)"
          },
          language: %{
            type: "string",
            enum: ["elixir", "python", "javascript", "typescript", "tsx"],
            description: "Language for source code parsing"
          },
          name: %{
            type: "string",
            description: "Symbol name to search for"
          },
          pattern: %{
            type: "string",
            description: "Search pattern for symbol search"
          },
          kind: %{
            type: "string",
            enum: ["function", "class", "module", "method", "variable", "constant", "import"],
            description: "Filter by symbol kind"
          },
          limit: %{
            type: "integer",
            default: 50,
            description: "Maximum results to return"
          }
        },
        required: ["operation"]
      }
    },
    # ==========================================================================
    # LIBRARY - Package documentation lookup (SPEC-022 Universal Library)
    # ==========================================================================
    %{
      name: "library",
      description:
        "Search and fetch documentation for external packages. Operations: get (fetch package info), search (search packages), ensure (ensure package is cached), discover (auto-discover and cache project dependencies), stats (cache statistics). Supports Hex.pm (Elixir), PyPI (Python), NPM (JavaScript), crates.io (Rust).",
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: ["get", "search", "ensure", "discover", "stats"],
            default: "get",
            description: "Operation to perform"
          },
          name: %{
            type: "string",
            description: "Package name"
          },
          query: %{
            type: "string",
            description: "Search query for package search"
          },
          ecosystem: %{
            type: "string",
            enum: ["hex", "pypi", "npm", "crates"],
            default: "hex",
            description: "Package ecosystem"
          },
          version: %{
            type: "string",
            description: "Specific version to fetch (default: latest)"
          },
          path: %{
            type: "string",
            description: "Project path for discover operation (default: current workspace)"
          },
          limit: %{
            type: "integer",
            default: 10,
            description: "Maximum results for search"
          }
        },
        required: ["operation"]
      }
    },
    # ==========================================================================
    # GRAPH - [DEPRECATED] Alias for knowledge tool
    # Kept for backward compatibility - redirects to unified knowledge tool
    # ==========================================================================
    %{
      name: "graph",
      description:
        "[DEPRECATED: Use 'knowledge' tool instead] Synapse graph operations. All operations now available in unified 'knowledge' tool with additional SemanticStore capabilities.",
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: ["query", "traverse", "explore", "node", "path", "stats", "link"],
            default: "query",
            description: "Operation to perform (redirects to knowledge tool)"
          },
          query: %{type: "string", description: "Search query"},
          node_id: %{type: "string", description: "Node ID"},
          node_name: %{type: "string", description: "Node name"},
          node_type: %{
            type: "string",
            enum: ["concept", "file", "function", "module", "external_lib", "memory"]
          },
          from_node: %{type: "string"},
          to_node: %{type: "string"},
          max_depth: %{type: "integer", default: 3},
          direction: %{type: "string", enum: ["outgoing", "incoming", "both"], default: "outgoing"},
          limit: %{type: "integer", default: 20}
        },
        required: ["operation"]
      }
    },
    # ==========================================================================
    # COGNITIVE - Epistemic Uncertainty & Meta-Cognition (SPEC-024)
    # ==========================================================================
    %{
      name: "cognitive",
      description:
        "Epistemic uncertainty and meta-cognitive operations. Assess confidence, detect knowledge gaps, and generate calibrated responses. Operations: assess (evaluate confidence), gaps (detect knowledge gaps), query (full epistemic query with calibrated response), can_answer (check if topic is answerable), suggest (get learning suggestions), stats (tracker statistics).",
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: ["assess", "gaps", "query", "can_answer", "suggest", "stats"],
            default: "assess",
            description: "Operation to perform"
          },
          topic: %{
            type: "string",
            description: "Topic or query to assess/analyze"
          },
          content: %{
            type: "string",
            description: "Content to format with calibrated response"
          },
          min_confidence: %{
            type: "number",
            default: 0.4,
            description: "Minimum confidence threshold for can_answer"
          },
          limit: %{
            type: "integer",
            default: 5,
            description: "Maximum results for suggest operation"
          }
        },
        required: ["operation"]
      }
    },
    # ==========================================================================
    # DIAGNOSTICS - Compile/lint errors and warnings (SPEC-029)
    # ==========================================================================
    %{
      name: "diagnostics",
      description:
        "Get compile/lint errors and warnings for files. Supports Elixir (mix compile, credo), TypeScript (tsc, eslint), Python (ruff/pylint, mypy), Rust (cargo check, clippy), and Go (go build, golangci-lint). Operations: check (compiler), lint (linter), typecheck (type checker), all (run all diagnostics).",
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: ["check", "lint", "typecheck", "all"],
            default: "all",
            description: "Type of diagnostics to run"
          },
          path: %{
            type: "string",
            description: "File or directory path. Omit for entire workspace."
          },
          language: %{
            type: "string",
            enum: ["auto", "elixir", "typescript", "python", "rust", "go"],
            default: "auto",
            description: "Language to check. Auto-detects from file extension or project files."
          },
          severity: %{
            type: "string",
            enum: ["error", "warning", "info", "all"],
            default: "all",
            description: "Filter results by severity level"
          }
        }
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

      "code_symbols" ->
        dispatch_code_symbols(arguments)

      "library" ->
        dispatch_library(arguments)

      "graph" ->
        # DEPRECATED: Redirect to unified knowledge tool
        Logger.warning(
          "[DEPRECATED] 'graph' tool is deprecated. Use 'knowledge' tool instead with same operations."
        )

        dispatch_knowledge(arguments)

      "cognitive" ->
        dispatch_cognitive(arguments)

      "diagnostics" ->
        dispatch_diagnostics(arguments)

      # Legacy aliases for backward compatibility
      "http_request" ->
        dispatch_fetch(Map.put(arguments, "format", "raw"))

      "plan" ->
        dispatch_think(Map.merge(arguments, %{"operation" => "plan", "thought" => "plan"}))

      "consult_graph" ->
        Logger.warning(
          "[DEPRECATED] 'consult_graph' is deprecated. Use 'knowledge operation=query' instead."
        )

        dispatch_knowledge(Map.put(arguments, "operation", "query"))

      "teach_mimo" ->
        Logger.warning(
          "[DEPRECATED] 'teach_mimo' is deprecated. Use 'knowledge operation=teach' instead."
        )

        dispatch_knowledge(Map.put(arguments, "operation", "teach"))

      _ ->
        {:error,
         "Unknown tool: #{tool_name}. Available: file, terminal, fetch, think, web_parse, search, web_extract, sonar, vision, knowledge, code_symbols, library, graph, cognitive, diagnostics, blink, browser"}
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

      "edit" ->
        opts = []
        opts = if args["global"], do: Keyword.put(opts, :global, args["global"]), else: opts

        opts =
          if args["expected_count"],
            do: Keyword.put(opts, :expected_count, args["expected_count"]),
            else: opts

        opts = if args["dry_run"], do: Keyword.put(opts, :dry_run, args["dry_run"]), else: opts
        Mimo.Skills.FileOps.edit(path, args["old_str"] || "", args["new_str"] || "", opts)

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

      "glob" ->
        opts = []

        opts =
          if args["base_path"], do: Keyword.put(opts, :base_path, args["base_path"]), else: opts

        opts = if args["exclude"], do: Keyword.put(opts, :exclude, args["exclude"]), else: opts
        opts = if args["limit"], do: Keyword.put(opts, :limit, args["limit"]), else: opts

        opts =
          if Map.has_key?(args, "respect_gitignore"),
            do: Keyword.put(opts, :respect_gitignore, args["respect_gitignore"]),
            else: opts

        Mimo.Skills.FileOps.glob(args["pattern"] || "**/*", opts)

      "multi_replace" ->
        replacements = args["replacements"] || []
        opts = []
        opts = if args["global"], do: Keyword.put(opts, :global, args["global"]), else: opts
        Mimo.Skills.FileOps.multi_replace(replacements, opts)

      "diff" ->
        opts = []
        opts = if args["path1"], do: Keyword.put(opts, :path1, args["path1"]), else: opts
        opts = if args["path2"], do: Keyword.put(opts, :path2, args["path2"]), else: opts
        opts = if args["path"], do: Keyword.put(opts, :path, args["path"]), else: opts

        opts =
          if args["proposed_content"],
            do: Keyword.put(opts, :proposed_content, args["proposed_content"]),
            else: opts

        Mimo.Skills.FileOps.diff(opts)

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
        cwd = args["cwd"]
        env = args["env"]
        shell = args["shell"]
        name = args["name"]

        opts = [
          timeout: timeout,
          yolo: yolo,
          confirm: confirm
        ]

        # Add optional params if provided
        opts = if cwd, do: Keyword.put(opts, :cwd, cwd), else: opts
        opts = if env, do: Keyword.put(opts, :env, env), else: opts
        opts = if shell, do: Keyword.put(opts, :shell, shell), else: opts
        opts = if name, do: Keyword.put(opts, :name, name), else: opts

        {:ok, Mimo.Skills.Terminal.execute(command, opts)}

      "start_process" ->
        name = args["name"]
        opts = [timeout_ms: args["timeout"] || 5000]
        opts = if name, do: Keyword.put(opts, :name, name), else: opts
        Mimo.Skills.Terminal.start_process(command, opts)

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
  # KNOWLEDGE DISPATCHER - Unified Knowledge Graph (SemanticStore + Synapse)
  # ==========================================================================
  defp dispatch_knowledge(args) do
    op = args["operation"] || "query"

    case op do
      # SemanticStore operations
      "query" ->
        dispatch_knowledge_query(args)

      "teach" ->
        dispatch_knowledge_teach(args)

      # Synapse graph operations (merged from graph tool)
      "traverse" ->
        dispatch_graph_traverse(args)

      "explore" ->
        dispatch_graph_explore(args)

      "node" ->
        dispatch_graph_node(args)

      "path" ->
        dispatch_graph_path(args)

      "stats" ->
        dispatch_knowledge_stats(args)

      "link" ->
        dispatch_graph_link(args)

      # SPEC-025: Cognitive Codebase Integration operations
      "link_memory" ->
        dispatch_link_memory(args)

      "sync_dependencies" ->
        dispatch_sync_dependencies(args)

      "neighborhood" ->
        dispatch_neighborhood(args)

      _ ->
        {:error,
         "Unknown knowledge operation: #{op}. Available: query, teach, traverse, explore, node, path, stats, link, link_memory, sync_dependencies, neighborhood"}
    end
  end

  # Unified query - searches both SemanticStore and Synapse with fallback
  defp dispatch_knowledge_query(args) do
    alias Mimo.SemanticStore.{Query, Resolver}
    query = args["query"]
    entity = args["entity"]
    predicate = args["predicate"]
    depth = args["depth"] || 3

    cond do
      entity && predicate ->
        # Structured query - use SemanticStore transitive closure
        case Query.transitive_closure(entity, "entity", predicate, max_depth: depth) do
          results when is_list(results) and length(results) > 0 ->
            formatted =
              Enum.map(results, &%{id: &1.id, type: &1.type, depth: &1.depth, path: &1.path})

            {:ok, %{source: "semantic_store", results: formatted, count: length(results)}}

          _ ->
            # Fallback to Synapse graph search
            fallback_to_synapse_query(entity, depth)
        end

      query && query != "" ->
        # Natural language query - try both stores
        semantic_result = try_semantic_query(query)
        synapse_result = try_synapse_query(query, args)

        # Merge results from both stores
        {:ok,
         %{
           query: query,
           semantic_store: semantic_result,
           synapse_graph: synapse_result,
           combined_count: count_results(semantic_result) + count_results(synapse_result)
         }}

      true ->
        {:error, "Query string or entity+predicate required for knowledge lookup"}
    end
  end

  defp try_semantic_query(query) do
    alias Mimo.SemanticStore.Resolver

    case Resolver.resolve_entity(query, :auto) do
      {:ok, entity_id} ->
        rels = Mimo.SemanticStore.Query.get_relationships(entity_id, "entity")
        %{found: true, entity: entity_id, relationships: rels}

      {:error, :ambiguous, candidates} ->
        %{found: false, ambiguous: true, candidates: candidates}

      _ ->
        %{found: false}
    end
  rescue
    _ -> %{found: false, error: "semantic_store_unavailable"}
  end

  defp try_synapse_query(query, args) do
    opts = []
    opts = if args["limit"], do: Keyword.put(opts, :max_nodes, args["limit"]), else: opts

    case Mimo.Synapse.QueryEngine.query(query, opts) do
      {:ok, result} ->
        %{
          found: length(result.nodes) > 0,
          nodes: format_graph_nodes(result.nodes),
          count: length(result.nodes)
        }

      _ ->
        %{found: false}
    end
  rescue
    _ -> %{found: false, error: "synapse_unavailable"}
  end

  defp fallback_to_synapse_query(entity, depth) do
    # Try to find node in Synapse by name
    case Mimo.Synapse.Graph.search_nodes(entity, limit: 1) do
      [node | _] ->
        results = Mimo.Synapse.Traversal.bfs(node.id, max_depth: depth)

        {:ok,
         %{source: "synapse_fallback", node: format_graph_node(node), traversal: length(results)}}

      [] ->
        {:ok, %{source: "none", found: false, message: "No results in either knowledge store"}}
    end
  rescue
    _ -> {:ok, %{source: "none", found: false}}
  end

  defp count_results(%{count: c}), do: c
  defp count_results(%{found: true}), do: 1
  defp count_results(_), do: 0

  defp dispatch_knowledge_teach(args) do
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
          {:ok, id} -> {:ok, %{status: "learned", triple_id: id, store: "semantic"}}
          error -> error
        end

      text && text != "" ->
        case Ingestor.ingest_text(text, source) do
          {:ok, count} -> {:ok, %{status: "learned", triples_created: count, store: "semantic"}}
          error -> error
        end

      true ->
        {:error, "Text or subject+predicate+object required for teaching"}
    end
  end

  # Combined stats from both stores
  defp dispatch_knowledge_stats(_args) do
    import Ecto.Query, only: [from: 2]

    synapse_stats = Mimo.Synapse.Graph.stats()

    # Get SemanticStore stats
    semantic_count =
      try do
        Mimo.Repo.one(from(t in Mimo.SemanticStore.Triple, select: count(t.id))) || 0
      rescue
        _ -> 0
      end

    {:ok,
     %{
       semantic_store: %{triples: semantic_count},
       synapse_graph: synapse_stats,
       total_knowledge_items: semantic_count + (synapse_stats[:total_nodes] || 0)
     }}
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
                try do
                  # Check if body is valid UTF-8 before processing
                  if String.valid?(response.body) do
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
                  else
                    # Binary response (zstd, etc.) - fallback to browser
                    Logger.info("[Blink] Binary/non-UTF8 response, falling back to browser")
                    blink_fallback_to_browser(url, format, browser_input)
                  end
                rescue
                  e ->
                    # Body encoding/format error - fallback to browser
                    Logger.info(
                      "[Blink] Body encoding error: #{inspect(e)}, falling back to browser"
                    )

                    blink_fallback_to_browser(url, format, browser_input)
                catch
                  kind, reason ->
                    Logger.info(
                      "[Blink] Caught #{kind}: #{inspect(reason)}, falling back to browser"
                    )

                    blink_fallback_to_browser(url, format, browser_input)
                end

              {:error, reason} ->
                # Fallback to browser tool on failure
                Logger.info("[Blink] Fetch failed, falling back to browser: #{inspect(reason)}")
                blink_fallback_to_browser(url, format, browser_input)

              {:challenge, challenge_info} ->
                # Challenge detected - escalate to browser
                Logger.info(
                  "[Blink] Challenge detected (#{inspect(challenge_info.type)}), escalating to browser"
                )

                blink_fallback_to_browser(url, format, browser_input)

              {:blocked, blocked_info} ->
                # Blocked - escalate to browser
                Logger.info(
                  "[Blink] Blocked (#{inspect(blocked_info.reason)}), escalating to browser"
                )

                blink_fallback_to_browser(url, format, browser_input)
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
                try do
                  # Check if body is valid UTF-8 before processing
                  if String.valid?(response.body) do
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
                  else
                    # Binary response (zstd, etc.) - fallback to browser
                    Logger.info("[Blink] Binary/non-UTF8 response, falling back to browser")
                    blink_fallback_to_browser(url, format, browser_input)
                  end
                rescue
                  e ->
                    # Body encoding/format error - fallback to browser
                    Logger.info(
                      "[Blink] Body encoding error in smart mode: #{inspect(e)}, falling back to browser"
                    )

                    blink_fallback_to_browser(url, format, browser_input)
                catch
                  kind, reason ->
                    Logger.info(
                      "[Blink] Caught #{kind}: #{inspect(reason)}, falling back to browser"
                    )

                    blink_fallback_to_browser(url, format, browser_input)
                end

              {:error, reason} ->
                # Fallback to browser on smart fetch failure
                Logger.info(
                  "[Blink] Smart fetch failed, falling back to browser: #{inspect(reason)}"
                )

                blink_fallback_to_browser(url, format, browser_input)

              {:challenge, challenge_info} ->
                # Challenge after all layers - escalate to browser
                Logger.info(
                  "[Blink] Challenge persists after all layers (#{inspect(challenge_info.type)}), escalating to browser"
                )

                blink_fallback_to_browser(url, format, browser_input)

              {:blocked, blocked_info} ->
                # Still blocked after retries - escalate to browser
                Logger.info(
                  "[Blink] Still blocked after retries (#{inspect(blocked_info.reason)}), escalating to browser"
                )

                blink_fallback_to_browser(url, format, browser_input)
            end

          _ ->
            {:error, "Unknown blink operation: #{op}"}
        end
    end
  end

  # Fallback to full browser when blink fails
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

  # ==========================================================================
  # CODE_SYMBOLS DISPATCHER - Code structure analysis (SPEC-021)
  # ==========================================================================

  defp dispatch_code_symbols(args) do
    op = args["operation"] || "symbols"

    case op do
      "parse" ->
        dispatch_code_parse(args)

      "symbols" ->
        dispatch_code_list_symbols(args)

      "references" ->
        dispatch_code_references(args)

      "search" ->
        dispatch_code_search(args)

      "definition" ->
        dispatch_code_definition(args)

      "call_graph" ->
        dispatch_code_call_graph(args)

      "index" ->
        dispatch_code_index(args)

      _ ->
        {:error, "Unknown code_symbols operation: #{op}"}
    end
  end

  defp dispatch_code_parse(args) do
    cond do
      args["path"] ->
        case Mimo.Code.TreeSitter.parse_file(args["path"]) do
          {:ok, tree} ->
            case Mimo.Code.TreeSitter.get_sexp(tree) do
              {:ok, sexp} -> {:ok, %{parsed: true, sexp: String.slice(sexp, 0, 2000)}}
              error -> error
            end

          error ->
            error
        end

      args["source"] && args["language"] ->
        case Mimo.Code.TreeSitter.parse(args["source"], args["language"]) do
          {:ok, tree} ->
            {:ok, symbols} = Mimo.Code.TreeSitter.get_symbols(tree)
            {:ok, refs} = Mimo.Code.TreeSitter.get_references(tree)
            {:ok, %{parsed: true, symbols: symbols, references: refs}}

          error ->
            error
        end

      true ->
        {:error, "Either path or source+language is required"}
    end
  end

  defp dispatch_code_list_symbols(args) do
    cond do
      args["path"] && File.dir?(args["path"]) ->
        # List symbols in directory
        case Mimo.Code.SymbolIndex.index_directory(args["path"]) do
          {:ok, _} ->
            stats = Mimo.Code.SymbolIndex.stats()
            {:ok, stats}

          error ->
            error
        end

      args["path"] ->
        # List symbols in file
        symbols = Mimo.Code.SymbolIndex.symbols_in_file(args["path"])
        {:ok, %{file: args["path"], symbols: symbols, count: length(symbols)}}

      true ->
        # Return index stats
        {:ok, Mimo.Code.SymbolIndex.stats()}
    end
  end

  defp dispatch_code_references(args) do
    name = args["name"] || ""

    if name == "" do
      {:error, "Symbol name is required for references lookup"}
    else
      refs = Mimo.Code.SymbolIndex.find_references(name, limit: args["limit"] || 50)

      {:ok,
       %{
         symbol: name,
         references: Enum.map(refs, &format_reference/1),
         count: length(refs)
       }}
    end
  end

  defp dispatch_code_search(args) do
    pattern = args["pattern"] || args["name"] || ""

    if pattern == "" do
      {:error, "Search pattern is required"}
    else
      opts = []
      opts = if args["kind"], do: Keyword.put(opts, :kind, args["kind"]), else: opts
      opts = if args["limit"], do: Keyword.put(opts, :limit, args["limit"]), else: opts

      symbols = Mimo.Code.SymbolIndex.search(pattern, opts)

      {:ok,
       %{
         pattern: pattern,
         symbols: Enum.map(symbols, &format_symbol/1),
         count: length(symbols)
       }}
    end
  end

  defp dispatch_code_definition(args) do
    name = args["name"] || ""

    if name == "" do
      {:error, "Symbol name is required"}
    else
      case Mimo.Code.SymbolIndex.find_definition(name) do
        nil ->
          {:ok, %{symbol: name, found: false}}

        symbol ->
          {:ok, %{symbol: name, found: true, definition: format_symbol(symbol)}}
      end
    end
  end

  defp dispatch_code_call_graph(args) do
    name = args["name"] || ""

    if name == "" do
      {:error, "Symbol name is required"}
    else
      graph = Mimo.Code.SymbolIndex.call_graph(name)
      {:ok, %{symbol: name, callers: graph.callers, callees: graph.callees}}
    end
  end

  defp dispatch_code_index(args) do
    path = args["path"] || "."

    if File.dir?(path) do
      case Mimo.Code.SymbolIndex.index_directory(path) do
        {:ok, results} ->
          stats =
            results
            |> Enum.filter(&match?({:ok, _}, &1))
            |> Enum.map(fn {:ok, s} -> s end)

          total_symbols = Enum.reduce(stats, 0, fn s, acc -> acc + s.symbols_added end)
          total_refs = Enum.reduce(stats, 0, fn s, acc -> acc + s.references_added end)

          {:ok,
           %{
             indexed_files: length(stats),
             total_symbols: total_symbols,
             total_references: total_refs
           }}

        error ->
          error
      end
    else
      Mimo.Code.SymbolIndex.index_file(path)
    end
  end

  defp format_symbol(symbol) do
    %{
      name: symbol.name,
      qualified_name: symbol.qualified_name,
      kind: symbol.kind,
      file_path: symbol.file_path,
      start_line: symbol.start_line,
      end_line: symbol.end_line
    }
  end

  defp format_reference(ref) do
    %{
      name: ref.name,
      kind: ref.kind,
      file_path: ref.file_path,
      line: ref.line,
      col: ref.col
    }
  end

  # ==========================================================================
  # LIBRARY DISPATCHER - Package documentation (SPEC-022)
  # ==========================================================================

  defp dispatch_library(args) do
    op = args["operation"] || "get"

    case op do
      "get" ->
        dispatch_library_get(args)

      "search" ->
        dispatch_library_search(args)

      "ensure" ->
        dispatch_library_ensure(args)

      "discover" ->
        dispatch_library_discover(args)

      "stats" ->
        {:ok, Mimo.Library.CacheManager.stats()}

      _ ->
        {:error, "Unknown library operation: #{op}"}
    end
  end

  defp dispatch_library_get(args) do
    name = args["name"]
    ecosystem = parse_ecosystem(args["ecosystem"] || "hex")

    if is_nil(name) or name == "" do
      {:error, "Package name is required"}
    else
      opts = if args["version"], do: [version: args["version"]], else: []

      case Mimo.Library.Index.get_package(name, ecosystem, opts) do
        {:ok, package} ->
          {:ok, format_package(package)}

        {:error, :not_found} ->
          {:ok, %{name: name, ecosystem: ecosystem, found: false}}

        error ->
          error
      end
    end
  end

  defp dispatch_library_search(args) do
    query = args["query"] || args["name"] || ""
    ecosystem = parse_ecosystem(args["ecosystem"] || "hex")

    if query == "" do
      {:error, "Search query is required"}
    else
      results = Mimo.Library.Index.search(query, ecosystem: ecosystem, limit: args["limit"] || 10)
      {:ok, %{query: query, ecosystem: ecosystem, results: results, count: length(results)}}
    end
  end

  defp dispatch_library_ensure(args) do
    name = args["name"]
    ecosystem = parse_ecosystem(args["ecosystem"] || "hex")

    if is_nil(name) or name == "" do
      {:error, "Package name is required"}
    else
      opts = if args["version"], do: [version: args["version"]], else: []

      case Mimo.Library.Index.ensure_cached(name, ecosystem, opts) do
        :ok ->
          {:ok, %{name: name, ecosystem: ecosystem, cached: true}}

        {:error, reason} ->
          {:ok, %{name: name, ecosystem: ecosystem, cached: false, error: inspect(reason)}}
      end
    end
  end

  defp dispatch_library_discover(args) do
    path = args["path"] || File.cwd!()

    case Mimo.Library.AutoDiscovery.discover_and_cache(path) do
      {:ok, result} ->
        {:ok,
         %{
           path: path,
           ecosystems: result.ecosystems,
           total_dependencies: result.total_dependencies,
           cached_successfully: result.cached_successfully,
           failed: result.failed
         }}

      {:error, reason} ->
        {:error, "Discovery failed: #{reason}"}
    end
  end

  defp parse_ecosystem(ecosystem) when is_binary(ecosystem) do
    case String.downcase(ecosystem) do
      "hex" -> :hex
      "pypi" -> :pypi
      "npm" -> :npm
      "crates" -> :crates
      _ -> :hex
    end
  end

  defp parse_ecosystem(ecosystem) when is_atom(ecosystem), do: ecosystem
  defp parse_ecosystem(_), do: :hex

  defp format_package(package) do
    %{
      name: package[:name] || package["name"],
      version: package[:version] || package["version"],
      description: package[:description] || package["description"],
      found: true,
      docs_url: package[:docs_url] || package["docs_url"],
      modules_count: length(package[:modules] || package["modules"] || []),
      dependencies: package[:dependencies] || package["dependencies"] || []
    }
  end

  # ==========================================================================
  # GRAPH HELPERS - Used by unified knowledge dispatcher
  # Note: dispatch_graph was removed - graph tool now redirects to knowledge
  # ==========================================================================

  defp dispatch_graph_traverse(args) do
    node_id = args["node_id"] || args["node_name"]

    if is_nil(node_id) or node_id == "" do
      {:error, "node_id or node_name is required"}
    else
      # If node_name given, try to find node first
      actual_node_id =
        if args["node_name"] do
          node_type = parse_node_type(args["node_type"])

          case Mimo.Synapse.Graph.get_node(node_type, args["node_name"]) do
            nil ->
              # Try search
              case Mimo.Synapse.Graph.search_nodes(args["node_name"], limit: 1) do
                [node | _] -> node.id
                [] -> nil
              end

            node ->
              node.id
          end
        else
          node_id
        end

      if actual_node_id do
        opts = []

        opts =
          if args["max_depth"], do: Keyword.put(opts, :max_depth, args["max_depth"]), else: opts

        opts =
          if args["direction"] do
            dir = String.to_atom(args["direction"])
            Keyword.put(opts, :direction, dir)
          else
            opts
          end

        results = Mimo.Synapse.Traversal.bfs(actual_node_id, opts)

        {:ok,
         %{
           start_node: actual_node_id,
           results:
             Enum.map(results, fn r ->
               %{
                 node: format_graph_node(r.node),
                 depth: r.depth,
                 path: r.path
               }
             end),
           total: length(results)
         }}
      else
        {:error, "Node not found"}
      end
    end
  end

  defp dispatch_graph_explore(args) do
    query = args["query"] || ""

    if query == "" do
      {:error, "Query is required for explore"}
    else
      opts = if args["limit"], do: [limit: args["limit"]], else: []
      Mimo.Synapse.QueryEngine.explore(query, opts)
    end
  end

  defp dispatch_graph_node(args) do
    node_id = args["node_id"] || args["node_name"]

    if is_nil(node_id) or node_id == "" do
      {:error, "node_id or node_name is required"}
    else
      # If node_name given, try to find node first
      actual_node_id =
        if args["node_name"] do
          node_type = if args["node_type"], do: parse_node_type(args["node_type"]), else: :function

          case Mimo.Synapse.Graph.get_node(node_type, args["node_name"]) do
            nil ->
              case Mimo.Synapse.Graph.search_nodes(args["node_name"], limit: 1) do
                [node | _] -> node.id
                [] -> nil
              end

            node ->
              node.id
          end
        else
          node_id
        end

      if actual_node_id do
        hops = args["max_depth"] || 2

        case Mimo.Synapse.QueryEngine.node_context(actual_node_id, hops: hops) do
          {:ok, result} ->
            {:ok,
             %{
               node: format_graph_node(result.node),
               neighbors: format_graph_nodes(result.neighbors),
               context: result.context,
               edges: length(result.edges)
             }}

          {:error, reason} ->
            {:error, "Node context failed: #{inspect(reason)}"}
        end
      else
        {:error, "Node not found"}
      end
    end
  end

  defp dispatch_graph_path(args) do
    from_node = args["from_node"]
    to_node = args["to_node"]

    if is_nil(from_node) or is_nil(to_node) do
      {:error, "from_node and to_node are required"}
    else
      opts = if args["max_depth"], do: [max_depth: args["max_depth"]], else: []

      case Mimo.Synapse.Traversal.shortest_path(from_node, to_node, opts) do
        {:ok, path} ->
          {:ok,
           %{
             from: from_node,
             to: to_node,
             path: path,
             length: length(path) - 1
           }}

        {:error, :no_path} ->
          {:ok,
           %{
             from: from_node,
             to: to_node,
             path: [],
             error: "No path found"
           }}
      end
    end
  end

  defp dispatch_graph_link(args) do
    # Link a file or directory to the graph
    path = args["path"]

    if is_nil(path) or path == "" do
      {:error, "Path is required for link operation"}
    else
      if File.dir?(path) do
        Mimo.Synapse.Linker.link_directory(path)
      else
        Mimo.Synapse.Linker.link_code_file(path)
      end
    end
  end

  # ==========================================================================
  # SPEC-025: Cognitive Codebase Integration Operations
  # ==========================================================================

  defp dispatch_link_memory(args) do
    # Link a memory to code entities (files, functions, libraries)
    memory_id = args["memory_id"]

    if is_nil(memory_id) or memory_id == "" do
      {:error, "memory_id is required for link_memory operation"}
    else
      case Mimo.Repo.get(Mimo.Brain.Engram, memory_id) do
        nil ->
          {:error, "Memory not found: #{memory_id}"}

        memory ->
          result = Mimo.Brain.MemoryLinker.link_memory(memory_id, memory.content)

          {:ok,
           %{
             memory_id: memory_id,
             linked_files: length(result[:linked_files] || []),
             linked_functions: length(result[:linked_functions] || []),
             linked_libraries: length(result[:linked_libraries] || []),
             details: result
           }}
      end
    end
  end

  defp dispatch_sync_dependencies(args) do
    # Sync project dependencies from mix.exs, package.json, etc.
    path = args["path"] || File.cwd!()

    case Mimo.Synapse.DependencySync.sync_dependencies(path) do
      {:ok, result} ->
        {:ok,
         %{
           path: path,
           synced_files: result[:synced_files] || [],
           total_dependencies: result[:total_dependencies] || 0,
           ecosystems: result[:ecosystems] || [],
           details: result
         }}

      {:error, reason} ->
        {:error, "Failed to sync dependencies: #{inspect(reason)}"}
    end
  end

  defp dispatch_neighborhood(args) do
    # Get the neighborhood (ego graph) around a node
    node_id = args["node_id"]
    node_name = args["node_name"]
    node_type = args["node_type"]
    depth = args["depth"] || 2
    limit = args["limit"] || 50

    # Find node by ID or by name/type
    node =
      cond do
        not is_nil(node_id) ->
          Mimo.Repo.get(Mimo.Synapse.GraphNode, node_id)

        not is_nil(node_name) ->
          type = parse_node_type(node_type)
          Mimo.Synapse.Graph.get_node(type, node_name)

        true ->
          nil
      end

    if is_nil(node) do
      {:error, "Node not found. Provide node_id or node_name (with optional node_type)"}
    else
      case Mimo.Synapse.PathFinder.neighborhood(node.id, depth: depth, limit: limit) do
        {:ok, result} ->
          {:ok,
           %{
             center_node: format_graph_node(node),
             depth: depth,
             nodes: format_graph_nodes(result[:nodes] || []),
             edges: format_edges(result[:edges] || []),
             node_count: length(result[:nodes] || []),
             edge_count: length(result[:edges] || [])
           }}

        {:error, reason} ->
          {:error, "Failed to get neighborhood: #{inspect(reason)}"}
      end
    end
  end

  defp format_edges(edges) do
    Enum.map(edges, fn edge ->
      %{
        id: edge.id,
        from_node_id: edge.from_node_id,
        to_node_id: edge.to_node_id,
        edge_type: edge.edge_type,
        weight: edge.weight || 1.0,
        properties: edge.properties || %{}
      }
    end)
  end

  defp parse_node_type(nil), do: :function
  defp parse_node_type("concept"), do: :concept
  defp parse_node_type("file"), do: :file
  defp parse_node_type("function"), do: :function
  defp parse_node_type("module"), do: :module
  defp parse_node_type("external_lib"), do: :external_lib
  defp parse_node_type("memory"), do: :memory
  defp parse_node_type(type) when is_atom(type), do: type
  defp parse_node_type(_), do: :function

  defp format_graph_nodes(nodes) do
    Enum.map(nodes, &format_graph_node/1)
  end

  defp format_graph_node(nil), do: nil

  defp format_graph_node(node) do
    %{
      id: node.id,
      type: node.node_type,
      name: node.name,
      properties: node.properties || %{},
      access_count: node.access_count || 0
    }
  end

  # ==========================================================================
  # DIAGNOSTICS DISPATCHER - Compile/Lint Errors (SPEC-029)
  # ==========================================================================
  defp dispatch_diagnostics(args) do
    path = args["path"]
    opts = []

    opts =
      if args["operation"] do
        op = String.to_atom(args["operation"])
        Keyword.put(opts, :operation, op)
      else
        opts
      end

    opts =
      if args["language"] do
        lang = String.to_atom(args["language"])
        Keyword.put(opts, :language, lang)
      else
        opts
      end

    opts =
      if args["severity"] do
        sev = String.to_atom(args["severity"])
        Keyword.put(opts, :severity, sev)
      else
        opts
      end

    Mimo.Skills.Diagnostics.check(path, opts)
  end

  # ==========================================================================
  # COGNITIVE DISPATCHER - Epistemic Uncertainty (SPEC-024)
  # ==========================================================================
  defp dispatch_cognitive(args) do
    op = args["operation"] || "assess"

    case op do
      "assess" ->
        topic = args["topic"] || ""

        if topic == "" do
          {:error, "Topic is required for assess operation"}
        else
          uncertainty = Mimo.Cognitive.ConfidenceAssessor.assess(topic)
          {:ok, format_uncertainty(uncertainty)}
        end

      "gaps" ->
        topic = args["topic"] || ""

        if topic == "" do
          {:error, "Topic is required for gaps operation"}
        else
          gap = Mimo.Cognitive.GapDetector.analyze(topic)

          {:ok,
           %{
             topic: topic,
             gap_type: gap.gap_type,
             severity: gap.severity,
             suggestion: gap.suggestion,
             actions: gap.actions,
             details: gap.details
           }}
        end

      "query" ->
        topic = args["topic"] || ""

        if topic == "" do
          {:error, "Topic is required for query operation"}
        else
          {:ok, result} = Mimo.Cognitive.EpistemicBrain.query(topic)

          {:ok,
           %{
             response: result.response,
             confidence: result.uncertainty.confidence,
             score: Float.round(result.uncertainty.score, 3),
             gap_type: result.gap_analysis.gap_type,
             actions_taken: result.actions_taken,
             can_answer: result.uncertainty.confidence in [:high, :medium]
           }}
        end

      "can_answer" ->
        topic = args["topic"] || ""
        min_confidence_val = args["min_confidence"] || 0.4

        if topic == "" do
          {:error, "Topic is required for can_answer operation"}
        else
          # Convert numeric confidence to confidence level
          min_level =
            cond do
              min_confidence_val >= 0.7 -> :high
              min_confidence_val >= 0.4 -> :medium
              min_confidence_val >= 0.2 -> :low
              true -> :unknown
            end

          can_answer = Mimo.Cognitive.EpistemicBrain.can_answer?(topic, min_level)
          uncertainty = Mimo.Cognitive.ConfidenceAssessor.assess(topic)

          {:ok,
           %{
             topic: topic,
             can_answer: can_answer,
             confidence: uncertainty.confidence,
             score: Float.round(uncertainty.score, 3),
             recommendation: if(can_answer, do: "proceed", else: "research_needed")
           }}
        end

      "suggest" ->
        limit = args["limit"] || 5
        targets = Mimo.Cognitive.UncertaintyTracker.suggest_learning_targets(limit: limit)

        {:ok,
         %{
           learning_targets:
             Enum.map(targets, fn t ->
               %{
                 topic: t.topic,
                 priority: Float.round(t.priority, 3),
                 reason: t.reason,
                 suggested_action: t.suggested_action
               }
             end),
           count: length(targets)
         }}

      "stats" ->
        stats = Mimo.Cognitive.UncertaintyTracker.stats()
        avg_conf = Map.get(stats, :avg_confidence) || Map.get(stats, :average_confidence) || 0.0

        {:ok,
         %{
           total_queries: stats.total_queries,
           unique_topics: stats.unique_topics,
           gaps_detected: stats.gaps_detected,
           confidence_distribution: Map.get(stats, :confidence_distribution, %{}),
           average_confidence: Float.round(avg_conf * 1.0, 3)
         }}

      _ ->
        {:error,
         "Unknown cognitive operation: #{op}. Available: assess, gaps, query, can_answer, suggest, stats"}
    end
  end

  defp format_uncertainty(uncertainty) do
    %{
      topic: uncertainty.topic,
      confidence: uncertainty.confidence,
      score: Float.round(uncertainty.score, 3),
      evidence_count: uncertainty.evidence_count,
      source_types: uncertainty.sources |> Enum.map(& &1.type) |> Enum.uniq(),
      staleness: Float.round(uncertainty.staleness, 3),
      has_gap: Mimo.Cognitive.Uncertainty.has_gap?(uncertainty),
      gap_indicators: uncertainty.gap_indicators
    }
  end
end
