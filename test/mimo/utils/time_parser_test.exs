defmodule Mimo.Utils.TimeParserTest do
  @moduledoc """
  Tests for Mimo.Utils.TimeParser module.
  Tests natural language time expression parsing.
  """
  use ExUnit.Case, async: true

  alias Mimo.Utils.TimeParser

  describe "parse/1 - basic expressions" do
    test "parses 'today'" do
      {:ok, {from, to}} = TimeParser.parse("today")

      assert DateTime.diff(to, from, :second) >= 0
      assert from.hour == 0
      assert from.minute == 0
    end

    test "parses 'yesterday'" do
      {:ok, {from, to}} = TimeParser.parse("yesterday")

      now = DateTime.utc_now()
      yesterday = DateTime.add(now, -1, :day)

      # From should be start of yesterday
      assert from.day == yesterday.day
      assert from.hour == 0

      # To should be end of yesterday
      assert to.day == yesterday.day
      assert to.hour == 23
    end

    test "parses 'last week'" do
      {:ok, {from, to}} = TimeParser.parse("last week")

      diff_days = DateTime.diff(to, from, :day)
      assert diff_days >= 6 and diff_days <= 7
    end

    test "parses 'last month'" do
      {:ok, {from, to}} = TimeParser.parse("last month")

      diff_days = DateTime.diff(to, from, :day)
      assert diff_days >= 29 and diff_days <= 30
    end

    test "parses 'this week'" do
      {:ok, {from, _to}} = TimeParser.parse("this week")

      # From should be a Monday
      day_of_week = Date.day_of_week(DateTime.to_date(from))
      assert day_of_week == 1
    end

    test "parses 'last hour'" do
      {:ok, {from, to}} = TimeParser.parse("last hour")

      diff_minutes = DateTime.diff(to, from, :minute)
      assert diff_minutes >= 59 and diff_minutes <= 60
    end
  end

  describe "parse/1 - relative expressions" do
    test "parses 'N days ago'" do
      {:ok, {from, to}} = TimeParser.parse("3 days ago")

      diff_days = DateTime.diff(to, from, :day)
      assert diff_days >= 2 and diff_days <= 3
    end

    test "parses 'N hours ago'" do
      {:ok, {from, to}} = TimeParser.parse("5 hours ago")

      diff_hours = DateTime.diff(to, from, :hour)
      assert diff_hours >= 4 and diff_hours <= 5
    end

    test "parses 'N weeks ago'" do
      {:ok, {from, to}} = TimeParser.parse("2 weeks ago")

      diff_days = DateTime.diff(to, from, :day)
      assert diff_days >= 13 and diff_days <= 14
    end

    test "parses 'N months ago'" do
      {:ok, {from, to}} = TimeParser.parse("1 month ago")

      diff_days = DateTime.diff(to, from, :day)
      assert diff_days >= 29 and diff_days <= 30
    end

    test "parses 'N minutes ago'" do
      {:ok, {from, to}} = TimeParser.parse("30 minutes ago")

      diff_minutes = DateTime.diff(to, from, :minute)
      assert diff_minutes >= 29 and diff_minutes <= 30
    end

    test "parses singular forms (1 day ago, 1 hour ago)" do
      {:ok, {from1, _to1}} = TimeParser.parse("1 day ago")
      {:ok, {from2, _to2}} = TimeParser.parse("1 hour ago")

      assert is_struct(from1, DateTime)
      assert is_struct(from2, DateTime)
    end
  end

  describe "parse/1 - alternative formats" do
    test "parses 'past N days'" do
      {:ok, {from, to}} = TimeParser.parse("past 7 days")

      diff_days = DateTime.diff(to, from, :day)
      assert diff_days >= 6 and diff_days <= 7
    end

    test "parses 'last N hours'" do
      {:ok, {from, to}} = TimeParser.parse("last 24 hours")

      diff_hours = DateTime.diff(to, from, :hour)
      assert diff_hours >= 23 and diff_hours <= 24
    end
  end

  describe "parse/1 - edge cases" do
    test "returns error for invalid expression" do
      assert {:error, message} = TimeParser.parse("not a time")
      assert message =~ "Cannot parse"
    end

    test "returns error for nil" do
      assert {:error, _} = TimeParser.parse(nil)
    end

    test "returns error for non-string" do
      assert {:error, _} = TimeParser.parse(123)
    end

    test "handles case insensitivity" do
      {:ok, {from1, _}} = TimeParser.parse("TODAY")
      {:ok, {from2, _}} = TimeParser.parse("Today")
      {:ok, {from3, _}} = TimeParser.parse("today")

      assert from1.hour == from2.hour
      assert from2.hour == from3.hour
    end

    test "handles whitespace" do
      {:ok, _} = TimeParser.parse("  yesterday  ")
      {:ok, _} = TimeParser.parse("3  days  ago")
    end
  end

  describe "parse_from/1" do
    test "returns only the from datetime" do
      {:ok, from} = TimeParser.parse_from("yesterday")

      assert is_struct(from, DateTime)
    end
  end

  describe "parse_naive/1" do
    test "returns NaiveDateTime tuple" do
      {:ok, {from, to}} = TimeParser.parse_naive("yesterday")

      assert is_struct(from, NaiveDateTime)
      assert is_struct(to, NaiveDateTime)
    end
  end
end
