defmodule Mimo.Brain.Interaction do
  @moduledoc """
  Interaction represents a single tool call made by an AI.

  This is the "working memory" - raw records of everything that happens.
  Interactions are periodically consolidated into engrams by the
  Background Curator based on importance.

  Lifecycle:
  1. AI calls a tool → Interaction created (consolidated: false)
  2. Background Curator analyzes unconsolidated interactions
  3. LLM determines importance and creates engrams if warranted
  4. Interaction marked as consolidated (or discarded if trivial)
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Mimo.Repo
  alias Mimo.Brain.Thread

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "interactions" do
    field :tool_name, :string
    field :arguments, :map, default: %{}
    field :result_summary, :string
    field :duration_ms, :integer
    field :timestamp, :utc_datetime_usec
    field :consolidated, :boolean, default: false

    belongs_to :thread, Thread
    many_to_many :engrams, Mimo.Brain.Engram, join_through: "interaction_engrams"

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for an interaction.
  """
  def changeset(interaction, attrs) do
    interaction
    |> cast(attrs, [:tool_name, :arguments, :result_summary, :duration_ms, :timestamp, :consolidated, :thread_id])
    |> validate_required([:tool_name])
    |> put_default_timestamp()
    |> truncate_result_summary()
  end

  defp put_default_timestamp(changeset) do
    case get_field(changeset, :timestamp) do
      nil -> put_change(changeset, :timestamp, DateTime.utc_now())
      _ -> changeset
    end
  end

  # Keep result summaries reasonable (max 10KB)
  defp truncate_result_summary(changeset) do
    case get_change(changeset, :result_summary) do
      nil -> changeset
      summary when byte_size(summary) > 10_000 ->
        truncated = String.slice(summary, 0, 9_900) <> "\n... [truncated]"
        put_change(changeset, :result_summary, truncated)
      _ -> changeset
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────

  @doc """
  Records a new interaction (tool call).

  ## Parameters
  - `tool_name` - Name of the tool called
  - `opts` - Options:
    - `:thread_id` - ID of the current thread
    - `:arguments` - Map of arguments passed to the tool
    - `:result_summary` - Brief summary of the result
    - `:duration_ms` - How long the call took
  """
  def record(tool_name, opts \\ []) do
    attrs = %{
      tool_name: tool_name,
      thread_id: Keyword.get(opts, :thread_id),
      arguments: Keyword.get(opts, :arguments, %{}),
      result_summary: Keyword.get(opts, :result_summary),
      duration_ms: Keyword.get(opts, :duration_ms)
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets unconsolidated interactions for processing by the curator.

  Returns interactions that haven't been processed yet, ordered by timestamp.
  """
  def get_unconsolidated(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    
    # Get interactions older than 5 minutes (give time for context to accumulate)
    cutoff = DateTime.add(DateTime.utc_now(), -5, :minute)

    from(i in __MODULE__,
      where: i.consolidated == false,
      where: i.timestamp < ^cutoff,
      order_by: [asc: i.timestamp],
      limit: ^limit,
      preload: [:thread]
    )
    |> Repo.all()
  end

  @doc """
  Gets recent interactions for a thread (working memory view).
  """
  def get_recent_for_thread(thread_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    minutes = Keyword.get(opts, :minutes, 30)
    cutoff = DateTime.add(DateTime.utc_now(), -minutes, :minute)

    from(i in __MODULE__,
      where: i.thread_id == ^thread_id,
      where: i.timestamp > ^cutoff,
      order_by: [desc: i.timestamp],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Gets interactions by IDs.
  """
  def get_by_ids(ids) when is_list(ids) do
    from(i in __MODULE__, where: i.id in ^ids)
    |> Repo.all()
  end

  @doc """
  Marks interactions as consolidated.
  """
  def mark_consolidated(ids) when is_list(ids) do
    from(i in __MODULE__, where: i.id in ^ids)
    |> Repo.update_all(set: [consolidated: true, updated_at: DateTime.utc_now()])
  end

  def mark_consolidated(%__MODULE__{id: id}) do
    mark_consolidated([id])
  end

  @doc """
  Deletes old consolidated interactions to save space.
  Default is 30 days retention.
  """
  def cleanup_old(days \\ 30) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    from(i in __MODULE__,
      where: i.consolidated == true,
      where: i.timestamp < ^cutoff
    )
    |> Repo.delete_all()
  end

  @doc """
  Gets interaction statistics.
  """
  def stats do
    total = Repo.aggregate(__MODULE__, :count)
    unconsolidated = Repo.aggregate(from(i in __MODULE__, where: i.consolidated == false), :count)

    # Tool usage breakdown
    tool_stats =
      from(i in __MODULE__,
        group_by: i.tool_name,
        select: {i.tool_name, count(i.id)},
        order_by: [desc: count(i.id)],
        limit: 10
      )
      |> Repo.all()
      |> Map.new()

    %{
      total: total,
      unconsolidated: unconsolidated,
      consolidated: total - unconsolidated,
      top_tools: tool_stats
    }
  end

  @doc """
  Groups interactions by time window for batch analysis.
  """
  def group_by_window(interactions, window_minutes \\ 5) do
    interactions
    |> Enum.group_by(fn interaction ->
      # Round timestamp down to nearest window
      unix = DateTime.to_unix(interaction.timestamp)
      window_seconds = window_minutes * 60
      rounded = div(unix, window_seconds) * window_seconds
      DateTime.from_unix!(rounded)
    end)
    |> Enum.sort_by(fn {window_start, _} -> window_start end)
  end

  @doc """
  Summarizes interactions for LLM analysis.
  Returns a text summary suitable for importance scoring.
  """
  def summarize_for_llm(interactions) when is_list(interactions) do
    interactions
    |> Enum.map(&format_interaction/1)
    |> Enum.join("\n\n---\n\n")
  end

  defp format_interaction(interaction) do
    args_str = 
      interaction.arguments
      |> summarize_args()
      |> Jason.encode!(pretty: false)

    result_str = 
      case interaction.result_summary do
        nil -> "No result captured"
        summary -> String.slice(summary, 0, 500)
      end

    """
    Tool: #{interaction.tool_name}
    Time: #{interaction.timestamp}
    Args: #{args_str}
    Duration: #{interaction.duration_ms || "unknown"}ms
    Result: #{result_str}
    """
  end

  # Summarize args, redacting long values
  defp summarize_args(args) when is_map(args) do
    args
    |> Enum.map(fn {k, v} -> {k, summarize_value(v)} end)
    |> Map.new()
  end
  defp summarize_args(args), do: args

  defp summarize_value(v) when is_binary(v) and byte_size(v) > 200 do
    String.slice(v, 0, 200) <> "..."
  end
  defp summarize_value(v) when is_map(v) do
    summarize_args(v)
  end
  defp summarize_value(v) when is_list(v) and length(v) > 5 do
    Enum.take(v, 5) ++ ["... (#{length(v) - 5} more)"]
  end
  defp summarize_value(v), do: v
end
