defmodule Mimo.Utils.InputValidation do
  @moduledoc """
  Input validation utilities for MCP tool parameters.

  Provides sanitization and validation for common parameter types
  to prevent edge cases from causing unexpected behavior.
  """

  @doc """
  Validates and clamps a limit parameter to a safe range.

  - Returns `default` if value is nil
  - Returns `min` if value is negative
  - Returns `max` if value exceeds maximum
  - Converts strings to integers if possible

  ## Examples

      iex> validate_limit(nil, default: 10)
      10

      iex> validate_limit(-1, default: 10)
      1

      iex> validate_limit(1000, default: 10, max: 100)
      100

      iex> validate_limit("50", default: 10)
      50
  """
  @spec validate_limit(term(), keyword()) :: pos_integer()
  def validate_limit(value, opts \\ []) do
    default = Keyword.get(opts, :default, 10)
    min = Keyword.get(opts, :min, 1)
    max = Keyword.get(opts, :max, 1000)

    value
    |> to_integer(default)
    |> max(min)
    |> min(max)
  end

  @doc """
  Validates and clamps an offset parameter (0-indexed pagination).

  - Returns 0 if value is nil or negative
  - Converts strings to integers if possible

  ## Examples

      iex> validate_offset(nil)
      0

      iex> validate_offset(-50)
      0

      iex> validate_offset("100")
      100
  """
  @spec validate_offset(term(), keyword()) :: non_neg_integer()
  def validate_offset(value, opts \\ []) do
    max = Keyword.get(opts, :max, 100_000)

    value
    |> to_integer(0)
    |> max(0)
    |> min(max)
  end

  @doc """
  Validates a threshold parameter (0.0 to 1.0 range).

  - Returns `default` if value is nil
  - Clamps to 0.0-1.0 range

  ## Examples

      iex> validate_threshold(nil, default: 0.3)
      0.3

      iex> validate_threshold(1.5, default: 0.3)
      1.0

      iex> validate_threshold(-0.5, default: 0.3)
      0.0
  """
  @spec validate_threshold(term(), keyword()) :: float()
  def validate_threshold(value, opts \\ []) do
    default = Keyword.get(opts, :default, 0.5)

    value
    |> to_float(default)
    |> max(0.0)
    |> min(1.0)
  end

  @doc """
  Validates a days parameter for time-based queries.

  ## Examples

      iex> validate_days(nil, default: 30)
      30

      iex> validate_days(-1, default: 30)
      1

      iex> validate_days(1000, default: 30, max: 365)
      365
  """
  @spec validate_days(term(), keyword()) :: pos_integer()
  def validate_days(value, opts \\ []) do
    default = Keyword.get(opts, :default, 30)
    max = Keyword.get(opts, :max, 365)

    value
    |> to_integer(default)
    |> max(1)
    |> min(max)
  end

  @doc """
  Validates a timeout parameter in milliseconds.

  ## Examples

      iex> validate_timeout(nil, default: 30_000)
      30000

      iex> validate_timeout(100, default: 30_000, min: 1_000)
      1000

      iex> validate_timeout(600_000, default: 30_000, max: 120_000)
      120000
  """
  @spec validate_timeout(term(), keyword()) :: pos_integer()
  def validate_timeout(value, opts \\ []) do
    default = Keyword.get(opts, :default, 30_000)
    min = Keyword.get(opts, :min, 1_000)
    max = Keyword.get(opts, :max, 300_000)

    value
    |> to_integer(default)
    |> max(min)
    |> min(max)
  end

  @doc """
  Validates a max_tokens parameter for LLM calls.

  ## Examples

      iex> validate_max_tokens(nil, default: 1000)
      1000

      iex> validate_max_tokens(50_000, default: 1000, max: 4096)
      4096
  """
  @spec validate_max_tokens(term(), keyword()) :: pos_integer()
  def validate_max_tokens(value, opts \\ []) do
    default = Keyword.get(opts, :default, 1000)
    max = Keyword.get(opts, :max, 8192)

    value
    |> to_integer(default)
    |> max(1)
    |> min(max)
  end

  @doc """
  Validates a depth/hops parameter for graph traversal.

  ## Examples

      iex> validate_depth(nil, default: 3)
      3

      iex> validate_depth(100, default: 3, max: 10)
      10
  """
  @spec validate_depth(term(), keyword()) :: pos_integer()
  def validate_depth(value, opts \\ []) do
    default = Keyword.get(opts, :default, 3)
    max = Keyword.get(opts, :max, 10)

    value
    |> to_integer(default)
    |> max(1)
    |> min(max)
  end

  # Private helpers

  defp to_integer(nil, default), do: default
  defp to_integer(value, _default) when is_integer(value), do: value
  defp to_integer(value, _default) when is_float(value), do: trunc(value)

  defp to_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp to_integer(_value, default), do: default

  defp to_float(nil, default), do: default
  defp to_float(value, _default) when is_float(value), do: value
  defp to_float(value, _default) when is_integer(value), do: value / 1
  defp to_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> default
    end
  end
  defp to_float(_value, default), do: default
end
