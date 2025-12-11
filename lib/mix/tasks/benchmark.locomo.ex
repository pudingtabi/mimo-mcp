defmodule Mix.Tasks.Benchmark.Locomo do
  @moduledoc """
  Run the LOCOMO benchmark against the Mimo memory system.

  ## Usage

      mix benchmark.locomo --dataset path/to/locomo.jsonl
      mix benchmark.locomo --sample 50 --strategy semantic
      mix benchmark.locomo --synthetic --sample 20

  ## Options
    * `--dataset, -d`   Path to LOCOMO JSON/JSONL dataset (defaults to synthetic)
    * `--sample, -s`    Number of conversations to evaluate (default: all)
    * `--limit, -l`     Retrieval top-k (default: 5)
    * `--strategy`      :exact | :semantic | :llm (default: semantic)
    * `--threshold`     Correctness threshold for semantic/llm (default: 0.7)
    * `--output, -o`    Path to save JSON results (default: bench/results/locomo_<timestamp>.json)
    * `--keep`          Do not clear previous LOCOMO memories for the run_id
    * `--synthetic`     Force synthetic dataset generation when no dataset is provided
  """
  use Mix.Task

  alias Mimo.Benchmark.{LOCOMO, SyntheticLOCOMO}

  @shortdoc "Run LOCOMO memory benchmark"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          dataset: :string,
          sample: :integer,
          limit: :integer,
          strategy: :string,
          threshold: :float,
          output: :string,
          keep: :boolean,
          synthetic: :boolean
        ],
        aliases: [d: :dataset, s: :sample, l: :limit, o: :output]
      )

    Mix.Task.run("app.start")

    dataset_path =
      cond do
        opts[:dataset] -> opts[:dataset]
        true -> generate_synthetic(opts)
      end

    sample = opts[:sample]
    limit = opts[:limit] || 5
    strategy = parse_strategy(opts[:strategy])
    threshold = opts[:threshold] || 0.7
    clear_run? = not (opts[:keep] || false)

    IO.puts("\n=== LOCOMO Benchmark ===")
    IO.puts("Dataset: #{dataset_path}")
    IO.puts("Sample: #{sample || "all"}")
    IO.puts("Strategy: #{strategy}")
    IO.puts("Top-k: #{limit}")
    IO.puts("Threshold: #{threshold}\n")

    {:ok, summary} =
      LOCOMO.run(dataset_path,
        sample: sample,
        limit: limit,
        strategy: strategy,
        threshold: threshold,
        clear_run: clear_run?,
        save_results: true,
        output: opts[:output]
      )

    print_summary(summary)
  end

  defp parse_strategy(nil), do: :semantic

  defp parse_strategy(str) when is_binary(str) do
    case String.downcase(str) do
      "exact" -> :exact
      "semantic" -> :semantic
      "llm" -> :llm
      _ -> :semantic
    end
  end

  defp generate_synthetic(opts) do
    sample = opts[:sample] || 50
    tmp = Path.join(System.tmp_dir!(), "locomo_synthetic_" <> timestamp() <> ".jsonl")

    SyntheticLOCOMO.generate(sample, 20, 10)
    |> Enum.map_join("\n", &Jason.encode!/1)
    |> then(&File.write!(tmp, &1))

    IO.puts("Using synthetic dataset: #{tmp}")
    tmp
  end

  defp print_summary(%{metrics: metrics} = summary) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("LOCOMO RESULTS")
    IO.puts(String.duplicate("=", 60))

    IO.puts("Overall Accuracy:    #{pct(metrics.overall_accuracy)}")
    IO.puts("  - Factual:         #{pct(metrics.factual_accuracy)}")
    IO.puts("  - Temporal:        #{pct(metrics.temporal_accuracy)}")
    IO.puts("  - Multi-hop:       #{pct(metrics.multi_hop_accuracy)}")

    IO.puts("\nLatency:")
    IO.puts("  - Average:         #{Float.round(metrics.avg_latency_ms, 2)} ms")
    IO.puts("  - P95:             #{metrics.p95_latency_ms} ms")
    IO.puts("  - P99:             #{metrics.p99_latency_ms} ms")

    IO.puts("\nTotals:")
    IO.puts("  - Questions:       #{metrics.total_questions}")
    IO.puts("  - Memories stored: #{summary.ingestion.memories}")
    IO.puts("  - Token estimate:  #{summary.ingestion.tokens}")
    IO.puts("  - Tokens/question: #{metrics.tokens_per_question}")

    IO.puts("\nComparison (paper numbers):")
    IO.puts("  - Mem0: 67% LOCOMO, ~7K tokens/conv")
    IO.puts("  - Zep:  94.8% DMR (different metric)")
  end

  defp pct(val) when is_number(val), do: "#{Float.round(val * 100, 1)}%"
  defp pct(_), do: "n/a"

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:\-]/, "")
  end
end
