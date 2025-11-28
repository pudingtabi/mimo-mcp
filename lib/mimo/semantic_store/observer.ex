defmodule Mimo.SemanticStore.Observer do
  @moduledoc """
  Proactive context injection ("Active Inference").

  Monitors conversation context and proactively suggests relevant 
  graph relationships without being asked.

  Guard Rails:
  - Relevance threshold: Only suggest confidence > 0.90
  - Freshness filter: Only suggest facts < 5 minutes old in conversation
  - Novelty filter: Don't repeat recently mentioned facts
  - Hard limit: Max 2 suggestions per turn
  """

  use GenServer
  require Logger

  alias Mimo.SemanticStore.Query

  @relevance_threshold 0.90
  @freshness_seconds 300
  @max_suggestions 2

  # ==========================================================================
  # Client API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Observes conversation context and returns relevant suggestions.

  ## Parameters
    - `entities` - List of entity IDs mentioned in current context
    - `conversation_history` - Recent conversation for deduplication
    - `opts` - Options

  ## Returns
    - `{:ok, suggestions}` - List of relevant relationship suggestions
  """
  @spec observe(list(String.t()), list(map()), keyword()) :: {:ok, list(map())}
  def observe(entities, conversation_history \\ [], opts \\ []) do
    GenServer.call(__MODULE__, {:observe, entities, conversation_history, opts})
  end

  @doc """
  Updates the observer with new context (async).
  """
  @spec update_context(map()) :: :ok
  def update_context(context) do
    GenServer.cast(__MODULE__, {:update_context, context})
  end

  # ==========================================================================
  # Server Callbacks
  # ==========================================================================

  @impl true
  def init(_opts) do
    state = %{
      recent_suggestions: [],
      context: %{},
      stats: %{
        suggestions_made: 0,
        suggestions_accepted: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:observe, entities, conversation_history, _opts}, _from, state) do
    suggestions =
      entities
      |> find_relevant_relationships()
      |> filter_by_relevance(@relevance_threshold)
      |> filter_by_freshness(conversation_history, @freshness_seconds)
      |> filter_not_mentioned(conversation_history)
      |> filter_not_recently_suggested(state.recent_suggestions)
      |> Enum.take(@max_suggestions)

    # Track suggestions
    new_state = %{
      state
      | recent_suggestions: (suggestions ++ state.recent_suggestions) |> Enum.take(10),
        stats: %{state.stats | suggestions_made: state.stats.suggestions_made + length(suggestions)}
    }

    {:reply, {:ok, suggestions}, new_state}
  end

  @impl true
  def handle_cast({:update_context, context}, state) do
    {:noreply, %{state | context: Map.merge(state.context, context)}}
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp find_relevant_relationships(entities) do
    Enum.flat_map(entities, fn entity_id ->
      case Query.get_relationships(entity_id, "entity") do
        %{outgoing: out, incoming: inc} ->
          format_relationships(entity_id, out, inc)

        _ ->
          []
      end
    end)
  end

  defp format_relationships(entity_id, outgoing, incoming) do
    out_formatted =
      Enum.map(outgoing, fn triple ->
        %{
          type: :outgoing,
          entity: entity_id,
          predicate: triple.predicate,
          target: triple.object_id,
          confidence: triple.confidence || 1.0,
          timestamp: triple.inserted_at,
          text: "#{entity_id} #{triple.predicate} #{triple.object_id}"
        }
      end)

    in_formatted =
      Enum.map(incoming, fn triple ->
        %{
          type: :incoming,
          entity: entity_id,
          predicate: triple.predicate,
          source: triple.subject_id,
          confidence: triple.confidence || 1.0,
          timestamp: triple.inserted_at,
          text: "#{triple.subject_id} #{triple.predicate} #{entity_id}"
        }
      end)

    out_formatted ++ in_formatted
  end

  defp filter_by_relevance(suggestions, threshold) do
    Enum.filter(suggestions, fn s -> s.confidence >= threshold end)
  end

  defp filter_by_freshness(suggestions, conversation_history, max_age_seconds) do
    # Get timestamps of entities mentioned in conversation
    mentioned_timestamps = extract_mention_timestamps(conversation_history)
    now = DateTime.utc_now()

    Enum.filter(suggestions, fn s ->
      case Map.get(mentioned_timestamps, s.entity) do
        # Entity not mentioned, include suggestion
        nil ->
          true

        mention_time ->
          # Only include if entity was mentioned recently
          DateTime.diff(now, mention_time) < max_age_seconds
      end
    end)
  end

  defp filter_not_mentioned(suggestions, conversation_history) do
    # Extract all text from conversation with input validation
    conversation_text =
      conversation_history
      |> Enum.map(fn
        msg when is_map(msg) -> msg["content"] || msg[:content] || ""
        _ -> ""
      end)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.filter(suggestions, fn s ->
      # Don't suggest if the exact relationship was already mentioned
      not String.contains?(conversation_text, String.downcase(s.text))
    end)
  end

  defp filter_not_recently_suggested(suggestions, recent_suggestions) do
    recent_texts = MapSet.new(recent_suggestions, fn s -> s.text end)

    Enum.filter(suggestions, fn s ->
      not MapSet.member?(recent_texts, s.text)
    end)
  end

  defp extract_mention_timestamps(conversation_history) do
    # Extract entity mentions with timestamps from conversation
    # This is a simplified implementation with input validation
    conversation_history
    |> Enum.with_index()
    |> Enum.flat_map(fn {msg, _idx} ->
      case msg do
        msg when is_map(msg) ->
          content = msg["content"] || msg[:content] || ""
          timestamp = msg["timestamp"] || DateTime.utc_now()

          # Extract entity-like patterns (word:word format)
          Regex.scan(~r/\b([a-z]+:[a-z_]+)\b/i, content)
          |> Enum.map(fn [_, entity] -> {String.downcase(entity), timestamp} end)

        _ ->
          []
      end
    end)
    |> Map.new()
  end
end
