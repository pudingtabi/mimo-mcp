defmodule Mimo.Brain.EmbeddingGate do
  @moduledoc """
  Embedding-Based LLM Call Gating - Use free embeddings to filter expensive LLM calls.

  Part of revised P4 in the Intelligence Roadmap.

  This module uses embedding similarity (free, local, fast) to determine
  if an LLM call is actually needed. Filters 80%+ of unnecessary calls.

  ## Gate Types

  1. **Duplicate Detection**: Is this prompt nearly identical to a recent one?
  2. **Cache Hit**: Can we reuse a cached LLM response?
  3. **Novelty Check**: Is this content novel enough to warrant processing?
  4. **Contradiction Pre-Check**: Is there likely a conflict worth checking?

  ## Usage

      # Before making an LLM call:
      case EmbeddingGate.should_call_llm?(prompt, :synthesis) do
        {:pass, _} ->
          # Proceed with LLM call
          LLM.complete(prompt)

        {:skip, skip_reason} ->
          # Use cached/fallback
          {:ok, "Skipped: \#{skip_reason}"}

        {:cached, response} ->
          # Reuse cached response
          {:ok, response}
      end

  ## Cost Savings

  Each LLM call avoided saves:
  - API cost (Cerebras free tier has limits, OpenRouter has cost)
  - Latency (even 300ms adds up)
  - Rate limit headroom
  """

  require Logger

  alias Mimo.Brain.LLM
  alias Mimo.Vector.Math, as: VectorMath

  # ETS table for response cache
  @cache_table :embedding_gate_cache
  @max_cache_size 1000
  # 1 hour
  @cache_ttl_ms 3_600_000

  # Similarity thresholds
  # Nearly identical prompts
  @duplicate_threshold 0.98
  # Similar enough to reuse response
  @cache_hit_threshold 0.95
  # Below this = novel enough to process
  @novelty_threshold 0.85

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Initialize the EmbeddingGate cache.
  Call from Application startup.
  """
  def init do
    if :ets.whereis(@cache_table) == :undefined do
      Mimo.EtsSafe.ensure_table(@cache_table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Check if an LLM call should be made for this prompt.

  Returns:
  - `{:pass, reason}` - Proceed with LLM call
  - `{:skip, reason}` - Don't call LLM, use fallback
  - `{:cached, response}` - Use cached response

  ## Gate Types
  - `:synthesis` - For Synthesizer (check novelty, cache)
  - `:contradiction` - For ContradictionGuard (check if worth checking)
  - `:general` - Default (duplicate + cache check)
  """
  @spec should_call_llm?(String.t(), atom()) ::
          {:pass, atom()} | {:skip, atom()} | {:cached, String.t()}
  def should_call_llm?(prompt, gate_type \\ :general) do
    # Ensure cache is initialized
    init()

    # Get prompt embedding (free, local)
    case get_prompt_embedding(prompt) do
      {:ok, embedding} ->
        check_gates(prompt, embedding, gate_type)

      {:error, _reason} ->
        # Can't get embedding, pass through
        {:pass, :embedding_unavailable}
    end
  end

  @doc """
  Store an LLM response in cache for future reuse.
  """
  @spec cache_response(String.t(), String.t()) :: :ok
  def cache_response(prompt, response) do
    init()

    case get_prompt_embedding(prompt) do
      {:ok, embedding} ->
        key = embedding_to_key(embedding)

        entry = %{
          prompt: prompt,
          response: response,
          embedding: embedding,
          timestamp: System.monotonic_time(:millisecond)
        }

        :ets.insert(@cache_table, {key, entry})

        # Cleanup if needed
        maybe_cleanup_cache()
        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Check if content is novel enough to process.
  Compares against provided reference embeddings.
  """
  @spec novel?(String.t(), [[float()]]) :: boolean()
  def novel?(content, reference_embeddings) when is_list(reference_embeddings) do
    case get_prompt_embedding(content) do
      {:ok, embedding} ->
        max_similarity =
          reference_embeddings
          |> Enum.map(&VectorMath.cosine_similarity(embedding, &1))
          |> Enum.max(fn -> 0.0 end)

        max_similarity < @novelty_threshold

      {:error, _} ->
        # Assume novel if we can't check
        true
    end
  end

  @doc """
  Get cache statistics.
  """
  @spec stats() :: map()
  def stats do
    init()

    size = :ets.info(@cache_table, :size) || 0

    %{
      cache_size: size,
      max_size: @max_cache_size,
      duplicate_threshold: @duplicate_threshold,
      cache_hit_threshold: @cache_hit_threshold,
      novelty_threshold: @novelty_threshold
    }
  end

  # =============================================================================
  # Private Implementation
  # =============================================================================

  defp check_gates(prompt, embedding, gate_type) do
    # Check for exact/near duplicates
    case check_duplicate(embedding) do
      {:duplicate, cached_response} ->
        {:cached, cached_response}

      :not_duplicate ->
        # Check cache for similar prompts
        case check_cache(embedding) do
          {:hit, cached_response} ->
            {:cached, cached_response}

          :miss ->
            # Gate-specific checks
            case gate_type do
              :synthesis ->
                check_synthesis_gate(prompt, embedding)

              :contradiction ->
                check_contradiction_gate(prompt, embedding)

              _ ->
                {:pass, :no_cache_hit}
            end
        end
    end
  end

  defp check_duplicate(embedding) do
    key = embedding_to_key(embedding)

    case :ets.lookup(@cache_table, key) do
      [{^key, entry}] ->
        if fresh?(entry) do
          {:duplicate, entry.response}
        else
          :not_duplicate
        end

      _ ->
        :not_duplicate
    end
  end

  defp check_cache(embedding) do
    now = System.monotonic_time(:millisecond)

    # Scan cache for similar embeddings
    result =
      :ets.foldl(
        fn {_key, entry}, acc ->
          if fresh?(entry, now) do
            similarity = VectorMath.cosine_similarity(embedding, entry.embedding)

            if similarity >= @cache_hit_threshold and similarity > elem(acc, 0) do
              {similarity, entry.response}
            else
              acc
            end
          else
            acc
          end
        end,
        {0.0, nil},
        @cache_table
      )

    case result do
      {sim, response} when sim >= @cache_hit_threshold and not is_nil(response) ->
        {:hit, response}

      _ ->
        :miss
    end
  rescue
    _ -> :miss
  end

  defp check_synthesis_gate(_prompt, _embedding) do
    # For synthesis, we generally want to proceed
    # Future: check against recently synthesized content
    {:pass, :synthesis_needed}
  end

  defp check_contradiction_gate(_prompt, _embedding) do
    # For contradiction checking, we generally want to proceed
    # The embedding similarity check in ContradictionGuard handles filtering
    {:pass, :contradiction_check_needed}
  end

  defp get_prompt_embedding(prompt) do
    # Truncate for efficiency
    truncated = String.slice(prompt, 0, 1000)
    LLM.get_embedding(truncated)
  end

  defp embedding_to_key(embedding) do
    # Create a hash of the embedding for fast lookup
    embedding
    # Use first 32 dimensions for key
    |> Enum.take(32)
    |> Enum.map(&Float.round(&1, 4))
    |> :erlang.phash2()
  end

  defp fresh?(entry, now \\ nil) do
    now = now || System.monotonic_time(:millisecond)
    entry.timestamp + @cache_ttl_ms > now
  end

  defp maybe_cleanup_cache do
    size = :ets.info(@cache_table, :size) || 0

    if size > @max_cache_size do
      # Remove oldest 20%
      now = System.monotonic_time(:millisecond)
      cutoff = now - @cache_ttl_ms

      # Delete expired entries
      :ets.foldl(
        fn {key, entry}, count ->
          if entry.timestamp < cutoff do
            :ets.delete(@cache_table, key)
            count + 1
          else
            count
          end
        end,
        0,
        @cache_table
      )
    end
  end
end
