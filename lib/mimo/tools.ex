defmodule Mimo.Tools do
  @moduledoc """
  MCP Tool Definitions and dispatcher.
  """

  @tool_definitions [
    %{
      name: "http_request",
      description:
        "Advanced HTTP client supporting POST, PUT, DELETE, custom headers, timeout control, and streaming responses. For simple GET-only requests, external fetch_* tools may be simpler.",
      input_schema: %{
        type: "object",
        properties: %{
          url: %{type: "string"},
          method: %{type: "string", enum: ["get", "post"], default: "get"},
          json: %{type: "object"},
          timeout: %{type: "integer"},
          headers: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{name: %{type: "string"}, value: %{type: "string"}}
            }
          }
        },
        required: ["url"]
      }
    },
    %{
      name: "web_parse",
      description: "Converts HTML to Markdown",
      input_schema: %{
        type: "object",
        properties: %{
          html: %{type: "string"}
        },
        required: ["html"]
      }
    },
    %{
      name: "terminal",
      description:
        "Execute sandboxed single commands with security allowlist. For interactive sessions with process management and pid tracking, use desktop_commander_* tools.",
      input_schema: %{
        type: "object",
        properties: %{
          command: %{type: "string"},
          timeout: %{type: "integer"},
          restricted: %{type: "boolean"}
        },
        required: ["command"]
      }
    },
    %{
      name: "file",
      description: "Sandboxed file operations (full-file and line-level)",
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
              "replace_string"
            ]
          },
          path: %{type: "string"},
          content: %{type: "string"},
          start_line: %{type: "integer"},
          end_line: %{type: "integer"},
          line_number: %{type: "integer"},
          pattern: %{type: "string"},
          old_str: %{type: "string"},
          new_str: %{type: "string"}
        },
        required: ["operation", "path"]
      }
    },
    %{
      name: "sonar",
      description: "UI Accessibility Scanner",
      input_schema: %{type: "object", properties: %{}}
    },
    %{
      name: "think",
      description: "Log reasoning steps",
      input_schema: %{
        type: "object",
        properties: %{
          thought: %{type: "string"}
        },
        required: ["thought"]
      }
    },
    %{
      name: "plan",
      description: "Log execution plan",
      input_schema: %{
        type: "object",
        properties: %{
          steps: %{type: "array", items: %{type: "string"}}
        },
        required: ["steps"]
      }
    },
    # Semantic Store Tools (Knowledge Graph)
    %{
      name: "consult_graph",
      description:
        "Query the semantic knowledge graph for entity relationships, dependencies, and transitive closures. Use this for structured relationship queries (e.g., 'what depends on X?'). For unstructured text search, use search_vibes or episodic memory tools.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Natural language query about relationships"},
          entity: %{type: "string", description: "Entity ID to query (e.g., 'service:auth')"},
          predicate: %{type: "string", description: "Relationship type (e.g., 'depends_on')"},
          depth: %{type: "integer", default: 3, description: "Max traversal depth"}
        },
        required: ["query"]
      }
    },
    %{
      name: "teach_mimo",
      description: "Add knowledge to the graph (teach a fact or relationship)",
      input_schema: %{
        type: "object",
        properties: %{
          text: %{type: "string", description: "Natural language fact to learn"},
          subject: %{type: "string", description: "Subject entity"},
          predicate: %{type: "string", description: "Relationship type"},
          object: %{type: "string", description: "Object entity"},
          source: %{type: "string", description: "Source of the fact"}
        },
        required: []
      }
    }
  ]

  def list_tools, do: @tool_definitions

  def dispatch(tool_name, arguments \\ %{}) do
    case tool_name do
      "http_request" ->
        Mimo.Skills.Network.fetch(arguments["url"], normalize_opts(arguments))

      "web_parse" ->
        {:ok, Mimo.Skills.Web.parse(arguments["html"])}

      "terminal" ->
        result =
          Mimo.Skills.Terminal.execute(arguments["command"],
            timeout: arguments["timeout"],
            restricted: Map.get(arguments, "restricted", true)
          )

        {:ok, result}

      "file" ->
        dispatch_file(arguments)

      "sonar" ->
        Mimo.Skills.Sonar.scan_ui()

      "think" ->
        Mimo.Skills.Cognition.think(arguments["thought"])

      "plan" ->
        Mimo.Skills.Cognition.plan(arguments["steps"])

      "consult_graph" ->
        dispatch_consult_graph(arguments)

      "teach_mimo" ->
        dispatch_teach_mimo(arguments)

      _ ->
        {:error, "Unknown tool: #{tool_name}"}
    end
  end

  defp dispatch_file(%{"operation" => op, "path" => path} = args) do
    case op do
      "read" ->
        Mimo.Skills.FileOps.read(path)

      "write" ->
        Mimo.Skills.FileOps.write(path, args["content"] || "")

      "ls" ->
        Mimo.Skills.FileOps.ls(path)

      "read_lines" ->
        start_line = args["start_line"] || 1
        end_line = args["end_line"] || -1
        Mimo.Skills.FileOps.read_lines(path, start_line, end_line)

      "insert_after" ->
        line_number = args["line_number"] || 0
        Mimo.Skills.FileOps.insert_after_line(path, line_number, args["content"] || "")

      "insert_before" ->
        line_number = args["line_number"] || 1
        Mimo.Skills.FileOps.insert_before_line(path, line_number, args["content"] || "")

      "replace_lines" ->
        start_line = args["start_line"] || 1
        end_line = args["end_line"] || args["start_line"] || 1
        Mimo.Skills.FileOps.replace_lines(path, start_line, end_line, args["content"] || "")

      "delete_lines" ->
        start_line = args["start_line"] || 1
        end_line = args["end_line"] || args["start_line"] || 1
        Mimo.Skills.FileOps.delete_lines(path, start_line, end_line)

      "search" ->
        Mimo.Skills.FileOps.search_lines(path, args["pattern"] || "")

      "replace_string" ->
        Mimo.Skills.FileOps.replace_string(path, args["old_str"] || "", args["new_str"] || "")

      _ ->
        {:error, "Unknown file operation: #{op}"}
    end
  end

  defp normalize_opts(args) do
    for {k, v} <- args, k in ["method", "timeout", "json", "headers"], v != nil, into: [] do
      key = if k == "method", do: :method, else: String.to_atom(k)
      value = if k == "method", do: String.to_atom(v), else: v
      {key, value}
    end
  end

  # ==========================================================================
  # Semantic Store Dispatchers
  # ==========================================================================

  defp dispatch_consult_graph(args) do
    alias Mimo.SemanticStore.{Query, Resolver}

    query = args["query"]
    entity = args["entity"]
    predicate = args["predicate"]
    depth = args["depth"] || 3

    cond do
      # Direct entity query
      entity && predicate ->
        case Query.transitive_closure(entity, "entity", predicate, max_depth: depth) do
          results when is_list(results) ->
            formatted =
              Enum.map(results, fn e ->
                %{id: e.id, type: e.type, depth: e.depth, path: e.path}
              end)

            {:ok, %{results: formatted, count: length(results)}}

          error ->
            error
        end

      # Natural language query - resolve entities first
      query ->
        # Extract potential entities from query
        case Resolver.resolve_entity(query, :auto) do
          {:ok, entity_id} ->
            relationships = Query.get_relationships(entity_id, "entity")
            {:ok, %{entity: entity_id, relationships: relationships}}

          {:error, :ambiguous, candidates} ->
            {:ok,
             %{
               ambiguous: true,
               candidates: candidates,
               message: "Multiple entities match. Please specify."
             }}

          {:error, _} ->
            {:ok, %{results: [], message: "No matching entities found"}}
        end

      true ->
        {:error, "Either 'query' or 'entity'+'predicate' required"}
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
      # Structured triple
      subject && predicate && object ->
        triple = %{subject: subject, predicate: predicate, object: object}

        case Ingestor.ingest_triple(triple, source) do
          {:ok, id} -> {:ok, %{status: "learned", triple_id: id}}
          error -> error
        end

      # Natural language
      text ->
        case Ingestor.ingest_text(text, source) do
          {:ok, count} -> {:ok, %{status: "learned", triples_created: count}}
          error -> error
        end

      true ->
        {:error, "Either 'text' or 'subject'+'predicate'+'object' required"}
    end
  end
end
