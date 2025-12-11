defmodule Mimo.Robustness.PatternDetector do
  @moduledoc """
  Pattern Detection Library (SPEC-070 Task A)

  Automated detection of red flag patterns that indicate fragile implementations.

  ## Red Flags Detected

  From IMPLEMENTATION_ROBUSTNESS.md and Dec 6 2025 incidents:

  - `execSync` with bash/system commands for logic
  - Synchronous `GenServer.call` during initialization
  - Complex orchestration between layers
  - No try/catch or case/rescue around external calls
  - Assumptions about system state without verification
  - String parsing of command output for logic decisions
  - Blocking operations on critical startup path
  - No graceful degradation when dependencies unavailable

  ## Usage

      {:ok, patterns} = PatternDetector.detect(code, :elixir)
      # Returns list of detected patterns with locations and fixes
  """

  @type language :: :elixir | :javascript | :typescript | :unknown
  @type pattern :: %{
          id: atom(),
          severity: :high | :medium | :low,
          description: String.t(),
          line: non_neg_integer(),
          match: String.t(),
          fix_template: String.t()
        }

  # Pattern definitions extracted from IMPLEMENTATION_ROBUSTNESS.md
  @elixir_patterns [
    %{
      id: :blocking_genserver_init,
      severity: :high,
      description: "Synchronous GenServer.call during init/start (Dec 6 incident pattern)",
      # Matches GenServer.call in def init or def start blocks
      regex: ~r/def\s+(?:init|start_link?|start)\b[^e]*\bGenServer\.call\b/s,
      fix_template: "Use Process.whereis check + catch exits instead of blocking call during init"
    },
    %{
      id: :blocking_genserver_no_catch,
      severity: :high,
      description: "GenServer.call without try/catch (no fallback on noproc/timeout)",
      # Matches GenServer.call - needs manual verification for try/catch
      regex: ~r/GenServer\.call\([^)]+\)/,
      fix_template:
        "Wrap in try/catch with {:exit, {:noproc, _}} and {:exit, {:timeout, _}} handlers"
    },
    %{
      id: :process_whereis_unguarded,
      severity: :medium,
      description: "Process.whereis result used directly without nil check",
      regex: ~r/Process\.whereis\([^)]+\)\s*\|>/,
      fix_template: "Use case Process.whereis(X) do nil -> default(); pid -> ... end"
    },
    %{
      id: :sync_operation_in_start,
      severity: :high,
      description: "Synchronous blocking operation in start function",
      regex: ~r/def\s+start_link?\b[^e]*?\b(?:wait_for|ensure_|check_\w+!)\b/s,
      fix_template: "Move synchronous checks to runtime (point of use) with fallbacks"
    },
    %{
      id: :no_rescue_external_call,
      severity: :medium,
      description: "External operation without rescue/catch (HTTP, File, Port)",
      regex: ~r/(?:HTTPoison|Req|Mint)\.(?:get|post|put|delete)!?\(/,
      fix_template: "Add try/rescue with fallback for network failures"
    },
    %{
      id: :system_cmd_for_logic,
      severity: :high,
      description: "System.cmd or Port.open for logic decisions (Dec 6 pattern)",
      # Matches System.cmd output assigned with = (pattern matching for logic)
      regex: ~r/=\s*System\.cmd\s*\(/,
      fix_template: "Replace with pure Elixir functions (File.stat, Path operations, etc.)"
    },
    %{
      id: :string_parse_command_output,
      severity: :medium,
      description: "String parsing of command output for logic",
      regex: ~r/\|>\s*String\.(?:split|trim|replace)\b.*System\.cmd/s,
      fix_template: "Use native Elixir APIs instead of parsing command output"
    }
  ]

  @javascript_patterns [
    %{
      id: :exec_sync_bash,
      severity: :high,
      description: "execSync with bash/shell command (Dec 6 incident pattern)",
      regex: ~r/execSync\s*\([^)]*(?:bash|sh|bc|find|grep|awk|sed|printf)/,
      fix_template: "Replace with native Node.js APIs (fs.statSync, path operations, etc.)"
    },
    %{
      id: :exec_sync_pipe,
      severity: :high,
      description: "execSync with piped commands",
      regex: ~r/execSync\s*\([^)]*\|[^)]*\)/,
      fix_template: "Break into separate operations using native Node.js APIs"
    },
    %{
      id: :exec_sync_no_try,
      severity: :high,
      description: "execSync without try/catch (blocks and can throw)",
      regex: ~r/execSync\s*\([^)]+\)/,
      fix_template: "Wrap in try/catch with graceful fallback, or use async exec"
    },
    %{
      id: :sync_compile_critical_path,
      severity: :high,
      description: "Synchronous compilation on critical startup path",
      regex: ~r/(?:syncCompile|compileSync)\s*\([^)]*\)\s*[;,]?\s*(?:startServer|listen|main)/s,
      fix_template: "Start immediately, run compilation async for next startup"
    },
    %{
      id: :no_fallback_on_error,
      severity: :medium,
      description: "Error thrown without fallback path",
      regex: ~r/throw\s+new\s+Error\([^)]+\)(?![^}]*catch)/,
      fix_template: "Add fallback behavior before throwing, or use graceful degradation"
    },
    %{
      id: :blocking_on_startup,
      severity: :high,
      description: "Blocking operation before server start",
      regex:
        ~r/(?:await\s+|\.then\([^)]*waitFor|ensureReady)\s*\([^)]*\)[;\s]*(?:app\.listen|server\.start)/s,
      fix_template: "Start server first, handle readiness checks on first request"
    },
    %{
      id: :external_cmd_for_logic,
      severity: :high,
      description: "External command for logic that could be pure JS",
      regex: ~r/execSync\s*\([^)]*\)\s*\.toString\(\)\s*\.(?:split|trim|match)/,
      fix_template: "Use native Node.js APIs (fs, path) instead of command parsing"
    },
    %{
      id: :spawn_sync_blocking,
      severity: :medium,
      description: "spawnSync used for potentially long operations",
      regex: ~r/spawnSync\s*\([^)]*(?:npm|yarn|mix|cargo|pip)/,
      fix_template: "Use async spawn with proper error handling for long operations"
    }
  ]

  @doc """
  Detect red flag patterns in source code.

  ## Parameters

  - `content` - Source code content as string
  - `language` - Programming language (:elixir, :javascript, :typescript, :unknown)

  ## Returns

  `{:ok, [pattern]}` where each pattern includes:
  - `:id` - Pattern identifier
  - `:severity` - :high, :medium, or :low
  - `:description` - Human-readable description
  - `:line` - Line number where pattern was found
  - `:match` - The matched text
  - `:fix_template` - Suggested fix
  """
  @spec detect(String.t(), language()) :: {:ok, [pattern()]} | {:error, term()}
  def detect(content, language) do
    patterns = get_patterns_for_language(language)
    lines = String.split(content, "\n")

    detected =
      patterns
      |> Enum.flat_map(fn pattern ->
        find_matches(content, lines, pattern)
      end)
      |> Enum.sort_by(& &1.line)

    {:ok, detected}
  rescue
    e -> {:error, {:pattern_detection_failed, e}}
  end

  @doc """
  Get all defined patterns for a language.
  """
  @spec get_patterns_for_language(language()) :: [map()]
  def get_patterns_for_language(:elixir), do: @elixir_patterns
  def get_patterns_for_language(:javascript), do: @javascript_patterns
  # Same patterns apply
  def get_patterns_for_language(:typescript), do: @javascript_patterns
  def get_patterns_for_language(_), do: []

  @doc """
  Check if a single pattern exists in content.
  """
  @spec pattern_exists?(String.t(), atom()) :: boolean()
  def pattern_exists?(content, pattern_id) do
    all_patterns = @elixir_patterns ++ @javascript_patterns

    case Enum.find(all_patterns, &(&1.id == pattern_id)) do
      nil -> false
      pattern -> Regex.match?(pattern.regex, content)
    end
  end

  @doc """
  Get a list of all known pattern IDs with their descriptions.
  """
  @spec list_patterns() :: [{atom(), String.t()}]
  def list_patterns do
    (@elixir_patterns ++ @javascript_patterns)
    |> Enum.map(&{&1.id, &1.description})
    |> Enum.uniq_by(fn {id, _} -> id end)
  end

  # --- Private Functions ---

  defp find_matches(content, _lines, pattern) do
    case Regex.scan(pattern.regex, content, return: :index) do
      [] ->
        []

      matches ->
        matches
        |> Enum.map(fn [{start_pos, length} | _] ->
          line_number = count_lines_before(content, start_pos)
          matched_text = String.slice(content, start_pos, min(length, 80))

          %{
            id: pattern.id,
            severity: pattern.severity,
            description: pattern.description,
            line: line_number,
            match: String.trim(matched_text),
            fix_template: pattern.fix_template
          }
        end)
    end
  end

  defp count_lines_before(content, position) do
    content
    |> String.slice(0, position)
    |> String.split("\n")
    |> length()
  end
end
