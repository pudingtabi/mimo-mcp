defmodule Mimo.Cognitive.KnowledgeTransfer do
  @moduledoc """
  Cross-domain knowledge transfer for applying learnings across contexts.

  Part of Phase 3: Emergent Capabilities - Cross-Domain Knowledge Transfer.

  This module enables Mimo to:
  1. Detect the current working domain (language, framework, problem type)
  2. Find relevant patterns/insights from other domains
  3. Translate patterns to the current domain's idioms
  4. Provide actionable cross-domain suggestions

  ## Example

  When working on Python error handling:
  - Detects domain: Python
  - Finds: "In Elixir, use {:ok, result} | {:error, reason} tuples for explicit error handling"
  - Translates: "In Python, consider using Result types (e.g., returns library) for explicit error handling"

  ## Integration

  Called from:
  - `ask_mimo` to enrich responses with cross-domain insights
  - `prepare_context` to include relevant cross-domain knowledge
  - Tool execution to suggest patterns from similar tasks in other domains
  """

  require Logger

  alias Mimo.Brain.Memory

  # Domain detection patterns
  @language_patterns %{
    elixir: ~r/\b(defmodule|defp\s|GenServer|Supervisor|Ecto|Phoenix)\b|\|>/,
    python: ~r/(def\s\w+\s*\(|import\s\w|from\s\w+\simport|class\s\w+:|__init__|self\.)/,
    javascript: ~r/\b(const\s|let\s|function\s|=>\s*\{|async\s|await\s|React|useState)\b/,
    typescript: ~r/\b(interface\s|type\s\w+\s=|:\s*(string|number|boolean)|<T>)\b/,
    rust: ~r/\b(fn\s\w+|impl\s|struct\s|enum\s|match\s|let\smut|unwrap\(\)|Result<)\b/,
    go: ~r/\b(func\s|package\s|import\s\(|:=|go\s\w+|chan\s|defer\s)\b/,
    sql: ~r/\b(SELECT|INSERT|UPDATE|DELETE|FROM|WHERE|JOIN|CREATE TABLE)\b/i
  }

  # Conceptual domain mappings for translation
  @concept_mappings %{
    error_handling: %{
      elixir: "{:ok, result} | {:error, reason} tuples, with/else blocks",
      python: "try/except, Result types (returns library), Optional types",
      rust: "Result<T, E>, Option<T>, ? operator for propagation",
      go: "multiple return values (result, error), errors.Is/As",
      javascript: "try/catch, Promise.catch(), Result pattern libraries",
      typescript: "try/catch with typed errors, Result<T, E> patterns"
    },
    concurrency: %{
      elixir: "GenServer, Task, Agent, message passing, OTP supervision",
      python: "asyncio, threading, multiprocessing, concurrent.futures",
      rust: "async/await, tokio, channels, Arc<Mutex<T>>",
      go: "goroutines, channels, sync package, context.Context",
      javascript: "Promise, async/await, Web Workers",
      typescript: "Promise<T>, async/await with proper typing"
    },
    state_management: %{
      elixir: "GenServer state, ETS tables, Agent, process dictionaries",
      python: "class attributes, dataclasses, global state, Redis",
      rust: "ownership, Rc/Arc, interior mutability (RefCell/Mutex)",
      go: "structs with methods, sync.Map, package-level vars",
      javascript: "closures, Redux, Context API, Zustand",
      typescript: "typed state interfaces, generic store patterns"
    },
    testing: %{
      elixir: "ExUnit, doctest, property-based testing (StreamData)",
      python: "pytest, unittest, hypothesis for property testing",
      rust: "#[test], proptest, integration tests in tests/",
      go: "testing package, table-driven tests, testify",
      javascript: "Jest, Mocha, React Testing Library",
      typescript: "Jest with ts-jest, type-safe mocks"
    }
  }

  @type domain :: atom()
  @type transfer_result :: %{
          source_domain: domain(),
          target_domain: domain(),
          concept: atom(),
          source_pattern: String.t(),
          target_pattern: String.t(),
          confidence: float(),
          related_memories: [map()]
        }

  @doc """
  Find cross-domain insights relevant to the current context.

  ## Parameters

  - `context` - The current working context (code, query, file content)
  - `opts` - Options:
    - `:target_domain` - Override detected domain
    - `:concepts` - Specific concepts to look for
    - `:limit` - Max results (default: 3)

  ## Returns

  List of transfer results with translated patterns.
  """
  @spec find_transfers(String.t(), keyword()) :: {:ok, [transfer_result()]} | {:error, term()}
  def find_transfers(context, opts \\ []) do
    target_domain = Keyword.get(opts, :target_domain) || detect_domain(context)
    concepts = Keyword.get(opts, :concepts) || detect_concepts(context)
    limit = Keyword.get(opts, :limit, 3)

    if target_domain == :unknown do
      {:ok, []}
    else
      # Find related memories from other domains
      transfers =
        concepts
        |> Enum.flat_map(fn concept ->
          find_concept_transfers(concept, target_domain, context)
        end)
        |> Enum.sort_by(& &1.confidence, :desc)
        |> Enum.take(limit)

      {:ok, transfers}
    end
  end

  @doc """
  Detect the programming domain from context.
  """
  @spec detect_domain(String.t()) :: domain()
  def detect_domain(context) when is_binary(context) do
    # First try syntax-based detection
    syntax_result =
      @language_patterns
      |> Enum.map(fn {lang, pattern} ->
        matches = Regex.scan(pattern, context) |> length()
        {lang, matches}
      end)
      |> Enum.max_by(fn {_lang, count} -> count end, fn -> {:unknown, 0} end)

    case syntax_result do
      {lang, count} when count > 0 ->
        lang

      _ ->
        # Fallback to keyword-based detection for natural language queries
        detect_domain_by_keywords(context)
    end
  end

  def detect_domain(_), do: :unknown

  # Keyword-based domain detection for natural language queries
  defp detect_domain_by_keywords(context) do
    context_lower = String.downcase(context)

    keyword_map = %{
      elixir: ["elixir", "phoenix", "ecto", "genserver", "otp"],
      python: ["python", "django", "flask", "pandas", "numpy", "pip"],
      javascript: ["javascript", "js", "node", "npm", "react", "vue", "angular"],
      typescript: ["typescript", "ts", "angular", "deno"],
      rust: ["rust", "cargo", "rustc", "tokio", "async-std"],
      go: ["golang", " go ", "goroutine", "gofmt"]
    }

    keyword_map
    |> Enum.map(fn {lang, keywords} ->
      count = Enum.count(keywords, &String.contains?(context_lower, &1))
      {lang, count}
    end)
    |> Enum.max_by(fn {_lang, count} -> count end, fn -> {:unknown, 0} end)
    |> case do
      {_lang, 0} -> :unknown
      {lang, _count} -> lang
    end
  end

  @doc """
  Detect relevant concepts from context.
  """
  @spec detect_concepts(String.t()) :: [atom()]
  def detect_concepts(context) when is_binary(context) do
    context_lower = String.downcase(context)

    concepts = []

    concepts =
      if String.contains?(context_lower, [
           "error",
           "exception",
           "catch",
           "rescue",
           "result",
           "ok",
           "err"
         ]) do
        [:error_handling | concepts]
      else
        concepts
      end

    concepts =
      if String.contains?(context_lower, [
           "async",
           "await",
           "spawn",
           "task",
           "thread",
           "concurrent",
           "parallel",
           "goroutine",
           "genserver"
         ]) do
        [:concurrency | concepts]
      else
        concepts
      end

    concepts =
      if String.contains?(context_lower, [
           "state",
           "store",
           "redux",
           "agent",
           "ets",
           "cache",
           "mutable"
         ]) do
        [:state_management | concepts]
      else
        concepts
      end

    concepts =
      if String.contains?(context_lower, ["test", "spec", "assert", "expect", "mock", "stub"]) do
        [:testing | concepts]
      else
        concepts
      end

    if concepts == [], do: [:error_handling], else: concepts
  end

  def detect_concepts(_), do: []

  @doc """
  Translate a pattern from one domain to another.
  """
  @spec translate_pattern(atom(), domain(), domain()) :: {:ok, String.t()} | {:error, :no_mapping}
  def translate_pattern(concept, source_domain, target_domain) do
    case get_in(@concept_mappings, [concept, target_domain]) do
      nil ->
        {:error, :no_mapping}

      pattern ->
        {:ok,
         "From #{source_domain}: #{get_in(@concept_mappings, [concept, source_domain]) || "N/A"}\nIn #{target_domain}: #{pattern}"}
    end
  end

  @doc """
  Get all supported domains.
  """
  @spec supported_domains() :: [domain()]
  def supported_domains do
    Map.keys(@language_patterns)
  end

  @doc """
  Get all supported concepts.
  """
  @spec supported_concepts() :: [atom()]
  def supported_concepts do
    Map.keys(@concept_mappings)
  end

  defp find_concept_transfers(concept, target_domain, context) do
    # Get other domains to search
    source_domains = supported_domains() -- [target_domain]

    # Search memory for relevant patterns from other domains
    memory_results = search_cross_domain_memories(concept, source_domains)

    # Build transfer results
    source_domains
    |> Enum.filter(fn domain ->
      # Only include domains we have mappings for
      get_in(@concept_mappings, [concept, domain]) != nil
    end)
    |> Enum.map(fn source_domain ->
      source_pattern = get_in(@concept_mappings, [concept, source_domain]) || ""
      target_pattern = get_in(@concept_mappings, [concept, target_domain]) || ""

      # Find related memories from this source domain
      related =
        Enum.filter(memory_results, fn m ->
          content = m[:content] || m["content"] || ""
          String.contains?(String.downcase(content), to_string(source_domain))
        end)

      # Calculate confidence based on relevance
      confidence =
        calculate_transfer_confidence(concept, source_domain, target_domain, context, related)

      %{
        source_domain: source_domain,
        target_domain: target_domain,
        concept: concept,
        source_pattern: source_pattern,
        target_pattern: target_pattern,
        confidence: confidence,
        related_memories: Enum.take(related, 2)
      }
    end)
    |> Enum.filter(&(&1.confidence > 0.3))
  end

  defp search_cross_domain_memories(concept, source_domains) do
    query = "#{concept} #{Enum.join(source_domains, " ")} pattern best practice"

    case Memory.search(query, limit: 10) do
      {:ok, results} -> results
      _ -> []
    end
  end

  defp calculate_transfer_confidence(
         concept,
         source_domain,
         target_domain,
         _context,
         related_memories
       ) do
    base_confidence = 0.5

    # Boost if we have related memories
    memory_boost = min(length(related_memories) * 0.1, 0.3)

    # Boost for well-known transfer pairs
    pair_boost =
      case {source_domain, target_domain, concept} do
        # Both use Result types
        {:elixir, :rust, :error_handling} -> 0.2
        {:go, :rust, :error_handling} -> 0.15
        # Both emphasize message passing
        {:elixir, :go, :concurrency} -> 0.2
        # Same ecosystem
        {:javascript, :typescript, _} -> 0.3
        _ -> 0.0
      end

    min(base_confidence + memory_boost + pair_boost, 1.0)
  end
end
