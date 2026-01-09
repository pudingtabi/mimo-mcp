defmodule Mimo.Brain.ErrorPredictor do
  @moduledoc """
  DEMAND 4: Predictive Error Detection for Small Models

  Analyzes planned actions BEFORE execution to detect common mistakes
  and stop them before they happen.

  ## How It Works

  1. Before major actions, analyze the plan/intent
  2. Check against known failure patterns from emergence system
  3. Check against heuristic rules (Haiku's common mistakes)
  4. Check against LEARNED failure patterns from actual failures (Phase 3)
  5. Return warnings and mandatory checkpoints

  ## Phase 3 Learning Integration

  ErrorPredictor now learns from actual failures:
  - Listens to [:mimo, :learning, :outcome] telemetry with success=false
  - Stores failure patterns in ETS with context and error details
  - Uses learned patterns to warn about similar actions in the future

  ## Usage

      # Before executing a file edit
      {:warnings, warnings} = ErrorPredictor.analyze_before_action(:file_edit, %{
        path: "lib/foo.ex",
        changes: "..."
      })

      # Before committing changes
      {:checkpoints, checkpoints} = ErrorPredictor.mandatory_checkpoints(:commit)

      # Get learned failure stats
      ErrorPredictor.stats()
  """

  require Logger

  alias Mimo.Brain.Emergence.Pattern

  @type action_type ::
          :file_edit | :terminal_command | :commit | :deploy | :refactor | :debug | :implement

  # ETS table for learned failure patterns (Phase 3)
  @learned_patterns_table :mimo_error_predictor_learned

  # Maximum learned patterns to keep (prevent unbounded growth)
  @max_learned_patterns 500

  # Pattern expiry in days
  @pattern_expiry_days 30

  # Known failure patterns from Haiku's C+ grade session
  @haiku_mistakes [
    %{
      id: :skip_compile,
      description: "Skipping compilation after code changes",
      checkpoint: "Run `mix compile` or equivalent after changes",
      severity: :high
    },
    %{
      id: :skip_tests,
      description: "Not running tests after changes",
      checkpoint: "Run test suite before declaring done",
      severity: :high
    },
    %{
      id: :leave_debug_code,
      description: "Leaving debug/logging code in production",
      checkpoint: "Remove debug code and test wrappers",
      severity: :medium
    },
    %{
      id: :cascade_blindness,
      description: "Not tracing errors back through cascade chains",
      checkpoint: "Trace error cascades backward to find root cause",
      severity: :high
    },
    %{
      id: :struct_access,
      description: "Using dot notation on potentially nil structs",
      checkpoint: "Use defensive Map.get for struct field access",
      severity: :medium
    },
    %{
      id: :duplicate_code,
      description: "Leaving duplicate code blocks after refactoring",
      checkpoint: "Search for and remove any duplicate implementations",
      severity: :medium
    }
  ]

  @doc """
  Analyze an action before execution and return warnings.
  """
  @spec analyze_before_action(action_type(), map()) :: {:warnings, list(map())}
  def analyze_before_action(action_type, context \\ %{}) do
    warnings =
      []
      |> add_action_specific_warnings(action_type, context)
      |> add_pattern_based_warnings(action_type, context)
      |> add_heuristic_warnings(action_type, context)
      |> Enum.uniq_by(& &1.id)

    {:warnings, warnings}
  end

  @doc """
  Get mandatory checkpoints for an action type.
  These MUST be verified before proceeding.
  """
  @spec mandatory_checkpoints(action_type()) :: {:checkpoints, list(map())}
  def mandatory_checkpoints(action_type) do
    checkpoints =
      case action_type do
        :file_edit ->
          [
            %{id: :compile, action: "Run `mix compile` to verify syntax", required: true},
            %{id: :format, action: "Run formatter to ensure style", required: false}
          ]

        :commit ->
          [
            %{id: :compile, action: "Run `mix compile` to verify syntax", required: true},
            %{id: :tests, action: "Run `mix test` to verify functionality", required: true},
            %{id: :debug_removed, action: "Verify no debug code left behind", required: true},
            %{
              id: :duplicates_removed,
              action: "Verify no duplicate code blocks",
              required: true
            }
          ]

        :deploy ->
          [
            %{id: :tests, action: "Run full test suite", required: true},
            %{id: :build, action: "Verify production build succeeds", required: true},
            %{id: :rollback_plan, action: "Have rollback procedure ready", required: true}
          ]

        :refactor ->
          [
            %{id: :compile, action: "Run `mix compile` after each step", required: true},
            %{id: :tests, action: "Run tests after each step", required: true},
            %{id: :duplicates, action: "Remove all old implementations", required: true}
          ]

        :debug ->
          [
            %{
              id: :cascade_trace,
              action: "Trace error backward through cascades",
              required: true
            },
            %{id: :root_cause, action: "Identify root cause before fixing", required: true},
            %{id: :verify_fix, action: "Verify fix with `mix compile`", required: true}
          ]

        :implement ->
          [
            %{id: :compile, action: "Run `mix compile` after implementation", required: true},
            %{id: :tests, action: "Run relevant tests", required: true},
            %{id: :coverage, action: "Consider adding new tests if needed", required: false}
          ]

        _ ->
          [
            %{id: :compile, action: "Run `mix compile` to verify", required: true}
          ]
      end

    {:checkpoints, checkpoints}
  end

  @doc """
  Generate a pre-action checklist based on context.
  """
  @spec generate_checklist(action_type(), map()) :: map()
  def generate_checklist(action_type, context \\ %{}) do
    {:warnings, warnings} = analyze_before_action(action_type, context)
    {:checkpoints, checkpoints} = mandatory_checkpoints(action_type)

    # Get relevant Haiku mistakes
    relevant_mistakes =
      @haiku_mistakes
      |> Enum.filter(fn m -> relevant_to_action?(m.id, action_type) end)

    %{
      action: action_type,
      warnings: warnings,
      checkpoints: checkpoints,
      haiku_lessons: relevant_mistakes,
      formatted: format_checklist(action_type, warnings, checkpoints, relevant_mistakes)
    }
  end

  @doc """
  Quick check: should this action be blocked?
  Returns true if there are high-severity warnings.
  """
  @spec should_block?(action_type(), map()) :: boolean()
  def should_block?(action_type, context \\ %{}) do
    {:warnings, warnings} = analyze_before_action(action_type, context)
    Enum.any?(warnings, fn w -> w.severity == :critical end)
  end

  defp add_action_specific_warnings(warnings, :file_edit, context) do
    path = Map.get(context, :path, "")
    changes = Map.get(context, :changes, "")

    new_warnings = []

    # Check for Ecto patterns
    new_warnings =
      if String.contains?(path, ["repo", "schema", "ecto"]) or
           String.contains?(changes, ["Repo.", "Ecto."]) do
        [
          %{
            id: :ecto_pattern,
            severity: :medium,
            message: "Ecto code detected. Use defensive Map.get for struct access.",
            suggestion: "Replace `struct.field` with `Map.get(struct, :field)`"
          }
          | new_warnings
        ]
      else
        new_warnings
      end

    # Check for debug code
    new_warnings =
      if String.contains?(changes, ["IO.inspect", "Logger.debug", "dbg(", "IEx.pry"]) do
        [
          %{
            id: :debug_code,
            severity: :medium,
            message: "Debug code detected. Remember to remove before commit.",
            suggestion: "Use `@tag :debug` for temporary code to track removal"
          }
          | new_warnings
        ]
      else
        new_warnings
      end

    warnings ++ new_warnings
  end

  defp add_action_specific_warnings(warnings, :terminal_command, context) do
    command = Map.get(context, :command, "")

    new_warnings = []

    # Check for dangerous commands
    new_warnings =
      if String.contains?(command, ["rm -rf", "drop database", "DELETE FROM", "truncate"]) do
        [
          %{
            id: :destructive_command,
            severity: :critical,
            message: "⚠️ DESTRUCTIVE COMMAND DETECTED. This cannot be undone.",
            suggestion: "Verify target carefully. Consider backup first."
          }
          | new_warnings
        ]
      else
        new_warnings
      end

    warnings ++ new_warnings
  end

  defp add_action_specific_warnings(warnings, :debug, _context) do
    [
      %{
        id: :cascade_warning,
        severity: :medium,
        message: "Debugging session. Remember to trace cascades backward.",
        suggestion: "Find root cause first, don't fix symptoms."
      }
      | warnings
    ]
  end

  defp add_action_specific_warnings(warnings, _action_type, _context), do: warnings

  defp add_pattern_based_warnings(warnings, action_type, context) do
    # Search for relevant failure patterns from emergence system
    action_string = to_string(action_type)
    query = "#{action_string} #{Map.get(context, :description, "")}"

    emergence_warnings =
      case Pattern.search_by_description(query, limit: 3) do
        patterns when is_list(patterns) ->
          patterns
          |> Enum.filter(fn p -> (p.success_rate || 1.0) < 0.7 end)
          |> Enum.map(fn p ->
            %{
              id: String.to_atom("pattern_#{p.id}"),
              severity: :medium,
              message: "Pattern warning: #{p.description}",
              suggestion:
                "This pattern has #{Float.round((p.success_rate || 0) * 100, 1)}% success rate"
            }
          end)

        _ ->
          []
      end

    # Phase 3: Also check learned failure patterns from actual failures
    learned_warnings =
      get_learned_patterns(action_type)
      |> Enum.map(fn pattern ->
        %{
          id: String.to_atom("learned_#{pattern.id}"),
          severity: if(pattern.occurrences >= 3, do: :high, else: :medium),
          message: "Learned failure: #{pattern.error_excerpt}",
          suggestion:
            "This type of failure has occurred #{pattern.occurrences} time(s) in similar actions"
        }
      end)

    warnings ++ emergence_warnings ++ learned_warnings
  rescue
    _ -> warnings
  end

  defp add_heuristic_warnings(warnings, action_type, context) do
    # Add relevant Haiku mistakes as warnings
    haiku_warnings =
      @haiku_mistakes
      |> Enum.filter(fn m -> relevant_to_action?(m.id, action_type) end)
      |> Enum.map(fn m ->
        %{
          id: m.id,
          severity: m.severity,
          message: "Haiku lesson: #{m.description}",
          suggestion: m.checkpoint
        }
      end)

    # Check for specific patterns in context
    description = Map.get(context, :description, "") |> String.downcase()

    additional_warnings =
      cond do
        String.contains?(description, ["quick", "fast", "just"]) ->
          [
            %{
              id: :rushing_detected,
              severity: :medium,
              message: "\"Quick\" language detected. Rushing leads to mistakes.",
              suggestion: "Take time to verify. Use reason (guided) first."
            }
          ]

        String.contains?(description, ["easy", "simple", "obvious"]) ->
          [
            %{
              id: :overconfidence_detected,
              severity: :low,
              message: "Overconfidence language detected.",
              suggestion: "Even \"simple\" changes can have unexpected effects."
            }
          ]

        true ->
          []
      end

    warnings ++ haiku_warnings ++ additional_warnings
  end

  defp relevant_to_action?(mistake_id, action_type) do
    mapping = %{
      skip_compile: [:file_edit, :implement, :refactor, :commit],
      skip_tests: [:implement, :refactor, :commit, :deploy],
      leave_debug_code: [:file_edit, :implement, :commit],
      cascade_blindness: [:debug],
      struct_access: [:file_edit, :implement, :refactor],
      duplicate_code: [:refactor, :commit]
    }

    action_type in (Map.get(mapping, mistake_id) || [])
  end

  defp format_checklist(action_type, warnings, checkpoints, haiku_lessons) do
    sections = ["# Pre-#{action_type} Checklist\n"]

    # Warnings section
    sections =
      if Enum.empty?(warnings) do
        sections
      else
        warning_lines =
          Enum.map(warnings, fn w ->
            icon = severity_icon(w.severity)
            "#{icon} **#{w.message}**\n   → #{w.suggestion}"
          end)

        sections ++ ["## ⚠️ Warnings\n" <> Enum.join(warning_lines, "\n")]
      end

    # Checkpoints section
    checkpoint_lines =
      Enum.map(checkpoints, fn c ->
        required = if c.required, do: "(REQUIRED)", else: "(optional)"
        "- [ ] #{c.action} #{required}"
      end)

    sections = sections ++ ["## ✅ Mandatory Checkpoints\n" <> Enum.join(checkpoint_lines, "\n")]

    # Haiku lessons section
    sections =
      if Enum.empty?(haiku_lessons) do
        sections
      else
        lesson_lines = Enum.map(haiku_lessons, fn l -> "- #{l.description}: #{l.checkpoint}" end)
        sections ++ ["## 📚 Lessons from Past Sessions\n" <> Enum.join(lesson_lines, "\n")]
      end

    Enum.join(sections, "\n\n")
  end

  defp severity_icon(:critical), do: "🚨"
  defp severity_icon(:high), do: "⚠️"
  defp severity_icon(:medium), do: "⚡"
  defp severity_icon(:low), do: "💡"
  defp severity_icon(_), do: "ℹ️"

  # ============================================================================
  # PHASE 3: Learning from Actual Failures
  # ============================================================================

  @doc """
  Initialize the learned patterns ETS table.
  Should be called from Application supervision tree.
  """
  @spec init_learning() :: :ok
  def init_learning do
    if :ets.whereis(@learned_patterns_table) == :undefined do
      :ets.new(@learned_patterns_table, [:named_table, :public, :set])
      Logger.info("[ErrorPredictor] Phase 3 learning initialized")

      # Attach to failure telemetry
      :telemetry.attach(
        "error-predictor-learning",
        [:mimo, :learning, :outcome],
        &__MODULE__.handle_learning_outcome/4,
        nil
      )
    end

    :ok
  rescue
    ArgumentError ->
      # Table already exists
      :ok
  end

  @doc """
  Get statistics about learned patterns.
  """
  @spec stats() :: map()
  def stats do
    init_learning()

    patterns =
      try do
        :ets.tab2list(@learned_patterns_table)
      rescue
        _ -> []
      end

    by_action_type =
      Enum.group_by(patterns, fn {_key, pattern} -> pattern.action_type end)
      |> Enum.map(fn {action, pats} -> {action, length(pats)} end)
      |> Map.new()

    %{
      total_learned_patterns: length(patterns),
      by_action_type: by_action_type,
      static_haiku_patterns: length(@haiku_mistakes),
      max_patterns: @max_learned_patterns,
      pattern_expiry_days: @pattern_expiry_days
    }
  end

  @doc """
  Record a failure pattern for learning.
  Called when a tool execution fails.
  """
  @spec record_failure(action_type(), map(), String.t()) :: :ok
  def record_failure(action_type, context, error_message) do
    init_learning()

    pattern_id = generate_pattern_id(action_type, context, error_message)

    pattern = %{
      id: pattern_id,
      action_type: action_type,
      context_keys: Map.keys(context),
      error_excerpt: String.slice(error_message, 0, 200),
      occurrences: 1,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    # Update existing or insert new
    case :ets.lookup(@learned_patterns_table, pattern_id) do
      [{^pattern_id, existing}] ->
        updated = %{
          existing
          | occurrences: existing.occurrences + 1,
            updated_at: DateTime.utc_now()
        }

        :ets.insert(@learned_patterns_table, {pattern_id, updated})

      [] ->
        # Check if we need to evict old patterns
        maybe_evict_old_patterns()
        :ets.insert(@learned_patterns_table, {pattern_id, pattern})
    end

    Logger.debug("[ErrorPredictor] Learned failure pattern: #{action_type}")
    :ok
  rescue
    e ->
      Logger.warning("[ErrorPredictor] Failed to record failure: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Handle learning outcome telemetry from FeedbackBridge.
  Records failures for future prediction.
  """
  def handle_learning_outcome(_event, _measurements, metadata, _config) do
    success = Map.get(metadata, :success, true)

    unless success do
      # Extract context for pattern learning
      context = Map.get(metadata, :context, %{})
      action_type = detect_action_type(context)
      error_message = extract_error_message(context)

      if action_type && error_message do
        record_failure(action_type, context, error_message)
      end
    end
  rescue
    _ -> :ok
  end

  @doc """
  Get learned patterns relevant to an action.
  """
  @spec get_learned_patterns(action_type()) :: [map()]
  def get_learned_patterns(action_type) do
    init_learning()

    try do
      cutoff = DateTime.utc_now() |> DateTime.add(-@pattern_expiry_days, :day)

      :ets.tab2list(@learned_patterns_table)
      |> Enum.filter(fn {_key, pattern} ->
        pattern.action_type == action_type and
          DateTime.compare(pattern.updated_at, cutoff) == :gt
      end)
      |> Enum.map(fn {_key, pattern} -> pattern end)
      |> Enum.sort_by(& &1.occurrences, :desc)
      |> Enum.take(5)
    rescue
      _ -> []
    end
  end

  # Generate a unique pattern ID based on action type and error characteristics
  defp generate_pattern_id(action_type, context, error_message) do
    # Extract key identifying features
    path = Map.get(context, :path, "")
    command = Map.get(context, :command, "")

    # Create a fingerprint
    fingerprint_data = [
      to_string(action_type),
      Path.extname(path),
      extract_error_type(error_message),
      if(String.length(command) > 0, do: "cmd", else: "")
    ]

    :crypto.hash(:md5, Enum.join(fingerprint_data, ":"))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp extract_error_type(error_message) do
    cond do
      String.contains?(error_message, "undefined function") -> "undefined_function"
      String.contains?(error_message, "UndefinedFunctionError") -> "undefined_function"
      String.contains?(error_message, "CompileError") -> "compile_error"
      String.contains?(error_message, "SyntaxError") -> "syntax_error"
      String.contains?(error_message, "exit code") -> "exit_code"
      String.contains?(error_message, "timeout") -> "timeout"
      String.contains?(error_message, "not found") -> "not_found"
      true -> "unknown"
    end
  end

  defp detect_action_type(context) do
    cond do
      Map.has_key?(context, :command) -> :terminal_command
      Map.has_key?(context, :path) and Map.has_key?(context, :operation) -> :file_edit
      Map.has_key?(context, :signal_type) and context.signal_type == :file -> :file_edit
      true -> nil
    end
  end

  defp extract_error_message(context) do
    cond do
      Map.has_key?(context, :error) -> to_string(context.error)
      Map.has_key?(context, :output) -> String.slice(to_string(context.output), 0, 500)
      Map.has_key?(context, :details) -> inspect(context.details)
      true -> nil
    end
  end

  defp maybe_evict_old_patterns do
    try do
      count = :ets.info(@learned_patterns_table, :size) || 0

      if count >= @max_learned_patterns do
        # Evict oldest 10%
        patterns = :ets.tab2list(@learned_patterns_table)

        to_evict =
          patterns
          |> Enum.sort_by(fn {_key, p} -> DateTime.to_unix(p.updated_at) end)
          |> Enum.take(div(@max_learned_patterns, 10))

        Enum.each(to_evict, fn {key, _} -> :ets.delete(@learned_patterns_table, key) end)

        Logger.debug("[ErrorPredictor] Evicted #{length(to_evict)} old patterns")
      end
    rescue
      _ -> :ok
    end
  end
end
