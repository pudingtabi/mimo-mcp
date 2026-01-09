defmodule Mimo.Context.WorkingMemory do
  @moduledoc """
  SPEC-097: Working Memory for Universal Context Understanding.

  Tracks the current project focus and recent project history.
  Enables "last project" and "current project" resolution.

  ## Usage

      # Get current project
      WorkingMemory.current_project()

      # Set current project (called by onboard)
      WorkingMemory.set_project("/path/to/project")

      # Get recent projects
      WorkingMemory.recent_projects(5)
  """

  use GenServer
  require Logger

  alias Mimo.Context.{Entity, Project}

  @name __MODULE__

  # State structure
  defstruct [
    :current_project_path,
    recent_projects: [],
    session_start: nil,
    max_recent: 10
  ]

  # Client API

  @doc """
  Start the Working Memory GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Get the current project path.
  """
  @spec current_project() :: String.t() | nil
  def current_project do
    GenServer.call(@name, :current_project)
  catch
    :exit, _ -> nil
  end

  @doc """
  Get the current project as a Project struct.
  """
  @spec current_project_info() :: Project.t() | nil
  def current_project_info do
    case current_project() do
      nil -> nil
      path -> Project.find(path)
    end
  end

  @doc """
  Set the current project. Called by onboard when a project is indexed.
  """
  @spec set_project(String.t()) :: :ok
  def set_project(path) do
    GenServer.cast(@name, {:set_project, path})
  end

  @doc """
  Get the N most recent projects (excluding current).
  """
  @spec recent_projects(non_neg_integer()) :: [String.t()]
  def recent_projects(n \\ 5) do
    GenServer.call(@name, {:recent_projects, n})
  catch
    :exit, _ -> []
  end

  @doc """
  Get the last project (the one before current).
  """
  @spec last_project() :: String.t() | nil
  def last_project do
    case recent_projects(1) do
      [path | _] -> path
      [] -> nil
    end
  end

  @doc """
  Get the last project as a Project struct.
  """
  @spec last_project_info() :: Project.t() | nil
  def last_project_info do
    case last_project() do
      nil -> nil
      path -> Project.find(path)
    end
  end

  @doc """
  Get the current state (for debugging).
  """
  @spec state() :: map()
  def state do
    GenServer.call(@name, :state)
  catch
    :exit, _ -> %{}
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Ensure ETS tables exist for Project and Entity
    Project.init()
    Entity.init()

    state = %__MODULE__{
      current_project_path: nil,
      recent_projects: [],
      session_start: DateTime.utc_now(),
      max_recent: 10
    }

    Logger.info("[SPEC-097] Working Memory initialized")
    {:ok, state}
  end

  @impl true
  def handle_call(:current_project, _from, state) do
    {:reply, state.current_project_path, state}
  end

  @impl true
  def handle_call({:recent_projects, n}, _from, state) do
    recent = Enum.take(state.recent_projects, n)
    {:reply, recent, state}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_cast({:set_project, path}, state) do
    abs_path = Path.expand(path)

    # Update recent projects list
    new_recent =
      if state.current_project_path && state.current_project_path != abs_path do
        # Add previous current to recent, remove duplicates
        [state.current_project_path | state.recent_projects]
        |> Enum.reject(&(&1 == abs_path))
        |> Enum.uniq()
        |> Enum.take(state.max_recent)
      else
        state.recent_projects
        |> Enum.reject(&(&1 == abs_path))
        |> Enum.take(state.max_recent)
      end

    # Touch the project to update last_active
    Project.touch(abs_path)

    new_state = %{state | current_project_path: abs_path, recent_projects: new_recent}

    Logger.debug(
      "[SPEC-097] Working memory updated: current=#{abs_path}, recent=#{length(new_recent)}"
    )

    {:noreply, new_state}
  end
end
