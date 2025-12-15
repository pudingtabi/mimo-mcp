defmodule Mimo.Awakening.Hooks do
  @moduledoc """
  SPEC-040: Non-blocking hooks for Awakening XP events.

  This module provides safe, fire-and-forget notification functions
  that can be called from hot paths (like memory storage) without
  impacting performance. All operations are async and failure-tolerant.

  ## Usage

  Add to memory storage paths:

      # After storing a memory
      Mimo.Awakening.Hooks.memory_stored(engram)
      
      # After storing a relationship/triple  
      Mimo.Awakening.Hooks.relationship_created(triple)
      
      # After executing a tool
      Mimo.Awakening.Hooks.tool_executed(tool_name, result)
  """

  require Logger

  @doc """
  Notify awakening system that a memory was stored.
  Safe to call - never raises, returns immediately.
  """
  @spec memory_stored(map() | struct()) :: :ok
  def memory_stored(engram) do
    spawn_fire_and_forget(fn ->
      if awakening_available?() do
        category = get_category(engram)
        Mimo.Awakening.record_memory_stored(category)
      end
    end)
  end

  @doc """
  Notify awakening system that a relationship was created.
  Safe to call - never raises, returns immediately.
  """
  @spec relationship_created(map() | struct()) :: :ok
  def relationship_created(triple) do
    spawn_fire_and_forget(fn ->
      if awakening_available?() do
        predicate = get_predicate(triple)
        Mimo.Awakening.record_relationship_created(predicate)
      end
    end)
  end

  @doc """
  Notify awakening system that a tool was executed.
  Safe to call - never raises, returns immediately.
  """
  @spec tool_executed(String.t(), :ok | :error | {:ok, any()} | {:error, any()}) :: :ok
  def tool_executed(tool_name, result) do
    spawn_fire_and_forget(fn ->
      if awakening_available?(), do: Mimo.Awakening.record_tool_call(tool_name, success?(result))
    end)
  end

  defp success?(:ok), do: true
  defp success?({:ok, _}), do: true
  defp success?(_), do: false

  @doc """
  Notify awakening system that an insight was generated.
  Safe to call - never raises, returns immediately.
  """
  @spec insight_generated(String.t()) :: :ok
  def insight_generated(insight_type) do
    spawn_fire_and_forget(fn ->
      if awakening_available?() do
        Mimo.Awakening.record_insight_generated(insight_type)
      end
    end)
  end

  @doc """
  Notify awakening system of a reasoning session.
  Safe to call - never raises, returns immediately.
  """
  @spec reasoning_session_completed(non_neg_integer()) :: :ok
  def reasoning_session_completed(step_count) do
    spawn_fire_and_forget(fn ->
      if awakening_available?() do
        Mimo.Awakening.record_reasoning_session(step_count)
      end
    end)
  end

  @doc """
  Notify awakening system of knowledge graph activity.
  Safe to call - never raises, returns immediately.
  """
  @spec knowledge_graph_activity(atom()) :: :ok
  def knowledge_graph_activity(activity_type) do
    spawn_fire_and_forget(fn ->
      if awakening_available?() do
        Mimo.Awakening.record_knowledge_activity(activity_type)
      end
    end)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Check if awakening system is available
  defp awakening_available? do
    # Check if SessionTracker is running
    case Process.whereis(Mimo.Awakening.SessionTracker) do
      nil -> false
      _pid -> true
    end
  end

  # Spawn a fire-and-forget task with error handling
  defp spawn_fire_and_forget(fun) do
    spawn(fn ->
      try do
        fun.()
      rescue
        e ->
          Logger.debug("[Awakening.Hooks] Non-critical hook error: #{Exception.message(e)}")
      catch
        :exit, reason ->
          Logger.debug("[Awakening.Hooks] Non-critical hook exit: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # Extract category from engram
  defp get_category(%{category: category}) when is_atom(category), do: category
  defp get_category(%{category: category}) when is_binary(category), do: String.to_atom(category)
  defp get_category(_), do: :unknown

  # Extract predicate from triple
  defp get_predicate(%{predicate: predicate}) when is_binary(predicate), do: predicate
  defp get_predicate(%Mimo.SemanticStore.Triple{predicate: predicate}), do: predicate
  defp get_predicate(_), do: "unknown"
end
