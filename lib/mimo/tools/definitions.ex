defmodule Mimo.Tools.Definitions do
  @moduledoc """
  MCP Tool JSON Schema definitions.

  This module contains all tool definitions (JSON schemas) for the MCP protocol.
  Extracted from the monolithic tools.ex as part of SPEC-030 modularization.
  """

  @tool_definitions [
    # ==========================================================================
    # FILE - All file operations in one tool
    # ==========================================================================
    %{
      name: "file",
      description:
        "Sandboxed file operations with automatic memory context. Responses include related memories for accuracy. Operations: read, write, ls, read_lines, insert_after, insert_before, replace_lines, delete_lines, search, replace_string, edit, list_directory, get_info, move, create_directory, read_multiple, list_symbols, read_symbol, search_symbols, glob, multi_replace, diff. 💡 Memory context is auto-included. Store new insights with `memory operation=store` after learning.",
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
          proposed_content: %{type: "string", description: "Content to diff against file"},
          skip_memory_context: %{
            type: "boolean",
            default: false,
            description:
              "Skip auto-including memory context (for batch/performance-sensitive operations)"
          }
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
        "Execute commands and manage processes with automatic memory context. Responses include related memories (past errors, patterns) for accuracy. Operations: execute (default), start_process, read_output, interact, kill, force_kill, list_sessions, list_processes. 💡 Memory context is auto-included. Store important results with `memory operation=store category=action`.",
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
          confirm: %{type: "boolean", description: "Confirm destructive commands (rm, kill, etc.)"},
          skip_memory_context: %{
            type: "boolean",
            default: false,
            description:
              "Skip auto-including memory context (for batch/performance-sensitive operations)"
          }
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

  @doc """
  Returns all MCP tool definitions.
  """
  def definitions, do: @tool_definitions

  @doc """
  Returns the list of tool definitions (alias for definitions/0).
  """
  def list_tools, do: @tool_definitions
end
