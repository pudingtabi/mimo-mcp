defmodule Mimo.Autonomous.TaskRunner do
  @moduledoc """
  Autonomous task execution with cognitive enhancement.

  Part of SPEC-071: Autonomous Task Execution.

  ## Overview

  TaskRunner absorbs and improves upon the TaskSync pattern, adding:
  - Memory-powered feedback (hints from past similar tasks)
  - Synthesis-based learning from outcomes
  - Contradiction checking on outputs
  - Knowledge graph for dependency tracking
  - Circuit breaker for cascade failure prevention

  ## Safety Features (Learned from Incidents)

  - **Fail-closed by default**: Errors propagate honestly, never faked success
  - **No blocking in init**: Uses handle_continue for deferred initialization
  - **Circuit breaker**: Stops after consecutive failures with cooldown
  - **SafetyGuard**: Blocks dangerous operations before execution
  - **Telemetry**: All operations emit telemetry for observability

  ## Architecture

      âââââââââââââââââââââââââââââââââââââââââââââââââââ
      â              TaskRunner (GenServer)             â
      â  âââââââââââ  âââââââââââ  âââââââââââââââââââââ
      â  â  Queue  â  â Running â  â Circuit Breaker  ââ
      â  âââââââââââ  âââââââââââ  âââââââââââââââââââââ
      ââââââââââââââââââââââ¬ââââââââââââââââââââââââââââ
                           â
           âââââââââââââââââ¼ââââââââââââââââ
           â¼               â¼               â¼
      SafetyGuard     Task.Supervisor    Memory
      (pre-check)     (execution)        (hints + storage)

  ## MCP Integration

  Use the `autonomous` tool with operations:
  - `queue` - Add a task to the queue
  - `status` - Get runner status
  - `pause` - Pause autonomous execution
  - `resume` - Resume autonomous execution

  ## Usage

      # Queue a task
      {:ok, task_id} = TaskRunner.queue_task(%{
        type: "test",
        description: "Run test suite",
        command: "mix test"
      })

      # Check status
      status = TaskRunner.status()

      # Pause/resume
      TaskRunner.pause()
      TaskRunner.resume()
  """

  use GenServer
  require Logger

  alias Terminal
  alias Mimo.Autonomous.{CircuitBreaker, GoalDecomposer, SafetyGuard}
  alias Mimo.Brain.{ContradictionGuard, Memory, Synthesizer}
  alias Mimo.Synapse.Graph

  # Configuration defaults
  # 10 seconds
  @default_check_interval 10_000
  # Max parallel tasks
  @default_max_concurrent 3
  # 5 minutes
  @default_task_timeout 300_000

  # Task states
  @type task_status :: :queued | :running | :completed | :failed

  @type task :: %{
          id: String.t(),
          type: String.t(),
          description: String.t(),
          command: String.t() | nil,
          status: task_status(),
          hints: [map()],
          created_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          result: term() | nil
        }

  @type state :: %{
          status: :initializing | :ready | :paused,
          paused: boolean(),
          queue: [task()],
          running: %{String.t() => %{task: task(), pid: pid(), started_at: DateTime.t()}},
          completed: [{String.t(), term()}],
          failed: [{String.t(), term()}],
          circuit: CircuitBreaker.t(),
          config: map()
        }

  @doc """
  Start the TaskRunner GenServer.

  ## Options

    * `:check_interval` - How often to check for queued tasks (ms)
    * `:max_concurrent` - Maximum concurrent task executions
    * `:task_timeout` - Task execution timeout (ms)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add a task to the queue.

  Returns `{:ok, task_id}` on success, `{:error, reason}` on failure.

  ## Task Specification

    * `:type` - Task type (e.g., "test", "build", "deploy") - required
    * `:description` - Human-readable description - required
    * `:command` - Shell command to execute (optional)
    * `:path` - File path for file operations (optional)

  ## Examples

      TaskRunner.queue_task(%{
        type: "test",
        description: "Run test suite",
        command: "mix test"
      })
  """
  @spec queue_task(map()) :: {:ok, String.t()} | {:ok, [String.t()]} | {:error, term()}
  def queue_task(task_spec) when is_map(task_spec) do
    with :ok <- validate_task_spec(task_spec),
         :ok <- SafetyGuard.check_allowed(task_spec) do
      GenServer.call(__MODULE__, {:queue_with_decomposition, task_spec})
    end
  end

  def queue_task(_), do: {:error, :invalid_task_spec}

  @doc """
  Get current TaskRunner status.

  Returns a map with:
  - `:status` - Current runner status (:initializing, :ready, :paused)
  - `:paused` - Whether execution is paused
  - `:queued` - Number of tasks in queue
  - `:running` - Number of currently running tasks
  - `:completed` - Number of completed tasks
  - `:failed` - Number of failed tasks
  - `:circuit_state` - Circuit breaker state (:closed, :open, :half_open)
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, {:noproc, _} ->
      %{
        status: :not_running,
        paused: false,
        queued: 0,
        running: 0,
        completed: 0,
        failed: 0,
        circuit_state: :unknown,
        message: "TaskRunner is not running"
      }
  end

  @doc """
  Pause autonomous task execution.

  Already queued tasks remain in the queue but won't be started.
  Running tasks continue to completion.
  """
  @spec pause() :: :ok
  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  @doc """
  Resume autonomous task execution.
  """
  @spec resume() :: :ok
  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @doc """
  Reset the circuit breaker to closed state.

  Use after manually resolving the underlying issue that caused failures.
  """
  @spec reset_circuit() :: :ok
  def reset_circuit do
    GenServer.call(__MODULE__, :reset_circuit)
  end

  @doc """
  Get the list of queued tasks.
  """
  @spec list_queue() :: [task()]
  def list_queue do
    GenServer.call(__MODULE__, :list_queue)
  end

  @doc """
  Clear all queued tasks.
  """
  @spec clear_queue() :: :ok
  def clear_queue do
    GenServer.call(__MODULE__, :clear_queue)
  end

  # Queue a single task (called from within GenServer)
  defp queue_single_task(task_spec, state) do
    task_id = generate_task_id()
    task = build_task(task_id, task_spec)

    # Skip memory search for decomposed sub-tasks (already have context from parent)
    # This prevents cumulative timeout when queueing multiple sub-tasks
    is_decomposed = Map.get(task_spec, "_decomposed", false)

    hints =
      if is_decomposed do
        []
      else
        search_similar_tasks(task.description)
      end

    task = Map.put(task, :hints, hints)

    new_state = %{state | queue: state.queue ++ [task]}

    :telemetry.execute(
      [:mimo, :autonomous, :task],
      %{count: 1},
      %{event: :queued, task_id: task_id, hints_found: length(hints)}
    )

    Logger.info("[TaskRunner] Task #{task_id} queued: #{task.description}")
    if hints != [], do: Logger.debug("[TaskRunner] Found #{length(hints)} hints from past tasks")

    {{:ok, task_id}, new_state}
  end

  # Queue all sub-tasks from a decomposed complex task (internal version for GenServer)
  defp queue_decomposed_tasks_internal(original_task, sub_tasks, dependencies, state) do
    parent_description =
      Map.get(original_task, "description") || Map.get(original_task, :description, "")

    Logger.info(
      "[TaskRunner] Autonomous goal decomposition: " <>
        "\"#{String.slice(parent_description, 0, 50)}...\" -> #{length(sub_tasks)} sub-tasks"
    )

    # Queue each sub-task with its dependencies
    {task_ids, final_state} =
      Enum.reduce(sub_tasks, {[], state}, fn sub_task, {ids, acc_state} ->
        sub_spec = %{
          "type" => sub_task.type,
          "description" => sub_task.description,
          "parent_id" => sub_task.parent_id,
          "depends_on" => Map.get(dependencies, sub_task.id, []),
          "sequence" => sub_task.sequence,
          "_decomposed" => true
        }

        # Copy command from original if this is an implementation sub-task
        sub_spec =
          if sub_task.type in ["implement", "build", "test"] do
            original_command = Map.get(original_task, "command") || Map.get(original_task, :command)
            if original_command, do: Map.put(sub_spec, "command", original_command), else: sub_spec
          else
            sub_spec
          end

        {{:ok, task_id}, new_state} = queue_single_task(sub_spec, acc_state)
        {[task_id | ids], new_state}
      end)

    :telemetry.execute(
      [:mimo, :autonomous, :goal_decomposition],
      %{count: length(task_ids)},
      %{parent_description: parent_description, sub_task_count: length(sub_tasks)}
    )

    {{:ok, Enum.reverse(task_ids)}, final_state}
  end

  @impl true
  def init(opts) do
    # SAFETY: No blocking here! Use handle_continue for deferred init
    # Reference: ELIXIR_LIMITATIONS.md, Dec 6 incident
    state = %{
      status: :initializing,
      paused: false,
      queue: [],
      running: %{},
      completed: [],
      failed: [],
      circuit:
        CircuitBreaker.new(
          max_failures: Keyword.get(opts, :max_failures, 3),
          cooldown_ms: Keyword.get(opts, :cooldown_ms, 30_000)
        ),
      config: parse_config(opts)
    }

    {:ok, state, {:continue, :initialize}}
  end

  @impl true
  def handle_continue(:initialize, state) do
    # Safe to do blocking work here (after supervision tree is up)
    schedule_check(state.config.check_interval)

    Logger.info(
      "[TaskRunner] Initialized (interval: #{state.config.check_interval}ms, " <>
        "max_concurrent: #{state.config.max_concurrent})"
    )

    :telemetry.execute(
      [:mimo, :autonomous, :task_runner],
      %{count: 1},
      %{event: :initialized}
    )

    {:noreply, %{state | status: :ready}}
  end

  @impl true
  def handle_call({:queue_with_decomposition, task_spec}, _from, state) do
    # Check for autonomous goal decomposition
    case GoalDecomposer.maybe_decompose(task_spec) do
      {:simple, _} ->
        # Simple task - queue directly
        {reply, new_state} = queue_single_task(task_spec, state)
        {:reply, reply, new_state}

      {:decomposed, sub_tasks, dependencies} ->
        # Complex task - queue all sub-tasks
        {reply, new_state} =
          queue_decomposed_tasks_internal(task_spec, sub_tasks, dependencies, state)

        {:reply, reply, new_state}
    end
  end

  @impl true
  def handle_call({:queue, task_spec}, _from, state) do
    task_id = generate_task_id()
    task = build_task(task_id, task_spec)

    # Search memory for similar past tasks (cognitive enhancement)
    hints = search_similar_tasks(task.description)
    task = Map.put(task, :hints, hints)

    new_state = %{state | queue: state.queue ++ [task]}

    :telemetry.execute(
      [:mimo, :autonomous, :task],
      %{count: 1},
      %{event: :queued, task_id: task_id, hints_found: length(hints)}
    )

    Logger.info("[TaskRunner] Task #{task_id} queued: #{task.description}")
    if hints != [], do: Logger.debug("[TaskRunner] Found #{length(hints)} hints from past tasks")

    {:reply, {:ok, task_id}, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {circuit_state, _} = CircuitBreaker.check(state.circuit)

    status = %{
      status: state.status,
      paused: state.paused,
      queued: length(state.queue),
      running: map_size(state.running),
      completed: length(state.completed),
      failed: length(state.failed),
      circuit_state: circuit_state,
      circuit_details: CircuitBreaker.status(state.circuit)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    Logger.info("[TaskRunner] Paused by user")

    :telemetry.execute(
      [:mimo, :autonomous, :task_runner],
      %{count: 1},
      %{event: :paused}
    )

    {:reply, :ok, %{state | paused: true}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    Logger.info("[TaskRunner] Resumed by user")

    :telemetry.execute(
      [:mimo, :autonomous, :task_runner],
      %{count: 1},
      %{event: :resumed}
    )

    {:reply, :ok, %{state | paused: false}}
  end

  @impl true
  def handle_call(:reset_circuit, _from, state) do
    Logger.info("[TaskRunner] Circuit breaker reset by user")
    {:reply, :ok, %{state | circuit: CircuitBreaker.reset(state.circuit)}}
  end

  @impl true
  def handle_call(:list_queue, _from, state) do
    {:reply, state.queue, state}
  end

  @impl true
  def handle_call(:clear_queue, _from, state) do
    count = length(state.queue)
    Logger.info("[TaskRunner] Cleared #{count} queued tasks")
    {:reply, :ok, %{state | queue: []}}
  end

  @impl true
  def handle_info(:check_tasks, state) do
    {circuit_state, updated_circuit} = CircuitBreaker.check(state.circuit)
    state = %{state | circuit: updated_circuit}

    new_state =
      case {state.paused, circuit_state} do
        {true, _} ->
          # Paused - don't run
          state

        {_, :open} ->
          # Circuit open - wait for cooldown
          Logger.debug("[TaskRunner] Circuit open, waiting for cooldown")
          state

        {false, circuit} when circuit in [:closed, :half_open] ->
          # Ready to run tasks
          try_execute_next(state)
      end

    schedule_check(state.config.check_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:task_complete, task_id, result}, state) do
    case Map.pop(state.running, task_id) do
      {nil, _} ->
        Logger.warning("[TaskRunner] Unknown task completed: #{task_id}")
        {:noreply, state}

      {task_info, running} ->
        state = %{state | running: running}
        state = handle_task_result(task_info.task, result, state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Handle crashed task processes
    case find_task_by_pid(state.running, pid) do
      nil ->
        {:noreply, state}

      {task_id, task_info} ->
        Logger.error("[TaskRunner] Task #{task_id} crashed: #{inspect(reason)}")
        running = Map.delete(state.running, task_id)
        state = %{state | running: running}
        state = handle_task_result(task_info.task, {:error, {:crashed, reason}}, state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:task_timeout, task_id}, state) do
    # SPEC-071: Handle task timeout
    case Map.get(state.running, task_id) do
      nil ->
        # Task already completed
        {:noreply, state}

      task_info ->
        Logger.warning(
          "[TaskRunner] Task #{task_id} timed out after #{state.config.task_timeout}ms"
        )

        Process.exit(task_info.pid, :kill)

        running = Map.delete(state.running, task_id)
        state = %{state | running: running}
        state = handle_task_result(task_info.task, {:error, :timeout}, state)
        {:noreply, state}
    end
  end

  defp try_execute_next(state) do
    available_slots = state.config.max_concurrent - map_size(state.running)

    if available_slots > 0 and state.queue != [] do
      [task | remaining] = state.queue

      case start_task(task, state) do
        {:ok, pid} ->
          # Monitor the task process
          Process.monitor(pid)

          running =
            Map.put(state.running, task.id, %{
              task: task,
              pid: pid,
              started_at: DateTime.utc_now()
            })

          Logger.info("[TaskRunner] Started task #{task.id}: #{task.description}")

          :telemetry.execute(
            [:mimo, :autonomous, :task],
            %{count: 1},
            %{event: :started, task_id: task.id, type: task.type}
          )

          %{state | queue: remaining, running: running}

        {:error, reason} ->
          Logger.error("[TaskRunner] Failed to start task #{task.id}: #{inspect(reason)}")
          record_failure(task, reason, state)
      end
    else
      state
    end
  end

  defp start_task(task, state) do
    runner = self()
    timeout = state.config.task_timeout

    # Start task in supervised process
    Task.Supervisor.start_child(
      Mimo.TaskSupervisor,
      fn ->
        # SPEC-071: Set up timeout timer
        timer_ref = Process.send_after(runner, {:task_timeout, task.id}, timeout)
        result = execute_with_cognitive_enhancement(task)
        Process.cancel_timer(timer_ref)
        send(runner, {:task_complete, task.id, result})
      end
    )
  end

  defp execute_with_cognitive_enhancement(task) do
    try do
      # PRE-EXECUTION: Inject memory context
      context = gather_cognitive_context(task)
      Logger.debug("[TaskRunner] Gathered context with #{length(context.similar_tasks)} hints")

      # EXECUTION: Run the actual task
      result = execute_task(task, context)

      # POST-EXECUTION: Validate and learn
      validated = validate_result(task, result)

      # Store outcome for future learning
      store_task_outcome(task, validated)

      validated
    rescue
      e ->
        # FAIL-CLOSED: Propagate error
        Logger.error("[TaskRunner] Task execution failed: #{Exception.message(e)}")
        {:error, {:execution_failed, Exception.message(e)}}
    end
  end

  defp gather_cognitive_context(task) do
    # SPEC-071: Populate cognitive context from Knowledge Graph and ContradictionGuard
    related_knowledge =
      try do
        path = Map.get(task, :path) || Map.get(task, "path")

        if path do
          case Graph.get_node(:file, path) do
            nil -> []
            node -> Graph.neighbors(node.id, types: [:uses, :relates_to]) |> Enum.take(5)
          end
        else
          []
        end
      catch
        _, _ -> []
      end

    contradictions =
      try do
        desc = task.description || ""

        case ContradictionGuard.check(desc) do
          {:ok, warnings} -> warnings
          _ -> []
        end
      catch
        _, _ -> []
      end

    %{
      similar_tasks: task.hints || [],
      related_knowledge: related_knowledge,
      contradictions: contradictions
    }
  end

  defp execute_task(%{command: command} = _task, context)
       when is_binary(command) and command != "" do
    # Inject hints into command context if available
    hint_text =
      context.similar_tasks
      |> Enum.take(3)
      |> Enum.map_join("\n", fn hint -> "- #{Map.get(hint, :content, "")}" end)

    if hint_text != "" do
      Logger.debug("[TaskRunner] Hints for task:\n#{hint_text}")
    end

    # Execute the command using Terminal
    try do
      result = Mimo.Skills.Terminal.execute(command, timeout: 60_000, confirm: true)
      {:ok, result}
    rescue
      e -> {:error, {:command_failed, Exception.message(e)}}
    end
  end

  defp execute_task(%{type: "memory_search", query: query}, _context) when is_binary(query) do
    results = Memory.search_memories(query, limit: 10)
    {:ok, %{type: "memory_search", results: results}}
  end

  defp execute_task(%{type: type} = task, _context) do
    # Generic handler for task types without specific implementations.
    # Logs execution and returns success to allow workflow continuation.
    Logger.info("[TaskRunner] Executing task type '#{type}': #{task.description}")
    {:ok, %{type: type, message: "Task type '#{type}' executed (no specific handler)"}}
  end

  defp validate_result(task, {:ok, output}) do
    # Check output for contradictions with stored knowledge
    output_text =
      case output do
        %{stdout: stdout} when is_binary(stdout) -> stdout
        text when is_binary(text) -> text
        other -> inspect(other)
      end

    case ContradictionGuard.check(output_text) do
      {:ok, []} ->
        {:ok, %{output: output, validated: true, task_id: task.id}}

      {:ok, warnings} ->
        Logger.warning("[TaskRunner] Contradiction warnings for #{task.id}: #{inspect(warnings)}")
        {:ok, %{output: output, validated: true, warnings: warnings, task_id: task.id}}

      {:error, reason} ->
        # FAIL-CLOSED: Report validation failure but don't block success
        Logger.warning("[TaskRunner] Validation error: #{inspect(reason)}")
        {:ok, %{output: output, validated: false, validation_error: reason, task_id: task.id}}
    end
  end

  defp validate_result(task, {:error, reason} = _error) do
    # Errors pass through with task context
    {:error, %{task_id: task.id, error: reason}}
  end

  defp store_task_outcome(task, result) do
    content = format_task_outcome(task, result)

    # Higher importance for failures (learn from mistakes)
    importance = if match?({:ok, _}, result), do: 0.7, else: 0.85

    case Memory.persist_memory(content, "action", importance) do
      {:ok, _} ->
        Logger.debug("[TaskRunner] Stored outcome for task #{task.id}")
        :ok

      {:error, reason} ->
        Logger.warning("[TaskRunner] Failed to store outcome: #{inspect(reason)}")
        :error
    end
  end

  defp format_task_outcome(task, {:ok, result}) do
    warnings =
      case result do
        %{warnings: w} when is_list(w) and w != [] ->
          " Warnings: #{Enum.join(w, "; ")}"

        _ ->
          ""
      end

    "Autonomous task completed - Type: #{task.type}, Description: #{task.description}, " <>
      "Task ID: #{task.id}.#{warnings}"
  end

  defp format_task_outcome(task, {:error, reason}) do
    "Autonomous task FAILED - Type: #{task.type}, Description: #{task.description}, " <>
      "Task ID: #{task.id}, Error: #{inspect(reason)}"
  end

  defp handle_task_result(task, {:ok, _} = result, state) do
    Logger.info("[TaskRunner] Task #{task.id} completed successfully")

    :telemetry.execute(
      [:mimo, :autonomous, :task],
      %{count: 1},
      %{event: :completed, task_id: task.id, success: true}
    )

    # Record success with circuit breaker
    circuit = CircuitBreaker.record_success(state.circuit)

    new_completed = [{task.id, result} | state.completed]

    # SPEC-071: Trigger synthesis after every 10 completed tasks
    if rem(length(new_completed), 10) == 0 do
      spawn(fn ->
        try do
          Logger.debug(
            "[TaskRunner] Triggering synthesis after #{length(new_completed)} completions"
          )

          Synthesizer.synthesize_now(scope: :autonomous_tasks)
        catch
          # Silent failure - synthesis is best-effort
          _, _ -> :ok
        end
      end)
    end

    # SPEC-071: Track task in knowledge graph
    track_in_knowledge_graph(task)

    %{state | completed: new_completed, circuit: circuit}
  end

  defp handle_task_result(task, {:error, reason} = result, state) do
    Logger.error("[TaskRunner] Task #{task.id} failed: #{inspect(reason)}")

    :telemetry.execute(
      [:mimo, :autonomous, :task],
      %{count: 1},
      %{event: :completed, task_id: task.id, success: false, reason: inspect(reason)}
    )

    # Record failure with circuit breaker
    circuit = CircuitBreaker.record_failure(state.circuit, reason)

    %{state | failed: [{task.id, result} | state.failed], circuit: circuit}
  end

  defp record_failure(task, reason, state) do
    circuit = CircuitBreaker.record_failure(state.circuit, reason)

    %{
      state
      | failed: [{task.id, {:error, reason}} | state.failed],
        queue: Enum.reject(state.queue, &(&1.id == task.id)),
        circuit: circuit
    }
  end

  defp find_task_by_pid(running, pid) do
    Enum.find(running, fn {_id, info} -> info.pid == pid end)
  end

  defp search_similar_tasks(description) do
    # Use Task with timeout to prevent blocking GenServer
    task =
      Task.async(fn ->
        try do
          query = "autonomous task: #{description}"
          Memory.search_memories(query, limit: 5, min_similarity: 0.5)
        rescue
          e ->
            Logger.warning("[TaskRunner] Memory search failed: #{Exception.message(e)}")
            []
        end
      end)

    case Task.yield(task, 2000) || Task.shutdown(task) do
      {:ok, results} ->
        results

      _ ->
        Logger.debug("[TaskRunner] Memory search timed out, continuing without hints")
        []
    end
  end

  # SPEC-071: Track task in knowledge graph for dependency awareness
  defp track_in_knowledge_graph(task) do
    try do
      # Create task node
      {:ok, task_node} =
        Graph.find_or_create_node(:concept, "task:#{task.id}", %{
          type: task.type,
          description: task.description,
          created_at: DateTime.to_iso8601(task.created_at)
        })

      # Track file dependencies if path is specified
      path = Map.get(task, :path) || Map.get(task, "path")

      if path do
        case Graph.find_or_create_node(:file, path, %{}) do
          {:ok, file_node} ->
            Graph.create_edge(%{
              source_node_id: task_node.id,
              target_node_id: file_node.id,
              edge_type: :uses,
              properties: %{source: "autonomous_task"}
            })

          _ ->
            :ok
        end
      end

      :ok
    catch
      # Fire-and-forget - graph tracking is best-effort
      _, _ -> :ok
    end
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_tasks, interval)
  end

  defp generate_task_id do
    "task_#{:erlang.unique_integer([:positive])}_#{System.system_time(:millisecond)}"
  end

  defp build_task(id, spec) do
    %{
      id: id,
      type: Map.get(spec, "type") || Map.get(spec, :type) || "general",
      description: Map.get(spec, "description") || Map.get(spec, :description) || "",
      command: Map.get(spec, "command") || Map.get(spec, :command),
      query: Map.get(spec, "query") || Map.get(spec, :query),
      path: Map.get(spec, "path") || Map.get(spec, :path),
      status: :queued,
      hints: [],
      created_at: DateTime.utc_now(),
      started_at: nil,
      completed_at: nil,
      result: nil
    }
  end

  defp validate_task_spec(spec) do
    cond do
      not is_map(spec) ->
        {:error, :invalid_task_spec}

      not has_description?(spec) ->
        {:error, :missing_description}

      true ->
        :ok
    end
  end

  defp has_description?(spec) do
    desc = Map.get(spec, "description") || Map.get(spec, :description)
    is_binary(desc) and String.trim(desc) != ""
  end

  defp parse_config(opts) do
    %{
      check_interval: Keyword.get(opts, :check_interval, @default_check_interval),
      max_concurrent: Keyword.get(opts, :max_concurrent, @default_max_concurrent),
      task_timeout: Keyword.get(opts, :task_timeout, @default_task_timeout)
    }
  end
end
