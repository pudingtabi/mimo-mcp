defmodule Mimo.Tools.Dispatchers.Terminal do
  @moduledoc """
  Terminal operations dispatcher.

  Handles all terminal/process operations:
  - execute: Run a command
  - start_process: Start a background process
  - read_output: Read process output (calls Terminal.read_process_output/2)
  - interact: Send input to process (calls Terminal.interact_with_process/2)
  - kill: Graceful kill (calls Terminal.kill_process/1)
  - force_kill: Force terminate (calls Terminal.force_terminate/1)
  - list_sessions: List terminal sessions
  - list_processes: List running processes

  IMPORTANT: Function name mappings from SPEC-030:
  - "read_output" -> Terminal.read_process_output (NOT read_output!)
  - "force_kill" -> Terminal.force_terminate (NOT force_kill_process!)
  """

  alias Mimo.Tools.{Helpers, Suggestions}

  @doc """
  Dispatch terminal operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "execute"
    command = args["command"] || ""
    skip_context = Map.get(args, "skip_memory_context", false)

    result =
      case op do
        "execute" ->
          dispatch_execute(command, args, skip_context)

        "start_process" ->
          dispatch_start_process(command, args)

        "read_output" ->
          # CORRECT: Terminal.read_process_output (NOT read_output!)
          Mimo.Skills.Terminal.read_process_output(args["pid"], timeout_ms: args["timeout"] || 1000)

        "interact" ->
          # CORRECT: Terminal.interact_with_process (NOT interact!)
          Mimo.Skills.Terminal.interact_with_process(args["pid"], args["input"] || "")

        "kill" ->
          Mimo.Skills.Terminal.kill_process(args["pid"])

        "force_kill" ->
          # CORRECT: Terminal.force_terminate (NOT force_kill_process!)
          Mimo.Skills.Terminal.force_terminate(args["pid"])

        "list_sessions" ->
          Mimo.Skills.Terminal.list_sessions()

        "list_processes" ->
          Mimo.Skills.Terminal.list_processes()

        _ ->
          {:error, "Unknown terminal operation: #{op}"}
      end

    # Add cross-tool suggestions (SPEC-031 Phase 2)
    Suggestions.maybe_add_suggestion(result, "terminal", args)
  end

  # ==========================================================================
  # PRIVATE HELPERS
  # ==========================================================================

  defp dispatch_execute(command, args, skip_context) do
    timeout = args["timeout"] || 30_000
    yolo = Map.get(args, "yolo", false)
    confirm = Map.get(args, "confirm", false) || yolo
    cwd = args["cwd"]
    env = args["env"]
    shell = args["shell"]
    name = args["name"]

    opts = [
      timeout: timeout,
      yolo: yolo,
      confirm: confirm
    ]

    # Add optional params if provided
    opts = if cwd, do: Keyword.put(opts, :cwd, cwd), else: opts
    opts = if env, do: Keyword.put(opts, :env, env), else: opts
    opts = if shell, do: Keyword.put(opts, :shell, shell), else: opts
    opts = if name, do: Keyword.put(opts, :name, name), else: opts

    result = {:ok, Mimo.Skills.Terminal.execute(command, opts)}
    # Enrich with memory context for accuracy (Layer 2)
    Helpers.enrich_terminal_response(result, command, skip_context)
  end

  defp dispatch_start_process(command, args) do
    name = args["name"]
    opts = [timeout_ms: args["timeout"] || 5000]
    opts = if name, do: Keyword.put(opts, :name, name), else: opts
    Mimo.Skills.Terminal.start_process(command, opts)
  end
end
