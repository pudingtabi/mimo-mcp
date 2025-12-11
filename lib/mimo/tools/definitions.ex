defmodule Mimo.Tools.Definitions do
  @moduledoc """
  MCP Tool JSON Schema definitions.

  This module contains all tool definitions (JSON schemas) for the MCP protocol.
  Extracted from the monolithic tools.ex as part of SPEC-030 modularization.

  ## Tool Consolidation (Phase 2)

  Primary tools (exposed to MCP):
  - file, terminal, web, code, knowledge, memory, think, reason, onboard, cognitive, meta
  - ask_mimo, ingest (memory helpers)
  - run_procedure, list_procedures, mimo_reload_skills (procedural)
  - tool_usage, awakening_status (monitoring)

  Deprecated tools (hidden from MCP, still work internally):
  - fetch, search, blink, browser, vision, sonar, web_extract, web_parse → use `web`
  - code_symbols, library, diagnostics, graph → use `code` or `knowledge`
  - analyze_file, debug_error, prepare_context, suggest_next_tool → use `meta`
  - emergence, reflector, verify → use `cognitive`
  - store_fact, search_vibes → use `memory`
  """

  # Deprecated tool names - these are hidden from MCP exposure but still work internally
  @deprecated_tools MapSet.new([
    # Web aliases → use `web operation=...`
    "fetch", "search", "blink", "browser", "vision", "sonar", "web_extract", "web_parse",
    # Code aliases → use `code operation=...`
    "code_symbols", "library", "diagnostics", "graph",
    # Meta aliases → use `meta operation=...`
    "analyze_file", "debug_error", "prepare_context", "suggest_next_tool",
    # Cognitive aliases → use `cognitive operation=...`
    "emergence", "reflector", "verify",
    # Memory aliases → use `memory operation=...`
    "store_fact", "search_vibes"
  ])

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
            default: true,
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
        "Executes shell commands and manages processes with automatic memory context. You MUST provide the 'command' string argument explicitly. Do not run this without a command. Operations: execute (default), start_process, read_output, interact, kill, force_kill, list_sessions, list_processes. Responses include related memories (past errors, patterns) for accuracy. 💡 Memory context is auto-included. Store important results with `memory operation=store category=action`.",
      input_schema: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "The actual shell command to execute (e.g., 'ls -la', 'npm test', 'cargo build'). This parameter is REQUIRED."},
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
            default: true,
            description:
              "Skip auto-including memory context (for batch/performance-sensitive operations)"
          }
        },
        required: ["command"]
      }
    },
    # ==========================================================================
    # WEB - Unified Web Operations (Phase 4 Consolidation)
    # Consolidates: fetch, search, blink, browser, vision, sonar, web_extract, web_parse
    # ==========================================================================
    %{
      name: "web",
      description: """
      🌐 UNIFIED WEB OPERATIONS - All network, browser, and vision tools in one!

      This tool consolidates 8 previous tools for simpler orchestration:
      • fetch → `operation=fetch`
      • search → `operation=search`  
      • blink → `operation=blink`
      • browser → `operation=browser`
      • vision → `operation=vision`
      • sonar → `operation=sonar`
      • web_extract → `operation=extract`
      • web_parse → `operation=parse`

      ## Operations

      ### Content Retrieval
      • `fetch` - URL content in various formats (text/html/json/markdown/raw)
      • `extract` - Clean content extraction (Readability-style)
      • `parse` - Convert HTML to Markdown

      ### Search
      • `search` - Web search with library-first optimization
      • `code_search` - Code-specific search
      • `image_search` - Image search with optional vision analysis

      ### Browser Automation (HTTP-level)
      • `blink` - HTTP-level browser emulation (fast, bypasses basic WAF)
      • `blink_analyze` - Analyze URL protection type
      • `blink_smart` - Smart fetch with auto-escalation

      ### Browser Automation (Full)
      • `browser` - Full Puppeteer fetch (JavaScript execution)
      • `screenshot` - Capture page screenshot
      • `pdf` - Generate PDF from page
      • `evaluate` - Execute JavaScript on page
      • `interact` - UI automation actions
      • `test` - Run browser-based tests

      ### Vision & Accessibility
      • `vision` - Analyze images with AI
      • `sonar` - UI accessibility scanning with optional vision

      ## Examples

      ```
      # Fetch content
      web operation=fetch url="https://example.com" format=markdown

      # Web search (checks library cache first!)
      web operation=search query="phoenix framework docs"

      # Screenshot a page
      web operation=screenshot url="https://example.com" full_page=true

      # Analyze an image
      web operation=vision image="https://..." prompt="Describe this UI"

      # Bypass bot protection
      web operation=blink_smart url="https://protected-site.com"
      ```

      💡 TIP: For package docs, use `code operation=library_get` - it's faster (cached)!
      """,
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: [
              "fetch",
              "extract",
              "parse",
              "search",
              "code_search",
              "image_search",
              "blink",
              "blink_analyze",
              "blink_smart",
              "browser",
              "screenshot",
              "pdf",
              "evaluate",
              "interact",
              "test",
              "vision",
              "sonar"
            ],
            default: "fetch",
            description: "Operation to perform (default: fetch)"
          },
          # Common URL parameter
          url: %{type: "string", description: "URL for fetch/extract/blink/browser operations"},

          # Fetch parameters
          format: %{
            type: "string",
            enum: ["text", "html", "json", "markdown", "raw"],
            default: "text",
            description: "For fetch: output format"
          },
          method: %{
            type: "string",
            enum: ["get", "post"],
            default: "get",
            description: "For fetch: HTTP method"
          },
          json: %{type: "object", description: "For fetch: JSON body for POST requests"},
          headers: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{name: %{type: "string"}, value: %{type: "string"}}
            },
            description: "For fetch: HTTP headers"
          },
          timeout: %{type: "integer", description: "Timeout in milliseconds"},
          analyze_image: %{
            type: "boolean",
            default: false,
            description: "For fetch: auto-analyze image URLs with vision"
          },

          # Search parameters
          query: %{type: "string", description: "For search: search query"},
          num_results: %{type: "integer", default: 10, description: "For search: max results"},
          backend: %{
            type: "string",
            enum: ["auto", "duckduckgo", "bing", "brave"],
            default: "auto",
            description: "For search: search backend"
          },
          analyze_images: %{
            type: "boolean",
            default: false,
            description: "For image_search: analyze results with vision"
          },
          max_analyze: %{
            type: "integer",
            default: 3,
            description: "For image_search: max images to analyze"
          },

          # Blink parameters
          browser_profile: %{
            type: "string",
            enum: ["chrome", "firefox", "safari", "random"],
            default: "chrome",
            description: "For blink: browser to impersonate"
          },
          layer: %{type: "integer", default: 1, description: "For blink: bypass layer (0-2)"},
          max_retries: %{
            type: "integer",
            default: 3,
            description: "For blink_smart: max retry attempts"
          },

          # Browser parameters
          profile: %{
            type: "string",
            enum: ["chrome", "firefox", "safari", "mobile"],
            default: "chrome",
            description: "For browser: browser profile"
          },
          wait_for_selector: %{type: "string", description: "For browser: CSS selector to wait for"},
          wait_for_challenge: %{
            type: "boolean",
            default: true,
            description: "For browser: wait for Cloudflare"
          },
          force_browser: %{
            type: "boolean",
            default: false,
            description: "For browser: skip Blink optimization"
          },
          full_page: %{
            type: "boolean",
            default: true,
            description: "For screenshot: capture full page"
          },
          script: %{type: "string", description: "For evaluate: JavaScript code to execute"},
          actions: %{
            type: "string",
            description: "For interact: JSON array of actions [{type, selector, ...}]"
          },
          tests: %{
            type: "string",
            description: "For test: JSON array of test cases [{name, actions, assertions}]"
          },

          # Vision parameters
          image: %{type: "string", description: "For vision: image URL or base64 data"},
          prompt: %{type: "string", description: "For vision/sonar: analysis prompt"},
          max_tokens: %{
            type: "integer",
            default: 1000,
            description: "For vision: max response length"
          },

          # Sonar parameters
          vision: %{
            type: "boolean",
            default: false,
            description: "For sonar: include vision analysis"
          },

          # Extract parameters
          include_structured: %{
            type: "boolean",
            default: false,
            description: "For extract: include JSON-LD/OpenGraph"
          },

          # Parse parameters
          html: %{type: "string", description: "For parse: HTML content to convert"}
        },
        required: []
      }
    },
    # ==========================================================================
    # FETCH - [DEPRECATED] Use `web operation=fetch` instead
    # ==========================================================================
    %{
      name: "fetch",
      description:
        "⚠️ DEPRECATED: Use `web operation=fetch` instead. Fetch URL content. Format: text, html, json, markdown, raw.",
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
    # WEB_PARSE - [DEPRECATED] Use `web operation=parse` instead
    # ==========================================================================
    %{
      name: "web_parse",
      description: "⚠️ DEPRECATED: Use `web operation=parse` instead. Converts HTML to Markdown.",
      input_schema: %{
        type: "object",
        properties: %{html: %{type: "string"}},
        required: ["html"]
      }
    },
    # ==========================================================================
    # SEARCH - [DEPRECATED] Use `web operation=search` instead
    # ==========================================================================
    %{
      name: "search",
      description:
        "⚠️ DEPRECATED: Use `web operation=search` instead. Web search with DuckDuckGo/Bing/Brave fallback.",
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
    # WEB_EXTRACT - [DEPRECATED] Use `web operation=extract` instead
    # ==========================================================================
    %{
      name: "web_extract",
      description:
        "⚠️ DEPRECATED: Use `web operation=extract` instead. Extract clean content from web pages.",
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
    # SONAR - [DEPRECATED] Use `web operation=sonar` instead
    # ==========================================================================
    %{
      name: "sonar",
      description:
        "⚠️ DEPRECATED: Use `web operation=sonar` instead. UI Accessibility Scanner with optional vision analysis.",
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
    # VISION - [DEPRECATED] Use `web operation=vision` instead
    # ==========================================================================
    %{
      name: "vision",
      description:
        "⚠️ DEPRECATED: Use `web operation=vision` instead. Analyze images using vision-capable LLM.",
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
      description: """
      🧠 KNOWLEDGE GRAPH - Query RELATIONSHIPS between concepts, code, and entities.

      ⚠️ AUTO-TRIGGER: This tool should be called automatically when:
      • "how does X relate to Y" / "what depends on" / "what uses"
      • Architecture questions ("structure of", "flow of", "pipeline")
      • Dependency exploration ("imports", "calls", "requires")
      • "Which modules/files/functions" questions
      • Understanding code relationships before changes

      OPERATIONS:
      • query: Natural language relationship queries
      • teach: Store new relationships ("A depends on B")
      • traverse: Explore connections from a node
      • path: Find connection chain between two entities
      • neighborhood: Get nearby nodes within N hops

      WHY use this vs file search:
      - Understands RELATIONSHIPS not just text matches
      - Remembers context ACROSS SESSIONS
      - Can infer transitive dependencies (A→B→C means A→C)

      🚀 BOOTSTRAP: Run `operation=link path='/project/src'` at session start!
      """,
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
    # BLINK - [DEPRECATED] Use `web operation=blink` instead
    # ==========================================================================
    %{
      name: "blink",
      description:
        "⚠️ DEPRECATED: Use `web operation=blink` instead. HTTP-level browser emulation for bypassing basic bot detection.",
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
    # BROWSER - [DEPRECATED] Use `web operation=browser` instead
    # ==========================================================================
    %{
      name: "browser",
      description:
        "⚠️ DEPRECATED: Use `web operation=browser` instead. Full Puppeteer browser automation with JavaScript execution.",
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
            default: 60_000,
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
    # CODE - Unified Code Intelligence (SPEC-021 + SPEC-022 + SPEC-029)
    # Consolidates: code_symbols, library, diagnostics
    # ==========================================================================
    %{
      name: "code",
      description: """
      🧠 UNIFIED CODE INTELLIGENCE - Symbols, Library Docs, and Diagnostics in ONE tool!

      Three operation groups:
      1. SYMBOLS (code analysis) - Find definitions, references, call graphs
      2. LIBRARY (package docs) - Get/search npm/pypi/hex/crates documentation
      3. DIAGNOSTICS (errors) - Compile, lint, typecheck

      ═══════════════════════════════════════════════════════════════════════════
      SYMBOLS OPERATIONS (use instead of file search!)
      ═══════════════════════════════════════════════════════════════════════════
      ✓ code symbols path="lib/auth.ex"           → list all symbols in file
      ✓ code definition name="authenticate"        → find where function is defined
      ✓ code references name="UserService"         → find all usages
      ✓ code call_graph name="handle_request"      → who calls what
      ✓ code search pattern="auth*" kind=function  → search by pattern
      ✓ code index path="/project/src"             → build symbol database
      ✓ code parse source="def foo..." language=elixir → parse source code

      ═══════════════════════════════════════════════════════════════════════════
      LIBRARY OPERATIONS (faster than web search!)
      ═══════════════════════════════════════════════════════════════════════════
      ✓ code library_get name="phoenix" ecosystem=hex     → get package docs
      ✓ code library_search query="json" ecosystem=npm    → search packages
      ✓ code library_ensure name="requests" ecosystem=pypi → cache for offline
      ✓ code library_discover path="."                    → auto-cache all deps
      ✓ code library_stats                                → cache statistics

      ═══════════════════════════════════════════════════════════════════════════
      DIAGNOSTICS OPERATIONS (better than terminal!)
      ═══════════════════════════════════════════════════════════════════════════
      ✓ code diagnose path="/project"             → all errors (compile+lint+type)
      ✓ code check path="lib/"                    → compiler errors only
      ✓ code lint path="lib/"                     → linter warnings only
      ✓ code typecheck path="lib/"                → type errors only

      Supports: Elixir, TypeScript, Python, Rust, Go

      💡 MIGRATION: code_symbols, library, diagnostics tools still work but redirect here.
      """,
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: [
              # Symbol operations
              "parse",
              "symbols",
              "references",
              "search",
              "definition",
              "call_graph",
              "index",
              # Library operations
              "library",
              "library_get",
              "library_search",
              "library_ensure",
              "library_discover",
              "library_stats",
              # Diagnostics operations
              "check",
              "lint",
              "typecheck",
              "diagnose",
              "diagnostics_all"
            ],
            default: "symbols",
            description:
              "Operation: symbols/definition/references/call_graph/search/index/parse (code analysis), library_get/library_search/library_ensure/library_discover/library_stats (package docs), check/lint/typecheck/diagnose (diagnostics)"
          },
          # Symbol parameters
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
            enum: ["elixir", "python", "javascript", "typescript", "tsx", "auto", "rust", "go"],
            description: "Language for parsing or diagnostics (auto-detects if not specified)"
          },
          name: %{
            type: "string",
            description: "Symbol name to search for (for definition/references/call_graph)"
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
          # Library parameters
          ecosystem: %{
            type: "string",
            enum: ["hex", "pypi", "npm", "crates"],
            default: "hex",
            description: "Package ecosystem for library operations"
          },
          query: %{
            type: "string",
            description: "Search query for library_search"
          },
          version: %{
            type: "string",
            description: "Specific package version (default: latest)"
          },
          # Diagnostics parameters
          severity: %{
            type: "string",
            enum: ["error", "warning", "info", "all"],
            default: "all",
            description: "Filter diagnostics by severity level"
          },
          # Common
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
    # CODE_SYMBOLS - [DEPRECATED] Use 'code' tool instead
    # Kept for backward compatibility - redirects to unified code tool
    # ==========================================================================
    %{
      name: "code_symbols",
      description: """
      ⚠️ DEPRECATED: Use 'code' tool instead - it has symbols + library + diagnostics!

      This tool still works but redirects to the unified 'code' tool.

      Quick migration:
      • code_symbols symbols path="lib/" → code symbols path="lib/"
      • code_symbols definition name="foo" → code definition name="foo"
      • code_symbols references name="Bar" → code references name="Bar"

      🎯 The 'code' tool also includes library docs and diagnostics!
      """,
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
    # LIBRARY - [DEPRECATED] Use 'code' tool instead
    # Kept for backward compatibility - redirects to unified code tool
    # ==========================================================================
    %{
      name: "library",
      description: """
      ⚠️ DEPRECATED: Use 'code' tool instead - it has library + symbols + diagnostics!

      This tool still works but redirects to the unified 'code' tool.

      Quick migration:
      • library get name="phoenix" → code library_get name="phoenix" ecosystem=hex
      • library search query="json" → code library_search query="json" ecosystem=npm
      • library discover path="." → code library_discover path="."

      🎯 The 'code' tool also includes symbol navigation and diagnostics!
      """,
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
      description: """
      ⚠️ DEPRECATED: Use 'knowledge' tool instead - it has all graph operations plus more!

      This tool redirects to the unified 'knowledge' tool.

      Quick migration guide:
      • graph operation=query → knowledge operation=query
      • graph operation=link → knowledge operation=link (IMPORTANT: indexes code!)
      • graph operation=traverse → knowledge operation=traverse

      🚀 CRITICAL: Run `knowledge operation=link path='/project/src'` FIRST to enable graph queries!
      Without indexing, the knowledge graph is empty.

      💡 TIP: Switch to 'knowledge' tool for access to teach, sync_dependencies, and neighborhood operations.
      """,
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
        "Epistemic uncertainty and meta-cognitive operations. Assess confidence, detect knowledge gaps, and generate calibrated responses. Operations: assess (evaluate confidence), gaps (detect knowledge gaps), query (full epistemic query with calibrated response), can_answer (check if topic is answerable), suggest (get learning suggestions), stats (tracker statistics). ALSO INCLUDES: verify_* operations (SPEC-AI-TEST executable verification), emergence_* operations (SPEC-044 pattern detection), reflector_* operations (SPEC-043 self-reflection), verification_* operations (tracking). These are consolidated here for MCP cache compatibility.",
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: [
              "assess",
              "gaps",
              "query",
              "can_answer",
              "suggest",
              "stats",
              # Verify operations (SPEC-AI-TEST)
              "verify_count",
              "verify_math",
              "verify_logic",
              "verify_compare",
              "verify_self_check",
              # Emergence operations (SPEC-044)
              "emergence_detect",
              "emergence_dashboard",
              "emergence_alerts",
              "emergence_amplify",
              "emergence_promote",
              "emergence_cycle",
              "emergence_list",
              "emergence_search",
              "emergence_suggest",
              "emergence_status",
              # Reflector operations (SPEC-043)
              "reflector_reflect",
              "reflector_evaluate",
              "reflector_confidence",
              "reflector_errors",
              "reflector_format",
              "reflector_config",
              # Verification tracking
              "verification_stats",
              "verification_overconfidence",
              "verification_success_by_type",
              "verification_brier_score"
            ],
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
    # REASON - Unified Reasoning Engine (SPEC-035)
    # ==========================================================================
    %{
      name: "reason",
      description: """
      🧠 UNIFIED REASONING ENGINE - Use this BEFORE making complex changes!

      ⚠️ AUTO-TRIGGER: This tool should be called automatically when:
      • Multi-step tasks (implement feature, refactor, migrate)
      • Decision points ("should I", "which is better", "vs")
      • Architecture changes (restructure, redesign, modularize)
      • Debugging complex issues (intermittent bugs, race conditions)
      • Uncertainty detected ("maybe", "unsure", "not sure")

      STRATEGIES:
      • CoT (default): Math, logic, step-by-step problems
      • ToT: Ambiguous problems, creative tasks, multiple approaches
      • ReAct: Problems requiring tool use (file, terminal, search)
      • Reflexion: Learning from failures, iterative improvement

      WORKFLOW:
      1. `guided` → analyzes problem, selects strategy, returns session_id
      2. `step` → record reasoning steps with evaluation
      3. `branch`/`backtrack` → explore alternatives (ToT)
      4. `verify` → check logical consistency
      5. `reflect` → store lessons learned
      6. `conclude` → synthesize final answer

      💡 Memory integration means similar past problems are auto-retrieved!
      """,
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: [
              "guided",
              "decompose",
              "step",
              "verify",
              "reflect",
              "branch",
              "backtrack",
              "conclude"
            ],
            default: "guided",
            description:
              "Operation: guided (start), decompose, step, verify, reflect, branch (ToT), backtrack (ToT), conclude"
          },
          problem: %{
            type: "string",
            description: "For guided/decompose: The problem to reason about"
          },
          session_id: %{
            type: "string",
            description:
              "Session ID returned from guided (for step, reflect, branch, backtrack, conclude)"
          },
          thought: %{
            type: "string",
            description: "For step/branch: The reasoning step or branch thought"
          },
          strategy: %{
            type: "string",
            enum: ["auto", "cot", "tot", "react", "reflexion"],
            default: "auto",
            description: "For guided: Force a specific reasoning strategy"
          },
          thoughts: %{
            type: "array",
            items: %{type: "string"},
            description: "For verify: List of thoughts to verify (alternative to session_id)"
          },
          success: %{
            type: "boolean",
            default: false,
            description: "For reflect: Whether the reasoning led to success"
          },
          error: %{
            type: "string",
            description: "For reflect: Error message if unsuccessful"
          },
          result: %{
            type: "string",
            description: "For reflect: Result if successful"
          },
          to_branch: %{
            type: "string",
            description: "For backtrack: Specific branch ID to backtrack to"
          }
        },
        required: ["operation"]
      }
    },
    # ==========================================================================
    # DIAGNOSTICS - [DEPRECATED] Use 'code' tool instead
    # Kept for backward compatibility - redirects to unified code tool
    # ==========================================================================
    %{
      name: "diagnostics",
      description: """
      ⚠️ DEPRECATED: Use 'code' tool instead - it has diagnostics + symbols + library!

      This tool still works but redirects to the unified 'code' tool.

      Quick migration:
      • diagnostics all path="/project" → code diagnose path="/project"
      • diagnostics check path="lib/" → code check path="lib/"
      • diagnostics lint path="lib/" → code lint path="lib/"
      • diagnostics typecheck path="lib/" → code typecheck path="lib/"

      🎯 The 'code' tool also includes symbol navigation and library docs!
      """,
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
    },
    # ==========================================================================
    # ONBOARD - Project initialization meta-tool (SPEC-031 Phase 3)
    # ==========================================================================
    %{
      name: "onboard",
      description: """
      🚀 PROJECT INITIALIZATION - Run this at the start of each new project session!

      Auto-discovers and indexes:
      • Code symbols (functions, classes, modules) via code_symbols
      • Package dependencies (npm/pypi/hex/crates) via library
      • Knowledge graph nodes via knowledge

      After onboarding, ALL Mimo intelligent tools work at full capacity:
      • code_symbols → precise symbol lookup & navigation
      • knowledge → relationship queries & graph traversal
      • library → instant package documentation

      WHEN TO USE:
      • First time in a new project → onboard path='/project'
      • Project structure changed significantly → onboard force=true
      • Starting a new session in known project → usually auto-cached!

      The tool checks for existing project fingerprint. If already indexed,
      returns cached profile instantly. Use force=true to re-index.

      💡 TIP: This is the FIRST thing to run in any new codebase!
      """,
      input_schema: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            default: ".",
            description: "Project root path to index"
          },
          force: %{
            type: "boolean",
            default: false,
            description: "Re-index even if already done"
          }
        }
      }
    },
    # ==========================================================================
    # ANALYZE_FILE - [DEPRECATED] Use 'meta operation=analyze_file' instead
    # ==========================================================================
    %{
      name: "analyze_file",
      description: """
      ⚠️ DEPRECATED: Use `meta operation=analyze_file` instead.

      📊 UNIFIED FILE ANALYSIS - Get complete understanding of any file in one call!

      Chains multiple tools for comprehensive analysis:
      1. file read → Get file content & metadata
      2. code_symbols symbols → Get code structure (functions, classes)
      3. diagnostics all → Get compile/lint errors
      4. knowledge node → Get related knowledge graph context

      💡 This tool still works but redirects to the unified 'meta' tool.
      """,
      input_schema: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "File path to analyze (required)"
          },
          include_content: %{
            type: "boolean",
            default: false,
            description: "Include file content in response"
          },
          max_content_lines: %{
            type: "integer",
            default: 100,
            description: "Max lines of content to include"
          }
        },
        required: ["path"]
      }
    },
    # ==========================================================================
    # DEBUG_ERROR - [DEPRECATED] Use 'meta operation=debug_error' instead
    # ==========================================================================
    %{
      name: "debug_error",
      description: """
      ⚠️ DEPRECATED: Use `meta operation=debug_error` instead.

      🔧 ERROR DEBUGGING ASSISTANT - Find solutions to errors fast!

      Chains multiple tools for comprehensive error analysis:
      1. memory search → Find past similar errors & solutions
      2. code_symbols definition → Find where error originates
      3. diagnostics check → Get current compiler errors

      💡 This tool still works but redirects to the unified 'meta' tool.
      """,
      input_schema: %{
        type: "object",
        properties: %{
          message: %{
            type: "string",
            description: "Error message to debug (required)"
          },
          path: %{
            type: "string",
            description: "Optional path to narrow diagnostics scope"
          },
          symbol: %{
            type: "string",
            description: "Optional symbol name to look up definition"
          }
        },
        required: ["message"]
      }
    },
    # ==========================================================================
    # META - Unified Meta/Orchestration Tool (Phase 2 Consolidation)
    # ==========================================================================
    %{
      name: "meta",
      description: """
      🎯 META TOOL - Unified orchestration and composite operations.

      Consolidates 4 composite tools into a single unified interface:
      • analyze_file: Unified file analysis (file + symbols + diagnostics + knowledge)
      • debug_error: Error debugging assistant (memory + symbols + diagnostics)
      • prepare_context: Smart context aggregation (memory + knowledge + code + library)
      • suggest_next_tool: Workflow guidance based on task

      WHEN TO USE:
      • File analysis → meta operation=analyze_file path="src/app.ts"
      • Error debugging → meta operation=debug_error message="undefined function"
      • Context gathering → meta operation=prepare_context query="implement auth"
      • Next step guidance → meta operation=suggest_next_tool task="fix this bug"

      WHY USE META:
      • Reduces tool count for MCP cache compatibility
      • Unified interface for orchestration operations
      • Legacy standalone tools still work (backward compatible)

      💡 Part of Phase 2 tool consolidation (36→14 tools).
      """,
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: ["analyze_file", "debug_error", "prepare_context", "suggest_next_tool"],
            description: "Operation to perform (default: analyze_file)"
          },
          # analyze_file parameters
          path: %{
            type: "string",
            description: "For analyze_file: File path to analyze"
          },
          include_content: %{
            type: "boolean",
            default: false,
            description: "For analyze_file: Include file content in response"
          },
          max_content_lines: %{
            type: "integer",
            default: 100,
            description: "For analyze_file: Max lines of content to include"
          },
          # debug_error parameters
          message: %{
            type: "string",
            description: "For debug_error: Error message to debug"
          },
          symbol: %{
            type: "string",
            description: "For debug_error: Optional symbol name to look up definition"
          },
          # prepare_context parameters
          query: %{
            type: "string",
            description: "For prepare_context: The task or question to gather context for"
          },
          max_tokens: %{
            type: "integer",
            description: "For prepare_context: Approximate max tokens for output (default: 2000)"
          },
          sources: %{
            type: "array",
            items: %{type: "string"},
            description: "For prepare_context: Sources to query (memory, knowledge, code, library)"
          },
          include_scores: %{
            type: "boolean",
            description: "For prepare_context: Include relevance scores in output"
          },
          # suggest_next_tool parameters
          task: %{
            type: "string",
            description: "For suggest_next_tool: What you're trying to accomplish"
          },
          recent_tools: %{
            type: "array",
            items: %{type: "string"},
            description: "For suggest_next_tool: Tools used recently in this task"
          },
          context: %{
            type: "string",
            description: "For suggest_next_tool: Additional context about the situation"
          }
        },
        required: []
      }
    },
    # ==========================================================================
    # PREPARE_CONTEXT - [DEPRECATED] Use 'meta operation=prepare_context' instead
    # ==========================================================================
    # ==========================================================================
    # PREPARE_CONTEXT - [DEPRECATED] Use 'meta operation=prepare_context' instead
    # ==========================================================================
    %{
      name: "prepare_context",
      description: """
      ⚠️ DEPRECATED: Use `meta operation=prepare_context` instead.

      🧠 SMART CONTEXT - Give any model photographic memory of the project!

      Aggregates context from ALL Mimo cognitive systems in parallel:
      1. memory search → Relevant past memories and insights
      2. knowledge graph → Related concepts and relationships
      3. code_symbols → Matching code definitions and symbols
      4. library docs → Related package documentation

      💡 This tool still works but redirects to the unified 'meta' tool.
      """,
      input_schema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "The task or question to gather context for (required)"
          },
          max_tokens: %{
            type: "integer",
            description: "Approximate max tokens for output (default: 2000)"
          },
          sources: %{
            type: "array",
            items: %{type: "string"},
            description: "Sources to query: memory, knowledge, code, library (default: all)"
          },
          include_scores: %{
            type: "boolean",
            description: "Include relevance scores in output (default: false)"
          }
        },
        required: ["query"]
      }
    },
    # ==========================================================================
    # SUGGEST_NEXT_TOOL - [DEPRECATED] Use 'meta operation=suggest_next_tool' instead
    # ==========================================================================
    %{
      name: "suggest_next_tool",
      description: """
      ⚠️ DEPRECATED: Use `meta operation=suggest_next_tool` instead.

      🧭 WORKFLOW ROUTER - Get Mimo-optimal guidance for your next step!

      Analyzes your current task and recent tool usage to suggest the best next tool
      according to the Mimo workflow: Context → Intelligence → Action → Learning.

      💡 This tool still works but redirects to the unified 'meta' tool.
      """,
      input_schema: %{
        type: "object",
        properties: %{
          task: %{
            type: "string",
            description: "What you're trying to accomplish (required)"
          },
          recent_tools: %{
            type: "array",
            items: %{type: "string"},
            description: "Tools used recently in this task (helps avoid redundant suggestions)"
          },
          context: %{
            type: "string",
            description: "Additional context about the current situation"
          }
        },
        required: ["task"]
      }
    },
    # ==========================================================================
    # EMERGENCE - [DEPRECATED] Use 'cognitive operation=emergence_*' instead
    # ==========================================================================
    %{
      name: "emergence",
      description: """
      ⚠️ DEPRECATED: Use `cognitive operation=emergence_*` instead.

      🌱 EMERGENCE - Detect and promote emergent patterns in AI behavior.

      This tool still works but redirects to the unified 'cognitive' tool.

      Quick migration:
      • emergence operation=dashboard → cognitive operation=emergence_dashboard
      • emergence operation=detect → cognitive operation=emergence_detect
      • emergence operation=promote → cognitive operation=emergence_promote

      💡 The 'cognitive' tool consolidates all meta-cognitive operations.
      """,
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: [
              "detect",
              "dashboard",
              "alerts",
              "amplify",
              "promote",
              "cycle",
              "list",
              "search",
              "suggest",
              "status",
              "pattern"
            ],
            default: "dashboard",
            description: "Operation to perform"
          },
          pattern_id: %{
            type: "string",
            description: "Pattern ID for pattern/amplify/promote operations"
          },
          type: %{
            type: "string",
            enum: ["tool_sequence", "memory_cluster", "error_recovery", "optimization"],
            description: "Filter by pattern type for list operation"
          },
          status: %{
            type: "string",
            enum: ["emerging", "stable", "promoted", "dormant"],
            description: "Filter by pattern status for list operation"
          },
          query: %{
            type: "string",
            description: "Search query for search operation"
          },
          task: %{
            type: "string",
            description: "Task description for suggest operation"
          },
          limit: %{
            type: "integer",
            default: 20,
            description: "Maximum results for list/search operations"
          },
          min_confidence: %{
            type: "number",
            minimum: 0,
            maximum: 1,
            default: 0.5,
            description: "Minimum confidence threshold"
          }
        },
        required: []
      }
    },
    # ==========================================================================
    # REFLECTOR - [DEPRECATED] Use 'cognitive operation=reflector_*' instead
    # ==========================================================================
    %{
      name: "reflector",
      description: """
      ⚠️ DEPRECATED: Use `cognitive operation=reflector_*` instead.

      🪞 REFLECTOR - Metacognitive self-reflection and evaluation system.

      This tool still works but redirects to the unified 'cognitive' tool.

      Quick migration:
      • reflector operation=reflect → cognitive operation=reflector_reflect
      • reflector operation=evaluate → cognitive operation=reflector_evaluate
      • reflector operation=confidence → cognitive operation=reflector_confidence

      💡 The 'cognitive' tool consolidates all meta-cognitive operations.
      """,
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: ["reflect", "evaluate", "confidence", "errors", "format", "config"],
            default: "reflect",
            description: "Operation to perform"
          },
          content: %{
            type: "string",
            description: "Content to reflect on (thought, response, action)"
          },
          context: %{
            type: "string",
            description: "Additional context for reflection"
          },
          task: %{
            type: "string",
            description: "Original task/request being addressed"
          },
          dimensions: %{
            type: "array",
            items: %{
              type: "string",
              enum: ["accuracy", "completeness", "coherence", "relevance", "clarity"]
            },
            description: "Specific dimensions to evaluate (default: all)"
          },
          depth: %{
            type: "string",
            enum: ["quick", "standard", "deep"],
            default: "standard",
            description: "Reflection depth level"
          },
          include_suggestions: %{
            type: "boolean",
            default: true,
            description: "Include improvement suggestions"
          }
        },
        required: []
      }
    },
    # ==========================================================================
    # VERIFY - [DEPRECATED] Use 'cognitive operation=verify_*' instead
    # ==========================================================================
    %{
      name: "verify",
      description: """
      ⚠️ DEPRECATED: Use `cognitive operation=verify_*` instead.

      ✅ VERIFY - Executable verification for AI claims.

      This tool still works but redirects to the unified 'cognitive' tool.

      Quick migration:
      • verify operation=count → cognitive operation=verify_count
      • verify operation=math → cognitive operation=verify_math
      • verify operation=logic → cognitive operation=verify_logic

      💡 The 'cognitive' tool consolidates all meta-cognitive operations.
      """,
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: ["count", "math", "logic", "compare", "self_check"],
            description: "Type of verification to perform"
          },
          # Count operation parameters
          text: %{
            type: "string",
            description: "For count: text to analyze"
          },
          target: %{
            type: "string",
            description: "For count (letter): the letter/character to count"
          },
          type: %{
            type: "string",
            enum: ["letter", "word", "character"],
            description: "For count: what to count (letter/word/character)"
          },
          # Math operation parameters
          expression: %{
            type: "string",
            description: "For math: arithmetic expression to evaluate (e.g., '17 * 23')"
          },
          claimed_result: %{
            type: "number",
            description: "For math: the result you claim is correct"
          },
          # Logic operation parameters
          statements: %{
            type: "array",
            items: %{type: "string"},
            description: "For logic: list of logical statements/premises"
          },
          claim: %{
            type: "string",
            description: "For logic: the claim to verify against statements"
          },
          # Compare operation parameters
          value_a: %{
            type: "number",
            description: "For compare: first value"
          },
          value_b: %{
            type: "number",
            description: "For compare: second value"
          },
          relation: %{
            type: "string",
            enum: ["greater", "less", "equal", "greater_equal", "less_equal"],
            description: "For compare: relationship to verify"
          },
          # Self-check operation parameters
          problem: %{
            type: "string",
            description: "For self_check: the original problem/question"
          },
          claimed_answer: %{
            type: ["string", "number", "boolean", "null"],
            description: "The answer you want to verify independently"
          }
        },
        required: ["operation"]
      }
    },
    # ==========================================================================
    # AUTONOMOUS - Autonomous task execution with cognitive enhancement (SPEC-071)
    # ==========================================================================
    %{
      name: "autonomous",
      description:
        "Autonomous task execution with cognitive enhancement. Queue tasks for background execution with memory-powered hints, contradiction checking, and circuit breaker safety. Operations: queue (add task), status (get runner status), pause (stop execution), resume (continue execution), reset_circuit (reset after failures), list_queue (show queued tasks), clear_queue (remove all queued tasks), check_safety (validate task safety).",
      input_schema: %{
        type: "object",
        properties: %{
          operation: %{
            type: "string",
            enum: ["queue", "status", "pause", "resume", "reset_circuit", "list_queue", "clear_queue", "check_safety"],
            default: "status",
            description: "Operation to perform"
          },
          # Task queue parameters
          type: %{
            type: "string",
            description: "For queue: Task type (e.g., 'test', 'build', 'deploy', 'memory_search')"
          },
          description: %{
            type: "string",
            description: "For queue: Human-readable task description (required)"
          },
          command: %{
            type: "string",
            description: "For queue: Shell command to execute"
          },
          path: %{
            type: "string",
            description: "For queue: File path for file operations"
          },
          query: %{
            type: "string",
            description: "For queue: Query string for search-type tasks"
          }
        },
        required: ["operation"]
      }
    }
  ]

  @doc """
  Returns all MCP tool definitions (filtered - excludes deprecated tools).
  
  Deprecated tools are hidden from MCP exposure to reduce context consumption
  but still work internally for backward compatibility.
  """
  def definitions do
    @tool_definitions
    |> Enum.reject(fn tool -> 
      MapSet.member?(@deprecated_tools, to_string(tool.name))
    end)
  end

  @doc """
  Returns the list of tool definitions (alias for definitions/0).
  """
  def list_tools, do: definitions()

  @doc """
  Returns ALL tool definitions including deprecated ones.
  Used internally for backward compatibility routing.
  """
  def all_definitions, do: @tool_definitions

  @doc """
  Returns the set of deprecated tool names.
  """
  def deprecated_tools, do: @deprecated_tools

  @doc """
  Checks if a tool name is deprecated.
  """
  def deprecated?(name), do: MapSet.member?(@deprecated_tools, to_string(name))
end
