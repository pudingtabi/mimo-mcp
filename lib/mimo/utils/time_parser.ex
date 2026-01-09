defmodule Mimo.Utils.TimeParser do
  @moduledoc """
  Parse natural language time expressions to date ranges.

  Supports common expressions like:
  - "today", "yesterday"
  - "last week", "last month", "this week"
  - "N days ago", "N hours ago", "N weeks ago", "N months ago"
  - "between monday and wednesday" (future enhancement)

  ## Examples

      iex> TimeParser.parse("yesterday")
      {:ok, {~U[2024-01-01 00:00:00Z], ~U[2024-01-01 23:59:59Z]}}

      iex> TimeParser.parse("3 days ago")
      {:ok, {~U[2023-12-29 12:00:00Z], ~U[2024-01-02 12:00:00Z]}}

      iex> TimeParser.parse("invalid")
      {:error, "Cannot parse time expression: invalid"}
  """

  @doc """
  Parse natural language time expression to date range.

  Returns `{:ok, {from_datetime, to_datetime}}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, {DateTime.t(), DateTime.t()}} | {:error, String.t()}
  def parse(expression) when is_binary(expression) do
    now = DateTime.utc_now()
    normalized = String.downcase(String.trim(expression))
    do_parse(normalized, now)
  end

  def parse(nil), do: {:error, "Time expression cannot be nil"}
  def parse(_), do: {:error, "Time expression must be a string"}

  # Multi-head time parsing
  defp do_parse("today", now), do: {:ok, {start_of_day(now), now}}

  defp do_parse("yesterday", now) do
    yesterday = DateTime.add(now, -1, :day)
    {:ok, {start_of_day(yesterday), end_of_day(yesterday)}}
  end

  defp do_parse("last week", now), do: {:ok, {DateTime.add(now, -7, :day), now}}
  defp do_parse("last month", now), do: {:ok, {DateTime.add(now, -30, :day), now}}
  defp do_parse("this week", now), do: {:ok, {start_of_week(now), now}}
  defp do_parse("this month", now), do: {:ok, {start_of_month(now), now}}
  defp do_parse("last hour", now), do: {:ok, {DateTime.add(now, -1, :hour), now}}
  defp do_parse("last 24 hours", now), do: {:ok, {DateTime.add(now, -24, :hour), now}}
  defp do_parse(expr, now), do: parse_relative(expr, now)

  @doc """
  Parse and return the "from" date only.
  Useful for simple "since" queries.
  """
  @spec parse_from(String.t()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def parse_from(expression) do
    case parse(expression) do
      {:ok, {from, _to}} -> {:ok, from}
      error -> error
    end
  end

  @doc """
  Parse and return NaiveDateTime for Ecto queries.
  """
  @spec parse_naive(String.t()) ::
          {:ok, {NaiveDateTime.t(), NaiveDateTime.t()}} | {:error, String.t()}
  def parse_naive(expression) do
    case parse(expression) do
      {:ok, {from, to}} ->
        {:ok, {DateTime.to_naive(from), DateTime.to_naive(to)}}

      error ->
        error
    end
  end

  defp parse_relative(expr, now) do
    cond do
      # "N days ago", "N day ago"
      match = Regex.run(~r/^(\d+)\s*days?\s*ago$/, expr) ->
        [_, n] = match
        amount = String.to_integer(n)
        from = DateTime.add(now, -amount, :day)
        {:ok, {from, now}}

      # "N hours ago", "N hour ago"
      match = Regex.run(~r/^(\d+)\s*hours?\s*ago$/, expr) ->
        [_, n] = match
        amount = String.to_integer(n)
        from = DateTime.add(now, -amount, :hour)
        {:ok, {from, now}}

      # "N weeks ago", "N week ago"
      match = Regex.run(~r/^(\d+)\s*weeks?\s*ago$/, expr) ->
        [_, n] = match
        amount = String.to_integer(n) * 7
        from = DateTime.add(now, -amount, :day)
        {:ok, {from, now}}

      # "N months ago", "N month ago"
      match = Regex.run(~r/^(\d+)\s*months?\s*ago$/, expr) ->
        [_, n] = match
        amount = String.to_integer(n) * 30
        from = DateTime.add(now, -amount, :day)
        {:ok, {from, now}}

      # "N minutes ago", "N minute ago"
      match = Regex.run(~r/^(\d+)\s*minutes?\s*ago$/, expr) ->
        [_, n] = match
        amount = String.to_integer(n)
        from = DateTime.add(now, -amount, :minute)
        {:ok, {from, now}}

      # "past N days/hours/etc"
      match = Regex.run(~r/^(?:past|last)\s+(\d+)\s+(days?|hours?|weeks?|months?|minutes?)$/, expr) ->
        [_, n, unit] = match
        amount = String.to_integer(n)
        from = subtract_time(now, amount, unit)
        {:ok, {from, now}}

      # "since N days ago"
      match = Regex.run(~r/^since\s+(\d+)\s+(days?|hours?|weeks?|months?)\s*ago$/, expr) ->
        [_, n, unit] = match
        amount = String.to_integer(n)
        from = subtract_time(now, amount, unit)
        {:ok, {from, now}}

      true ->
        {:error, "Cannot parse time expression: #{expr}"}
    end
  end

  defp subtract_time(datetime, amount, unit) do
    unit_normalized = String.replace(unit, ~r/s$/, "")

    case unit_normalized do
      "day" -> DateTime.add(datetime, -amount, :day)
      "hour" -> DateTime.add(datetime, -amount, :hour)
      "week" -> DateTime.add(datetime, -amount * 7, :day)
      "month" -> DateTime.add(datetime, -amount * 30, :day)
      "minute" -> DateTime.add(datetime, -amount, :minute)
      _ -> datetime
    end
  end

  defp start_of_day(%DateTime{} = dt) do
    %{dt | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp end_of_day(%DateTime{} = dt) do
    %{dt | hour: 23, minute: 59, second: 59, microsecond: {999_999, 6}}
  end

  defp start_of_week(%DateTime{} = dt) do
    # Get day of week (1 = Monday, 7 = Sunday)
    day_of_week = Date.day_of_week(DateTime.to_date(dt))
    # Subtract days to get to Monday
    days_since_monday = day_of_week - 1
    monday = DateTime.add(dt, -days_since_monday, :day)
    start_of_day(monday)
  end

  defp start_of_month(%DateTime{} = dt) do
    %{dt | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
  end
end
