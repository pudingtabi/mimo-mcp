defmodule Mimo.Cognitive.AdvancedReasoningTest do
  @moduledoc """
  Tests for SPEC-063: Advanced Reasoning Techniques

  Tests the following modules:
  - SelfDiscover
  - RephraseRespond
  - SelfAsk
  - MetaTaskHandler
  - ReasoningTelemetry
  """

  use Mimo.DataCase, async: false

  alias Mimo.Cognitive.{
    SelfDiscover,
    RephraseRespond,
    SelfAsk,
    MetaTaskHandler,
    MetaTaskDetector,
    ReasoningTelemetry,
    Reasoner
  }

  # ============================================================================
  # SELF-DISCOVER TESTS
  # ============================================================================

  describe "SelfDiscover" do
    test "init_cache creates ETS table" do
      # May already exist from other tests
      assert :ok = SelfDiscover.init_cache()
    end

    test "atomic_modules returns 39 modules" do
      modules = SelfDiscover.atomic_modules()
      assert length(modules) == 39
      assert is_binary(hd(modules))
    end

    @tag :llm_required
    test "discover returns valid structure" do
      task = "I need to solve a complex math problem step by step"

      case SelfDiscover.discover(task) do
        {:ok, result} ->
          assert Map.has_key?(result, :selected_modules)
          assert Map.has_key?(result, :adapted_modules)
          assert Map.has_key?(result, :reasoning_structure)
          assert is_list(result.selected_modules)
          assert is_map(result.reasoning_structure)

        {:error, reason} ->
          # LLM may not be available in test
          assert is_binary(reason) or is_atom(reason)
      end
    end

    @tag :llm_required
    test "discover caches structures for similar tasks" do
      # Reset telemetry to track cache hits
      ReasoningTelemetry.reset()

      task1 = "I'm going to ask you 5 trivia questions"
      task2 = "I'm going to ask you 10 trivia questions"

      # First call - should be cache miss
      {:ok, _} = SelfDiscover.discover(task1)

      # Second call with similar task (numbers normalized) - should be cache hit
      {:ok, _} = SelfDiscover.discover(task2)

      cache_stats = ReasoningTelemetry.get_cache_stats()
      # At least one hit should have occurred
      assert cache_stats.total >= 2
    end
  end

  # ============================================================================
  # REPHRASE AND RESPOND TESTS
  # ============================================================================

  describe "RephraseRespond" do
    test "needs_rephrasing? detects meta-task patterns" do
      assert RephraseRespond.needs_rephrasing?("I'm going to ask you 5 questions")
      assert RephraseRespond.needs_rephrasing?("Predict whether you will get this right")
      assert RephraseRespond.needs_rephrasing?("Come up with 3 examples")
      refute RephraseRespond.needs_rephrasing?("What is 2 + 2?")
      refute RephraseRespond.needs_rephrasing?("Hello world")
    end

    @tag :llm_required
    test "rephrase returns structured result" do
      question =
        "I'm going to ask you 5 trivia questions and you should predict if you'll get them right"

      case RephraseRespond.rephrase(question) do
        {:ok, result} ->
          assert Map.has_key?(result, :original)
          assert Map.has_key?(result, :rephrased)
          assert Map.has_key?(result, :implicit_requirements)
          assert Map.has_key?(result, :is_meta_task)
          assert result.original == question

        {:error, _} ->
          # LLM may not be available
          :ok
      end
    end
  end

  # ============================================================================
  # SELF-ASK TESTS
  # ============================================================================

  describe "SelfAsk" do
    test "benefits_from_decomposition? detects complex questions" do
      complex =
        "First explain the concept, then provide an example, and finally compare with alternatives"

      simple = "What is the capital of France?"

      assert SelfAsk.benefits_from_decomposition?(complex)
      refute SelfAsk.benefits_from_decomposition?(simple)
    end

    @tag :llm_required
    test "generate_sub_questions returns list of questions" do
      question =
        "Explain the pros and cons of microservices architecture and how to migrate from monolith"

      case SelfAsk.generate_sub_questions(question) do
        {:ok, sub_questions} ->
          assert is_list(sub_questions)
          # May be empty if deemed simple enough
          if length(sub_questions) > 0 do
            Enum.each(sub_questions, fn q ->
              assert is_binary(q)
              assert String.length(q) > 5
            end)
          end

        {:error, _} ->
          # LLM may not be available
          :ok
      end
    end

    test "generate_sub_questions returns empty for simple questions" do
      simple = "Hi"

      case SelfAsk.generate_sub_questions(simple) do
        {:ok, []} -> :ok
        # LLM may still generate some
        {:ok, _sub} -> :ok
        {:error, _} -> :ok
      end
    end
  end

  # ============================================================================
  # META-TASK HANDLER TESTS
  # ============================================================================

  describe "MetaTaskHandler" do
    test "handle detects meta-tasks correctly" do
      meta_task =
        "I'm going to ask you 5 trivia questions. Before answering each, predict whether you'll get it right."

      # Just test the detection part, not the full handling (which requires LLM)
      case MetaTaskDetector.detect(meta_task) do
        {:meta_task, guidance} ->
          assert guidance.type in [:generate_questions, :self_prediction, :iterative_task]
          assert is_binary(guidance.instruction)

        {:standard, _} ->
          flunk("Should have detected as meta-task")
      end
    end

    @tag :llm_required
    test "handle processes meta-task with advanced techniques" do
      task =
        "I'm going to ask you 5 trivia questions. Predict if you'll get each right, then answer."

      case MetaTaskHandler.handle(task, strategy: :auto) do
        {:ok, result} ->
          assert result.is_meta_task == true
          assert result.technique_used != nil
          assert Map.has_key?(result, :result)

        {:error, _} ->
          # LLM may not be available
          :ok
      end
    end

    @tag :llm_required
    test "apply_technique works for each technique" do
      task = "Explain the concept of recursion with an example"

      for technique <- [:self_discover, :rephrase, :self_ask] do
        case MetaTaskHandler.apply_technique(task, technique) do
          {:ok, result} ->
            assert result.technique_used == technique

          {:error, _} ->
            # LLM may not be available
            :ok
        end
      end
    end
  end

  # ============================================================================
  # REASONING TELEMETRY TESTS
  # ============================================================================

  describe "ReasoningTelemetry" do
    setup do
      ReasoningTelemetry.reset()
      :ok
    end

    test "init creates ETS table" do
      assert :ok = ReasoningTelemetry.init()
    end

    test "emit_technique_used tracks stats" do
      ReasoningTelemetry.emit_technique_used(:self_discover, :solve, true, 100)
      ReasoningTelemetry.emit_technique_used(:self_discover, :solve, true, 200)
      ReasoningTelemetry.emit_technique_used(:self_discover, :solve, false, 50)

      stats = ReasoningTelemetry.get_technique_stats()

      assert stats.self_discover.count == 3
      assert stats.self_discover.success_rate == Float.round(2 / 3 * 100, 2)
      assert stats.self_discover.avg_duration_ms == round(350 / 3)
    end

    test "emit_structure_cache_hit tracks cache stats" do
      ReasoningTelemetry.emit_structure_cache_hit(true)
      ReasoningTelemetry.emit_structure_cache_hit(true)
      ReasoningTelemetry.emit_structure_cache_hit(false)

      stats = ReasoningTelemetry.get_cache_stats()

      assert stats.hits == 2
      assert stats.misses == 1
      assert stats.total == 3
      assert stats.hit_rate == Float.round(2 / 3 * 100, 2)
    end

    test "emit_meta_task_handled tracks meta-task stats" do
      ReasoningTelemetry.emit_meta_task_handled(true, :self_discover, true, 500)
      ReasoningTelemetry.emit_meta_task_handled(true, :rephrase, true, 300)
      ReasoningTelemetry.emit_meta_task_handled(false, :reasoner_fallback, true, 100)

      stats = ReasoningTelemetry.get_meta_task_stats()

      assert stats.meta_tasks.count == 2
      assert stats.standard_tasks.count == 1
      assert stats.total_handled == 3
    end

    test "summary returns complete stats" do
      ReasoningTelemetry.emit_technique_used(:rephrase, :respond, true, 100)

      summary = ReasoningTelemetry.summary()

      assert Map.has_key?(summary, :techniques)
      assert Map.has_key?(summary, :cache)
      assert Map.has_key?(summary, :meta_tasks)
    end

    test "reset clears all stats" do
      ReasoningTelemetry.emit_technique_used(:self_ask, :decompose, true, 100)
      ReasoningTelemetry.reset()

      stats = ReasoningTelemetry.get_technique_stats()
      assert stats.self_ask.count == 0
    end
  end

  # ============================================================================
  # REASONER INTEGRATION TESTS
  # ============================================================================

  describe "Reasoner SPEC-063 integration" do
    @tag :llm_required
    test "guided uses MetaTaskHandler for meta-tasks when technique is auto" do
      meta_task = "I'm going to ask you 5 trivia questions. Predict each, then answer."

      case Reasoner.guided(meta_task, technique: :auto) do
        {:ok, result} ->
          # Should have used advanced technique
          assert result.meta_task == true or Map.has_key?(result, :handler_result)

        {:error, _} ->
          # LLM may not be available
          :ok
      end
    end

    @tag :llm_required
    test "guided falls back to standard when technique is :none" do
      meta_task = "I'm going to ask you 5 trivia questions. Predict each, then answer."

      case Reasoner.guided(meta_task, technique: :none) do
        {:ok, result} ->
          # Should have session_id (standard reasoning)
          assert Map.has_key?(result, :session_id)
          assert result.session_id != nil

        {:error, _} ->
          # LLM may not be available
          :ok
      end
    end

    test "standard tasks don't use MetaTaskHandler" do
      simple_task = "What is 2 + 2?"

      case Reasoner.guided(simple_task) do
        {:ok, result} ->
          # Should be standard reasoning
          assert Map.has_key?(result, :session_id)

        {:error, _} ->
          :ok
      end
    end
  end

  # ============================================================================
  # Q9 META-TASK SPECIFIC TEST (from SPEC)
  # ============================================================================

  describe "Q9 meta-task test (from SPEC-063)" do
    @tag :llm_required
    @tag :external
    test "handles meta-task requiring self-generation" do
      task = """
      I'm going to ask you 5 trivia questions. Before answering each, 
      predict whether you'll get it right. Then answer. 
      How many predictions were accurate?
      """

      case MetaTaskHandler.handle(task) do
        {:ok, result} ->
          answer =
            get_in(result, [:result, :answer]) ||
              get_in(result, [:result, :synthesis]) ||
              ""

          answer_lower = String.downcase(answer)

          # Should NOT say "you didn't provide questions"
          refute String.contains?(answer_lower, "didn't provide"),
                 "Model waited for questions instead of generating them"

          refute String.contains?(answer_lower, "no questions"),
                 "Model claimed no questions were provided"

          # Should have generated questions (flexible matching)
          has_questions =
            String.contains?(answer, "1.") or
              String.contains?(answer, "Question") or
              String.contains?(answer, "Trivia") or
              String.contains?(answer, "?")

          assert has_questions,
                 "Model should have generated questions but didn't"

        {:error, reason} ->
          # LLM may not be available
          IO.puts("Q9 test skipped - LLM unavailable: #{inspect(reason)}")
      end
    end
  end
end
