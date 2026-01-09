defmodule Mimo.Brain.ActivityTracker do
  @moduledoc """
  Tracks Mimo usage activity to enable pause-aware memory decay.

  Instead of decaying memories based on calendar time, this tracks
  "active days" - days where Mimo was actually used. This prevents
  memories from decaying during vacations, holidays, or periods of
  inactivity.

  ## How it works

  1. Every tool call/query registers activity for the current day
  2. The decay scorer uses active_days instead of calendar_days
  3. If user is inactive for a month, memories don't decay during that time

  ## Configuration

      config :mimo_mcp, :activity_tracker,
        enabled: true,
        inactivity_threshold_hours: 24  # Consider inactive after 24h

  ## Usage

      # Register activity (called automatically by tools)
      ActivityTracker.register_activity()

      # Get active days since a date
      active_days = ActivityTracker.active_days_since(datetime)

      # Check if currently active
      ActivityTracker.active?()
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias Mimo.Repo

  @name __MODULE__
  @table :mimo_activity_tracker
  @inactivity_threshold_hours 24

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Register activity for the current moment.
  Called automatically when tools are used.
  """
  @spec register_activity() :: :ok
  def register_activity do
    GenServer.cast(@name, :register_activity)
  end

  @doc """
  Get the number of active days since a given datetime.
  Used by DecayScorer instead of raw calendar days.
  """
  @spec active_days_since(NaiveDateTime.t() | DateTime.t() | nil) :: float()
  def active_days_since(nil), do: 0.0

  def active_days_since(datetime) do
    GenServer.call(@name, {:active_days_since, datetime})
  end

  @doc """
  Check if Mimo is currently considered "active".
  """
  @spec active?() :: boolean()
  def active? do
    GenServer.call(@name, :active?)
  end

  @doc """
  Get activity statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(@name, :stats)
  end

  @doc """
  Get the last activity timestamp.
  """
  @spec last_activity() :: DateTime.t() | nil
  def last_activity do
    GenServer.call(@name, :last_activity)
  end

  @impl true
  def init(_opts) do
    # Create ETS table for fast activity lookups
    Mimo.EtsSafe.ensure_table(@table, [:named_table, :set, :public, read_concurrency: true])

    # Load activity history from database
    state = %{
      last_activity: nil,
      active_dates: MapSet.new(),
      total_active_days: 0
    }

    state = load_activity_history(state)

    Logger.info("ActivityTracker started (#{state.total_active_days} active days recorded)")
    {:ok, state}
  end

  @impl true
  def handle_cast(:register_activity, state) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    # Update last activity
    :ets.insert(@table, {:last_activity, now})

    # Check if this is a new active day
    new_state =
      if MapSet.member?(state.active_dates, today) do
        %{state | last_activity: now}
      else
        # Record new active day
        :ets.insert(@table, {{:active_date, today}, true})
        persist_active_day(today)

        %{
          state
          | last_activity: now,
            active_dates: MapSet.put(state.active_dates, today),
            total_active_days: state.total_active_days + 1
        }
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:active_days_since, datetime}, _from, state) do
    target_date = to_date(datetime)
    today = Date.utc_today()

    # Count active days between target_date and today
    active_days =
      state.active_dates
      |> Enum.count(fn date ->
        Date.compare(date, target_date) != :lt and
          Date.compare(date, today) != :gt
      end)

    # Add fractional day for today if active
    fractional =
      if MapSet.member?(state.active_dates, today) do
        # Fraction of today that has passed
        now = DateTime.utc_now()
        seconds_today = now.hour * 3600 + now.minute * 60 + now.second
        seconds_today / 86_400.0
      else
        0.0
      end

    result = max(0.0, active_days - 1 + fractional)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:active?, _from, state) do
    threshold_hours = get_config(:inactivity_threshold_hours, @inactivity_threshold_hours)

    is_active =
      case state.last_activity do
        nil ->
          false

        last ->
          hours_since = DateTime.diff(DateTime.utc_now(), last, :hour)
          hours_since < threshold_hours
      end

    {:reply, is_active, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      last_activity: state.last_activity,
      total_active_days: state.total_active_days,
      active_today: MapSet.member?(state.active_dates, Date.utc_today()),
      is_active: active?(state)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:last_activity, _from, state) do
    {:reply, state.last_activity, state}
  end

  defp load_activity_history(state) do
    # Load from ETS first (for restart recovery)
    last_activity =
      case :ets.lookup(@table, :last_activity) do
        [{:last_activity, time}] -> time
        [] -> nil
      end

    # Count distinct days from engram access timestamps.
    active_dates =
      try do
        query =
          from(e in Mimo.Brain.Engram,
            where: not is_nil(e.last_accessed_at),
            select: fragment("date(?)", e.last_accessed_at),
            distinct: true
          )

        dates =
          Repo.all(query)
          |> Enum.map(&parse_date/1)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        dates
      rescue
        _ -> MapSet.new()
      end

    %{
      state
      | last_activity: last_activity,
        active_dates: active_dates,
        total_active_days: MapSet.size(active_dates)
    }
  end

  defp persist_active_day(_date) do
    # Activity is reconstructed from engram access timestamps.
    # No separate persistence needed.
    :ok
  end

  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)
  defp to_date(%Date{} = d), do: d
  defp to_date(_), do: Date.utc_today()

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(%Date{} = date), do: date
  defp parse_date(_), do: nil

  defp active?(state) do
    threshold_hours = get_config(:inactivity_threshold_hours, @inactivity_threshold_hours)

    case state.last_activity do
      nil -> false
      last -> DateTime.diff(DateTime.utc_now(), last, :hour) < threshold_hours
    end
  end

  defp get_config(key, default) do
    Application.get_env(:mimo_mcp, :activity_tracker, [])
    |> Keyword.get(key, default)
  end
end
