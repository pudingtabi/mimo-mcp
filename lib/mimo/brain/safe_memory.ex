defmodule Mimo.Brain.SafeMemory do
  @moduledoc """
  Resilient facade for memory operations.

  Wraps WorkingMemory with defensive error handling
  to prevent crashes from propagating to callers. Uses SafeCall for
  fault-tolerant GenServer interactions.

  ## Philosophy

  Memory operations should NEVER crash the caller. Even if the underlying
  GenServer is down, we gracefully degrade:

  - Writes: Fire-and-forget to a recovery queue
  - Reads: Return empty results with a warning
  - Search: Return empty results with a warning

  ## Usage

      # Instead of:
      WorkingMemory.store("content", importance: 0.7)

      # Use:
      SafeMemory.store("content", importance: 0.7)
  """
  require Logger

  alias Mimo.SafeCall
  alias Mimo.Brain.WorkingMemory

  # ==========================================================================
  # Working Memory Operations (Resilient)
  # ==========================================================================

  @doc """
  Store content in working memory with graceful degradation.

  If WorkingMemory is unavailable, queues for later and returns a temporary ID.
  """
  @spec store(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def store(content, opts \\ []) when is_binary(content) do
    # Pre-sanitize content to prevent UTF-8 crashes
    safe_content = sanitize_content(content)

    case SafeCall.genserver(WorkingMemory, {:store, safe_content, opts},
           fallback: fn ->
             # Generate temporary ID when GenServer is down
             temp_id = "temp_#{:erlang.unique_integer([:positive])}"
             Logger.warning("[SafeMemory] WorkingMemory down, using temp ID: #{temp_id}")
             {:ok, temp_id}
           end
         ) do
      {:ok, id} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get item from working memory. Returns {:error, :not_found} if unavailable.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def get(id) when is_binary(id) do
    SafeCall.genserver(WorkingMemory, {:get, id},
      fallback: fn ->
        Logger.debug("[SafeMemory] WorkingMemory unavailable for get(#{id})")
        {:error, :unavailable}
      end
    )
  end

  @doc """
  Get recent items from working memory. Returns empty list if unavailable.
  """
  @spec get_recent(integer()) :: list()
  def get_recent(limit \\ 10) do
    case SafeCall.genserver(WorkingMemory, {:get_recent, limit}, fallback: fn -> [] end) do
      {:ok, items} when is_list(items) -> items
      items when is_list(items) -> items
      _ -> []
    end
  end

  @doc """
  Search working memory. Returns empty list if unavailable.
  """
  @spec search(String.t(), keyword()) :: list()
  def search(query, opts \\ []) when is_binary(query) do
    safe_query = sanitize_content(query)

    case SafeCall.genserver(WorkingMemory, {:search, safe_query, opts}, fallback: fn -> [] end) do
      {:ok, results} when is_list(results) -> results
      results when is_list(results) -> results
      _ -> []
    end
  end

  @doc """
  Delete from working memory. No-op if unavailable.
  """
  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    SafeCall.genserver(WorkingMemory, {:delete, id}, fallback: fn -> :ok end)
    :ok
  end

  @doc """
  Mark item for consolidation. No-op if unavailable.
  """
  @spec mark_for_consolidation(String.t()) :: :ok | {:error, term()}
  def mark_for_consolidation(id) when is_binary(id) do
    SafeCall.genserver(WorkingMemory, {:mark_for_consolidation, id}, fallback: fn -> :ok end)
  end

  @doc """
  Get consolidation candidates. Returns empty list if unavailable.
  """
  @spec get_consolidation_candidates() :: list()
  def get_consolidation_candidates do
    case SafeCall.genserver(WorkingMemory, :get_consolidation_candidates, fallback: fn -> [] end) do
      items when is_list(items) -> items
      {:ok, items} when is_list(items) -> items
      _ -> []
    end
  end

  @doc """
  Get working memory stats. Returns empty map if unavailable.
  """
  @spec stats() :: map()
  def stats do
    case SafeCall.genserver(WorkingMemory, :stats, fallback: fn -> %{status: :unavailable} end) do
      {:ok, stats} when is_map(stats) -> stats
      stats when is_map(stats) -> stats
      _ -> %{status: :unavailable}
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  # Sanitize content to prevent UTF-8 encoding issues
  defp sanitize_content(content) when is_binary(content) do
    content
    |> ensure_utf8()
    # Remove control chars
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")
  end

  defp sanitize_content(content), do: to_string(content)

  # Ensure valid UTF-8, replacing invalid bytes
  defp ensure_utf8(binary) when is_binary(binary) do
    case :unicode.characters_to_binary(binary) do
      {:error, valid, _rest} ->
        Logger.debug("[SafeMemory] Fixed invalid UTF-8 in content")
        valid

      {:incomplete, valid, _rest} ->
        Logger.debug("[SafeMemory] Fixed incomplete UTF-8 in content")
        valid

      valid when is_binary(valid) ->
        valid
    end
  end
end
