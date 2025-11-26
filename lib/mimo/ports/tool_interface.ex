defmodule Mimo.ToolInterface do
  @moduledoc """
  Port: ToolInterface

  Abstract port for direct, low-level memory operations.
  Provides store_fact/2, recall_procedure/2, search_vibes/2 operations.

  Part of the Universal Aperture architecture - isolates Mimo Core from protocol concerns.
  """
  require Logger

  @supported_tools [
    "store_fact",
    "recall_procedure",
    "search_vibes",
    "mimo_reload_skills",
    "mimo_store_memory",
    "ask_mimo"
  ]

  @doc """
  Execute a tool by name with given arguments.

  ## Supported Tools
    - store_fact: Insert JSON-LD triples into Semantic Store
    - recall_procedure: Retrieve rules from Procedural Store
    - search_vibes: Vector similarity search in Episodic Store
    - mimo_reload_skills: Hot-reload Procedural Store from disk
    - mimo_store_memory: Store a memory in the brain
    - ask_mimo: Consult Mimo's memory system

  ## Returns
    - {:ok, result} on success
    - {:error, reason} on failure
  """
  @spec execute(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def execute(tool_name, arguments \\ %{})

  def execute("search_vibes", %{"query" => query} = args) do
    limit = Map.get(args, "limit", 10)
    threshold = Map.get(args, "threshold", 0.3)

    results =
      Mimo.Brain.Memory.search_memories(query,
        limit: limit,
        min_similarity: threshold
      )

    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: results
     }}
  end

  def execute("store_fact", %{"content" => content} = args) do
    category = Map.get(args, "category", "fact")
    importance = Map.get(args, "importance", 0.5)

    case Mimo.Brain.Memory.persist_memory(content, category, importance) do
      {:ok, id} ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: %{stored: true, id: id}
         }}

      {:error, reason} ->
        {:error, "Failed to store fact: #{inspect(reason)}"}
    end
  end

  def execute("recall_procedure", %{"name" => _name} = _args) do
    # TODO: Implement procedural store retrieval
    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: %{status: "not_implemented", message: "Procedural store pending implementation"}
     }}
  end

  def execute("mimo_reload_skills", _args) do
    case Mimo.Registry.reload_skills() do
      {:ok, :reloaded} ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: %{status: "success", message: "Skills reloaded"}
         }}

      {:error, reason} ->
        {:error, "Reload failed: #{inspect(reason)}"}
    end
  end

  def execute("mimo_store_memory", %{"content" => content, "category" => category} = args) do
    importance = Map.get(args, "importance", 0.5)

    case Mimo.Brain.Memory.persist_memory(content, category, importance) do
      {:ok, id} ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: %{stored: true, id: id}
         }}

      {:error, reason} ->
        {:error, "Failed to store memory: #{inspect(reason)}"}
    end
  end

  def execute("ask_mimo", %{"query" => query}) do
    case Mimo.QueryInterface.ask(query) do
      {:ok, result} ->
        {:ok,
         %{
           tool_call_id: UUID.uuid4(),
           status: "success",
           data: result
         }}

      {:error, reason} ->
        {:error, "Query failed: #{inspect(reason)}"}
    end
  end

  def execute(tool_name, _args) when tool_name in @supported_tools do
    {:error, "Missing required arguments for tool: #{tool_name}"}
  end

  def execute(tool_name, _args) do
    {:error, "Unknown tool: #{tool_name}. Supported: #{inspect(@supported_tools)}"}
  end

  @doc """
  List all supported tools with their schemas.
  """
  @spec list_tools() :: [map()]
  def list_tools do
    [
      %{
        "name" => "search_vibes",
        "description" => "Vector similarity search in Episodic Store (memory search)",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query"},
            "limit" => %{"type" => "integer", "default" => 10, "description" => "Max results"},
            "threshold" => %{
              "type" => "number",
              "default" => 0.3,
              "description" => "Min similarity"
            }
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "store_fact",
        "description" => "Insert facts into Semantic/Episodic Store",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string", "description" => "The fact/content to store"},
            "category" => %{"type" => "string", "enum" => ["fact", "observation", "action", "plan"]},
            "importance" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
          },
          "required" => ["content"]
        }
      },
      %{
        "name" => "recall_procedure",
        "description" => "Retrieve rules from Procedural Store",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Procedure name to recall"}
          },
          "required" => ["name"]
        }
      },
      %{
        "name" => "mimo_reload_skills",
        "description" => "Hot-reload skills from disk without restart",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]
  end
end
