defmodule Mimo.Brain.ContradictionGuard do
  @moduledoc """
  Pre-Response Contradiction Detection - Catches conflicts before they reach the user.

  Part of P2 in the Intelligence Roadmap.

  This module:
  1. Extracts key claims from a proposed response
  2. Searches memory for related knowledge
  3. Detects contradictions between response and stored knowledge
  4. Returns warnings that can be injected into context

  ## Usage

  Before the LLM responds, check for contradictions:

      case ContradictionGuard.check(proposed_response) do
        {:ok, []} ->
          # No contradictions, proceed
          send_response(proposed_response)

        {:ok, warnings} ->
          # Found potential contradictions, inject into context
          context = "CONTRADICTION WARNING:\\n" <> Enum.join(warnings, "\\n")
          regenerate_with_context(context)
      end

  ## Integration Points

  - Called by `Mimo.Tools.Dispatchers.Meta` before response
  - Can be integrated into any tool's post-processing
  - Used by `ask_mimo` to validate responses
  """

  require Logger
  alias InferenceScheduler
  alias Mimo.Brain.{LLM, Memory}

  @claim_extraction_prompt """
  Extract the key factual claims from this text. Return as a JSON array of strings.
  Focus on: facts, preferences, technical details, design decisions.
  Ignore: opinions, suggestions, questions.

  TEXT:
  {{text}}

  Return ONLY a JSON array like: ["claim1", "claim2"]
  If no clear claims, return: []
  """

  @contradiction_check_prompt """
  Given this CLAIM and STORED KNOWLEDGE, is there a contradiction?

  CLAIM: {{claim}}

  STORED KNOWLEDGE: {{knowledge}}

  If there is a clear contradiction, respond with:
  CONTRADICTION: [brief explanation of the conflict]

  If no contradiction (compatible, unrelated, or claim extends knowledge), respond with:
  OK
  """

  @doc """
  Check a proposed response for contradictions with stored knowledge.

  Returns `{:ok, warnings}` where warnings is a list of contradiction descriptions.
  Empty list means no contradictions found.
  """
  @spec check(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def check(proposed_response, opts \\ []) do
    max_claims = Keyword.get(opts, :max_claims, 5)
    similarity_threshold = Keyword.get(opts, :similarity_threshold, 0.6)

    with {:ok, claims} <- extract_claims(proposed_response, max_claims),
         {:ok, warnings} <- check_claims(claims, similarity_threshold) do
      unless Enum.empty?(warnings) do
        Logger.info("[ContradictionGuard] Found #{length(warnings)} potential contradictions")
      end

      {:ok, warnings}
    end
  end

  @doc """
  Quick check that returns boolean - useful for guards.
  """
  @spec contradicts?(String.t()) :: boolean()
  def contradicts?(proposed_response) do
    case check(proposed_response) do
      {:ok, []} -> false
      {:ok, _warnings} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Extract factual claims from text using LLM.
  """
  @spec extract_claims(String.t(), integer()) :: {:ok, [String.t()]} | {:error, term()}
  def extract_claims(text, max_claims \\ 5) do
    # Truncate long texts
    truncated = String.slice(text, 0, 2000)

    prompt = String.replace(@claim_extraction_prompt, "{{text}}", truncated)

    # Use InferenceScheduler with :high priority (user-facing, needs fast response)
    # Fall back to direct LLM if scheduler unavailable
    result =
      try do
        Mimo.Brain.InferenceScheduler.request(:high, prompt,
          format: :json,
          max_tokens: 200,
          raw: true,
          temperature: 0.1
        )
      catch
        :exit, _ ->
          Logger.debug("[ContradictionGuard] InferenceScheduler unavailable, using direct LLM")
          LLM.complete(prompt, format: :json, max_tokens: 200, raw: true, temperature: 0.1)
      end

    case result do
      {:ok, response} ->
        case Jason.decode(response) do
          {:ok, claims} when is_list(claims) ->
            valid_claims =
              claims
              |> Enum.filter(fn x -> is_binary(x) and String.length(x) > 10 end)
              |> Enum.take(max_claims)

            {:ok, valid_claims}

          _ ->
            # JSON parse failed - fail closed (don't pretend we checked)
            Logger.warning("[ContradictionGuard] Failed to parse claims JSON: #{response}")
            {:error, :invalid_json}
        end

      {:error, reason} ->
        Logger.warning("[ContradictionGuard] LLM unavailable: #{inspect(reason)}")
        # Fail closed - propagate error so caller knows check didn't happen
        {:error, {:llm_unavailable, reason}}
    end
  end

  @doc """
  Check a list of claims against stored knowledge.
  Returns list of contradiction warnings, or error if any check failed.
  """
  @spec check_claims([String.t()], float()) :: {:ok, [String.t()]} | {:error, term()}
  def check_claims(claims, similarity_threshold) do
    # Use reduce_while to stop on first error (fail-closed)
    result =
      Enum.reduce_while(claims, {:ok, []}, fn claim, {:ok, acc_warnings} ->
        case check_single_claim(claim, similarity_threshold) do
          {:contradiction, warning} ->
            {:cont, {:ok, [warning | acc_warnings]}}

          :ok ->
            {:cont, {:ok, acc_warnings}}

          {:error, reason} ->
            # Fail closed - propagate error
            {:halt, {:error, {:claim_check_failed, claim, reason}}}
        end
      end)

    case result do
      {:ok, warnings} -> {:ok, Enum.reverse(warnings)}
      error -> error
    end
  end

  defp check_single_claim(claim, threshold) do
    # Search for related memories
    case Memory.search_memories(claim, limit: 3, min_similarity: threshold) do
      related when is_list(related) and related != [] ->
        # Found related memories - check for contradictions
        check_against_memories(claim, related)

      _ ->
        # No related memories - no contradiction possible
        :ok
    end
  end

  defp check_against_memories(claim, memories) do
    # Format memories for prompt
    knowledge_text =
      Enum.map_join(memories, "\n", fn m ->
        content = Map.get(m, :content, "")
        category = Map.get(m, :category, "unknown")
        "[#{category}] #{content}"
      end)

    prompt =
      @contradiction_check_prompt
      |> String.replace("{{claim}}", claim)
      |> String.replace("{{knowledge}}", knowledge_text)

    # Use InferenceScheduler with :high priority (user-facing)
    # Fall back to direct LLM if scheduler unavailable
    result =
      try do
        Mimo.Brain.InferenceScheduler.request(:high, prompt,
          max_tokens: 100,
          raw: true,
          temperature: 0.1
        )
      catch
        :exit, _ ->
          Logger.debug("[ContradictionGuard] InferenceScheduler unavailable, using direct LLM")
          LLM.complete(prompt, max_tokens: 100, raw: true, temperature: 0.1)
      end

    case result do
      {:ok, response} ->
        if String.starts_with?(String.upcase(response), "CONTRADICTION") do
          # Extract the explanation
          warning =
            response
            |> String.replace(~r/^CONTRADICTION:?\s*/i, "")
            |> String.trim()

          if String.length(warning) > 5 do
            {:contradiction, "Claim '#{String.slice(claim, 0, 50)}...' conflicts: #{warning}"}
          else
            :ok
          end
        else
          :ok
        end

      {:error, reason} ->
        # Fail closed - don't pretend check passed
        Logger.warning("[ContradictionGuard] LLM check failed: #{inspect(reason)}")
        {:error, {:llm_check_failed, reason}}
    end
  end

  @doc """
  Format warnings for injection into LLM context.
  """
  @spec format_warnings([String.t()]) :: String.t()
  def format_warnings([]), do: ""

  def format_warnings(warnings) do
    """
    ⚠️ CONTRADICTION DETECTED - Review before responding:
    #{Enum.map_join(warnings, "\n", fn w -> "• #{w}" end)}

    Consider revising your response to align with stored knowledge.
    """
  end

  @doc """
  One-shot check and format for easy integration.
  Returns empty string if no contradictions, warning string if found,
  or error indicator if check couldn't be performed.
  """
  @spec check_and_format(String.t()) :: String.t()
  def check_and_format(proposed_response) do
    case check(proposed_response) do
      {:ok, []} ->
        ""

      {:ok, warnings} ->
        format_warnings(warnings)

      {:error, reason} ->
        # Fail closed - indicate check couldn't happen
        "⚠️ CONTRADICTION CHECK FAILED: #{inspect(reason)} - Manual review recommended."
    end
  end
end
