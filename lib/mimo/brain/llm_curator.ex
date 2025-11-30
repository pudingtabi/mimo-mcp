defmodule Mimo.Brain.LLMCurator do
  @moduledoc """
  LLM-based Memory Curator for SPEC-012 Passive Memory System.

  Analyzes batches of interactions and determines:
  - What's worth remembering long-term
  - Importance score (0.0-1.0)
  - Appropriate category
  - Decay rate based on importance

  This mimics how biological memory works:
  - Not everything is remembered
  - Important things stick around longer
  - Trivial things fade quickly

  ## Importance Scoring Guidelines

  | Score   | Description                                      | Decay Rate | Half-Life  |
  |---------|--------------------------------------------------|------------|------------|
  | 0.9-1.0 | Critical facts, important decisions, key learnings | 0.0001   | ~2 years   |
  | 0.7-0.8 | Useful context, project details, preferences     | 0.001    | ~6 months  |
  | 0.5-0.6 | Routine actions that provide context             | 0.005    | ~3 months  |
  | 0.3-0.4 | Minor details, might be useful                   | 0.02     | ~1 month   |
  | 0.0-0.2 | Noise, errors, trivial interactions              | 0.1      | ~2 weeks   |

  ## Examples

      # Curate a batch of interactions
      {:ok, memories} = LLMCurator.curate(interactions)

      # Each memory has:
      # - content: Curated insight
      # - importance: 0.0-1.0
      # - category: fact | action | observation | plan | preference
      # - decay_rate: Based on importance
      # - source_interaction_ids: Link to raw data
  """

  require Logger
  alias Mimo.Brain.{LLM, Engram, Interaction}

  @curator_prompt """
  You are Mimo's Memory Curator. Analyze these recent AI interactions and determine what's worth remembering long-term.

  INTERACTIONS:
  {{interactions_json}}

  For each meaningful insight, provide:
  1. content: A concise, searchable summary (what happened and why it matters)
  2. importance: 0.0-1.0 score based on:
     - 0.9-1.0: Critical facts, important decisions, key learnings
     - 0.7-0.8: Useful context, project details, preferences discovered
     - 0.5-0.6: Routine actions that provide context
     - 0.3-0.4: Minor details, might be useful
     - 0.0-0.2: Noise, errors, trivial interactions
  3. category: fact | action | observation | plan | preference
  4. reasoning: Brief explanation of importance score

  RULES:
  - Combine related interactions into single insights
  - Skip pure noise (failed commands, typos, retries, simple status checks)
  - Highlight patterns (e.g., "User frequently works on X project")
  - Note preferences (e.g., "User prefers TypeScript over JavaScript")
  - Capture decisions and their rationale
  - Focus on WHAT was learned, not just WHAT was done

  OUTPUT FORMAT (JSON array only, no markdown, no explanation):
  [{"content": "...", "importance": 0.85, "category": "fact", "reasoning": "...", "source_interaction_ids": ["id1", "id2"]}]

  If nothing is worth remembering, return: []
  """

  @doc """
  Curate a batch of interactions into meaningful memories.

  Returns a list of memory candidates with importance scores and categories.

  ## Parameters

    - `interactions` - List of Interaction structs or maps with tool_name, arguments, result_summary, timestamp, id

  ## Returns

    - `{:ok, [memory_candidate]}` - List of curated memories
    - `{:error, reason}` - If curation fails

  ## Memory Candidate Format

      %{
        content: "Curated insight",
        importance: 0.75,
        category: "fact",
        reasoning: "Why this is important",
        decay_rate: 0.001,
        source_interaction_ids: ["uuid1", "uuid2"]
      }
  """
  @spec curate([map() | Interaction.t()]) :: {:ok, [map()]} | {:error, term()}
  def curate(interactions) when is_list(interactions) do
    if Enum.empty?(interactions) do
      {:ok, []}
    else
      do_curate(interactions)
    end
  end

  defp do_curate(interactions) do
    # Format interactions for LLM
    interactions_json = format_interactions_for_llm(interactions)

    # Build prompt
    prompt = String.replace(@curator_prompt, "{{interactions_json}}", interactions_json)

    # Call LLM with JSON format
    case LLM.complete(prompt, max_tokens: 2000, temperature: 0.3, format: :json, raw: true) do
      {:ok, response} ->
        parse_curator_response(response, interactions)

      {:error, :no_api_key} ->
        # Fallback: Use heuristic-based curation
        Logger.warning("LLM unavailable, using heuristic curation")
        {:ok, heuristic_curate(interactions)}

      {:error, reason} ->
        Logger.error("LLM curator failed: #{inspect(reason)}")
        # Fallback to heuristics on error
        {:ok, heuristic_curate(interactions)}
    end
  end

  @doc """
  Format interactions for LLM analysis.
  """
  def format_interactions_for_llm(interactions) do
    interactions
    |> Enum.map(&format_single_interaction/1)
    |> Jason.encode!(pretty: true)
  end

  defp format_single_interaction(%Interaction{} = i) do
    %{
      id: i.id,
      tool: i.tool_name,
      args: summarize_args(i.arguments),
      result: truncate_string(i.result_summary || "", 300),
      timestamp: format_timestamp(i.timestamp),
      duration_ms: i.duration_ms
    }
  end

  defp format_single_interaction(i) when is_map(i) do
    %{
      id: Map.get(i, :id) || Map.get(i, "id"),
      tool: Map.get(i, :tool_name) || Map.get(i, "tool_name"),
      args: summarize_args(Map.get(i, :arguments) || Map.get(i, "arguments") || %{}),
      result:
        truncate_string(
          to_string(Map.get(i, :result_summary) || Map.get(i, "result_summary") || ""),
          300
        ),
      timestamp: format_timestamp(Map.get(i, :timestamp) || Map.get(i, "timestamp")),
      duration_ms: Map.get(i, :duration_ms) || Map.get(i, "duration_ms")
    }
  end

  defp summarize_args(args) when is_map(args) do
    args
    |> Enum.take(5)
    |> Enum.map(fn {k, v} -> {k, summarize_value(v)} end)
    |> Map.new()
  end

  defp summarize_args(args), do: args

  defp summarize_value(v) when is_binary(v) and byte_size(v) > 100 do
    String.slice(v, 0, 100) <> "..."
  end

  defp summarize_value(v) when is_map(v), do: summarize_args(v)
  defp summarize_value(v) when is_list(v) and length(v) > 3, do: Enum.take(v, 3) ++ ["..."]
  defp summarize_value(v), do: v

  defp truncate_string(s, max_len) when byte_size(s) > max_len do
    String.slice(s, 0, max_len - 3) <> "..."
  end

  defp truncate_string(s, _), do: s

  defp format_timestamp(nil), do: nil
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_timestamp(other), do: to_string(other)

  @doc """
  Parse LLM curator response into memory candidates.
  """
  def parse_curator_response(response, interactions) do
    # Clean response
    cleaned =
      response
      |> String.replace(~r/```json\s*/i, "")
      |> String.replace(~r/```\s*/i, "")
      |> String.trim()

    # Build interaction ID map for validation
    interaction_ids =
      interactions
      |> Enum.map(fn i ->
        to_string(Map.get(i, :id) || Map.get(i, "id"))
      end)
      |> MapSet.new()

    case Jason.decode(cleaned) do
      {:ok, memories} when is_list(memories) ->
        validated =
          memories
          |> Enum.filter(&valid_memory_candidate?/1)
          |> Enum.map(fn m ->
            enrich_memory_candidate(m, interaction_ids)
          end)

        {:ok, validated}

      {:ok, _} ->
        # Not an array - return empty
        Logger.warning("Curator returned non-array response")
        {:ok, []}

      {:error, reason} ->
        Logger.warning("Failed to parse curator response: #{inspect(reason)}")
        {:ok, []}
    end
  end

  defp valid_memory_candidate?(m) when is_map(m) do
    content = m["content"] || m[:content]
    importance = m["importance"] || m[:importance]
    category = m["category"] || m[:category]

    is_binary(content) and
      byte_size(content) > 10 and
      is_number(importance) and
      importance >= 0 and importance <= 1 and
      category in ["fact", "action", "observation", "plan", "preference"]
  end

  defp valid_memory_candidate?(_), do: false

  defp enrich_memory_candidate(m, _interaction_ids) do
    importance = m["importance"] || m[:importance]

    %{
      content: m["content"] || m[:content],
      importance: importance,
      category: m["category"] || m[:category],
      reasoning: m["reasoning"] || m[:reasoning],
      decay_rate: Engram.importance_to_decay_rate(importance),
      source_interaction_ids:
        normalize_ids(m["source_interaction_ids"] || m[:source_interaction_ids] || [])
    }
  end

  defp normalize_ids(ids) when is_list(ids), do: Enum.map(ids, &to_string/1)
  defp normalize_ids(_), do: []

  @doc """
  Heuristic-based curation when LLM is unavailable.

  Uses simple rules to determine if interactions are worth remembering:
  - Memory operations → fact about what was remembered
  - File operations on important files → observation
  - Terminal commands with output → action
  - Search queries → observation about what was researched
  """
  def heuristic_curate(interactions) do
    interactions
    |> Enum.group_by(&extract_tool_group/1)
    |> Enum.flat_map(&curate_tool_group/1)
    |> Enum.filter(fn m -> m.importance >= 0.3 end)
  end

  defp extract_tool_group(%{tool_name: tool}), do: tool
  defp extract_tool_group(%{"tool_name" => tool}), do: tool
  defp extract_tool_group(_), do: "unknown"

  defp curate_tool_group({"memory", interactions}) do
    # Memory tool usage is meta-interesting
    count = length(interactions)

    if count >= 2 do
      ids = Enum.map(interactions, fn i -> to_string(i.id || i["id"]) end)

      [
        %{
          content: "User performed #{count} memory operations (storing/searching memories)",
          importance: 0.5,
          category: "observation",
          reasoning: "Memory usage patterns indicate active knowledge management",
          decay_rate: 0.005,
          source_interaction_ids: ids
        }
      ]
    else
      []
    end
  end

  defp curate_tool_group({"file", interactions}) do
    # Group by file path
    file_ops =
      interactions
      |> Enum.map(fn i ->
        args = i.arguments || i["arguments"] || %{}
        path = args["path"] || args[:path] || "unknown"
        op = args["operation"] || args[:operation] || "read"
        {path, op, i}
      end)
      |> Enum.group_by(fn {path, _, _} -> path end)

    Enum.flat_map(file_ops, fn {path, ops} ->
      if length(ops) >= 2 do
        op_types = Enum.map(ops, fn {_, op, _} -> op end) |> Enum.uniq() |> Enum.join(", ")
        ids = Enum.map(ops, fn {_, _, i} -> to_string(i.id || i["id"]) end)

        [
          %{
            content: "Worked on file #{Path.basename(path)}: #{op_types}",
            importance: 0.4,
            category: "action",
            reasoning: "Multiple operations on same file indicates focused work",
            decay_rate: 0.02,
            source_interaction_ids: ids
          }
        ]
      else
        []
      end
    end)
  end

  defp curate_tool_group({"search", interactions}) do
    queries =
      interactions
      |> Enum.map(fn i ->
        args = i.arguments || i["arguments"] || %{}
        args["query"] || args[:query] || ""
      end)
      |> Enum.filter(&(byte_size(&1) > 0))
      |> Enum.take(3)

    if length(queries) >= 1 do
      ids = Enum.map(interactions, fn i -> to_string(i.id || i["id"]) end)

      [
        %{
          content: "Researched: #{Enum.join(queries, ", ")}",
          importance: 0.5,
          category: "observation",
          reasoning: "Search queries reveal user interests and current focus",
          decay_rate: 0.005,
          source_interaction_ids: ids
        }
      ]
    else
      []
    end
  end

  defp curate_tool_group({"terminal", interactions}) do
    # Terminal commands that produced output
    with_output =
      interactions
      |> Enum.filter(fn i ->
        result = i.result_summary || i["result_summary"] || ""
        byte_size(to_string(result)) > 50
      end)

    if length(with_output) >= 1 do
      commands =
        with_output
        |> Enum.map(fn i ->
          args = i.arguments || i["arguments"] || %{}
          cmd = args["command"] || args[:command] || ""
          String.slice(cmd, 0, 50)
        end)
        |> Enum.take(3)

      ids = Enum.map(with_output, fn i -> to_string(i.id || i["id"]) end)

      [
        %{
          content: "Ran commands: #{Enum.join(commands, "; ")}",
          importance: 0.4,
          category: "action",
          reasoning: "Terminal activity shows development workflow",
          decay_rate: 0.02,
          source_interaction_ids: ids
        }
      ]
    else
      []
    end
  end

  defp curate_tool_group({_tool, _interactions}) do
    # Other tools - skip for now
    []
  end

  @doc """
  Calculate appropriate decay rate based on importance.
  Higher importance = slower decay = longer retention.
  """
  def importance_to_decay_rate(importance) do
    Engram.importance_to_decay_rate(importance)
  end
end
