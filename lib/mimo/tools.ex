defmodule Mimo.Tools do
  @moduledoc """
  MCP Tool Definitions and dispatcher.

  Consolidated native Elixir tools - fewer tools, more power.
  Each tool handles multiple operations via the 'operation' parameter.

  ## Core Tools (8 total)

  1. `file` - All file operations (read, write, ls, search, info, etc.)
  2. `terminal` - All terminal/process operations
  3. `fetch` - All network operations (text, html, json, markdown)
  4. `think` - All cognitive operations (thought, plan, sequential)
  5. `web_parse` - Convert HTML to Markdown
  6. `search` - Web search via Exa AI
  7. `sonar` - UI accessibility scanner
  8. `knowledge` - Knowledge graph operations
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
            description: "YOLO mode: bypass ALL safety checks (default false)"
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
      description: "Fetch URL content. Format: text, html, json, markdown, raw. Supports GET/POST.",
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
          timeout: %{type: "integer"}
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
    # SEARCH - Web search (native, no API key required)
    # ==========================================================================
    %{
      name: "search",
      description:
        "Search the web using DuckDuckGo. Operations: web (default), code. No API key required.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{type: "string"},
          operation: %{type: "string", enum: ["web", "code"], default: "web"},
          num_results: %{type: "integer", description: "Max results (default 10)"}
        },
        required: ["query"]
      }
    },
    # ==========================================================================
    # SONAR - UI accessibility scanner
    # ==========================================================================
    %{
      name: "sonar",
      description: "UI Accessibility Scanner",
      input_schema: %{type: "object", properties: %{}}
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

      "sonar" ->
        Mimo.Skills.Sonar.scan_ui()

      "knowledge" ->
        dispatch_knowledge(arguments)

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
         "Unknown tool: #{tool_name}. Available: file, terminal, fetch, think, web_parse, search, sonar, knowledge"}
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
  # SEARCH DISPATCHER
  # ==========================================================================
  defp dispatch_search(args) do
    query = args["query"] || ""
    op = args["operation"] || "web"
    opts = if args["num_results"], do: [num_results: args["num_results"]], else: []

    case op do
      "web" -> Mimo.Skills.Network.web_search(query, opts)
      "code" -> Mimo.Skills.Network.code_search(query, opts)
      _ -> {:error, "Unknown search operation: #{op}"}
    end
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
end
