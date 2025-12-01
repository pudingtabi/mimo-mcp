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
    field(:tool_name, :string)
    field(:arguments, :map, default: %{})
    field(:result_summary, :string)
    field(:duration_ms, :integer)
    field(:timestamp, :utc_datetime_usec)
    field(:consolidated, :boolean, default: false)

    belongs_to(:thread, Thread)
    many_to_many(:engrams, Mimo.Brain.Engram, join_through: "interaction_engrams")

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for an interaction.
  """
  def changeset(interaction, attrs) do
    interaction
    |> cast(attrs, [
      :tool_name,
      :arguments,
      :result_summary,
      :duration_ms,
      :timestamp,
      :consolidated,
      :thread_id
    ])
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
      nil ->
        changeset

      summary when byte_size(summary) > 10_000 ->
        truncated = String.slice(summary, 0, 9_900) <> "\n... [truncated]"
        put_change(changeset, :result_summary, truncated)

      _ ->
        changeset
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

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
  Gets basic interaction statistics.
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

  # ─────────────────────────────────────────────────────────────────
  # Tool Usage Analytics (SPEC-033)
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Get comprehensive tool usage statistics for analysis.

  ## Options
  - `:days` - Number of days to analyze (default: 30)
  - `:limit` - Max tools to return in rankings (default: 50)
  - `:include_daily` - Include daily breakdown (default: false)

  ## Returns
  A map with:
  - `summary` - High-level stats (total calls, unique tools, date range)
  - `rankings` - Tools ranked by usage count with percentages
  - `performance` - Average duration per tool
  - `daily` - Optional daily breakdown by tool (if include_daily: true)
  - `trends` - Usage trend analysis (growing vs declining tools)
  """
  @spec tool_usage_stats(keyword()) :: map()
  def tool_usage_stats(opts \\ []) do
    days = Keyword.get(opts, :days, 30)
    limit = Keyword.get(opts, :limit, 50)
    include_daily = Keyword.get(opts, :include_daily, false)

    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    # Build base stats
    summary = build_summary(cutoff)
    rankings = build_rankings(cutoff, limit, summary.total_calls)
    performance = build_performance_stats(cutoff)

    result = %{
      summary: summary,
      rankings: rankings,
      performance: performance,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Optionally add daily breakdown
    result =
      if include_daily do
        Map.put(result, :daily, build_daily_breakdown(cutoff, limit))
      else
        result
      end

    # Add trend analysis if we have enough data
    if days >= 7 do
      Map.put(result, :trends, build_trends(cutoff, days))
    else
      result
    end
  end

  defp build_summary(cutoff) do
    total_calls =
      from(i in __MODULE__, where: i.timestamp >= ^cutoff)
      |> Repo.aggregate(:count)

    unique_tools =
      from(i in __MODULE__,
        where: i.timestamp >= ^cutoff,
        select: i.tool_name,
        distinct: true
      )
      |> Repo.all()
      |> length()

    # Get date range
    {first_call, last_call} =
      from(i in __MODULE__,
        where: i.timestamp >= ^cutoff,
        select: {min(i.timestamp), max(i.timestamp)}
      )
      |> Repo.one() || {nil, nil}

    %{
      total_calls: total_calls,
      unique_tools: unique_tools,
      period_start: format_datetime(first_call),
      period_end: format_datetime(last_call),
      cutoff: DateTime.to_iso8601(cutoff)
    }
  end

  defp build_rankings(cutoff, limit, total_calls) do
    from(i in __MODULE__,
      where: i.timestamp >= ^cutoff,
      group_by: i.tool_name,
      select: %{
        tool_name: i.tool_name,
        count: count(i.id)
      },
      order_by: [desc: count(i.id)],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.with_index(1)
    |> Enum.map(fn {tool, rank} ->
      percentage =
        if total_calls > 0 do
          Float.round(tool.count / total_calls * 100, 2)
        else
          0.0
        end

      %{
        rank: rank,
        tool_name: tool.tool_name,
        count: tool.count,
        percentage: percentage
      }
    end)
  end

  defp build_performance_stats(cutoff) do
    from(i in __MODULE__,
      where: i.timestamp >= ^cutoff,
      where: not is_nil(i.duration_ms),
      group_by: i.tool_name,
      select: %{
        tool_name: i.tool_name,
        avg_duration_ms: avg(i.duration_ms),
        min_duration_ms: min(i.duration_ms),
        max_duration_ms: max(i.duration_ms),
        call_count: count(i.id)
      },
      order_by: [desc: avg(i.duration_ms)]
    )
    |> Repo.all()
    |> Enum.map(fn stats ->
      %{
        tool_name: stats.tool_name,
        avg_duration_ms: round_or_nil(stats.avg_duration_ms),
        min_duration_ms: stats.min_duration_ms,
        max_duration_ms: stats.max_duration_ms,
        call_count: stats.call_count
      }
    end)
  end

  defp build_daily_breakdown(cutoff, limit) do
    # Get top tools first
    top_tools =
      from(i in __MODULE__,
        where: i.timestamp >= ^cutoff,
        group_by: i.tool_name,
        select: i.tool_name,
        order_by: [desc: count(i.id)],
        limit: ^limit
      )
      |> Repo.all()

    # Get daily counts for each tool
    # SQLite date() function for grouping by day
    from(i in __MODULE__,
      where: i.timestamp >= ^cutoff,
      where: i.tool_name in ^top_tools,
      group_by: [fragment("date(?)", i.timestamp), i.tool_name],
      select: %{
        date: fragment("date(?)", i.timestamp),
        tool_name: i.tool_name,
        count: count(i.id)
      },
      order_by: [desc: fragment("date(?)", i.timestamp), desc: count(i.id)]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.date)
    |> Enum.map(fn {date, tools} ->
      %{
        date: date,
        tools:
          Enum.map(tools, fn t ->
            %{tool_name: t.tool_name, count: t.count}
          end)
      }
    end)
    |> Enum.sort_by(& &1.date, :desc)
  end

  defp build_trends(cutoff, days) do
    # Compare first half vs second half of the period
    midpoint = DateTime.add(DateTime.utc_now(), -div(days, 2), :day)

    # First half (older)
    first_half =
      from(i in __MODULE__,
        where: i.timestamp >= ^cutoff,
        where: i.timestamp < ^midpoint,
        group_by: i.tool_name,
        select: {i.tool_name, count(i.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Second half (recent)
    second_half =
      from(i in __MODULE__,
        where: i.timestamp >= ^midpoint,
        group_by: i.tool_name,
        select: {i.tool_name, count(i.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Calculate trends
    all_tools = MapSet.union(MapSet.new(Map.keys(first_half)), MapSet.new(Map.keys(second_half)))

    trends =
      all_tools
      |> Enum.map(fn tool ->
        old_count = Map.get(first_half, tool, 0)
        new_count = Map.get(second_half, tool, 0)

        change =
          cond do
            old_count == 0 and new_count > 0 -> :new
            old_count > 0 and new_count == 0 -> :abandoned
            old_count == 0 and new_count == 0 -> :unused
            true -> calculate_change_percentage(old_count, new_count)
          end

        %{
          tool_name: tool,
          first_half_count: old_count,
          second_half_count: new_count,
          change: change,
          trend: classify_trend(change)
        }
      end)
      |> Enum.sort_by(
        fn t ->
          case t.change do
            :new -> 1000
            :abandoned -> -1000
            :unused -> -2000
            n when is_number(n) -> n
          end
        end,
        :desc
      )

    %{
      period_comparison: "#{div(days, 2)} days vs #{div(days, 2)} days",
      growing:
        Enum.filter(trends, fn t -> t.trend == :growing end)
        |> Enum.take(10),
      declining:
        Enum.filter(trends, fn t -> t.trend == :declining end)
        |> Enum.take(10),
      new_tools:
        Enum.filter(trends, fn t -> t.change == :new end)
        |> Enum.map(& &1.tool_name),
      abandoned_tools:
        Enum.filter(trends, fn t -> t.change == :abandoned end)
        |> Enum.map(& &1.tool_name)
    }
  end

  defp calculate_change_percentage(old_count, new_count) when old_count > 0 do
    Float.round((new_count - old_count) / old_count * 100, 1)
  end

  defp calculate_change_percentage(_, _), do: 0.0

  defp classify_trend(change) do
    cond do
      change == :new -> :new
      change == :abandoned -> :abandoned
      change == :unused -> :unused
      is_number(change) and change > 20 -> :growing
      is_number(change) and change < -20 -> :declining
      true -> :stable
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(dt) when is_binary(dt), do: dt
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  defp round_or_nil(nil), do: nil
  defp round_or_nil(val) when is_float(val), do: round(val)
  defp round_or_nil(val), do: val

  @doc """
  Get usage stats for a specific tool.

  ## Options
  - `:days` - Number of days to analyze (default: 30)
  """
  @spec tool_detail(String.t(), keyword()) :: map()
  def tool_detail(tool_name, opts \\ []) do
    days = Keyword.get(opts, :days, 30)
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    # Basic stats
    stats =
      from(i in __MODULE__,
        where: i.timestamp >= ^cutoff,
        where: i.tool_name == ^tool_name,
        select: %{
          total_calls: count(i.id),
          avg_duration_ms: avg(i.duration_ms),
          min_duration_ms: min(i.duration_ms),
          max_duration_ms: max(i.duration_ms),
          first_call: min(i.timestamp),
          last_call: max(i.timestamp)
        }
      )
      |> Repo.one()

    # Daily breakdown
    daily =
      from(i in __MODULE__,
        where: i.timestamp >= ^cutoff,
        where: i.tool_name == ^tool_name,
        group_by: fragment("date(?)", i.timestamp),
        select: %{
          date: fragment("date(?)", i.timestamp),
          count: count(i.id),
          avg_duration_ms: avg(i.duration_ms)
        },
        order_by: [desc: fragment("date(?)", i.timestamp)]
      )
      |> Repo.all()
      |> Enum.map(fn d ->
        %{
          date: d.date,
          count: d.count,
          avg_duration_ms: round_or_nil(d.avg_duration_ms)
        }
      end)

    # Common arguments
    recent_args =
      from(i in __MODULE__,
        where: i.timestamp >= ^cutoff,
        where: i.tool_name == ^tool_name,
        select: i.arguments,
        order_by: [desc: i.timestamp],
        limit: 100
      )
      |> Repo.all()

    common_arg_keys = analyze_common_args(recent_args)

    %{
      tool_name: tool_name,
      total_calls: stats.total_calls || 0,
      avg_duration_ms: round_or_nil(stats.avg_duration_ms),
      min_duration_ms: stats.min_duration_ms,
      max_duration_ms: stats.max_duration_ms,
      first_call: format_datetime(stats.first_call),
      last_call: format_datetime(stats.last_call),
      daily_breakdown: daily,
      common_arguments: common_arg_keys,
      period_days: days
    }
  end

  defp analyze_common_args(args_list) do
    args_list
    |> Enum.flat_map(fn args ->
      case args do
        %{} -> Map.keys(args)
        _ -> []
      end
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, count} -> count end, :desc)
    |> Enum.take(10)
    |> Enum.map(fn {key, count} -> %{argument: key, frequency: count} end)
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
    Enum.map_join(interactions, "\n\n---\n\n", &format_interaction/1)
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
