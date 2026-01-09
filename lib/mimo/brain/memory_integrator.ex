defmodule Mimo.Brain.MemoryIntegrator do
  @moduledoc """
  LLM-based Memory Integration for SPEC-034 Temporal Memory Chains (TMC).

  When the NoveltyDetector classifies incoming content as :update or :ambiguous,
  the MemoryIntegrator uses LLM reasoning to decide how to handle it:

  - UPDATE: New info supersedes old (mark old as superseded, create new)
  - CORRECTION: Old info was wrong (supersede with correction type)
  - REFINEMENT: Merge complementary info (combine content, supersede old)
  - REDUNDANT: Essentially duplicate (reject, maybe reinforce old)
  - NEW: Despite similarity, this is distinct info (create new memory)

  The module maintains temporal chains so old context is never lost,
  just linked as superseded.

  ## Example

      iex> {:ok, result} = MemoryIntegrator.decide(
      ...>   "React 19 uses Server Components by default",
      ...>   existing_engram,
      ...>   %{category: :fact}
      ...> )
      {:ok, %{decision: :update, reasoning: "..."}}

      iex> {:ok, engram} = MemoryIntegrator.execute(
      ...>   :update,
      ...>   "React 19 uses Server Components by default",
      ...>   existing_engram,
      ...>   %{category: :fact}
      ...> )
  """

  require Logger
  alias Mimo.Brain.{Engram, LLM, Memory}
  alias Mimo.Repo

  @type decision :: :update | :correction | :refinement | :redundant | :new
  @type decision_result :: {:ok, %{decision: decision(), reasoning: String.t()}} | {:error, term()}

  @valid_decisions [:update, :correction, :refinement, :redundant, :new]

  @decision_prompt """
  You are a Memory Integration expert. Analyze these two pieces of information and decide how to handle them.

  EXISTING MEMORY (stored {{existing_age}}):
  Category: {{existing_category}}
  Content: {{existing_content}}

  NEW INFORMATION:
  Category: {{new_category}}
  Content: {{new_content}}

  Decide the relationship:

  1. UPDATE - New info supersedes old (e.g., "React 18..." → "React 19...")
     Use when: Same topic, newer/more accurate information

  2. CORRECTION - Old info was wrong, this fixes it
     Use when: Factual error discovered, explicit correction needed

  3. REFINEMENT - Both have value, merge them
     Use when: Complementary details, neither fully replaces the other

  4. REDUNDANT - Essentially the same, no new value
     Use when: Duplicate or near-duplicate, new adds nothing

  5. NEW - Despite similarity, these are distinct pieces of information
     Use when: Related topic but different facts, both should exist independently

  OUTPUT FORMAT (JSON only, no markdown):
  {"decision": "UPDATE|CORRECTION|REFINEMENT|REDUNDANT|NEW", "reasoning": "Brief explanation", "confidence": 0.0-1.0}
  """

  @merge_prompt """
  You are a Memory Consolidator. Merge these two related pieces of information into a single, coherent memory.

  ORIGINAL MEMORY:
  {{original_content}}

  NEW INFORMATION:
  {{new_content}}

  CONTEXT:
  {{reasoning}}

  Rules:
  - Preserve all unique facts from both
  - Prefer newer information when conflicting
  - Keep it concise but complete
  - Maintain the original category style ({{category}})

  OUTPUT: Just the merged content, no explanation or formatting.
  """

  @doc """
  Decide how to integrate new content with an existing memory.

  Uses LLM to analyze the relationship between new content and existing memory,
  returning one of: :update, :correction, :refinement, :redundant, or :new.

  ## Parameters

    - `new_content` - The new content to integrate
    - `existing` - The existing Engram struct or map with :content, :category
    - `opts` - Options:
      - `:category` - Category of new content (default: existing category)
      - `:timeout` - LLM timeout in ms (default: 30_000)

  ## Returns

    - `{:ok, %{decision: atom, reasoning: String.t, confidence: float}}`
    - `{:error, reason}`

  ## Example

      {:ok, result} = MemoryIntegrator.decide(
        "Phoenix 1.8 adds verified routes",
        existing_memory,
        category: :fact
      )
      # => {:ok, %{decision: :update, reasoning: "...", confidence: 0.9}}
  """
  @spec decide(String.t(), Engram.t() | map(), keyword()) :: decision_result()
  def decide(new_content, existing, opts \\ []) do
    if tmc_enabled?() do
      do_decide(new_content, existing, opts)
    else
      # When TMC is disabled, everything is treated as new
      {:ok, %{decision: :new, reasoning: "TMC disabled", confidence: 1.0}}
    end
  end

  defp do_decide(new_content, existing, opts) do
    existing_content = get_content(existing)
    existing_category = get_category(existing)
    new_category = Keyword.get(opts, :category, existing_category)

    # Calculate age of existing memory
    existing_age = calculate_age(existing)

    # Build prompt
    prompt =
      @decision_prompt
      |> String.replace("{{existing_age}}", existing_age)
      |> String.replace("{{existing_category}}", to_string(existing_category))
      |> String.replace("{{existing_content}}", existing_content)
      |> String.replace("{{new_category}}", to_string(new_category))
      |> String.replace("{{new_content}}", new_content)

    case LLM.complete(prompt, max_tokens: 200, temperature: 0.1, format: :json, raw: true) do
      {:ok, response} ->
        parse_decision_response(response)

      {:error, :no_api_key} ->
        # Fallback: use heuristic
        Logger.warning("LLM unavailable for integration decision, using heuristic")
        heuristic_decide(new_content, existing, opts)

      {:error, reason} ->
        Logger.error("LLM integration decision failed: #{inspect(reason)}")
        # Fallback to heuristic on error
        heuristic_decide(new_content, existing, opts)
    end
  end

  @doc """
  Execute an integration decision.

  Based on the decision from `decide/3`, this function performs the appropriate
  action: creating supersession chains, merging content, or rejecting duplicates.

  ## Parameters

    - `decision` - One of :update, :correction, :refinement, :redundant, :new
    - `new_content` - The new content
    - `existing` - The existing Engram (nil for :new decision)
    - `opts` - Options passed to Memory.store_memory/2

  ## Returns

    - `{:ok, engram}` - The created or updated engram
    - `{:ok, :skipped}` - For :redundant decisions
    - `{:error, reason}` - On failure

  ## Example

      {:ok, engram} = MemoryIntegrator.execute(:update, "New content", existing, category: "fact")
  """
  @spec execute(decision(), String.t(), Engram.t() | map() | nil, keyword()) ::
          {:ok, Engram.t()} | {:ok, :skipped} | {:error, term()}
  def execute(decision, new_content, existing, opts \\ [])

  def execute(:new, new_content, _existing, opts) do
    # Create completely new memory - no supersession
    # Category must be a string for persist_memory
    # Use persist_memory/5 to get full engram back (3-arg version returns just ID)
    category = normalize_category(opts[:category] || "fact")
    importance = opts[:importance] || 0.5
    Memory.persist_memory(new_content, category, importance, nil, %{})
  end

  def execute(:redundant, _new_content, existing, _opts) do
    # Don't create new memory, optionally reinforce existing
    if is_struct(existing, Engram) do
      # Reinforce by touching accessed_at (via search access)
      Logger.debug("TMC: Redundant content, reinforcing existing memory #{existing.id}")
    end

    {:ok, :skipped}
  end

  def execute(:update, new_content, existing, opts) do
    supersede_and_create(existing, new_content, :update, opts)
  end

  def execute(:correction, new_content, existing, opts) do
    supersede_and_create(existing, new_content, :correction, opts)
  end

  def execute(:refinement, new_content, existing, opts) do
    # Merge content via LLM
    case merge_content(get_content(existing), new_content, opts) do
      {:ok, merged_content} ->
        supersede_and_create(existing, merged_content, :refinement, opts)

      {:error, _reason} ->
        # Fallback: just supersede with new content
        supersede_and_create(existing, new_content, :refinement, opts)
    end
  end

  @doc """
  Merge two pieces of content using LLM.

  Used for :refinement decisions where both old and new content have value.

  ## Parameters

    - `original_content` - The original/existing content
    - `new_content` - The new content to merge in
    - `opts` - Options:
      - `:category` - Category for context
      - `:reasoning` - Context about why we're merging

  ## Returns

    - `{:ok, merged_content}` - The merged content string
    - `{:error, reason}` - On failure
  """
  @spec merge_content(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def merge_content(original_content, new_content, opts \\ []) do
    category = Keyword.get(opts, :category, :fact)
    reasoning = Keyword.get(opts, :reasoning, "Combining complementary information")

    prompt =
      @merge_prompt
      |> String.replace("{{original_content}}", original_content)
      |> String.replace("{{new_content}}", new_content)
      |> String.replace("{{reasoning}}", reasoning)
      |> String.replace("{{category}}", to_string(category))

    case LLM.complete(prompt, max_tokens: 500, temperature: 0.2, raw: true) do
      {:ok, merged} ->
        {:ok, String.trim(merged)}

      {:error, :no_api_key} ->
        # Fallback: simple concatenation
        Logger.warning("LLM unavailable for merge, using simple concatenation")
        {:ok, "#{original_content}\n\n[Update]: #{new_content}"}

      {:error, reason} ->
        {:error, {:merge_failed, reason}}
    end
  end

  @doc """
  Mark an engram as superseded by a new one.

  Creates the temporal chain link between old and new memories.

  ## Parameters

    - `old_engram` - The engram being superseded
    - `new_engram` - The engram that supersedes it
    - `supersession_type` - One of :update, :correction, :refinement

  ## Returns

    - `{:ok, updated_engram}` - The old engram with supersession info
    - `{:error, reason}` - On failure
  """
  @spec supersede(Engram.t(), Engram.t(), atom()) :: {:ok, Engram.t()} | {:error, term()}
  def supersede(%Engram{} = old_engram, %Engram{} = new_engram, supersession_type) do
    changeset =
      old_engram
      |> Ecto.Changeset.change(%{
        superseded_at: DateTime.utc_now() |> DateTime.truncate(:second),
        supersession_type: to_string(supersession_type)
      })

    case Repo.update(changeset) do
      {:ok, updated} ->
        Logger.info(
          "TMC: Superseded memory #{old_engram.id} with #{new_engram.id} (#{supersession_type})"
        )

        {:ok, updated}

      {:error, changeset} ->
        {:error, {:supersession_failed, changeset}}
    end
  end

  @doc """
  Check if TMC feature is enabled.
  """
  @spec tmc_enabled?() :: boolean()
  def tmc_enabled? do
    flags = Application.get_env(:mimo_mcp, :feature_flags, [])

    case Keyword.get(flags, :temporal_memory_chains, false) do
      {:system, env_var, default} ->
        case System.get_env(env_var) do
          nil -> default
          "true" -> true
          "1" -> true
          _ -> false
        end

      value when is_boolean(value) ->
        value

      _ ->
        false
    end
  end

  # Normalize category to string (Engram schema uses :string type)
  defp normalize_category(cat) when is_atom(cat), do: Atom.to_string(cat)
  defp normalize_category(cat) when is_binary(cat), do: cat
  defp normalize_category(_), do: "fact"

  defp supersede_and_create(existing, new_content, supersession_type, opts) do
    category = normalize_category(opts[:category] || get_category(existing))
    importance = opts[:importance] || 0.5
    supersedes_id = get_id(existing)

    # Use WriteSerializer.transaction to ensure all DB operations go through
    # the same serialized path - avoids deadlock with nested transactions
    Mimo.Brain.WriteSerializer.transaction(fn ->
      metadata = %{supersedes_id: supersedes_id}

      do_supersede_and_create(
        existing,
        new_content,
        category,
        importance,
        metadata,
        supersedes_id,
        supersession_type
      )
    end)
    |> normalize_transaction_result()
  end

  defp do_supersede_and_create(
         existing,
         new_content,
         category,
         importance,
         metadata,
         supersedes_id,
         supersession_type
       ) do
    case Memory.persist_memory(new_content, category, importance, nil, metadata) do
      {:ok, new_engram} ->
        new_engram = ensure_supersedes_id(new_engram, supersedes_id)
        result = mark_existing_superseded(existing, new_engram, supersession_type)
        {:ok, result}

      {:error, reason} ->
        Repo.rollback({:persist_failed, reason})
    end
  end

  defp ensure_supersedes_id(engram, supersedes_id) do
    if engram.supersedes_id != supersedes_id do
      case Repo.update(Ecto.Changeset.change(engram, %{supersedes_id: supersedes_id})) do
        {:ok, updated} ->
          updated

        {:error, changeset} ->
          Logger.error("Failed to set supersedes_id: #{inspect(changeset.errors)}")
          Repo.rollback({:supersedes_update_failed, changeset.errors})
      end
    else
      engram
    end
  end

  defp mark_existing_superseded(existing, new_engram, supersession_type)
       when is_struct(existing, Engram) do
    case supersede(existing, new_engram, supersession_type) do
      {:ok, _} ->
        new_engram

      {:error, reason} ->
        Logger.error("Failed to mark old memory as superseded: #{inspect(reason)}")
        Repo.rollback({:supersession_failed, reason})
    end
  end

  defp mark_existing_superseded(_existing, new_engram, _supersession_type), do: new_engram

  # SPEC-STABILITY: WriteSerializer.transaction wraps Repo.transaction which double-wraps results
  # Handle all possible patterns from nested transactions
  defp normalize_transaction_result({:ok, {:ok, engram}}), do: {:ok, engram}
  defp normalize_transaction_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_transaction_result({:ok, engram}) when is_struct(engram, Engram), do: {:ok, engram}
  defp normalize_transaction_result({:ok, engram}) when is_map(engram), do: {:ok, engram}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp normalize_transaction_result(other) do
    Logger.warning("Unexpected transaction result in MemoryIntegrator: #{inspect(other)}")
    {:error, {:unexpected_result, other}}
  end

  defp parse_decision_response(response) do
    cleaned =
      response
      |> String.replace(~r/```json\s*/i, "")
      |> String.replace(~r/```\s*/i, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"decision" => decision_str} = result} ->
        build_decision_from_result(decision_str, result)

      {:ok, _} ->
        Logger.warning("Unexpected LLM response format")
        {:ok, %{decision: :new, reasoning: "Unexpected response format", confidence: 0.5}}

      {:error, reason} ->
        Logger.warning("Failed to parse decision response: #{inspect(reason)}")
        {:ok, %{decision: :new, reasoning: "Parse error, defaulting to new", confidence: 0.5}}
    end
  end

  defp build_decision_from_result(decision_str, result) do
    decision = parse_decision_string(decision_str)

    if decision in @valid_decisions do
      {:ok,
       %{
         decision: decision,
         reasoning: result["reasoning"] || "No reasoning provided",
         confidence: result["confidence"] || 0.8
       }}
    else
      Logger.warning("Invalid decision from LLM: #{decision_str}, defaulting to :new")

      {:ok,
       %{decision: :new, reasoning: "Invalid LLM decision, defaulting to new", confidence: 0.5}}
    end
  end

  defp parse_decision_string(str) when is_binary(str) do
    str
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :new
  end

  defp heuristic_decide(new_content, existing, opts) do
    existing_content = get_content(existing)
    existing_category = get_category(existing)
    new_category = Keyword.get(opts, :category, existing_category)

    # Simple heuristics
    cond do
      # Same category, very similar length - likely update
      existing_category == new_category and
          abs(String.length(new_content) - String.length(existing_content)) < 50 ->
        {:ok,
         %{
           decision: :update,
           reasoning: "Heuristic: similar length, same category",
           confidence: 0.6
         }}

      # New is much longer - likely refinement
      String.length(new_content) > String.length(existing_content) * 1.5 ->
        {:ok,
         %{
           decision: :refinement,
           reasoning: "Heuristic: new content significantly longer",
           confidence: 0.6
         }}

      # New is much shorter - might be redundant or distinct
      String.length(new_content) < String.length(existing_content) * 0.5 ->
        {:ok,
         %{
           decision: :new,
           reasoning: "Heuristic: new content much shorter, likely distinct",
           confidence: 0.5
         }}

      # Default: treat as update
      true ->
        {:ok, %{decision: :update, reasoning: "Heuristic: default to update", confidence: 0.5}}
    end
  end

  defp get_content(%Engram{content: content}), do: content
  defp get_content(%{content: content}), do: content
  defp get_content(%{"content" => content}), do: content
  defp get_content(_), do: ""

  defp get_category(%Engram{category: category}), do: category
  defp get_category(%{category: category}), do: normalize_category(category)
  defp get_category(%{"category" => category}), do: normalize_category(category)
  defp get_category(_), do: "fact"

  defp get_id(%Engram{id: id}), do: id
  defp get_id(%{id: id}), do: id
  defp get_id(%{"id" => id}), do: id
  defp get_id(_), do: nil

  defp calculate_age(%Engram{inserted_at: inserted_at}) when not is_nil(inserted_at) do
    now = DateTime.utc_now()
    # Handle NaiveDateTime
    dt =
      case inserted_at do
        %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC")
        %DateTime{} = dt -> dt
      end

    diff_seconds = DateTime.diff(now, dt, :second)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)} minutes ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)} hours ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86400)} days ago"
      true -> "#{div(diff_seconds, 604_800)} weeks ago"
    end
  end

  defp calculate_age(_), do: "unknown time"
end
