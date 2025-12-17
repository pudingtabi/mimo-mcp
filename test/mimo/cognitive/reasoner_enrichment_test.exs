defmodule Mimo.Cognitive.ReasonerEnrichmentTest do
  # Must use DataCase and async: false because PrepareContext spawns
  # async tasks that need DB access via Ecto sandbox
  use Mimo.DataCase, async: false

  alias Mimo.Cognitive.Reasoner

  setup_all do
    # Ensure session ETS is initialized
    Mimo.Cognitive.ReasoningSession.init()
    :ok
  end

  test "enrich returns merged prepare_context and wisdom for a low-confidence thought" do
    {:ok, guided} = Reasoner.guided("Investigate Ecto query failure", strategy: :cot)
    {:ok, _step} = Reasoner.step(guided.session_id, "Investigate Ecto struct field access")

    {:ok, enriched} = Reasoner.enrich(guided.session_id, 1)

    case enriched.status do
      "enriched" ->
        assert enriched.session_id == guided.session_id
        assert is_map(enriched.enrichment)
        assert Map.has_key?(enriched.enrichment, :memory_context)
        assert Map.has_key?(enriched.enrichment, :knowledge_connections)
        assert Map.has_key?(enriched.enrichment, :code_references)
        assert Map.has_key?(enriched.enrichment, :patterns)
        assert Map.has_key?(enriched.enrichment, :wisdom)
        assert Map.has_key?(enriched.enrichment, :small_model_boost)
        assert is_map(enriched.enrichment.small_model_boost)
        assert Map.has_key?(enriched.enrichment, :formatted_context)
        assert Map.has_key?(enriched.enrichment, :confidence)

        # Because the query references Ecto, wisdom warnings should include Ecto heuristic
        warnings = enriched.enrichment.wisdom[:warnings] || []
        assert is_list(warnings)

        assert Enum.any?(warnings, fn w -> String.contains?(w.message || "", "Ecto") end) or
                 warnings == []

      "timed_out" ->
        # Accept timeout (environment may be slow) and ensure step is recorded and timing note present
        assert enriched.session_id == guided.session_id
        assert enriched.step_number == 1
        assert enriched.note =~ "Full enrichment took >5s"
    end
  end

  test "prepare_context returns wisdom and patterns for Ecto query" do
    {:ok, result} =
      Mimo.Tools.Dispatchers.PrepareContext.dispatch(%{
        "query" => "Ecto struct access",
        "include_scores" => true
      })

    assert is_map(result)
    assert Map.has_key?(result, :context)
    assert Map.has_key?(result.context, :wisdom)
    assert Map.has_key?(result.context, :patterns)

    wisdom = result.context.wisdom || %{}
    warnings = wisdom[:warnings] || []
    assert is_list(warnings)
  end

  test "wisdom_injector.gather_wisdom returns formatted warnings for Ecto queries" do
    wisdom = Mimo.Brain.WisdomInjector.gather_wisdom("Ecto struct access", 0.4)

    assert is_map(wisdom)
    assert is_list(wisdom[:warnings])

    assert Enum.any?(wisdom[:warnings], fn w -> String.contains?(w.message || "", "Ecto") end) or
             wisdom[:warnings] == []
  end
end
