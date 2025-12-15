defmodule Mimo.Benchmark.LOCOMO do
  @moduledoc """
  LOCOMO benchmark harness for evaluating Mimo's memory retrieval accuracy.

  Provides dataset loading, ingestion into the memory store, question evaluation,
  metric aggregation, and result serialization. Designed to be driven via
  `Mix.Tasks.Benchmark.Locomo` or called directly from tests/benchmarks.
  """

  require Logger
  import Ecto.Query

  alias Mimo.Benchmark.Evaluator
  alias Mimo.Brain.{Engram, Memory}
  alias Mimo.Repo

  @results_dir "bench/results"
  @default_concurrency 4

  @type question_type :: :factual | :temporal | :multi_hop | :unknown

  @type result :: %{
          correct: boolean(),
          question_type: question_type(),
          latency_ms: non_neg_integer(),
          retrieved_count: non_neg_integer(),
          similarity_score: float(),
          score: float(),
          question_id: String.t() | nil,
          turn_reference: term()
        }

  @doc """
  Load conversations from a JSONL or JSON file.

  Accepts either JSONL (one conversation per line) or a JSON array/object with
  a `"conversations"` field.
  """
  @spec load_conversations(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def load_conversations(path) do
    if String.ends_with?(path, ".jsonl") do
      load_jsonl(path)
    else
      load_json(path)
    end
  rescue
    e -> {:error, e}
  end

  defp load_jsonl(path) do
    conversations =
      path
      |> File.stream!()
      |> Stream.map(&Jason.decode!/1)
      |> Enum.to_list()

    {:ok, conversations}
  end

  defp load_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, extract_conversations(decoded)}
    end
  end

  defp extract_conversations(%{"conversations" => list}) when is_list(list), do: list
  defp extract_conversations(list) when is_list(list), do: list

  defp extract_conversations(other),
    do: raise(ArgumentError, "Unexpected dataset format: #{inspect(other)}")

  @doc """
  Ingest a conversation into the memory store with parallel turn processing.

  Stores each turn as an `:observation` memory, tagged with LOCOMO metadata so
  runs can be isolated and cleaned up safely.

  Options:
    * `:context_id` - override context ID for all turns
    * `:importance` - importance score (default: 0.6)
    * `:concurrency` - max parallel store operations (default: 10)
  """
  @spec ingest_conversation(map(), String.t(), keyword()) ::
          {:ok, %{count: non_neg_integer(), tokens: non_neg_integer()}} | {:error, term()}
  def ingest_conversation(conversation, run_id, opts \\ []) do
    base_context = Keyword.get(opts, :context_id)
    importance = Keyword.get(opts, :importance, 0.6)
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)

    conv_id = conversation["conversation_id"] || "conv_#{System.unique_integer([:positive])}"
    turns = conversation["turns"] || []

    base_metadata = %{
      "benchmark" => "locomo",
      "run_id" => run_id,
      "conversation_id" => conv_id
    }

    results =
      turns
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {turn, idx} ->
          speaker = turn["speaker"] || "unknown"
          text = turn["text"] || ""
          turn_no = turn["turn"] || idx
          context_id = base_context || "#{run_id}:#{conv_id}"

          metadata =
            base_metadata
            |> Map.put("turn", turn_no)
            |> Map.put("speaker", speaker)
            |> Map.put("context_id", context_id)

          attrs = %{
            content: format_turn(turn_no, speaker, text),
            type: "observation",
            importance: importance,
            metadata: metadata
          }

          case Memory.store(attrs) do
            {:ok, _id} ->
              {:ok, token_estimate(text)}

            {:error, reason} ->
              Logger.error("Failed to store turn #{turn_no} (#{conv_id}): #{inspect(reason)}")
              {:error, reason}
          end
        end,
        max_concurrency: concurrency,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    {count, tokens} =
      Enum.reduce(results, {0, 0}, fn
        {:ok, {:ok, token_count}}, {acc_count, acc_tokens} ->
          {acc_count + 1, acc_tokens + token_count}

        {:ok, {:error, _}}, acc ->
          acc

        {:exit, _reason}, acc ->
          acc
      end)

    {:ok, %{count: count, tokens: tokens}}
  end

  @doc """
  Evaluate a single question against stored memories.
  """
  @spec evaluate_question(map(), keyword()) :: result()
  def evaluate_question(question, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    limit = Keyword.get(opts, :limit, 5)
    strategy = Keyword.get(opts, :strategy, :semantic)
    threshold = Keyword.get(opts, :threshold, 0.7)

    {:ok, memories} = Memory.search(question["text"], limit: limit)

    latency_ms = System.monotonic_time(:millisecond) - start_time

    predicted =
      memories
      |> Enum.map_join(" ", &(&1[:content] || ""))

    expected = question["answer"] || ""

    {correct, score, _details} =
      Evaluator.evaluate(predicted, expected, strategy, threshold: threshold)

    similarity =
      memories
      |> Enum.map(&Map.get(&1, :similarity, 0.0))
      |> Enum.max(fn -> 0.0 end)

    %{
      correct: correct,
      question_type: question_type(question["type"]),
      latency_ms: latency_ms,
      retrieved_count: length(memories),
      similarity_score: similarity,
      score: score,
      question_id: question["id"],
      turn_reference: question["turn_reference"]
    }
  end

  @doc """
  Run the full benchmark for a dataset path.

  Options:
    * `:sample` - limit number of conversations
    * `:limit` - retrieval top-k (default: 5)
    * `:strategy` - evaluation strategy (:exact | :semantic | :llm)
    * `:threshold` - correctness threshold for semantic/llm (default: 0.7)
    * `:clear_run` - whether to delete previous LOCOMO memories for the run_id (default: true)
    * `:run_id` - identifier used in metadata (default: generated)
    * `:save_results` - boolean to persist JSON to bench/results (default: true)
    * `:output` - optional explicit output path
    * `:progress` - show progress indicator (default: true)
    * `:concurrency` - parallel ingestion concurrency (default: 10)
  """
  @spec run(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(dataset_path, opts \\ []) do
    with {:ok, conversations} <- load_conversations(dataset_path) do
      run_id = Keyword.get(opts, :run_id, "locomo_" <> timestamp())
      sample_size = Keyword.get(opts, :sample, length(conversations)) |> min(length(conversations))
      limit = Keyword.get(opts, :limit, 5)
      strategy = Keyword.get(opts, :strategy, :semantic)
      threshold = Keyword.get(opts, :threshold, 0.7)
      clear? = Keyword.get(opts, :clear_run, true)
      show_progress? = Keyword.get(opts, :progress, true)
      concurrency = Keyword.get(opts, :concurrency, @default_concurrency)

      if clear?, do: clear_run(run_id)

      sampled_conversations = Enum.take(conversations, sample_size)
      total = length(sampled_conversations)

      {results, ingest_totals} =
        sampled_conversations
        |> Enum.with_index(1)
        |> Enum.map_reduce(%{memories: 0, tokens: 0}, fn {conv, idx}, acc ->
          if show_progress?, do: IO.write("\r  Processing conversation #{idx}/#{total}...")

          {:ok, ingest_info} =
            ingest_conversation(conv, run_id,
              context_id: conv["conversation_id"],
              concurrency: concurrency
            )

          question_results =
            conv["questions"]
            |> List.wrap()
            |> Enum.flat_map(fn
              list when is_list(list) -> list
              item when is_map(item) -> [item]
              _ -> []
            end)
            |> Enum.map(
              &evaluate_question(&1, limit: limit, strategy: strategy, threshold: threshold)
            )

          {%{conversation_id: conv["conversation_id"], results: question_results},
           %{
             memories: acc.memories + ingest_info.count,
             tokens: acc.tokens + ingest_info.tokens
           }}
        end)

      if show_progress?, do: IO.puts("\r  Processing complete.                    ")

      flat_results = results |> Enum.flat_map(&(&1[:results] || []))

      summary = %{
        run_id: run_id,
        dataset: dataset_path,
        sample_size: sample_size,
        strategy: strategy,
        limit: limit,
        threshold: threshold,
        ingestion: ingest_totals,
        metrics: compute_aggregate_metrics(flat_results, ingest_totals),
        results: flat_results
      }

      maybe_save(summary, Keyword.get(opts, :save_results, true), opts[:output])
      {:ok, summary}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_save(summary, false, _output), do: summary

  defp maybe_save(summary, true, output) do
    File.mkdir_p!(@results_dir)

    filename =
      output ||
        Path.join(
          @results_dir,
          "locomo_" <> (summary[:run_id] || timestamp()) <> ".json"
        )

    File.write!(filename, Jason.encode!(summary, pretty: true))
    Logger.info("LOCOMO results saved to #{filename}")
    summary
  end

  defp compute_aggregate_metrics(results, ingestion) do
    by_type = Enum.group_by(results, & &1.question_type)
    latencies = Enum.map(results, & &1.latency_ms)
    total_questions = length(results)

    # Token efficiency: tokens per question (for comparison with Mem0's 7K tokens/conv)
    tokens_per_question =
      if total_questions > 0,
        do: ingestion.tokens / total_questions,
        else: 0.0

    %{
      overall_accuracy: accuracy(results),
      factual_accuracy: accuracy(by_type[:factual] || []),
      temporal_accuracy: accuracy(by_type[:temporal] || []),
      multi_hop_accuracy: accuracy(by_type[:multi_hop] || []),
      avg_latency_ms: avg(latencies),
      p95_latency_ms: percentile(latencies, 95),
      p99_latency_ms: percentile(latencies, 99),
      total_questions: total_questions,
      avg_retrieved: avg(Enum.map(results, & &1.retrieved_count)),
      avg_similarity: avg(Enum.map(results, & &1.similarity_score)),
      tokens_per_question: Float.round(tokens_per_question, 2)
    }
  end

  defp accuracy([]), do: 0.0
  defp accuracy(results), do: Enum.count(results, & &1.correct) / length(results)

  defp avg([]), do: 0.0
  defp avg(list), do: Enum.sum(list) / length(list)

  defp percentile([], _p), do: 0

  defp percentile(list, p) when is_number(p) and p >= 0 and p <= 100 do
    sorted = Enum.sort(list)
    n = length(sorted)

    if n == 1 do
      hd(sorted)
    else
      # Linear interpolation method (numpy default)
      rank = p / 100 * (n - 1)
      lower = trunc(rank)
      upper = min(lower + 1, n - 1)
      weight = rank - lower

      lower_val = Enum.at(sorted, lower)
      upper_val = Enum.at(sorted, upper)

      round(lower_val + weight * (upper_val - lower_val))
    end
  end

  defp question_type("factual"), do: :factual
  defp question_type("temporal"), do: :temporal
  defp question_type("multi_hop"), do: :multi_hop
  defp question_type(_), do: :unknown

  defp format_turn(turn, speaker, text), do: "[Turn #{turn}] #{speaker}: #{text}"

  defp token_estimate(text) when is_binary(text), do: div(String.length(text), 4)
  defp token_estimate(_), do: 0

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:\-]/, "")
  end

  defp clear_run(run_id) do
    {deleted, _} =
      Repo.delete_all(
        from(e in Engram,
          where: fragment("json_extract(?, '$.benchmark') = 'locomo'", e.metadata),
          where: fragment("json_extract(?, '$.run_id') = ?", e.metadata, ^run_id)
        )
      )

    Logger.debug("Cleared #{deleted} engrams for LOCOMO run #{run_id}")
  end
end
