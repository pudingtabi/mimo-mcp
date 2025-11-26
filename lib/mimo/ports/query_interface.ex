defmodule Mimo.QueryInterface do
  @moduledoc """
  Port: QueryInterface

  Abstract port for natural language queries routed through the Meta-Cognitive Router.
  This port is protocol-agnostic - adapters (HTTP, MCP, CLI) call these functions.

  Part of the Universal Aperture architecture - isolates Mimo Core from protocol concerns.
  """
  require Logger

  @doc """
  Process a natural language query through the Meta-Cognitive Router.
  Routes to appropriate stores (Episodic, Semantic, Procedural) based on query classification.

  ## Parameters
    - query: The natural language query string
    - context_id: Optional session/context identifier for continuity
    - opts: Additional options (timeout_ms, etc.)

  ## Returns
    - {:ok, result} with router_decision and results from memory stores
    - {:error, reason} on failure
  """
  @spec ask(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def ask(query, context_id \\ nil, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5000)

    task =
      Task.async(fn ->
        # Classify the query through Meta-Cognitive Router
        router_decision = Mimo.MetaCognitiveRouter.classify(query)

        # Search memories based on router decision
        memories = search_by_decision(query, router_decision)

        # Consult LLM if needed for synthesis
        synthesis =
          case router_decision.requires_synthesis do
            true ->
              case Mimo.Brain.LLM.consult_chief_of_staff(query, memories.episodic) do
                {:ok, response} -> response
                {:error, _} -> nil
              end

            false ->
              nil
          end

        %{
          query_id: UUID.uuid4(),
          router_decision: router_decision,
          results: memories,
          synthesis: synthesis,
          context_id: context_id
        }
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp search_by_decision(query, decision) do
    %{
      episodic: search_episodic(query, decision),
      semantic: search_semantic(query, decision),
      procedural: search_procedural(query, decision)
    }
  end

  defp search_episodic(query, %{primary_store: :episodic} = _decision) do
    Mimo.Brain.Memory.search_memories(query, limit: 10)
  end

  defp search_episodic(query, %{secondary_stores: stores}) when is_list(stores) do
    if :episodic in stores do
      Mimo.Brain.Memory.search_memories(query, limit: 5)
    else
      []
    end
  end

  defp search_episodic(_query, _decision), do: []

  defp search_semantic(_query, %{primary_store: :semantic} = _decision) do
    # TODO: Implement graph/JSON-LD semantic store
    %{status: "not_implemented", message: "Semantic store pending implementation"}
  end

  defp search_semantic(_query, _decision), do: nil

  defp search_procedural(_query, %{primary_store: :procedural} = _decision) do
    # TODO: Implement rule engine procedural store
    %{status: "not_implemented", message: "Procedural store pending implementation"}
  end

  defp search_procedural(_query, _decision), do: nil
end
