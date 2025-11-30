defmodule Mimo.Skills.Diagnostics do
  @moduledoc """
  Multi-language diagnostics: compile errors, lint warnings, type checking.

  Provides VS Code-like `get_errors` functionality for AI agents.
  Supports Elixir, TypeScript, Python, Rust, and Go.

  ## Operations
  - :check - Run compiler checks
  - :lint - Run linter (credo, eslint, ruff, clippy, golangci-lint)
  - :typecheck - Run type checker (dialyzer, tsc, mypy)
  - :all - Run all diagnostics

  ## Usage
      {:ok, result} = Diagnostics.check("/path/to/file.ex")
      {:ok, result} = Diagnostics.check("/path/to/project", operation: :lint)
  """

  require Logger

  @timeout 60_000
  @max_output_size 100_000

  @doc """
  Run diagnostics on a file or directory.

  ## Options
    - `:operation` - :check, :lint, :typecheck, or :all (default: :all)
    - `:language` - :auto, :elixir, :typescript, :python, :rust, :go (default: :auto)
    - `:severity` - :error, :warning, :info, or :all (default: :all)

  ## Returns
      {:ok, %{
        path: "/path/to/file",
        language: :elixir,
        diagnostics: [...],
        error_count: 2,
        warning_count: 5,
        info_count: 1
      }}
  """
  def check(path \\ nil, opts \\ []) do
    path = path || get_project_root()
    language = Keyword.get(opts, :language, :auto)
    operation = Keyword.get(opts, :operation, :all)
    severity_filter = Keyword.get(opts, :severity, :all)

    language = if language == :auto, do: detect_language(path), else: language

    if language == :unknown do
      {:ok,
       %{
         path: path,
         language: :unknown,
         diagnostics: [],
         error_count: 0,
         warning_count: 0,
         info_count: 0,
         message: "Could not detect language for path: #{path}"
       }}
    else
      results = run_diagnostics(path, language, operation)
      filtered = filter_by_severity(results, severity_filter)

      {:ok,
       %{
         path: path,
         language: language,
         diagnostics: filtered,
         error_count: count_by_severity(filtered, :error),
         warning_count: count_by_severity(filtered, :warning),
         info_count: count_by_severity(filtered, :info)
       }}
    end
  end

  defp run_diagnostics(path, language, operation) do
    case operation do
      :check ->
        run_compiler(path, language)

      :lint ->
        run_linter(path, language)

      :typecheck ->
        run_typechecker(path, language)

      :all ->
        compile_results = run_compiler(path, language)
        lint_results = run_linter(path, language)
        type_results = run_typechecker(path, language)
        merge_results([compile_results, lint_results, type_results])
    end
  end

  # ==========================================================================
  # Language-Specific Compilers
  # ==========================================================================

  defp run_compiler(path, :elixir) do
    project_root = find_project_root(path, "mix.exs")

    if project_root do
      run_command("mix", ["compile", "--force", "--return-errors"],
        cd: project_root,
        env: [{"MIX_ENV", "dev"}]
      )
      |> parse_elixir_output()
    else
      []
    end
  end

  defp run_compiler(path, :typescript) do
    project_root =
      find_project_root(path, "tsconfig.json") ||
        find_project_root(path, "package.json")

    if project_root do
      run_command("npx", ["tsc", "--noEmit", "--pretty", "false"], cd: project_root)
      |> parse_typescript_output()
    else
      []
    end
  end

  defp run_compiler(path, :python) do
    # Python syntax check with py_compile
    if File.regular?(path) do
      run_command("python", ["-m", "py_compile", path])
      |> parse_python_syntax_output(path)
    else
      # For directories, use ruff as a fast syntax checker
      run_command("ruff", ["check", "--select=E999", path])
      |> parse_ruff_output()
    end
  end

  defp run_compiler(path, :rust) do
    project_root = find_project_root(path, "Cargo.toml")

    if project_root do
      run_command("cargo", ["check", "--message-format=json"], cd: project_root)
      |> parse_cargo_output()
    else
      []
    end
  end

  defp run_compiler(path, :go) do
    project_root = find_project_root(path, "go.mod")

    if project_root do
      run_command("go", ["build", "-o", "/dev/null", "./..."], cd: project_root)
      |> parse_go_output()
    else
      []
    end
  end

  defp run_compiler(_, _), do: []

  # ==========================================================================
  # Linters
  # ==========================================================================

  defp run_linter(path, :elixir) do
    project_root = find_project_root(path, "mix.exs")

    if project_root && has_credo?(project_root) do
      run_command("mix", ["credo", "--format", "json", "--strict"], cd: project_root)
      |> parse_credo_output()
    else
      []
    end
  end

  defp run_linter(path, :typescript) do
    project_root = find_project_root(path, "package.json")

    if project_root && has_eslint?(project_root) do
      # Use project-relative path for eslint
      relative_path = if File.regular?(path), do: Path.relative_to(path, project_root), else: "."

      run_command("npx", ["eslint", "--format", "json", relative_path], cd: project_root)
      |> parse_eslint_output()
    else
      []
    end
  end

  defp run_linter(path, :python) do
    if command_exists?("ruff") do
      run_command("ruff", ["check", "--output-format", "json", path])
      |> parse_ruff_output()
    else
      if command_exists?("pylint") do
        run_command("pylint", ["--output-format=json", path])
        |> parse_pylint_output()
      else
        []
      end
    end
  end

  defp run_linter(path, :rust) do
    project_root = find_project_root(path, "Cargo.toml")

    if project_root && command_exists?("cargo-clippy") do
      run_command("cargo", ["clippy", "--message-format=json"], cd: project_root)
      |> parse_cargo_output()
      |> Enum.filter(&(&1.source == :clippy))
    else
      []
    end
  end

  defp run_linter(path, :go) do
    project_root = find_project_root(path, "go.mod")

    if project_root && command_exists?("golangci-lint") do
      run_command("golangci-lint", ["run", "--out-format", "json"], cd: project_root)
      |> parse_golangci_output()
    else
      []
    end
  end

  defp run_linter(_, _), do: []

  # ==========================================================================
  # Type Checkers
  # ==========================================================================

  defp run_typechecker(_path, :elixir) do
    # Dialyzer is slow, skip for now unless explicitly requested
    # In the future, could add a :dialyzer option
    []
  end

  defp run_typechecker(path, :typescript) do
    # TypeScript compiler IS the type checker
    run_compiler(path, :typescript)
  end

  defp run_typechecker(path, :python) do
    if command_exists?("mypy") do
      run_command("mypy", ["--show-error-codes", "--no-error-summary", path])
      |> parse_mypy_output()
    else
      []
    end
  end

  defp run_typechecker(_, _), do: []

  # ==========================================================================
  # Output Parsers
  # ==========================================================================

  defp parse_elixir_output({output, _exit_code}) do
    # Parse Elixir compiler output
    # Format: "lib/file.ex:10:5: warning: unused variable"
    # Or: "** (CompileError) lib/file.ex:10: undefined function foo/1"

    results = []

    # Match standard warnings/errors
    standard_matches =
      Regex.scan(
        ~r/([^\s:]+):(\d+):?(\d+)?:\s*(warning|error)?:?\s*(.+)/m,
        output
      )

    standard_results =
      Enum.map(standard_matches, fn match ->
        case match do
          [_, file, line, col, severity, message] ->
            %{
              file: file,
              line: safe_parse_int(line, 1),
              column: safe_parse_int(col, 1),
              severity: parse_severity(severity, :warning),
              message: String.trim(message),
              source: :compiler
            }

          [_, file, line, "", severity, message] ->
            %{
              file: file,
              line: safe_parse_int(line, 1),
              column: 1,
              severity: parse_severity(severity, :warning),
              message: String.trim(message),
              source: :compiler
            }

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Match CompileError format
    compile_errors =
      Regex.scan(
        ~r/\*\*\s*\((\w+Error)\)\s*([^:]+):(\d+):\s*(.+)/m,
        output
      )

    error_results =
      Enum.map(compile_errors, fn
        [_, _error_type, file, line, message] ->
          %{
            file: file,
            line: safe_parse_int(line, 1),
            column: 1,
            severity: :error,
            message: String.trim(message),
            source: :compiler
          }

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    results ++ standard_results ++ error_results
  end

  defp parse_typescript_output({output, _exit_code}) do
    # Format: "file.ts(10,5): error TS2322: Type 'string' is not assignable to type 'number'."
    Regex.scan(~r/([^\s(]+)\((\d+),(\d+)\):\s*(error|warning)\s+(TS\d+):\s*(.+)/m, output)
    |> Enum.map(fn [_, file, line, col, severity, code, message] ->
      %{
        file: file,
        line: safe_parse_int(line, 1),
        column: safe_parse_int(col, 1),
        severity: parse_severity(severity, :error),
        message: "[#{code}] #{String.trim(message)}",
        source: :tsc
      }
    end)
  end

  defp parse_credo_output({output, _exit_code}) do
    case Jason.decode(output) do
      {:ok, %{"issues" => issues}} when is_list(issues) ->
        Enum.map(issues, fn issue ->
          %{
            file: issue["filename"],
            line: issue["line_no"] || 1,
            column: issue["column"] || 1,
            severity: credo_priority_to_severity(issue["priority"]),
            message: "[#{issue["check"]}] #{issue["message"]}",
            source: :credo
          }
        end)

      _ ->
        []
    end
  end

  defp parse_eslint_output({output, _exit_code}) do
    case Jason.decode(output) do
      {:ok, results} when is_list(results) ->
        Enum.flat_map(results, fn file_result ->
          file = file_result["filePath"] || ""
          messages = file_result["messages"] || []

          Enum.map(messages, fn msg ->
            %{
              file: file,
              line: msg["line"] || 1,
              column: msg["column"] || 1,
              severity: eslint_severity_to_atom(msg["severity"]),
              message: "[#{msg["ruleId"]}] #{msg["message"]}",
              source: :eslint
            }
          end)
        end)

      _ ->
        []
    end
  end

  defp parse_ruff_output({output, _exit_code}) do
    case Jason.decode(output) do
      {:ok, results} when is_list(results) ->
        Enum.map(results, fn issue ->
          %{
            file: issue["filename"] || "",
            line: get_in(issue, ["location", "row"]) || 1,
            column: get_in(issue, ["location", "column"]) || 1,
            severity: :warning,
            message: "[#{issue["code"]}] #{issue["message"]}",
            source: :ruff
          }
        end)

      _ ->
        []
    end
  end

  defp parse_pylint_output({output, _exit_code}) do
    case Jason.decode(output) do
      {:ok, results} when is_list(results) ->
        Enum.map(results, fn issue ->
          %{
            file: issue["path"] || "",
            line: issue["line"] || 1,
            column: issue["column"] || 1,
            severity: pylint_type_to_severity(issue["type"]),
            message: "[#{issue["symbol"]}] #{issue["message"]}",
            source: :pylint
          }
        end)

      _ ->
        []
    end
  end

  defp parse_mypy_output({output, _exit_code}) do
    # Format: "file.py:10: error: Incompatible types [error-code]"
    Regex.scan(~r/([^:]+):(\d+):\s*(error|warning|note):\s*(.+)/m, output)
    |> Enum.map(fn [_, file, line, severity, message] ->
      %{
        file: file,
        line: safe_parse_int(line, 1),
        column: 1,
        severity: parse_severity(severity, :error),
        message: String.trim(message),
        source: :mypy
      }
    end)
  end

  defp parse_cargo_output({output, _exit_code}) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"reason" => "compiler-message", "message" => msg}} ->
          parse_cargo_message(msg)

        _ ->
          []
      end
    end)
  end

  defp parse_cargo_message(msg) do
    level = msg["level"]
    message_text = msg["message"] || ""
    code = get_in(msg, ["code", "code"]) || ""
    spans = msg["spans"] || []

    Enum.map(spans, fn span ->
      %{
        file: span["file_name"] || "",
        line: span["line_start"] || 1,
        column: span["column_start"] || 1,
        severity: cargo_level_to_severity(level),
        message: if(code != "", do: "[#{code}] #{message_text}", else: message_text),
        source: if(String.starts_with?(code, "clippy"), do: :clippy, else: :rustc)
      }
    end)
  end

  defp parse_go_output({output, _exit_code}) do
    # Format: "file.go:10:5: error message"
    Regex.scan(~r/([^:]+):(\d+):(\d+):\s*(.+)/m, output)
    |> Enum.map(fn [_, file, line, col, message] ->
      %{
        file: file,
        line: safe_parse_int(line, 1),
        column: safe_parse_int(col, 1),
        severity: :error,
        message: String.trim(message),
        source: :go
      }
    end)
  end

  defp parse_golangci_output({output, _exit_code}) do
    case Jason.decode(output) do
      {:ok, %{"Issues" => issues}} when is_list(issues) ->
        Enum.map(issues, fn issue ->
          %{
            file: get_in(issue, ["Pos", "Filename"]) || "",
            line: get_in(issue, ["Pos", "Line"]) || 1,
            column: get_in(issue, ["Pos", "Column"]) || 1,
            severity: golangci_severity_to_atom(issue["Severity"]),
            message: "[#{issue["FromLinter"]}] #{issue["Text"]}",
            source: :golangci
          }
        end)

      _ ->
        []
    end
  end

  defp parse_python_syntax_output({output, exit_code}, path) do
    if exit_code == 0 do
      []
    else
      # Parse py_compile error output
      Regex.scan(~r/File "([^"]+)", line (\d+)/m, output)
      |> Enum.map(fn [_, file, line] ->
        %{
          file: file,
          line: safe_parse_int(line, 1),
          column: 1,
          severity: :error,
          message: "Syntax error",
          source: :py_compile
        }
      end)
      |> case do
        [] ->
          [
            %{
              file: path,
              line: 1,
              column: 1,
              severity: :error,
              message: String.trim(output),
              source: :py_compile
            }
          ]

        results ->
          results
      end
    end
  end

  # ==========================================================================
  # Severity Converters
  # ==========================================================================

  defp credo_priority_to_severity(priority) when is_number(priority) do
    cond do
      priority >= 10 -> :error
      priority >= 1 -> :warning
      true -> :info
    end
  end

  defp credo_priority_to_severity(_), do: :warning

  defp eslint_severity_to_atom(2), do: :error
  defp eslint_severity_to_atom(1), do: :warning
  defp eslint_severity_to_atom(_), do: :info

  defp pylint_type_to_severity("error"), do: :error
  defp pylint_type_to_severity("fatal"), do: :error
  defp pylint_type_to_severity("warning"), do: :warning
  defp pylint_type_to_severity("refactor"), do: :info
  defp pylint_type_to_severity("convention"), do: :info
  defp pylint_type_to_severity(_), do: :warning

  defp cargo_level_to_severity("error"), do: :error
  defp cargo_level_to_severity("warning"), do: :warning
  defp cargo_level_to_severity("note"), do: :info
  defp cargo_level_to_severity(_), do: :warning

  defp golangci_severity_to_atom("error"), do: :error
  defp golangci_severity_to_atom("warning"), do: :warning
  defp golangci_severity_to_atom(_), do: :warning

  defp parse_severity("error", _), do: :error
  defp parse_severity("warning", _), do: :warning
  defp parse_severity("info", _), do: :info
  defp parse_severity("note", _), do: :info
  defp parse_severity(nil, default), do: default
  defp parse_severity("", default), do: default
  defp parse_severity(_, default), do: default

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp detect_language(path) do
    cond do
      String.ends_with?(path, [".ex", ".exs"]) -> :elixir
      String.ends_with?(path, [".ts", ".tsx"]) -> :typescript
      # Use TS tooling for JS too
      String.ends_with?(path, [".js", ".jsx"]) -> :typescript
      String.ends_with?(path, ".py") -> :python
      String.ends_with?(path, ".rs") -> :rust
      String.ends_with?(path, ".go") -> :go
      File.dir?(path) -> detect_project_language(path)
      true -> :unknown
    end
  end

  defp detect_project_language(path) do
    cond do
      File.exists?(Path.join(path, "mix.exs")) -> :elixir
      File.exists?(Path.join(path, "tsconfig.json")) -> :typescript
      File.exists?(Path.join(path, "package.json")) -> :typescript
      File.exists?(Path.join(path, "pyproject.toml")) -> :python
      File.exists?(Path.join(path, "requirements.txt")) -> :python
      File.exists?(Path.join(path, "Cargo.toml")) -> :rust
      File.exists?(Path.join(path, "go.mod")) -> :go
      true -> :unknown
    end
  end

  defp find_project_root(path, marker_file) do
    path = if File.dir?(path), do: path, else: Path.dirname(path)
    find_project_root_up(path, marker_file)
  end

  defp find_project_root_up(path, marker_file) do
    cond do
      File.exists?(Path.join(path, marker_file)) -> path
      path == "/" -> nil
      true -> find_project_root_up(Path.dirname(path), marker_file)
    end
  end

  defp get_project_root do
    System.get_env("MIMO_ROOT") || File.cwd!()
  end

  defp has_credo?(project_root) do
    mix_exs = Path.join(project_root, "mix.exs")

    if File.exists?(mix_exs) do
      content = File.read!(mix_exs)
      String.contains?(content, ":credo")
    else
      false
    end
  end

  defp has_eslint?(project_root) do
    File.exists?(Path.join(project_root, ".eslintrc.js")) ||
      File.exists?(Path.join(project_root, ".eslintrc.json")) ||
      File.exists?(Path.join(project_root, ".eslintrc.yml")) ||
      File.exists?(Path.join(project_root, "eslint.config.js")) ||
      File.exists?(Path.join(project_root, "eslint.config.mjs"))
  end

  defp command_exists?(cmd) do
    case System.cmd("which", [cmd], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp run_command(cmd, args, opts \\ []) do
    cd = Keyword.get(opts, :cd, File.cwd!())
    env = Keyword.get(opts, :env, [])

    try do
      task =
        Task.async(fn ->
          System.cmd(cmd, args,
            cd: cd,
            stderr_to_stdout: true,
            env: env
          )
        end)

      case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, exit_code}} ->
          # Truncate large outputs
          truncated_output =
            if byte_size(output) > @max_output_size do
              binary_part(output, 0, @max_output_size) <> "\n... [truncated]"
            else
              output
            end

          {truncated_output, exit_code}

        nil ->
          {"Command timed out after #{@timeout}ms", 124}
      end
    rescue
      e ->
        Logger.debug("Command failed: #{cmd} #{inspect(args)} - #{Exception.message(e)}")
        {"Command not found or failed: #{cmd}", 127}
    end
  end

  defp safe_parse_int(nil, default), do: default
  defp safe_parse_int("", default), do: default

  defp safe_parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp safe_parse_int(n, _default) when is_integer(n), do: n
  defp safe_parse_int(_, default), do: default

  defp merge_results(result_lists) do
    result_lists
    |> List.flatten()
    |> Enum.uniq_by(fn d -> {d.file, d.line, d.message} end)
  end

  defp filter_by_severity(results, :all), do: results

  defp filter_by_severity(results, severity) do
    Enum.filter(results, &(&1.severity == severity))
  end

  defp count_by_severity(results, severity) do
    Enum.count(results, &(&1.severity == severity))
  end
end
