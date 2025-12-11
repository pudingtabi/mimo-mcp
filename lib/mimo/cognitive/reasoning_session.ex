defmodule Mimo.Cognitive.ReasoningSession do
  @moduledoc """
  Manages reasoning session state in ETS.

  Reasoning sessions store the context and progress of multi-step
  reasoning processes (CoT, ToT, ReAct, Reflexion).

  This is a GenServer that owns the ETS table, ensuring session data
  persists across MCP request boundaries.

  ## Session Lifecycle

  1. `create/2` - Create a new session for a problem
  2. `get/1` - Retrieve session state
  3. `add_thought/2` - Add a reasoning step
  4. `add_branch/2` - Create a ToT branch
  5. `complete/1` - Mark session as complete
  6. `cleanup_expired/0` - Remove stale sessions

  ## Storage

  Sessions are stored in ETS for fast access. They auto-expire
  after 1 hour of inactivity. The GenServer runs periodic cleanup.
  """
  use GenServer
  require Logger

  @table :reasoning_sessions
  # 1 hour TTL
  @ttl_ms 3_600_000
  # Cleanup every 10 minutes
  @cleanup_interval_ms 600_000

  @type strategy :: :cot | :tot | :react | :reflexion | :auto
  @type status :: :active | :completed | :stuck | :abandoned

  @type thought :: %{
          id: String.t(),
          content: String.t(),
          step: non_neg_integer(),
          evaluation: :good | :maybe | :bad | nil,
          confidence: float(),
          branch_id: String.t() | nil,
          timestamp: DateTime.t()
        }

  @type branch :: %{
          id: String.t(),
          parent_id: String.t() | nil,
          thoughts: [thought()],
          evaluation: :promising | :uncertain | :dead_end,
          explored: boolean()
        }

  @type session :: %{
          id: String.t(),
          problem: String.t(),
          strategy: strategy(),
          thoughts: [thought()],
          branches: [branch()],
          current_branch_id: String.t() | nil,
          confidence_history: [float()],
          decomposition: [String.t()],
          similar_problems: [map()],
          status: status(),
          started_at: DateTime.t(),
          last_activity: DateTime.t()
        }

  # ============================================================================
  # GenServer Setup
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Try to reclaim ETS table from heir (if we crashed and restarted)
    # Otherwise create new table with heir for crash recovery
    table =
      case Mimo.EtsHeirManager.reclaim_table(@table, self()) do
        {:ok, reclaimed_table} ->
          Logger.info("✅ ReasoningSession recovered ETS table after crash")
          reclaimed_table

        :not_found ->
          # First start or table was cleaned up - create new with heir
          Mimo.EtsHeirManager.create_table(
            @table,
            [:named_table, :set, :public, read_concurrency: true],
            self()
          )
      end

    Logger.info("✅ ReasoningSession initialized with ETS table (heir-protected)")
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    case cleanup_expired() do
      {:ok, count} when count > 0 ->
        Logger.debug("ReasoningSession: cleaned up #{count} expired sessions")

      _ ->
        :ok
    end

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  # ============================================================================
  # Public API (unchanged interface, but table is now persistent)
  # ============================================================================

  @doc """
  Initialize the ETS table for session storage.
  Called during application startup.

  NOTE: This is now handled by GenServer init. This function is kept
  for backwards compatibility but is a no-op.
  """
  @spec init() :: :ok | {:error, term()}
  def init do
    # Table is created by GenServer.init/1
    # This is kept for backwards compatibility
    :ok
  end

  @doc """
  Create a new reasoning session.

  ## Parameters

  - `problem` - The problem statement to reason about
  - `strategy` - The reasoning strategy (:cot, :tot, :react, :reflexion)
  - `opts` - Optional parameters:
    - `:decomposition` - Initial problem decomposition
    - `:similar_problems` - Related past problems found
  """
  @spec create(String.t(), strategy(), keyword()) :: session()
  def create(problem, strategy, opts \\ []) do
    session_id = generate_session_id()
    now = DateTime.utc_now()

    # Create root branch for ToT strategy
    {branches, current_branch_id} =
      if strategy == :tot do
        root_branch = %{
          id: "branch_root",
          parent_id: nil,
          thoughts: [],
          evaluation: :uncertain,
          explored: false
        }

        {[root_branch], "branch_root"}
      else
        {[], nil}
      end

    session = %{
      id: session_id,
      problem: problem,
      strategy: strategy,
      thoughts: [],
      branches: branches,
      current_branch_id: current_branch_id,
      confidence_history: [],
      decomposition: Keyword.get(opts, :decomposition, []),
      similar_problems: Keyword.get(opts, :similar_problems, []),
      status: :active,
      started_at: now,
      last_activity: now
    }

    :ets.insert(@table, {session_id, session})
    session
  end

  @doc """
  Retrieve a session by ID.
  """
  @spec get(String.t()) :: {:ok, session()} | {:error, :not_found}
  def get(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, session}] ->
        # Update last activity on access
        updated = %{session | last_activity: DateTime.utc_now()}
        :ets.insert(@table, {session_id, updated})
        {:ok, updated}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Update a session with new data.
  """
  @spec update(String.t(), map()) :: {:ok, session()} | {:error, :not_found}
  def update(session_id, updates) when is_map(updates) do
    case get(session_id) do
      {:ok, session} ->
        updated =
          session
          |> Map.merge(updates)
          |> Map.put(:last_activity, DateTime.utc_now())

        :ets.insert(@table, {session_id, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Add a thought to the session.
  """
  @spec add_thought(String.t(), thought()) :: {:ok, session()} | {:error, :not_found}
  def add_thought(session_id, thought) do
    case get(session_id) do
      {:ok, session} ->
        thought_with_defaults =
          Map.merge(thought, %{
            id: thought[:id] || generate_thought_id(),
            timestamp: thought[:timestamp] || DateTime.utc_now(),
            branch_id: thought[:branch_id] || session.current_branch_id
          })

        updated_thoughts = session.thoughts ++ [thought_with_defaults]

        # Also add to current branch if ToT
        updated_branches =
          if session.strategy == :tot and session.current_branch_id do
            Enum.map(session.branches, fn branch ->
              if branch.id == session.current_branch_id do
                %{branch | thoughts: branch.thoughts ++ [thought_with_defaults]}
              else
                branch
              end
            end)
          else
            session.branches
          end

        # Update confidence history
        confidence_history =
          if thought_with_defaults[:confidence] do
            session.confidence_history ++ [thought_with_defaults.confidence]
          else
            session.confidence_history
          end

        updated = %{
          session
          | thoughts: updated_thoughts,
            branches: updated_branches,
            confidence_history: confidence_history,
            last_activity: DateTime.utc_now()
        }

        :ets.insert(@table, {session_id, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Add a new branch to the session (ToT strategy).
  """
  @spec add_branch(String.t(), branch()) :: {:ok, session()} | {:error, :not_found}
  def add_branch(session_id, branch) do
    case get(session_id) do
      {:ok, session} ->
        branch_with_defaults =
          Map.merge(branch, %{
            id: branch[:id] || generate_branch_id(),
            parent_id: branch[:parent_id] || session.current_branch_id,
            thoughts: branch[:thoughts] || [],
            evaluation: branch[:evaluation] || :uncertain,
            explored: branch[:explored] || false
          })

        updated = %{
          session
          | branches: session.branches ++ [branch_with_defaults],
            current_branch_id: branch_with_defaults.id,
            last_activity: DateTime.utc_now()
        }

        :ets.insert(@table, {session_id, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Switch to a different branch.
  """
  @spec switch_branch(String.t(), String.t()) :: {:ok, session()} | {:error, term()}
  def switch_branch(session_id, branch_id) do
    case get(session_id) do
      {:ok, session} ->
        if Enum.any?(session.branches, &(&1.id == branch_id)) do
          updated = %{
            session
            | current_branch_id: branch_id,
              last_activity: DateTime.utc_now()
          }

          :ets.insert(@table, {session_id, updated})
          {:ok, updated}
        else
          {:error, :branch_not_found}
        end

      error ->
        error
    end
  end

  @doc """
  Mark a branch as dead end.
  """
  @spec mark_branch_dead_end(String.t(), String.t()) :: {:ok, session()} | {:error, term()}
  def mark_branch_dead_end(session_id, branch_id) do
    case get(session_id) do
      {:ok, session} ->
        updated_branches =
          Enum.map(session.branches, fn branch ->
            if branch.id == branch_id do
              %{branch | evaluation: :dead_end, explored: true}
            else
              branch
            end
          end)

        updated = %{
          session
          | branches: updated_branches,
            last_activity: DateTime.utc_now()
        }

        :ets.insert(@table, {session_id, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Find the best unexplored branch.
  """
  @spec find_best_unexplored_branch(session()) :: branch() | nil
  def find_best_unexplored_branch(session) do
    session.branches
    |> Enum.filter(fn branch ->
      not branch.explored and branch.evaluation != :dead_end
    end)
    |> Enum.sort_by(fn branch ->
      case branch.evaluation do
        :promising -> 0
        :uncertain -> 1
        _ -> 2
      end
    end)
    |> List.first()
  end

  @doc """
  Mark session as completed.
  """
  @spec complete(String.t()) :: {:ok, session()} | {:error, :not_found}
  def complete(session_id) do
    update(session_id, %{status: :completed})
  end

  @doc """
  Mark session as stuck.
  """
  @spec mark_stuck(String.t()) :: {:ok, session()} | {:error, :not_found}
  def mark_stuck(session_id) do
    update(session_id, %{status: :stuck})
  end

  @doc """
  Delete a session.
  """
  @spec delete(String.t()) :: :ok
  def delete(session_id) do
    :ets.delete(@table, session_id)
    :ok
  end

  @doc """
  Clean up expired sessions (older than TTL).
  """
  @spec cleanup_expired() :: {:ok, non_neg_integer()}
  def cleanup_expired do
    now = DateTime.utc_now()
    cutoff_ms = @ttl_ms

    expired =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, session} ->
        diff_ms = DateTime.diff(now, session.last_activity, :millisecond)
        diff_ms > cutoff_ms
      end)
      |> Enum.map(fn {id, _} -> id end)

    Enum.each(expired, &delete/1)
    {:ok, length(expired)}
  end

  @doc """
  List all active sessions.
  """
  @spec list_active() :: [session()]
  def list_active do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, session} -> session end)
    |> Enum.filter(&(&1.status == :active))
  end

  @doc """
  List all completed sessions.
  Used by AutoGenerator to find candidates for procedure generation.
  """
  @spec list_completed() :: [session()]
  def list_completed do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, session} -> session end)
    |> Enum.filter(&(&1.status == :completed))
  end

  @doc """
  Get session statistics.
  """
  @spec stats() :: map()
  def stats do
    sessions = :ets.tab2list(@table) |> Enum.map(fn {_id, s} -> s end)

    %{
      total_sessions: length(sessions),
      active: Enum.count(sessions, &(&1.status == :active)),
      completed: Enum.count(sessions, &(&1.status == :completed)),
      stuck: Enum.count(sessions, &(&1.status == :stuck)),
      by_strategy: Enum.frequencies_by(sessions, & &1.strategy)
    }
  end

  # Private helpers

  defp generate_session_id do
    random = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    "reason_#{random}"
  end

  defp generate_thought_id do
    random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "thought_#{random}"
  end

  defp generate_branch_id do
    random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "branch_#{random}"
  end
end
