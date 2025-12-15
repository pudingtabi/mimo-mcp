defmodule Mimo.EtsSafe do
  @moduledoc """
  Safe ETS table operations for multi-instance environments.

  When multiple Mimo instances attempt to start on the same BEAM node
  (or when tests run concurrently), named ETS tables can conflict.
  This module provides safe table creation that handles race conditions
  and duplicate table scenarios gracefully.

  ## Usage

  Instead of:
      :ets.new(:my_table, [:named_table, :set, :public])

  Use:
      Mimo.EtsSafe.ensure_table(:my_table, [:named_table, :set, :public])

  The function will either create the table or return the existing one.
  """

  require Logger

  @doc """
  Create or reuse an existing named ETS table.

  Returns the table reference regardless of whether it was created or reused.
  This is safe for concurrent calls and multi-instance scenarios.

  ## Parameters

  - `name` - Atom name for the table
  - `opts` - Standard ETS options (must include :named_table for this to work)

  ## Returns

  - Table reference (atom for named tables, tid for unnamed)

  ## Examples

      iex> Mimo.EtsSafe.ensure_table(:my_cache, [:named_table, :set, :public])
      :my_cache

      # Calling again is safe
      iex> Mimo.EtsSafe.ensure_table(:my_cache, [:named_table, :set, :public])
      :my_cache
  """
  @spec ensure_table(atom(), list()) :: :ets.tid() | atom()
  def ensure_table(name, opts) when is_atom(name) do
    case :ets.whereis(name) do
      :undefined ->
        try do
          :ets.new(name, opts)
        rescue
          ArgumentError ->
            # Race condition: table was created between whereis check and new
            # This is expected in concurrent scenarios
            case :ets.whereis(name) do
              :undefined ->
                # Table truly doesn't exist and we can't create it - re-raise
                reraise ArgumentError, "Cannot create or find ETS table #{name}", __STACKTRACE__

              tid ->
                Logger.debug("[EtsSafe] Reused existing table #{name} after race condition")
                tid
            end
        end

      tid ->
        # Table already exists, reuse it
        Logger.debug("[EtsSafe] Reusing existing table #{name}")
        tid
    end
  end

  @doc """
  Check if a named ETS table already exists.
  """
  @spec table_exists?(atom()) :: boolean()
  def table_exists?(name) when is_atom(name) do
    :ets.whereis(name) != :undefined
  end

  @doc """
  Safely delete a table if it exists.
  Returns :ok regardless of whether the table existed.
  """
  @spec delete_if_exists(atom()) :: :ok
  def delete_if_exists(name) when is_atom(name) do
    case :ets.whereis(name) do
      :undefined -> :ok
      _tid -> :ets.delete(name)
    end

    :ok
  end
end
