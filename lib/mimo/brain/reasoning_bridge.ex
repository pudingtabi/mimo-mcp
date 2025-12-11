defmodule Mimo.Brain.ReasoningBridge do
  @moduledoc """
  SPEC-058: Bridge between Reasoner and Memory systems.

  Provides reasoning-enhanced memory operations:
  - Ingestion: Analyze content before storage (importance, relationships, tags)
  - Retrieval: Enhance queries and rerank results
  - Audit: Persist reasoning traces with memories

  ## Feature Flags

  This module respects the `:reasoning_memory_enabled` flag for gradual rollout.
  When disabled, all functions return graceful fallbacks.

  ## Integration Points

  - Memory.persist_memory/3 - Enhanced with reasoning context
  - Memory.search_memories/2 - Optional query analysis and reranking
  """

  require Logger

  alias Mimo.Cognitive.Reasoner
  alias Mimo.Brain.{LLM, Engram}

  # ============================================================================
  # Type Specifications
  # ============================================================================

  @type reasoning_context :: %{
          session_id: String.t() | nil,
          strategy: :cot | :tot | :react | :reflexion | :none,
          decomposition: [String.t()],
          importance_reasoning: String.t() | nil,
          detected_relationships: [relationship()],
          tags_reasoning: String.t() | nil,
          confidence: float()
        }

  @type relationship :: %{
          type: :depends_on | :contradicts | :extends | :supersedes | :related_to,
          target_id: integer(),
          confidence: float()
        }

  @type query_analysis :: %{
          String.t() => term()
        }

  # ============================================================================
  # Ingestion Path
  # ============================================================================

  @doc """
  Analyze content before memory storage.

  Returns reasoning context to attach to the memory.

  ## Options

    * `:category` - Memory category (default: "fact")
    * `:similar_memories` - List of similar Engram structs for relationship detection

  ## Returns

    * `{:ok, reasoning_context}` - Analysis succeeded
    * `{:skip, :disabled}` - Reasoning is disabled

  ## Examples

      {:ok, ctx} = analyze_for_storage("User prefers TypeScript", category: "observation")
      # ctx.importance_reasoning, ctx.detected_relationships, etc.
  """
  @spec analyze_for_storage(String.t(), keyword()) :: {:ok, reasoning_context()} | {:skip, :disabled}
  def analyze_for_storage(content, opts \\ []) do
    if reasoning_enabled?() do
      category = Keyword.get(opts, :category, "fact")
      existing_similar = Keyword.get(opts, :similar_memories, [])

      problem = build_ingestion_problem(content, category, existing_similar)

      case Reasoner.guided(problem, strategy: :cot) do
        {:ok, session} ->
          context = extract_reasoning_context(session, content, opts)
          {:ok, context}

        {:error, reason} ->
          Logger.warning("ReasoningBridge: Failed to analyze - #{inspect(reason)}")
          {:ok, default_context()}
      end
    else
      {:skip, :disabled}
    end
  end

  @doc """
  Score importance using reasoning.

  Considers:
  - Content specificity (specific > generic)
  - Actionability (actionable > informational)
  - Uniqueness (novel > redundant)
  - User relevance (explicit preference > inferred)

  ## Options

    * `:base_importance` - Fallback importance if reasoning fails (default: 0.5)

  ## Examples

      score = score_importance("NEVER commit API keys to git", "fact")
      # => 0.95 (high importance for security constraint)

      score = score_importance("The project uses React", "fact")
      # => 0.55 (general tech fact)
  """
  @spec score_importance(String.t(), String.t(), keyword()) :: float()
  def score_importance(content, category, opts \\ []) do
    base_score = Keyword.get(opts, :base_importance, 0.5)

    if reasoning_enabled?() do
      prompt = """
      Score the importance of this memory (0.0-1.0):

      Content: #{content}
      Category: #{category}

      Scoring criteria:
      - 0.9-1.0: Critical constraints, security requirements, explicit user preferences
      - 0.7-0.8: Key technical decisions, project-specific patterns
      - 0.5-0.6: General facts, observations
      - 0.3-0.4: Temporary context, session-specific
      - 0.1-0.2: Low-priority notes

      OUTPUT JSON: {"score": 0.0-1.0, "reasoning": "brief explanation"}
      """

      case LLM.complete(prompt, max_tokens: 100, format: :json) do
        {:ok, response} ->
          parse_importance_response(response, base_score)

        {:error, _reason} ->
          base_score
      end
    else
      base_score
    end
  end

  @doc """
  Detect relationships to existing memories.

  Identifies semantic relationships between new content and similar existing memories.

  ## Relationship Types

    * `:depends_on` - New content relies on existing
    * `:contradicts` - New content conflicts with existing
    * `:extends` - New content adds to existing
    * `:supersedes` - New content replaces existing
    * `:related_to` - General semantic relation

  ## Examples

      existing = [%Engram{id: 1, content: "React 18 is the latest version"}]
      rels = detect_relationships("React 19 is now the latest version", existing)
      # => [%{type: :supersedes, target_id: 1, confidence: 0.92}]
  """
  @spec detect_relationships(String.t(), [Engram.t()]) :: [relationship()]
  def detect_relationships(content, similar_memories) when length(similar_memories) > 0 do
    if reasoning_enabled?() do
      existing_summaries =
        similar_memories
        |> Enum.take(5)
        |> Enum.map(fn m -> "- [ID:#{m.id}] #{String.slice(m.content, 0, 100)}" end)
        |> Enum.join("\n")

      prompt = """
      Analyze relationships between NEW content and EXISTING memories:

      NEW: #{content}

      EXISTING:
      #{existing_summaries}

      For each relationship found, specify:
      - type: depends_on | contradicts | extends | supersedes | related_to
      - target_id: ID of the related memory
      - confidence: 0.0-1.0

      OUTPUT JSON: {"relationships": [{"type": "...", "target_id": N, "confidence": 0.0-1.0}]}
      """

      case LLM.complete(prompt, max_tokens: 300, format: :json) do
        {:ok, response} ->
          parse_relationships_response(response)

        {:error, _reason} ->
          []
      end
    else
      []
    end
  end

  def detect_relationships(_, _), do: []

  @doc """
  Generate semantic tags using reasoning.

  Tags are lowercase, hyphenated, and cover key concepts, technologies, or domains.

  ## Examples

      tags = generate_tags("Phoenix uses Ecto for database access", "fact")
      # => ["phoenix", "ecto", "database", "elixir"]
  """
  @spec generate_tags(String.t(), String.t()) :: [String.t()]
  def generate_tags(content, category) do
    if reasoning_enabled?() do
      prompt = """
      Generate 2-5 semantic tags for this memory:

      Content: #{content}
      Category: #{category}

      Tags should be:
      - Lowercase, single words or hyphenated
      - Specific enough to be useful for retrieval
      - Cover key concepts, technologies, or domains

      OUTPUT JSON: {"tags": ["tag1", "tag2", ...]}
      """

      case LLM.complete(prompt, max_tokens: 100, format: :json) do
        {:ok, response} ->
          parse_tags_response(response)

        {:error, _reason} ->
          []
      end
    else
      []
    end
  end

  # ============================================================================
  # Retrieval Path
  # ============================================================================

  @doc """
  Analyze query intent for better retrieval.

  Determines:
  - Intent: factual, temporal, relational, or exploratory
  - Key concepts for search
  - Expanded terms (synonyms)
  - Time context hints

  ## Examples

      {:ok, analysis} = analyze_query("What did we decide about auth last week?")
      # analysis.intent => "temporal"
      # analysis.time_context => "last week"
      # analysis.key_concepts => ["auth", "decision"]
  """
  @spec analyze_query(String.t()) :: {:ok, query_analysis()}
  def analyze_query(query) do
    if reasoning_enabled?() do
      prompt = """
      Analyze this memory search query:

      Query: #{query}

      Determine:
      1. intent: factual | temporal | relational | exploratory
      2. key_concepts: Main concepts to search for
      3. expanded_terms: Synonyms or related terms to include
      4. time_context: Any temporal hints (recent, yesterday, last week, etc.)

      OUTPUT JSON: {"intent": "...", "key_concepts": [...], "expanded_terms": [...], "time_context": "..."|null}
      """

      case LLM.complete(prompt, max_tokens: 150, format: :json) do
        {:ok, response} ->
          {:ok, parse_query_analysis_response(response)}

        {:error, _reason} ->
          {:ok, default_query_analysis(query)}
      end
    else
      {:ok, default_query_analysis(query)}
    end
  end

  @doc """
  Rerank search results using reasoning about relevance.

  Only activates when there are more than 3 results to rerank.

  ## Examples

      results = [...list of Engram structs...]
      analysis = %{"intent" => "factual"}
      reranked = rerank("auth configuration", results, analysis)
  """
  @spec rerank(String.t(), [Engram.t()], query_analysis()) :: [Engram.t()]
  def rerank(query, results, query_analysis) when length(results) > 3 do
    if reasoning_enabled?() do
      summaries =
        results
        |> Enum.with_index()
        |> Enum.map(fn {r, i} -> "#{i}. #{String.slice(r.content, 0, 150)}" end)
        |> Enum.join("\n")

      prompt = """
      Rerank these search results for the query.

      Query: #{query}
      Intent: #{query_analysis["intent"] || "factual"}

      Results:
      #{summaries}

      Return indices in order of relevance (most relevant first).
      OUTPUT JSON: {"ranking": [0, 2, 1, ...]}
      """

      case LLM.complete(prompt, max_tokens: 100, format: :json) do
        {:ok, response} ->
          apply_ranking(results, response)

        {:error, _reason} ->
          results
      end
    else
      results
    end
  end

  def rerank(_, results, _), do: results

  # ============================================================================
  # Public Helpers
  # ============================================================================

  @doc """
  Check if reasoning-memory integration is enabled.

  Respects both compile-time and runtime configuration.
  """
  @spec reasoning_enabled?() :: boolean()
  def reasoning_enabled? do
    Application.get_env(:mimo, :reasoning_memory_enabled, false)
  end

  @doc """
  Returns a default reasoning context when reasoning is disabled or fails.
  """
  @spec default_context() :: reasoning_context()
  def default_context do
    %{
      session_id: nil,
      strategy: :none,
      decomposition: [],
      importance_reasoning: "Default (reasoning disabled)",
      detected_relationships: [],
      tags_reasoning: nil,
      confidence: 0.5
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp build_ingestion_problem(content, category, similar) do
    similar_summary =
      if Enum.empty?(similar),
        do: "None",
        else: similar |> Enum.take(3) |> Enum.map(& &1.content) |> Enum.join("; ")

    """
    Analyze this new memory for storage:

    Content: #{content}
    Category: #{category}
    Similar existing: #{similar_summary}

    Determine:
    1. Is this genuinely new information or redundant?
    2. What importance score (0-1) should it have?
    3. What relationships exist with similar memories?
    4. What tags would help retrieval?
    """
  end

  defp extract_reasoning_context(session, content, opts) do
    similar_memories = Keyword.get(opts, :similar_memories, [])

    %{
      session_id: session.session_id,
      strategy: session.strategy || :cot,
      decomposition: session[:decomposition] || [],
      importance_reasoning: session[:guidance],
      detected_relationships: detect_relationships(content, similar_memories),
      tags_reasoning: nil,
      confidence: get_in(session, [:confidence, :score]) || 0.7
    }
  end

  defp default_query_analysis(query) do
    %{
      "intent" => "factual",
      "key_concepts" => [query],
      "expanded_terms" => [],
      "time_context" => nil
    }
  end

  defp parse_importance_response(response, base_score) do
    case Jason.decode(response) do
      {:ok, %{"score" => score}} when is_number(score) ->
        Float.round(score, 2)

      {:ok, %{"score" => score_str}} when is_binary(score_str) ->
        case Float.parse(score_str) do
          {score, _} -> Float.round(score, 2)
          :error -> base_score
        end

      _ ->
        # Try to extract score from text
        extract_score_from_text(response, base_score)
    end
  end

  defp extract_score_from_text(text, default) do
    case Regex.run(~r/["']?score["']?\s*[:=]\s*([\d.]+)/, text) do
      [_, score_str] ->
        case Float.parse(score_str) do
          {score, _} when score >= 0.0 and score <= 1.0 -> Float.round(score, 2)
          _ -> default
        end

      nil ->
        default
    end
  end

  defp parse_relationships_response(response) do
    case Jason.decode(response) do
      {:ok, %{"relationships" => rels}} when is_list(rels) ->
        Enum.map(rels, fn r ->
          %{
            type: parse_relationship_type(r["type"]),
            target_id: r["target_id"],
            confidence: r["confidence"] || 0.5
          }
        end)
        |> Enum.reject(fn r -> is_nil(r.target_id) end)

      _ ->
        []
    end
  end

  defp parse_relationship_type(type) when is_binary(type) do
    case String.downcase(type) do
      "depends_on" -> :depends_on
      "contradicts" -> :contradicts
      "extends" -> :extends
      "supersedes" -> :supersedes
      _ -> :related_to
    end
  end

  defp parse_relationship_type(_), do: :related_to

  defp parse_tags_response(response) do
    case Jason.decode(response) do
      {:ok, %{"tags" => tags}} when is_list(tags) ->
        tags
        |> Enum.take(5)
        |> Enum.map(&String.downcase/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp parse_query_analysis_response(response) do
    case Jason.decode(response) do
      {:ok, analysis} when is_map(analysis) ->
        %{
          "intent" => analysis["intent"] || "factual",
          "key_concepts" => analysis["key_concepts"] || [],
          "expanded_terms" => analysis["expanded_terms"] || [],
          "time_context" => analysis["time_context"]
        }

      _ ->
        %{
          "intent" => "factual",
          "key_concepts" => [],
          "expanded_terms" => [],
          "time_context" => nil
        }
    end
  end

  defp apply_ranking(results, response) do
    case Jason.decode(response) do
      {:ok, %{"ranking" => indices}} when is_list(indices) ->
        indices
        |> Enum.map(&Enum.at(results, &1))
        |> Enum.reject(&is_nil/1)

      _ ->
        results
    end
  end
end
