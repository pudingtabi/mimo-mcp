defmodule Mimo.Tools.Dispatchers.Onboard.Tracker do
  @moduledoc "Tracks onboarding progress and state."
  use GenServer
  require Logger
  alias Mimo.Brain.Memory
  alias Mimo.Tools.Dispatchers.{Code, Knowledge, Library}
  alias Mimo.Tools.Dispatchers.Onboard.Tracker

  # State structure
  defstruct [
    # :idle, :running, :completed, :partial, :failed
    status: :idle,
    path: nil,
    fingerprint: nil,
    start_time: nil,
    finish_time: nil,
    progress: %{
      symbols: :pending,
      deps: :pending,
      graph: :pending,
      # SPEC-096 Synergy P1
      library_learn: :pending
    },
    results: %{
      symbols: nil,
      deps: nil,
      graph: nil,
      library_learn: nil
    },
    error: nil
  ]

  # Client API

  def start_link(_) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  def start_onboarding(path, fingerprint) do
    GenServer.call(__MODULE__, {:start, path, fingerprint})
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  def update_progress(type, status, result \\ nil) do
    GenServer.cast(__MODULE__, {:update_progress, type, status, result})
  end

  # Server Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:start, path, fingerprint}, _from, state) do
    if state.status == :running do
      {:reply, {:error, :already_running}, state}
    else
      new_state = %__MODULE__{
        status: :running,
        path: path,
        fingerprint: fingerprint,
        start_time: System.monotonic_time(:millisecond),
        progress: %{symbols: :running, deps: :running, graph: :running, library_learn: :running},
        results: %{symbols: nil, deps: nil, graph: nil, library_learn: nil}
      }

      # Start the background task
      Task.Supervisor.start_child(Mimo.TaskSupervisor, fn ->
        run_background_tasks(path)
      end)

      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    duration =
      if state.start_time do
        end_time = state.finish_time || System.monotonic_time(:millisecond)
        end_time - state.start_time
      else
        0
      end

    response = %{
      status: state.status,
      path: state.path,
      duration_ms: duration,
      progress: state.progress,
      results: state.results,
      error: state.error
    }

    {:reply, response, state}
  end

  @impl true
  def handle_cast({:update_progress, type, status, result}, state) do
    new_progress = Map.put(state.progress, type, status)
    new_results = if result, do: Map.put(state.results, type, result), else: state.results

    # Check if all done
    all_done = Enum.all?(Map.values(new_progress), fn s -> s in [:done, :error, :timeout] end)

    {new_status, finish_time} =
      if all_done do
        # Check if any errors
        has_errors = Enum.any?(Map.values(new_progress), fn s -> s in [:error, :timeout] end)
        final_status = if has_errors, do: :partial, else: :completed

        # Store fingerprint if successful or partial
        store_fingerprint(
          state.path,
          state.fingerprint,
          new_results.symbols,
          new_results.deps,
          new_results.graph
        )

        {final_status, System.monotonic_time(:millisecond)}
      else
        {state.status, state.finish_time}
      end

    new_state = %{
      state
      | progress: new_progress,
        results: new_results,
        status: new_status,
        finish_time: finish_time
    }

    {:noreply, new_state}
  end

  defp run_background_tasks(path) do
    # We run these in parallel tasks but report back individually
    # SPEC-096: Added library_learn for synergy

    # Define the tasks
    tasks = [
      {:symbols, fn -> Code.dispatch(%{"operation" => "index", "path" => path}) end},
      {:deps,
       fn ->
         Library.dispatch(%{"operation" => "discover", "path" => path})
       end},
      {:graph, fn -> Knowledge.dispatch(%{"operation" => "link", "path" => path}) end},
      # SPEC-096 Synergy P1: Learn library docs after discovering deps
      {:library_learn,
       fn ->
         # Small delay to let deps discovery run first
         Process.sleep(500)
         Mimo.Learning.LibraryLearner.learn_project_deps(path, max_deps: 10)
       end}
    ]

    tasks
    |> Enum.each(fn {type, func} ->
      Task.Supervisor.async_nolink(Mimo.TaskSupervisor, fn ->
        try do
          case func.() do
            {:ok, result} ->
              Tracker.update_progress(type, :done, result)

            {:error, reason} ->
              Logger.warning("[OnboardTracker] #{type} failed: #{inspect(reason)}")
              Tracker.update_progress(type, :error, %{error: reason})
          end
        rescue
          e ->
            Logger.error("[OnboardTracker] #{type} crashed: #{Exception.message(e)}")

            Tracker.update_progress(type, :error, %{
              error: Exception.message(e)
            })
        end
      end)
    end)
  end

  defp store_fingerprint(path, fingerprint, symbols, deps, graph) do
    content = """
    Project onboarded: #{path}
    Fingerprint: #{fingerprint}
    Symbols: #{get_in(symbols || %{}, [:total_symbols]) || 0}
    Dependencies: #{get_in(deps || %{}, [:total_dependencies]) || 0}
    Graph nodes: #{get_in(graph || %{}, [:nodes_created]) || get_in(graph || %{}, [:nodes]) || 0}
    Indexed at: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    """

    Memory.store(%{
      content: content,
      type: "fact",
      metadata: %{
        "fingerprint" => fingerprint,
        "path" => path,
        "category" => "project_onboard"
      }
    })
  end
end
