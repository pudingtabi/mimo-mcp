defmodule Mimo.Cognitive.Amplifier.ClaimExtractor do
  @moduledoc """
  SPEC-092 Phase 1: Extracts verifiable claims from reasoning thoughts.

  The core problem: Mimo's reasoning validation is purely syntactic (checking
  length, regex patterns) rather than semantic (verifying content accuracy).

  This module extracts claims that CAN be verified against sources:
  - SPEC claims: "SPEC-092 defines query intent classification"
  - Line claims: "amplifier.ex:123 checks decomposition"
  - File claims: "lib/mimo/brain/memory.ex contains the store function"
  - Code claims: "`cleanup_stale_edges` returns {:ok, count}"

  These extracted claims are then passed to ClaimVerifier for semantic verification.
  """

  @type claim_type :: :spec_claim | :file_claim | :code_claim | :line_claim
  @type claim :: %{
          type: claim_type(),
          subject: String.t(),
          predicate: String.t(),
          object: String.t(),
          raw_match: String.t(),
          confidence: float()
        }

  @doc """
  Extract verifiable claims from a reasoning thought.

  Returns a list of claims that can be verified against actual sources.

  ## Examples

      iex> ClaimExtractor.extract("SPEC-092 defines query intent classification")
      [%{type: :spec_claim, subject: "SPEC-092", predicate: "defines", object: "query intent classification", ...}]

      iex> ClaimExtractor.extract("amplifier.ex:42 contains the conclude function")
      [%{type: :line_claim, subject: "amplifier.ex:42", predicate: "contains", object: "the conclude function", ...}]
  """
  @spec extract(String.t() | nil) :: [claim()]
  def extract(nil), do: []
  def extract(""), do: []

  def extract(thought) when is_binary(thought) do
    []
    |> extract_spec_claims(thought)
    |> extract_line_claims(thought)
    |> extract_file_claims(thought)
    |> extract_code_claims(thought)
    |> Enum.uniq_by(& &1.raw_match)
  end

  @doc """
  Extract only claims of a specific type.
  """
  @spec extract(String.t(), claim_type()) :: [claim()]
  def extract(thought, type) when is_binary(thought) and is_atom(type) do
    thought
    |> extract()
    |> Enum.filter(&(&1.type == type))
  end

  # Pattern: "SPEC-NNN says/defines/requires/is about X"
  # Also handles: "per SPEC-NNN", "according to SPEC-NNN", "SPEC-NNN:"
  defp extract_spec_claims(claims, thought) do
    # Primary pattern: SPEC-NNN <verb> <content>
    primary_pattern =
      ~r/(SPEC-\d+)\s+(says|defines|requires|is about|specifies|describes|mandates|implements|adds|enables|provides)\s+([^.!?\n]{10,})/i

    # Secondary pattern: "per SPEC-NNN, X" or "according to SPEC-NNN, X"
    secondary_pattern = ~r/(?:per|according to|as per|from)\s+(SPEC-\d+)[,:]?\s+([^.!?\n]{10,})/i

    # Colon pattern: "SPEC-NNN: X"
    colon_pattern = ~r/(SPEC-\d+):\s+([^.!?\n]{10,})/i

    primary_claims =
      Regex.scan(primary_pattern, thought)
      |> Enum.map(fn [full_match, spec, verb, content] ->
        %{
          type: :spec_claim,
          subject: String.upcase(spec),
          predicate: String.downcase(verb),
          object: String.trim(content),
          raw_match: full_match,
          confidence: 0.9
        }
      end)

    secondary_claims =
      Regex.scan(secondary_pattern, thought)
      |> Enum.map(fn [full_match, spec, content] ->
        %{
          type: :spec_claim,
          subject: String.upcase(spec),
          predicate: "states",
          object: String.trim(content),
          raw_match: full_match,
          confidence: 0.8
        }
      end)

    colon_claims =
      Regex.scan(colon_pattern, thought)
      |> Enum.map(fn [full_match, spec, content] ->
        %{
          type: :spec_claim,
          subject: String.upcase(spec),
          predicate: "states",
          object: String.trim(content),
          raw_match: full_match,
          confidence: 0.85
        }
      end)

    claims ++ primary_claims ++ secondary_claims ++ colon_claims
  end

  # Pattern: "file.ex:123 - description" or "file.ex:123 contains X"
  defp extract_line_claims(claims, thought) do
    # Pattern with line number and description
    pattern = ~r/([\w\/\-\.]+\.exs?):(\d+)\s*[-–:]\s*([^.\n]{5,})/

    # Pattern with explicit verb
    verb_pattern =
      ~r/([\w\/\-\.]+\.exs?):(\d+)\s+(contains|has|shows|defines|implements)\s+([^.!?\n]{5,})/i

    line_claims =
      Regex.scan(pattern, thought)
      |> Enum.map(fn [full_match, file, line, content] ->
        %{
          type: :line_claim,
          subject: "#{file}:#{line}",
          predicate: "contains",
          object: String.trim(content),
          raw_match: full_match,
          confidence: 0.95,
          metadata: %{file: file, line: String.to_integer(line)}
        }
      end)

    verb_claims =
      Regex.scan(verb_pattern, thought)
      |> Enum.map(fn [full_match, file, line, verb, content] ->
        %{
          type: :line_claim,
          subject: "#{file}:#{line}",
          predicate: String.downcase(verb),
          object: String.trim(content),
          raw_match: full_match,
          confidence: 0.95,
          metadata: %{file: file, line: String.to_integer(line)}
        }
      end)

    claims ++ line_claims ++ verb_claims
  end

  # Pattern: "lib/path/file.ex contains/has/defines X"
  defp extract_file_claims(claims, thought) do
    # Full path pattern
    pattern =
      ~r/((?:lib|test|config|priv)\/[\w\/\-\.]+\.(?:ex|exs|json|yaml|md))\s+(contains|has|defines|implements|exports|provides|includes)\s+([^.!?\n]{5,})/i

    # Simple filename pattern
    simple_pattern =
      ~r/\b([\w_]+\.(?:ex|exs))\s+(contains|has|defines|implements)\s+([^.!?\n]{5,})/i

    full_claims =
      Regex.scan(pattern, thought)
      |> Enum.map(fn [full_match, file, verb, content] ->
        %{
          type: :file_claim,
          subject: file,
          predicate: String.downcase(verb),
          object: String.trim(content),
          raw_match: full_match,
          confidence: 0.9
        }
      end)

    simple_claims =
      Regex.scan(simple_pattern, thought)
      |> Enum.reject(fn [_, file, _, _] ->
        # Reject if already captured by full path pattern
        Enum.any?(full_claims, fn c -> String.ends_with?(c.subject, file) end)
      end)
      |> Enum.map(fn [full_match, file, verb, content] ->
        %{
          type: :file_claim,
          subject: file,
          predicate: String.downcase(verb),
          object: String.trim(content),
          raw_match: full_match,
          confidence: 0.7
        }
      end)

    claims ++ full_claims ++ simple_claims
  end

  # Pattern: `code` checks/returns/validates X
  defp extract_code_claims(claims, thought) do
    # Backtick code pattern
    pattern =
      ~r/`([^`]+)`\s+(checks|returns|validates|calls|uses|implements|creates|stores|accepts|expects)\s+([^.!?\n]{5,})/i

    # Function call pattern: function_name/arity returns X
    arity_pattern =
      ~r/\b([\w_]+\/\d)\s+(returns|accepts|expects|produces)\s+([^.!?\n]{5,})/i

    backtick_claims =
      Regex.scan(pattern, thought)
      |> Enum.map(fn [full_match, code, verb, content] ->
        %{
          type: :code_claim,
          subject: code,
          predicate: String.downcase(verb),
          object: String.trim(content),
          raw_match: full_match,
          confidence: 0.85
        }
      end)

    arity_claims =
      Regex.scan(arity_pattern, thought)
      |> Enum.map(fn [full_match, func, verb, content] ->
        %{
          type: :code_claim,
          subject: func,
          predicate: String.downcase(verb),
          object: String.trim(content),
          raw_match: full_match,
          confidence: 0.8
        }
      end)

    claims ++ backtick_claims ++ arity_claims
  end

  @doc """
  Check if a thought contains any verifiable claims.
  """
  @spec has_claims?(String.t()) :: boolean()
  def has_claims?(thought) do
    thought
    |> extract()
    |> Enum.any?()
  end

  @doc """
  Get a summary of claim types found in a thought.
  """
  @spec summarize(String.t()) :: %{total: non_neg_integer(), by_type: map()}
  def summarize(thought) do
    claims = extract(thought)

    by_type =
      claims
      |> Enum.group_by(& &1.type)
      |> Enum.map(fn {type, list} -> {type, length(list)} end)
      |> Enum.into(%{})

    %{
      total: length(claims),
      by_type: by_type
    }
  end
end
