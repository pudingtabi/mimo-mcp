defmodule Mimo.ToolInterface do
  @moduledoc """
  Port: ToolInterface

  Abstract port for direct, low-level memory operations.
  Routes to internal tools or external skills via Registry.

  Part of the Universal Aperture architecture - isolates Mimo Core from protocol concerns.
  """
  require Logger

  @doc """
  Execute a tool by name with given arguments.
  Routes to internal tools or external skills automatically.

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
    # v3.0 Roadmap: Procedural store retrieval with FSM state machine lookup
    #               and execution context preparation for complex multi-step procedures
    # Current behavior: Returns "not_implemented" - procedures accessed via skills manifest
    {:ok,
     %{
       tool_call_id: UUID.uuid4(),
       status: "success",
       data: %{status: "not_implemented", message: "Procedural store pending implementation"}
     }}
  end

  def execute("mimo_reload_skills", _args) do
    case Mimo.ToolRegistry.reload_skills() do
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

  # Fallback: route unknown tools through Registry (external skills)
  def execute(tool_name, arguments) do
    case Mimo.ToolRegistry.get_tool_owner(tool_name) do
      {:ok, {:skill, skill_name, _pid}} ->
        # Route to external skill
        Logger.debug("Routing #{tool_name} to skill #{skill_name}")

        case Mimo.Skills.Client.call_tool(skill_name, tool_name, arguments) do
          {:ok, result} ->
            {:ok,
             %{
               tool_call_id: UUID.uuid4(),
               status: "success",
               data: result
             }}

          {:error, reason} ->
            {:error, "Skill execution failed: #{inspect(reason)}"}
        end

      {:ok, {:internal, _}} ->
        # Internal tool without specific handler - missing arguments
        {:error, "Missing required arguments for tool: #{tool_name}"}

      {:error, :not_found} ->
        available = Mimo.ToolRegistry.list_all_tools() |> Enum.map(& &1["name"]) |> Enum.take(10)
        {:error, "Unknown tool: #{tool_name}. Available tools include: #{inspect(available)}"}

      {:error, reason} ->
        {:error, "Tool routing failed: #{inspect(reason)}"}
    end
  end

  @doc """
  List all supported tools with their schemas.
  """
  @spec list_tools() :: [map()]
  def list_tools do
    Mimo.ToolRegistry.list_all_tools()
  end
end
