defmodule Mimo.Cognitive.Amplifier.ClaimVerifier do
  @moduledoc """
  SPEC-092 Phase 2: Verifies claims extracted from reasoning thoughts.

  This module performs SEMANTIC verification - actually checking if claims
  are true by reading sources, not just checking syntactic properties.

  Verification methods by claim type:
  - spec_claim: Search memory/docs for SPEC content, fuzzy match against claim
  - line_claim: Read file at specific line, verify content exists
  - file_claim: Read file, search for claimed content
  - code_claim: Use code symbols to verify function behavior/existence
  """

  require Logger

  alias Mimo.Cognitive.Amplifier.ClaimExtractor

  @type verification_result :: %{
          claim: ClaimExtractor.claim(),
          verified: boolean(),
          confidence: float(),
          evidence: String.t() | nil,
          method: atom()
        }

  @doc """
  Verify a list of claims against their sources.

  Returns verification results for each claim.
  """
  @spec verify_all([ClaimExtractor.claim()]) :: [verification_result()]
  def verify_all(claims) when is_list(claims) do
    claims
    |> Enum.map(&verify/1)
  end

  @doc """
  Verify a single claim against its source.
  """
  @spec verify(ClaimExtractor.claim()) :: verification_result()
  def verify(%{type: :spec_claim} = claim) do
    verify_spec_claim(claim)
  end

  def verify(%{type: :line_claim} = claim) do
    verify_line_claim(claim)
  end

  def verify(%{type: :file_claim} = claim) do
    verify_file_claim(claim)
  end

  def verify(%{type: :code_claim} = claim) do
    verify_code_claim(claim)
  end

  # SPEC-074-ENHANCED: URL claim verification
  def verify(%{type: :url_claim} = claim) do
    verify_url_claim(claim)
  end

  # SPEC-074-ENHANCED: Reasoning/logical claim verification
  def verify(%{type: :reasoning_claim} = claim) do
    verify_reasoning_claim(claim)
  end

  # SPEC-074-ENHANCED: Temporal claim verification
  def verify(%{type: :temporal_claim} = claim) do
    verify_temporal_claim(claim)
  end

  def verify(claim) do
    %{
      claim: claim,
      verified: false,
      confidence: 0.0,
      evidence: "Unknown claim type",
      method: :unknown
    }
  end

  # Verify SPEC claims by searching memory and docs
  defp verify_spec_claim(%{subject: spec_id, object: claimed_content} = claim) do
    # First try memory search for SPEC content
    case search_memory_for_spec(spec_id) do
      {:ok, memories} when memories != [] ->
        # Check if any memory content fuzzy-matches the claim
        match_result = fuzzy_match_claim(claimed_content, memories)

        %{
          claim: claim,
          verified: match_result.matched,
          confidence: match_result.confidence,
          evidence: match_result.evidence,
          method: :memory_search
        }

      _ ->
        # Fallback: search for SPEC files in docs/
        case search_docs_for_spec(spec_id) do
          {:ok, content} ->
            match_result = fuzzy_match_content(claimed_content, content)

            %{
              claim: claim,
              verified: match_result.matched,
              confidence: match_result.confidence,
              evidence: match_result.evidence,
              method: :doc_file
            }

          {:error, _} ->
            %{
              claim: claim,
              verified: false,
              confidence: 0.0,
              evidence: "SPEC document not found: #{spec_id}",
              method: :not_found
            }
        end
    end
  end

  # Verify line claims by reading the specific line
  defp verify_line_claim(
         %{metadata: %{file: file, line: line_num}, object: claimed_content} = claim
       ) do
    case read_file_line(file, line_num) do
      {:ok, actual_content} ->
        match_result = fuzzy_match_content(claimed_content, actual_content)

        %{
          claim: claim,
          verified: match_result.matched,
          confidence: match_result.confidence,
          evidence: "Line #{line_num}: #{String.slice(actual_content, 0, 100)}",
          method: :line_read
        }

      {:error, reason} ->
        %{
          claim: claim,
          verified: false,
          confidence: 0.0,
          evidence: "Could not read #{file}:#{line_num} - #{reason}",
          method: :read_failed
        }
    end
  end

  # Handle line claims without metadata
  defp verify_line_claim(%{subject: subject, object: _claimed_content} = claim) do
    case parse_file_line(subject) do
      {:ok, file, line_num} ->
        verify_line_claim(%{claim | metadata: %{file: file, line: line_num}})

      :error ->
        %{
          claim: claim,
          verified: false,
          confidence: 0.0,
          evidence: "Could not parse file:line from #{subject}",
          method: :parse_failed
        }
    end
  end

  # Verify file claims by searching file content
  defp verify_file_claim(%{subject: file_path, object: claimed_content} = claim) do
    case read_file_content(file_path) do
      {:ok, content} ->
        match_result = fuzzy_match_content(claimed_content, content)

        %{
          claim: claim,
          verified: match_result.matched,
          confidence: match_result.confidence,
          evidence: if(match_result.matched, do: "Found in file", else: "Not found in file"),
          method: :file_search
        }

      {:error, reason} ->
        %{
          claim: claim,
          verified: false,
          confidence: 0.0,
          evidence: "Could not read #{file_path} - #{reason}",
          method: :read_failed
        }
    end
  end

  # Verify code claims by checking symbol existence and properties
  defp verify_code_claim(
         %{subject: code_ref, predicate: predicate, object: claimed_content} = claim
       ) do
    # Try to find the symbol definition
    case find_code_symbol(code_ref) do
      {:ok, symbol_info} ->
        # Verify based on predicate type
        match_result = verify_code_predicate(predicate, claimed_content, symbol_info)

        %{
          claim: claim,
          verified: match_result.matched,
          confidence: match_result.confidence,
          evidence: match_result.evidence,
          method: :code_symbol
        }

      {:error, _} ->
        %{
          claim: claim,
          verified: false,
          confidence: 0.0,
          evidence: "Symbol not found: #{code_ref}",
          method: :symbol_not_found
        }
    end
  end

  # SPEC-074-ENHANCED: Verify URL claims by fetching web content
  defp verify_url_claim(%{subject: url, object: claimed_content} = claim) do
    try do
      case Mimo.Tools.Dispatchers.Web.dispatch(%{
             "operation" => "fetch",
             "url" => url,
             "format" => "text"
           }) do
        {:ok, %{content: actual}} when is_binary(actual) ->
          match_result = fuzzy_match_content(claimed_content, actual)

          %{
            claim: claim,
            verified: match_result.matched,
            confidence: match_result.confidence * 0.9,
            evidence:
              if(match_result.matched, do: "Content found at URL", else: "Content not found at URL"),
            method: :url_fetch
          }

        {:ok, %{"content" => actual}} when is_binary(actual) ->
          match_result = fuzzy_match_content(claimed_content, actual)

          %{
            claim: claim,
            verified: match_result.matched,
            confidence: match_result.confidence * 0.9,
            evidence:
              if(match_result.matched, do: "Content found at URL", else: "Content not found at URL"),
            method: :url_fetch
          }

        _ ->
          %{
            claim: claim,
            verified: false,
            confidence: 0.0,
            evidence: "Could not fetch URL",
            method: :url_failed
          }
      end
    rescue
      _ ->
        %{
          claim: claim,
          verified: false,
          confidence: 0.0,
          evidence: "Error fetching URL",
          method: :url_error
        }
    end
  end

  # SPEC-074-ENHANCED: Verify reasoning claims (if-then logical consistency)
  defp verify_reasoning_claim(%{subject: premise, object: conclusion} = claim) do
    # Use pattern matching and heuristics to check logical consistency
    # More sophisticated verification could use LLM but we avoid external calls here

    # Simple heuristic: check if conclusion relates to premise
    premise_terms = extract_key_terms(premise)
    conclusion_terms = extract_key_terms(conclusion)

    # Check for term overlap (weak indicator of logical connection)
    overlap = MapSet.intersection(premise_terms, conclusion_terms) |> MapSet.size()
    total = max(MapSet.size(premise_terms) + MapSet.size(conclusion_terms), 1)
    overlap_ratio = overlap / total

    # Check for logical connectors
    has_logical_structure = check_logical_structure(premise, conclusion)

    {verified, confidence} =
      cond do
        has_logical_structure and overlap_ratio > 0.3 ->
          {true, 0.7}

        overlap_ratio > 0.4 ->
          {true, 0.6}

        overlap_ratio > 0.2 ->
          {true, 0.4}

        true ->
          {false, 0.2}
      end

    %{
      claim: claim,
      verified: verified,
      confidence: confidence,
      evidence: "Logical consistency check: #{Float.round(overlap_ratio * 100, 1)}% term overlap",
      method: :reasoning_check
    }
  end

  # SPEC-074-ENHANCED: Verify temporal claims (before/after relationships)
  defp verify_temporal_claim(%{subject: event1, object: event2, predicate: relation} = claim) do
    # Try to extract date/time information from events
    date1 = extract_date(event1)
    date2 = extract_date(event2)

    {verified, confidence, evidence} =
      cond do
        # Both dates extracted - can verify
        date1 != nil and date2 != nil ->
          chronological = Date.compare(date1, date2) == :lt

          case relation do
            "before" ->
              {chronological, 0.9, "Dates: #{date1} vs #{date2}"}

            "after" ->
              {not chronological, 0.9, "Dates: #{date1} vs #{date2}"}

            _ ->
              {false, 0.0, "Unknown temporal relation: #{relation}"}
          end

        # Try to detect temporal ordering from text patterns
        true ->
          ordering = infer_temporal_ordering(event1, event2)

          case {relation, ordering} do
            {"before", :first_earlier} -> {true, 0.5, "Inferred from text patterns"}
            {"after", :second_earlier} -> {true, 0.5, "Inferred from text patterns"}
            _ -> {false, 0.3, "Could not determine temporal relationship"}
          end
      end

    %{
      claim: claim,
      verified: verified,
      confidence: confidence,
      evidence: evidence,
      method: :temporal_check
    }
  end

  defp extract_key_terms(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.reject(&is_stop_word?/1)
    |> MapSet.new()
  end

  defp is_stop_word?(word) do
    word in ~w(the a an is are was were been have has had will would could should this that these those with from into about than then when where which while)
  end

  defp check_logical_structure(premise, conclusion) do
    # Check for logical indicators
    logical_patterns = [
      ~r/\b(if|when|since|because|given)\b/i,
      ~r/\b(then|therefore|thus|so|hence)\b/i,
      ~r/\b(implies?|means?|results? in)\b/i
    ]

    combined = premise <> " " <> conclusion
    Enum.count(logical_patterns, &Regex.match?(&1, combined)) >= 1
  end

  defp extract_date(text) do
    # Try to extract a date from text
    # Patterns: YYYY-MM-DD, Month DD YYYY, DD/MM/YYYY, etc.
    cond do
      match = Regex.run(~r/(\d{4})-(\d{2})-(\d{2})/, text) ->
        [_, year, month, day] = match

        case Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
          {:ok, date} -> date
          _ -> nil
        end

      match = Regex.run(~r/(\w+)\s+(\d{1,2}),?\s+(\d{4})/, text) ->
        [_, month_name, day, year] = match
        month = parse_month(month_name)

        if month do
          case Date.new(String.to_integer(year), month, String.to_integer(day)) do
            {:ok, date} -> date
            _ -> nil
          end
        else
          nil
        end

      true ->
        nil
    end
  end

  defp parse_month(name) do
    months = %{
      "january" => 1,
      "jan" => 1,
      "february" => 2,
      "feb" => 2,
      "march" => 3,
      "mar" => 3,
      "april" => 4,
      "apr" => 4,
      "may" => 5,
      "june" => 6,
      "jun" => 6,
      "july" => 7,
      "jul" => 7,
      "august" => 8,
      "aug" => 8,
      "september" => 9,
      "sep" => 9,
      "sept" => 9,
      "october" => 10,
      "oct" => 10,
      "november" => 11,
      "nov" => 11,
      "december" => 12,
      "dec" => 12
    }

    Map.get(months, String.downcase(name))
  end

  defp infer_temporal_ordering(event1, event2) do
    # Look for temporal markers
    earlier_markers = ~w(first initially originally before earlier previously)
    later_markers = ~w(then later after subsequently finally eventually)

    e1_lower = String.downcase(event1)
    e2_lower = String.downcase(event2)

    e1_has_earlier = Enum.any?(earlier_markers, &String.contains?(e1_lower, &1))
    e1_has_later = Enum.any?(later_markers, &String.contains?(e1_lower, &1))
    e2_has_earlier = Enum.any?(earlier_markers, &String.contains?(e2_lower, &1))
    e2_has_later = Enum.any?(later_markers, &String.contains?(e2_lower, &1))

    cond do
      e1_has_earlier or e2_has_later -> :first_earlier
      e2_has_earlier or e1_has_later -> :second_earlier
      true -> :unknown
    end
  end

  # --- Helper functions ---

  defp search_memory_for_spec(spec_id) do
    try do
      case Mimo.Brain.Memory.search(spec_id, limit: 5) do
        {:ok, memories} -> {:ok, memories}
        _ -> {:ok, []}
      end
    rescue
      _ -> {:ok, []}
    end
  end

  defp search_docs_for_spec(spec_id) do
    # Try common doc locations
    paths = [
      "docs/specs/#{String.downcase(spec_id)}.md",
      "docs/#{String.downcase(spec_id)}.md",
      "SPECS/#{spec_id}.md"
    ]

    Enum.find_value(paths, {:error, :not_found}, fn path ->
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        _ -> nil
      end
    end)
  end

  defp read_file_line(file, line_num) do
    # Try to find the file
    full_path = find_file_path(file)

    case File.read(full_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        if line_num > 0 and line_num <= length(lines) do
          {:ok, Enum.at(lines, line_num - 1)}
        else
          {:error, "Line #{line_num} out of range (file has #{length(lines)} lines)"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_file_content(file_path) do
    full_path = find_file_path(file_path)
    File.read(full_path)
  end

  defp find_file_path(file) do
    cond do
      # Already absolute or starts with lib/test/etc
      String.starts_with?(file, "/") -> file
      String.starts_with?(file, "lib/") -> file
      String.starts_with?(file, "test/") -> file
      String.starts_with?(file, "config/") -> file
      # Try to find it
      File.exists?("lib/mimo/#{file}") -> "lib/mimo/#{file}"
      File.exists?("lib/#{file}") -> "lib/#{file}"
      true -> file
    end
  end

  defp parse_file_line(subject) do
    case Regex.run(~r/(.+):(\d+)/, subject) do
      [_, file, line] -> {:ok, file, String.to_integer(line)}
      _ -> :error
    end
  end

  defp find_code_symbol(code_ref) do
    # Clean up the code reference
    symbol_name =
      code_ref
      # Remove arity
      |> String.replace(~r/\/\d+$/, "")
      |> String.trim()

    try do
      case Mimo.Code.SymbolIndex.find_definition(symbol_name) do
        {:ok, info} -> {:ok, info}
        _ -> {:error, :not_found}
      end
    rescue
      _ -> {:error, :not_found}
    end
  end

  defp verify_code_predicate("returns", claimed_return, symbol_info) do
    # Check if the function's return type or actual returns match
    source = Map.get(symbol_info, :source, "")

    cond do
      String.contains?(source, claimed_return) ->
        %{matched: true, confidence: 0.8, evidence: "Found '#{claimed_return}' in function body"}

      String.contains?(String.downcase(source), String.downcase(claimed_return)) ->
        %{matched: true, confidence: 0.6, evidence: "Found similar content (case-insensitive)"}

      true ->
        %{matched: false, confidence: 0.3, evidence: "Could not verify return value"}
    end
  end

  defp verify_code_predicate(_predicate, claimed_content, symbol_info) do
    # Generic check - see if claimed content appears in symbol
    source = Map.get(symbol_info, :source, "")

    if String.contains?(String.downcase(source), String.downcase(claimed_content)) do
      %{matched: true, confidence: 0.7, evidence: "Content found in symbol definition"}
    else
      %{matched: false, confidence: 0.3, evidence: "Could not verify claim against symbol"}
    end
  end

  defp fuzzy_match_claim(claimed_content, memories) when is_list(memories) do
    # Extract content from memories and check for matches
    memory_contents =
      Enum.map_join(memories, " ", fn
        %{content: c} -> c
        %{"content" => c} -> c
        _ -> ""
      end)

    fuzzy_match_content(claimed_content, memory_contents)
  end

  defp fuzzy_match_content(claimed, actual) do
    claimed_lower = String.downcase(claimed)
    actual_lower = String.downcase(actual)

    # Extract key terms from the claim (words > 3 chars)
    key_terms =
      claimed_lower
      |> String.split(~r/\W+/)
      |> Enum.filter(&(String.length(&1) > 3))
      |> Enum.uniq()

    # Count how many key terms appear in actual content
    matches = Enum.count(key_terms, &String.contains?(actual_lower, &1))
    total = max(length(key_terms), 1)

    match_ratio = matches / total

    cond do
      # Exact substring match
      String.contains?(actual_lower, claimed_lower) ->
        %{matched: true, confidence: 0.95, evidence: "Exact match found"}

      # High term overlap (>80%)
      match_ratio >= 0.8 ->
        %{matched: true, confidence: 0.85, evidence: "#{matches}/#{total} key terms matched"}

      # Moderate term overlap (>60%)
      match_ratio >= 0.6 ->
        %{
          matched: true,
          confidence: 0.7,
          evidence: "#{matches}/#{total} key terms matched (moderate)"
        }

      # Low overlap
      match_ratio >= 0.4 ->
        %{matched: false, confidence: 0.4, evidence: "Only #{matches}/#{total} key terms matched"}

      true ->
        %{matched: false, confidence: 0.2, evidence: "Low match: #{matches}/#{total} terms"}
    end
  end

  @doc """
  Verify claims from a thought string.
  Convenience function that extracts and verifies in one call.
  """
  @spec verify_thought(String.t()) :: %{
          claims: [ClaimExtractor.claim()],
          results: [verification_result()],
          summary: map()
        }
  def verify_thought(thought) do
    claims = ClaimExtractor.extract(thought)
    results = verify_all(claims)

    verified_count = Enum.count(results, & &1.verified)
    total = length(results)

    summary = %{
      total_claims: total,
      verified: verified_count,
      failed: total - verified_count,
      verification_rate: if(total > 0, do: verified_count / total, else: 1.0),
      high_confidence: Enum.count(results, &(&1.confidence >= 0.7))
    }

    %{
      claims: claims,
      results: results,
      summary: summary
    }
  end

  @doc """
  Check if a thought passes verification threshold.
  """
  @spec passes_verification?(String.t(), float()) :: boolean()
  def passes_verification?(thought, threshold \\ 0.7) do
    %{summary: summary} = verify_thought(thought)
    summary.verification_rate >= threshold
  end
end
