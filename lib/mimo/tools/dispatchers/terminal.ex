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

  SPEC-087: Wired to OutcomeDetector for feedback loop closure.
  """

  alias Mimo.Cognitive.{FeedbackLoop, OutcomeDetector}
  alias Mimo.Tools.{Helpers, Suggestions}
  alias Mimo.Skills.Terminal, as: TerminalSkill
  alias Mimo.Utils.InputValidation

  @doc """
  Dispatch terminal operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "execute"
    command = args["command"] || ""
    skip_context = Map.get(args, "skip_memory_context", true)

    result =
      case op do
        "execute" ->
          dispatch_execute(command, args, skip_context)

        "start_process" ->
          dispatch_start_process(command, args)

        "read_output" ->
          # CORRECT: Terminal.read_process_output (NOT read_output!)
          timeout = InputValidation.validate_timeout(args["timeout"], default: 1000)
          TerminalSkill.read_process_output(args["pid"], timeout_ms: timeout)

        "interact" ->
          # CORRECT: Terminal.interact_with_process (NOT interact!)
          TerminalSkill.interact_with_process(args["pid"], args["input"] || "")

        "kill" ->
          TerminalSkill.kill_process(args["pid"])

        "force_kill" ->
          # CORRECT: Terminal.force_terminate (NOT force_kill_process!)
          TerminalSkill.force_terminate(args["pid"])

        "list_sessions" ->
          TerminalSkill.list_sessions()

        "list_processes" ->
          TerminalSkill.list_processes()

        _ ->
          {:error, "Unknown terminal operation: #{op}"}
      end

    # Add cross-tool suggestions (SPEC-031 Phase 2)
    Suggestions.maybe_add_suggestion(result, "terminal", args)
  end

  defp dispatch_execute(command, args, skip_context) do
    # Validate timeout (default 30s, max 5min)
    timeout = InputValidation.validate_timeout(args["timeout"], default: 30_000, max: 300_000)
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

    raw_result = TerminalSkill.execute(command, opts)

    # SPEC-087: Detect outcome and record to feedback loop
    record_terminal_outcome(command, raw_result)

    result = {:ok, raw_result}
    # Enrich with memory context for accuracy (Layer 2)
    Helpers.enrich_terminal_response(result, command, skip_context)
  end

  # SPEC-087: Record terminal execution outcome to feedback loop
  defp record_terminal_outcome(command, %{status: exit_code, output: output} = _result) do
    # Generate session ID for memory correlation
    session_id = generate_session_id(command)

    # Detect outcome using OutcomeDetector
    detection = OutcomeDetector.detect_terminal(exit_code, output || "")

    # Build context for FeedbackLoop (includes session_id for memory correlation)
    context = %{
      command: command,
      exit_code: exit_code,
      signal_type: detection.signal_type,
      output_length: String.length(output || ""),
      session_id: session_id
    }

    # Build outcome for FeedbackLoop
    outcome = %{
      success: detection.outcome == :success,
      outcome: detection.outcome,
      confidence: detection.confidence,
      signals: detection.signals,
      details: detection.details
    }

    # Record asynchronously (non-blocking)
    FeedbackLoop.record_outcome(:tool_execution, context, outcome)
  rescue
    # Don't let outcome detection failures break tool execution
    _ -> :ok
  end

  defp record_terminal_outcome(_command, _result), do: :ok

  # Generate a session ID for correlating memory retrievals with outcomes
  defp generate_session_id(command) do
    timestamp = System.system_time(:millisecond)
    hash = :erlang.phash2({command, timestamp})
    "term_#{hash}"
  end

  defp dispatch_start_process(command, args) do
    name = args["name"]
    timeout = InputValidation.validate_timeout(args["timeout"], default: 5000)
    opts = [timeout_ms: timeout]
    opts = if name, do: Keyword.put(opts, :name, name), else: opts
    TerminalSkill.start_process(command, opts)
  end
end
