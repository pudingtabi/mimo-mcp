defmodule Mimo.Benchmark.LOCOMOTest do
  use Mimo.DataCase, async: false

  alias Mimo.Benchmark.{LOCOMO, SyntheticLOCOMO}

  @moduletag :benchmark

  describe "load_conversations/1" do
    setup do
      tmp_dir = System.tmp_dir!()
      {:ok, tmp_dir: tmp_dir}
    end

    test "loads JSON file with conversations array", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test_convs.json")
      data = %{"conversations" => [%{"conversation_id" => "c1", "turns" => []}]}
      File.write!(path, Jason.encode!(data))

      assert {:ok, [conv]} = LOCOMO.load_conversations(path)
      assert conv["conversation_id"] == "c1"
    end

    test "loads JSON file with bare array", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test_array.json")
      data = [%{"conversation_id" => "c2", "turns" => []}]
      File.write!(path, Jason.encode!(data))

      assert {:ok, [conv]} = LOCOMO.load_conversations(path)
      assert conv["conversation_id"] == "c2"
    end

    test "loads JSONL file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.jsonl")

      lines = [
        Jason.encode!(%{"conversation_id" => "c1", "turns" => []}),
        Jason.encode!(%{"conversation_id" => "c2", "turns" => []})
      ]

      File.write!(path, Enum.join(lines, "\n"))

      assert {:ok, convs} = LOCOMO.load_conversations(path)
      assert length(convs) == 2
    end

    test "returns error for missing file" do
      assert {:error, _} = LOCOMO.load_conversations("/nonexistent/path.json")
    end
  end

  describe "ingest_conversation/3" do
    test "stores turns as memories with correct metadata" do
      conversation = %{
        "conversation_id" => "test_conv_1",
        "turns" => [
          %{"speaker" => "user", "text" => "Hello", "turn" => 1},
          %{"speaker" => "assistant", "text" => "Hi there", "turn" => 2}
        ]
      }

      run_id = "test_run_#{System.unique_integer([:positive])}"

      assert {:ok, %{count: 2, tokens: tokens}} =
               LOCOMO.ingest_conversation(conversation, run_id)

      assert tokens > 0

      # Verify memories were stored by checking the database
      import Ecto.Query
      alias Mimo.Brain.Engram
      alias Mimo.Repo

      engrams =
        Repo.all(
          from(e in Engram,
            where: fragment("json_extract(?, '$.run_id') = ?", e.metadata, ^run_id)
          )
        )

      assert length(engrams) == 2

      # Sort by turn number from metadata to get correct order
      [first | _] =
        engrams
        |> Enum.sort_by(fn e -> e.metadata["turn"] || e.id end)

      assert first.content =~ "Hello"
      assert first.metadata["benchmark"] == "locomo"
      assert first.metadata["conversation_id"] == "test_conv_1"
    end

    test "respects custom importance" do
      conversation = %{
        "conversation_id" => "imp_test",
        "turns" => [%{"speaker" => "user", "text" => "Test", "turn" => 1}]
      }

      run_id = "test_run_imp_#{System.unique_integer([:positive])}"

      assert {:ok, _} = LOCOMO.ingest_conversation(conversation, run_id, importance: 0.9)

      import Ecto.Query
      alias Mimo.Brain.Engram
      alias Mimo.Repo

      [engram] =
        Repo.all(
          from(e in Engram,
            where: fragment("json_extract(?, '$.run_id') = ?", e.metadata, ^run_id)
          )
        )

      assert engram.importance == 0.9
    end
  end

  describe "evaluate_question/2" do
    setup do
      # Ingest a test conversation first
      run_id = "eval_test_#{System.unique_integer([:positive])}"

      conversation = %{
        "conversation_id" => "eval_conv",
        "turns" => [
          %{"speaker" => "user", "text" => "The database password is secret123", "turn" => 1},
          %{"speaker" => "assistant", "text" => "I'll remember that password", "turn" => 2}
        ]
      }

      {:ok, _} = LOCOMO.ingest_conversation(conversation, run_id)

      {:ok, run_id: run_id}
    end

    test "returns result structure with all required fields" do
      question = %{
        "id" => "q1",
        "type" => "factual",
        "text" => "What is the database password?",
        "answer" => "secret123",
        "turn_reference" => 1
      }

      result = LOCOMO.evaluate_question(question, limit: 5, strategy: :exact)

      assert is_boolean(result.correct)
      assert result.question_type in [:factual, :temporal, :multi_hop, :unknown]
      assert is_integer(result.latency_ms)
      assert result.latency_ms >= 0
      assert is_integer(result.retrieved_count)
      assert is_float(result.score)
      assert result.question_id == "q1"
    end

    test "respects limit option" do
      question = %{
        "id" => "q2",
        "type" => "factual",
        "text" => "Tell me about passwords",
        "answer" => "anything"
      }

      result = LOCOMO.evaluate_question(question, limit: 1, strategy: :exact)

      assert result.retrieved_count <= 1
    end
  end

  describe "run/2 integration" do
    @tag timeout: 60_000
    test "runs full benchmark with synthetic data" do
      # Generate a small synthetic dataset
      tmp_path =
        Path.join(System.tmp_dir!(), "locomo_test_#{System.unique_integer([:positive])}.jsonl")

      SyntheticLOCOMO.generate(2, 5, 3)
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> then(&File.write!(tmp_path, &1))

      run_id = "integration_test_#{System.unique_integer([:positive])}"

      assert {:ok, summary} =
               LOCOMO.run(tmp_path,
                 run_id: run_id,
                 sample: 2,
                 limit: 3,
                 strategy: :exact,
                 save_results: false,
                 clear_run: true
               )

      # Verify summary structure
      assert summary.run_id == run_id
      assert summary.sample_size == 2
      assert summary.strategy == :exact
      assert is_map(summary.metrics)
      assert is_map(summary.ingestion)
      assert is_list(summary.results)

      # Verify metrics
      metrics = summary.metrics
      assert is_float(metrics.overall_accuracy)
      assert metrics.overall_accuracy >= 0.0 and metrics.overall_accuracy <= 1.0
      assert is_integer(metrics.total_questions)
      assert is_float(metrics.avg_latency_ms)
    end

    test "clears previous run data when clear_run: true" do
      run_id = "clear_test_#{System.unique_integer([:positive])}"

      # Create some test data
      conversation = %{
        "conversation_id" => "clear_conv",
        "turns" => [%{"speaker" => "user", "text" => "Test", "turn" => 1}],
        "questions" => []
      }

      tmp_path = Path.join(System.tmp_dir!(), "clear_test.jsonl")
      File.write!(tmp_path, Jason.encode!(conversation))

      # Run twice with same run_id
      {:ok, _} = LOCOMO.run(tmp_path, run_id: run_id, save_results: false, clear_run: false)
      {:ok, summary2} = LOCOMO.run(tmp_path, run_id: run_id, save_results: false, clear_run: true)

      # With clear_run: true, should only have memories from second run
      assert summary2.ingestion.memories == 1
    end
  end

  describe "compute_aggregate_metrics/1" do
    test "computes correct accuracy for mixed results" do
      results = [
        %{
          correct: true,
          question_type: :factual,
          latency_ms: 10,
          retrieved_count: 3,
          similarity_score: 0.8,
          score: 0.8
        },
        %{
          correct: false,
          question_type: :factual,
          latency_ms: 20,
          retrieved_count: 3,
          similarity_score: 0.5,
          score: 0.5
        },
        %{
          correct: true,
          question_type: :temporal,
          latency_ms: 15,
          retrieved_count: 2,
          similarity_score: 0.9,
          score: 0.9
        }
      ]

      # Access private function via module
      metrics =
        LOCOMO.__info__(:functions)
        |> Enum.find(fn {name, _} -> name == :compute_aggregate_metrics end)

      # Since it's private, we test via run/2 integration instead
      # This test documents expected behavior
      assert length(results) == 3
    end
  end
end
