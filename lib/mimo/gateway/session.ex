defmodule Mimo.Gateway.Session do
  @moduledoc """
  Gateway session state management.

  Tracks the session state including:
  - Which tools have been called
  - Current phase in the workflow
  - Prerequisites met
  """

  use Agent
  require Logger

  # 30 minutes
  @session_timeout_ms 30 * 60 * 1000

  defstruct [
    :id,
    :created_at,
    :updated_at,
    phase: :initial,
    reason_called?: false,
    memory_searched?: false,
    tool_history: [],
    warnings: [],
    metadata: %{},
    # Quality Gate context - stores reasoning for evaluation
    reasoning_context: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          phase: atom(),
          reason_called?: boolean(),
          memory_searched?: boolean(),
          tool_history: list(),
          warnings: list(),
          metadata: map()
        }

  # ETS table for session storage
  @table __MODULE__

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        # Check if table exists before creating (prevents crash on restart)
        if :ets.whereis(@table) == :undefined do
          :ets.new(@table, [:named_table, :public, :set])
        end

        %{}
      end,
      name: __MODULE__
    )
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Get or create a session.
  """
  def get_or_create(session_id) when is_binary(session_id) do
    case get(session_id) do
      {:ok, session} -> {:ok, session}
      {:error, :not_found} -> create(session_id)
    end
  end

  def get_or_create(nil), do: create(generate_id())

  @doc """
  Create a new session.
  """
  def create(session_id \\ generate_id()) do
    session = %__MODULE__{
      id: session_id,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    try do
      :ets.insert(@table, {session_id, session})
      {:ok, session}
    rescue
      ArgumentError ->
        # Table doesn't exist yet (not started)
        {:ok, session}
    end
  end

  @doc """
  Get a session by ID.
  """
  def get(session_id) do
    try do
      case :ets.lookup(@table, session_id) do
        [{^session_id, session}] -> {:ok, session}
        [] -> {:error, :not_found}
      end
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end

  @doc """
  Update a session.
  """
  def update(%__MODULE__{} = session) do
    session = %{session | updated_at: DateTime.utc_now()}

    try do
      :ets.insert(@table, {session.id, session})
      {:ok, session}
    rescue
      ArgumentError -> {:ok, session}
    end
  end

  @doc """
  Record a tool call in the session.
  """
  def record_tool_call(%__MODULE__{} = session, tool_name, args \\ %{}) do
    entry = %{
      tool: tool_name,
      args: args,
      timestamp: DateTime.utc_now()
    }

    session = %{
      session
      | tool_history: [entry | session.tool_history],
        updated_at: DateTime.utc_now()
    }

    # Update flags based on tool
    session = update_flags(session, tool_name, args)

    {:ok, session}
  end

  # Update session flags based on tool calls
  defp update_flags(session, "reason", _args) do
    %{session | reason_called?: true, phase: :reasoning}
  end

  defp update_flags(session, "memory", %{"operation" => "search"}) do
    %{session | memory_searched?: true, phase: :context}
  end

  defp update_flags(session, "memory", %{"operation" => "synthesize"}) do
    %{session | memory_searched?: true, phase: :context}
  end

  defp update_flags(session, "code", _args) do
    %{session | phase: :intelligence}
  end

  defp update_flags(session, "file", %{"operation" => op}) when op in ["edit", "write"] do
    %{session | phase: :action}
  end

  defp update_flags(session, "terminal", _args) do
    %{session | phase: :action}
  end

  defp update_flags(session, _tool, _args), do: session

  defp generate_id do
    "gateway_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  @doc """
  Clean up expired sessions.
  """
  def cleanup_expired do
    cutoff = DateTime.add(DateTime.utc_now(), -@session_timeout_ms, :millisecond)

    try do
      :ets.foldl(
        fn {id, session}, acc ->
          if DateTime.compare(session.updated_at, cutoff) == :lt do
            :ets.delete(@table, id)
            acc + 1
          else
            acc
          end
        end,
        0,
        @table
      )
    rescue
      ArgumentError -> 0
    end
  end
end
