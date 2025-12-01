defmodule Mimo.Skills.FileOps do
  @moduledoc """
  Efficient, symbol-aware file operations with streaming reads.

  Designed for AI agents - optimized to save tokens and be effective:
  - 500-line chunks for large files (reads multiple times to understand)
  - Symbol search and extraction (functions, classes, methods)
  - Line-targeted insertions and replacements
  - Semantic search within files

  All operations are sandboxed with path traversal prevention.
  """

  @max_chunk_lines 500
  @max_file_size 10 * 1024 * 1024
  @file_timeout 5_000

  # Convert file system errors to human-readable messages
  defp format_file_error(:enoent, path), do: {:error, "File not found: #{path}"}
  defp format_file_error(:eacces, path), do: {:error, "Permission denied: #{path}"}
  defp format_file_error(:eisdir, path), do: {:error, "Is a directory: #{path}"}
  defp format_file_error(:enotdir, path), do: {:error, "Not a directory: #{path}"}
  defp format_file_error(:enospc, _path), do: {:error, "No space left on device"}
  defp format_file_error(:enomem, _path), do: {:error, "Out of memory"}
  defp format_file_error(:eexist, path), do: {:error, "File already exists: #{path}"}

  defp format_file_error(:path_outside_allowed_roots, path),
    do: {:error, "Path outside allowed roots: #{path}"}

  defp format_file_error(:file_too_large, path), do: {:error, "File too large (max 10MB): #{path}"}
  defp format_file_error(:timeout, path), do: {:error, "Operation timed out: #{path}"}
  defp format_file_error(reason, path) when is_atom(reason), do: {:error, "#{reason}: #{path}"}
  defp format_file_error(reason, _path), do: {:error, "#{inspect(reason)}"}

  defp sandbox_root do
    (System.get_env("MIMO_ROOT") || File.cwd!()) |> Path.expand()
  end

  # Get list of allowed roots (sandbox_root + any additional from MIMO_ALLOWED_PATHS)
  defp allowed_roots do
    base = [sandbox_root()]

    additional =
      case System.get_env("MIMO_ALLOWED_PATHS") do
        nil -> []
        "" -> []
        paths -> String.split(paths, ":") |> Enum.map(&Path.expand/1)
      end

    # Also allow /workspace by default for VS Code devcontainers
    workspace = ["/workspace"] |> Enum.filter(&File.dir?/1)

    (base ++ additional ++ workspace) |> Enum.uniq()
  end

  # ==========================================================================
  # SMART READ - Chunked reading for large files
  # ==========================================================================

  @doc """
  Smart read with automatic chunking for large files.
  Returns max 500 lines at a time with metadata for continuation.

  ## Options
    - `:offset` - Start line (1-indexed, default 1)
    - `:limit` - Max lines to return (default 500)

  ## Returns
    ```
    {:ok, %{
      content: "...",
      lines_read: 500,
      total_lines: 2000,
      offset: 1,
      has_more: true,
      next_offset: 501
    }}
    ```
  """
  def read(path, opts \\ []) when is_binary(path) do
    offset = Keyword.get(opts, :offset, 1)
    limit = min(Keyword.get(opts, :limit, @max_chunk_lines), @max_chunk_lines)

    task = Task.async(fn -> do_chunked_read(path, offset, limit) end)

    case Task.yield(task, @file_timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp do_chunked_read(path, offset, limit) do
    with {:ok, safe_path} <- expand_safe(path),
         {:ok, stat} <- File.stat(safe_path),
         :ok <- check_not_directory(stat),
         :ok <- check_file_size(stat) do
      # Stream-read for efficiency
      lines =
        safe_path
        |> File.stream!([], :line)
        |> Stream.with_index(1)
        |> Stream.drop(offset - 1)
        |> Stream.take(limit)
        |> Enum.to_list()

      total_lines = count_lines_fast(safe_path)
      lines_read = length(lines)
      content = Enum.map_join(lines, fn {line, _idx} -> line end)

      # Remove trailing newline if present for cleaner output
      content = String.trim_trailing(content, "\n")

      {:ok,
       %{
         content: content,
         lines_read: lines_read,
         total_lines: total_lines,
         offset: offset,
         has_more: offset + lines_read - 1 < total_lines,
         next_offset: offset + lines_read
       }}
    else
      {:error, reason} -> format_file_error(reason, path)
    end
  end

  defp check_not_directory(%{type: :directory}), do: {:error, :eisdir}
  defp check_not_directory(_), do: :ok

  defp check_file_size(%{size: size}) when size > @max_file_size, do: {:error, :file_too_large}
  defp check_file_size(_), do: :ok

  defp count_lines_fast(path) do
    path
    |> File.stream!([], :line)
    |> Enum.count()
  end

  # ==========================================================================
  # SYMBOL OPERATIONS - Code-aware reading and editing
  # ==========================================================================

  @doc """
  Extract symbols (functions, classes, methods) from a file.
  Returns symbol names with their line ranges for targeted reading.

  ## Supported languages (auto-detected by extension):
    - Elixir: def, defp, defmodule, defmacro
    - Python: def, class, async def
    - JavaScript/TypeScript: function, class, const/let/var with arrow functions
    - Ruby: def, class, module
    - Go: func, type

  ## Returns
    ```
    {:ok, [
      %{name: "MyModule", type: :module, start_line: 1, end_line: 100},
      %{name: "my_function", type: :function, start_line: 5, end_line: 15}
    ]}
    ```
  """
  def list_symbols(path) when is_binary(path) do
    task = Task.async(fn -> do_list_symbols(path) end)

    case Task.yield(task, @file_timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp do_list_symbols(path) do
    with {:ok, safe_path} <- expand_safe(path),
         {:ok, content} <- File.read(safe_path) do
      ext = Path.extname(path) |> String.downcase()
      symbols = extract_symbols(content, ext)
      {:ok, symbols}
    end
  end

  defp extract_symbols(content, ext) do
    lines = String.split(content, "\n")

    patterns = symbol_patterns(ext)

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, idx} ->
      Enum.flat_map(patterns, fn {type, regex} ->
        case Regex.run(regex, line) do
          [_, name | _] -> [%{name: name, type: type, line: idx, text: String.trim(line)}]
          _ -> []
        end
      end)
    end)
  end

  defp symbol_patterns(ext) when ext in [".ex", ".exs"] do
    [
      {:module, ~r/^\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)/},
      {:function, ~r/^\s*def\s+([a-z_][a-z0-9_?!]*)/},
      {:private_function, ~r/^\s*defp\s+([a-z_][a-z0-9_?!]*)/},
      {:macro, ~r/^\s*defmacro\s+([a-z_][a-z0-9_?!]*)/}
    ]
  end

  defp symbol_patterns(ext) when ext in [".py"] do
    [
      {:class, ~r/^\s*class\s+([A-Z][A-Za-z0-9_]*)/},
      {:function, ~r/^\s*(?:async\s+)?def\s+([a-z_][a-z0-9_]*)/}
    ]
  end

  defp symbol_patterns(ext) when ext in [".js", ".ts", ".jsx", ".tsx"] do
    [
      {:class, ~r/^\s*(?:export\s+)?class\s+([A-Z][A-Za-z0-9_]*)/},
      {:function, ~r/^\s*(?:export\s+)?(?:async\s+)?function\s+([a-zA-Z_][a-zA-Z0-9_]*)/},
      {:const_function,
       ~r/^\s*(?:export\s+)?const\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(?:async\s+)?\(/},
      {:arrow_function,
       ~r/^\s*(?:export\s+)?(?:const|let|var)\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(?:async\s+)?\([^)]*\)\s*=>/}
    ]
  end

  defp symbol_patterns(ext) when ext in [".rb"] do
    [
      {:module, ~r/^\s*module\s+([A-Z][A-Za-z0-9_]*)/},
      {:class, ~r/^\s*class\s+([A-Z][A-Za-z0-9_]*)/},
      {:function, ~r/^\s*def\s+([a-z_][a-z0-9_?!]*)/}
    ]
  end

  defp symbol_patterns(ext) when ext in [".go"] do
    [
      {:function, ~r/^func\s+(?:\([^)]+\)\s+)?([A-Za-z_][A-Za-z0-9_]*)/},
      {:type, ~r/^type\s+([A-Z][A-Za-z0-9_]*)/}
    ]
  end

  defp symbol_patterns(_), do: []

  @doc """
  Read a specific symbol's code block.
  Finds the symbol and returns its full definition with context.

  ## Options
    - `:context_before` - Lines of context before (default 0)
    - `:context_after` - Lines of context after (default 0)
  """
  def read_symbol(path, symbol_name, opts \\ []) when is_binary(path) do
    context_before = Keyword.get(opts, :context_before, 0)
    context_after = Keyword.get(opts, :context_after, 0)

    with {:ok, symbols} <- list_symbols(path),
         symbol when not is_nil(symbol) <- Enum.find(symbols, &(&1.name == symbol_name)) do
      # Read from symbol line with context
      start_line = max(1, symbol.line - context_before)
      # Estimate end by reading ahead (we'll refine this)
      {:ok, chunk} = read(path, offset: start_line, limit: 100 + context_after)

      {:ok,
       %{
         symbol: symbol,
         content: chunk.content,
         start_line: start_line,
         lines_read: chunk.lines_read
       }}
    else
      nil -> {:error, :symbol_not_found}
      error -> error
    end
  end

  @doc """
  Search for symbols matching a pattern across files.
  """
  def search_symbols(base_path, pattern, opts \\ []) when is_binary(base_path) do
    max_results = Keyword.get(opts, :max_results, 50)

    task =
      Task.async(fn ->
        with {:ok, safe_path} <- expand_safe(base_path) do
          results = find_symbols_recursive(safe_path, pattern, max_results, [])
          {:ok, results}
        end
      end)

    case Task.yield(task, @file_timeout * 2) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp find_symbols_recursive(_path, _pattern, max, acc) when length(acc) >= max do
    Enum.reverse(acc) |> Enum.take(max)
  end

  defp find_symbols_recursive(path, pattern, max, acc) do
    cond do
      File.dir?(path) ->
        case File.ls(path) do
          {:ok, entries} ->
            # Skip hidden dirs and common non-code dirs
            entries = Enum.reject(entries, &skip_directory?/1)

            Enum.reduce(entries, acc, fn entry, current_acc ->
              if length(current_acc) >= max do
                current_acc
              else
                find_symbols_recursive(Path.join(path, entry), pattern, max, current_acc)
              end
            end)

          {:error, _} ->
            acc
        end

      code_file?(path) ->
        case list_symbols(path) do
          {:ok, symbols} ->
            matches =
              Enum.filter(symbols, fn s ->
                String.contains?(String.downcase(s.name), String.downcase(pattern))
              end)
              |> Enum.map(&Map.put(&1, :file, path))

            acc ++ matches

          _ ->
            acc
        end

      true ->
        acc
    end
  end

  defp skip_directory?(name) do
    name in ["node_modules", ".git", "_build", "deps", ".elixir_ls", "__pycache__", ".venv", "venv"] or
      String.starts_with?(name, ".")
  end

  defp code_file?(path) do
    ext = Path.extname(path) |> String.downcase()

    ext in [
      ".ex",
      ".exs",
      ".py",
      ".js",
      ".ts",
      ".jsx",
      ".tsx",
      ".rb",
      ".go",
      ".rs",
      ".java",
      ".c",
      ".cpp",
      ".h"
    ]
  end

  # ==========================================================================
  # SEMANTIC SEARCH - Find code by meaning
  # ==========================================================================

  @doc """
  Search file contents using pattern matching.
  Returns matches with line numbers and context.
  """
  def search(path, pattern, opts \\ []) when is_binary(path) do
    context_lines = Keyword.get(opts, :context, 2)
    max_results = Keyword.get(opts, :max_results, 50)

    task =
      Task.async(fn ->
        with {:ok, safe_path} <- expand_safe(path) do
          if File.dir?(safe_path) do
            search_in_directory(safe_path, pattern, max_results, context_lines)
          else
            search_in_file(safe_path, pattern, max_results, context_lines)
          end
        end
      end)

    case Task.yield(task, @file_timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp search_in_file(path, pattern, max_results, context_lines) do
    case File.read(path) do
      {:ok, content} ->
        regex = Regex.compile!(pattern, [:caseless])
        lines = String.split(content, "\n")

        matches =
          lines
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
          |> Enum.take(max_results)
          |> Enum.map(fn {line, idx} ->
            before = get_context(lines, idx, -context_lines)
            after_ctx = get_context(lines, idx, context_lines)

            %{
              file: path,
              line: idx,
              content: line,
              context_before: before,
              context_after: after_ctx
            }
          end)

        {:ok, matches}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp search_in_directory(path, pattern, max_results, context_lines) do
    results = grep_recursive(path, pattern, max_results, context_lines, [])
    {:ok, results}
  end

  defp grep_recursive(_path, _pattern, max, _ctx, acc) when length(acc) >= max do
    Enum.reverse(acc) |> Enum.take(max)
  end

  defp grep_recursive(path, pattern, max, ctx, acc) do
    case File.ls(path) do
      {:ok, entries} ->
        entries = Enum.reject(entries, &skip_directory?/1)

        Enum.reduce(entries, acc, fn entry, current_acc ->
          if length(current_acc) >= max do
            current_acc
          else
            full_path = Path.join(path, entry)

            cond do
              File.dir?(full_path) ->
                grep_recursive(full_path, pattern, max, ctx, current_acc)

              text_file?(full_path) ->
                case search_in_file(full_path, pattern, max - length(current_acc), ctx) do
                  {:ok, matches} -> current_acc ++ matches
                  _ -> current_acc
                end

              true ->
                current_acc
            end
          end
        end)

      {:error, _} ->
        acc
    end
  end

  defp text_file?(path) do
    ext = Path.extname(path) |> String.downcase()

    ext in [
      ".ex",
      ".exs",
      ".py",
      ".js",
      ".ts",
      ".jsx",
      ".tsx",
      ".rb",
      ".go",
      ".rs",
      ".java",
      ".c",
      ".cpp",
      ".h",
      ".md",
      ".txt",
      ".json",
      ".yaml",
      ".yml",
      ".toml",
      ".xml",
      ".html",
      ".css",
      ".scss",
      ".sh",
      ".bash"
    ]
  end

  defp get_context(lines, current_idx, offset) when offset < 0 do
    start_idx = max(0, current_idx - 1 + offset)
    end_idx = current_idx - 2

    if end_idx >= start_idx do
      Enum.slice(lines, start_idx..end_idx)
    else
      []
    end
  end

  defp get_context(lines, current_idx, offset) when offset > 0 do
    start_idx = current_idx
    end_idx = min(length(lines) - 1, current_idx - 1 + offset)

    if end_idx >= start_idx do
      Enum.slice(lines, start_idx..end_idx)
    else
      []
    end
  end

  defp get_context(_lines, _idx, 0), do: []

  # ==========================================================================
  # LINE OPERATIONS - Targeted insertions and edits
  # ==========================================================================

  @doc """
  Insert content at a specific line number.

  ## Options
    - `:position` - :before or :after (default :after)
  """
  def insert_at_line(path, line_number, content, opts \\ []) when is_binary(path) do
    position = Keyword.get(opts, :position, :after)

    with {:ok, safe_path} <- expand_safe(path),
         {:ok, existing} <- File.read(safe_path) do
      lines = String.split(existing, "\n")
      new_lines = String.split(content, "\n")

      insert_idx =
        case position do
          :before -> max(0, line_number - 1)
          :after -> line_number
        end

      {before, after_lines} = Enum.split(lines, insert_idx)
      result = Enum.join(before ++ new_lines ++ after_lines, "\n")

      File.write(safe_path, result)
    end
  end

  # Legacy aliases for compatibility
  def insert_after_line(path, line_number, content) do
    insert_at_line(path, line_number, content, position: :after)
  end

  def insert_before_line(path, line_number, content) do
    insert_at_line(path, line_number, content, position: :before)
  end

  @doc """
  Replace lines from start_line to end_line (inclusive).
  """
  def replace_lines(path, start_line, end_line, content) when is_binary(path) do
    with {:ok, safe_path} <- expand_safe(path),
         {:ok, existing} <- File.read(safe_path) do
      lines = String.split(existing, "\n")
      new_lines = String.split(content, "\n")

      before = Enum.take(lines, start_line - 1)
      after_lines = Enum.drop(lines, end_line)
      result = Enum.join(before ++ new_lines ++ after_lines, "\n")

      File.write(safe_path, result)
    end
  end

  @doc """
  Delete lines from start_line to end_line (inclusive).
  """
  def delete_lines(path, start_line, end_line) when is_binary(path) do
    with {:ok, safe_path} <- expand_safe(path),
         {:ok, existing} <- File.read(safe_path) do
      lines = String.split(existing, "\n")

      before = Enum.take(lines, start_line - 1)
      after_lines = Enum.drop(lines, end_line)
      result = Enum.join(before ++ after_lines, "\n")

      File.write(safe_path, result)
    end
  end

  @doc """
  Replace first occurrence of old_str with new_str.
  """
  def replace_string(path, old_str, new_str) when is_binary(path) do
    with {:ok, safe_path} <- expand_safe(path),
         {:ok, content} <- File.read(safe_path) do
      if String.contains?(content, old_str) do
        new_content = String.replace(content, old_str, new_str, global: false)
        File.write(safe_path, new_content)
      else
        {:error, :pattern_not_found}
      end
    end
  end

  @doc """
  Advanced edit operation with validation and multiple replacement support.

  Options:
    - `:global` - Replace all occurrences (default: false)
    - `:expected_count` - Expected number of replacements (validates match count)
    - `:dry_run` - Don't write, just return what would happen (default: false)

  Returns:
    - `{:ok, %{replacements: count, ...}}` on success
    - `{:error, reason}` on failure

  ## Examples

      # Replace single occurrence (validates uniqueness)
      edit(path, "old", "new")

      # Replace all occurrences  
      edit(path, "old", "new", global: true)

      # Validate expected replacements
      edit(path, "old", "new", expected_count: 3, global: true)

      # Preview changes without writing
      edit(path, "old", "new", dry_run: true)
  """
  def edit(path, old_str, new_str, opts \\ []) when is_binary(path) do
    global = Keyword.get(opts, :global, false)
    expected_count = Keyword.get(opts, :expected_count)
    dry_run = Keyword.get(opts, :dry_run, false)

    with {:ok, safe_path} <- expand_safe(path),
         {:ok, content} <- File.read(safe_path) do
      # Count occurrences
      match_count = count_occurrences(content, old_str)

      cond do
        match_count == 0 ->
          # No matches found - provide context
          {:error,
           %{
             reason: :pattern_not_found,
             searched_for: truncate_string(old_str, 100),
             file_size: byte_size(content),
             suggestion: "Verify the exact text including whitespace and line endings"
           }}

        expected_count && match_count != expected_count ->
          # Mismatch in expected count
          {:error,
           %{
             reason: :unexpected_match_count,
             expected: expected_count,
             found: match_count,
             suggestion:
               if(match_count > expected_count,
                 do: "Add more context to make the match unique",
                 else: "Check if the pattern exists in the file"
               )
           }}

        !global && match_count > 1 ->
          # Multiple matches but not global - warn and provide options
          {:error,
           %{
             reason: :multiple_matches,
             match_count: match_count,
             suggestion:
               "Use global: true to replace all, or add more context to make the match unique",
             preview: find_match_locations(content, old_str, 3)
           }}

        true ->
          # Perform the replacement
          replacement_count = if global, do: match_count, else: 1
          new_content = String.replace(content, old_str, new_str, global: global)

          if dry_run do
            {:ok,
             %{
               dry_run: true,
               would_replace: replacement_count,
               diff_preview: generate_diff_preview(content, new_content)
             }}
          else
            case File.write(safe_path, new_content) do
              :ok ->
                {:ok,
                 %{
                   status: :success,
                   file: path,
                   replacements: replacement_count,
                   old_size: byte_size(content),
                   new_size: byte_size(new_content)
                 }}

              {:error, reason} ->
                {:error, %{reason: :write_failed, detail: reason}}
            end
          end
      end
    end
  end

  # Count occurrences of a substring
  defp count_occurrences(content, pattern) do
    # Split and count segments minus 1
    parts = String.split(content, pattern)
    length(parts) - 1
  end

  # Truncate long strings for error messages
  defp truncate_string(str, max_len) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len) <> "..."
    else
      str
    end
  end

  # Find match locations with context
  defp find_match_locations(content, pattern, max_matches) do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _idx} -> String.contains?(line, pattern) end)
    |> Enum.take(max_matches)
    |> Enum.map(fn {line, idx} ->
      %{line_number: idx, preview: truncate_string(String.trim(line), 80)}
    end)
  end

  # Generate a simple diff preview
  defp generate_diff_preview(old_content, new_content) do
    old_lines = String.split(old_content, "\n")
    new_lines = String.split(new_content, "\n")

    # Find first difference
    diff_start =
      Enum.zip(old_lines, new_lines)
      |> Enum.find_index(fn {old, new} -> old != new end)

    if diff_start do
      %{
        changed_at_line: diff_start + 1,
        old_line: Enum.at(old_lines, diff_start) |> truncate_string(100),
        new_line: Enum.at(new_lines, diff_start) |> truncate_string(100)
      }
    else
      %{no_visible_diff: true}
    end
  end

  # Legacy: read_lines for backward compatibility
  def read_lines(path, start_line, end_line \\ -1) when is_binary(path) do
    limit = if end_line == -1, do: @max_chunk_lines, else: end_line - start_line + 1
    read(path, offset: start_line, limit: limit)
  end

  # ==========================================================================
  # BASIC FILE OPERATIONS
  # ==========================================================================

  def write(path, content, opts \\ []) when is_binary(path) do
    mode = Keyword.get(opts, :mode, :rewrite)

    with {:ok, safe_path} <- expand_safe(path) do
      safe_path |> Path.dirname() |> File.mkdir_p()

      case mode do
        :append -> File.write(safe_path, content, [:append])
        _ -> File.write(safe_path, content)
      end
    end
  end

  def write_with_mode(path, content, mode) do
    write(path, content, mode: mode)
  end

  def ls(path \\ ".") when is_binary(path) do
    with {:ok, safe_path} <- expand_safe(path) do
      File.ls(safe_path)
    end
  end

  def list_directory(path, opts \\ []) when is_binary(path) do
    depth = Keyword.get(opts, :depth, 1)

    task =
      Task.async(fn ->
        with {:ok, safe_path} <- expand_safe(path) do
          entries = list_recursive(safe_path, depth, 0)
          {:ok, entries}
        end
      end)

    case Task.yield(task, @file_timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp list_recursive(path, max_depth, current_depth) when current_depth >= max_depth do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.map(entries, fn entry ->
          full_path = Path.join(path, entry)
          type = if File.dir?(full_path), do: :dir, else: :file
          %{name: entry, type: type}
        end)

      {:error, _} ->
        []
    end
  end

  defp list_recursive(path, max_depth, current_depth) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full_path = Path.join(path, entry)

          if File.dir?(full_path) do
            children = list_recursive(full_path, max_depth, current_depth + 1)
            [%{name: entry, type: :dir, children: children}]
          else
            [%{name: entry, type: :file}]
          end
        end)

      {:error, _} ->
        []
    end
  end

  def get_info(path) when is_binary(path) do
    task =
      Task.async(fn ->
        with {:ok, safe_path} <- expand_safe(path),
             {:ok, stat} <- File.stat(safe_path) do
          line_count =
            if stat.type == :regular and stat.size <= 1_000_000 do
              count_lines_fast(safe_path)
            else
              if stat.type == :regular, do: :large_file, else: 0
            end

          {:ok,
           %{
             path: safe_path,
             size: stat.size,
             type: stat.type,
             line_count: line_count,
             is_directory: stat.type == :directory,
             is_file: stat.type == :regular
           }}
        end
      end)

    case Task.yield(task, @file_timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  def exists?(path) when is_binary(path) do
    case expand_safe(path) do
      {:ok, safe_path} -> File.exists?(safe_path)
      {:error, _} -> false
    end
  end

  def create_directory(path) when is_binary(path) do
    with {:ok, safe_path} <- expand_safe(path) do
      File.mkdir_p(safe_path)
    end
  end

  def move(source, destination) when is_binary(source) and is_binary(destination) do
    with {:ok, safe_source} <- expand_safe(source),
         {:ok, safe_dest} <- expand_safe(destination) do
      File.rename(safe_source, safe_dest)
    end
  end

  def read_multiple(paths) when is_list(paths) do
    results =
      Enum.map(paths, fn path ->
        case read(path, limit: @max_chunk_lines) do
          {:ok, data} -> %{path: path, content: data.content, error: nil, truncated: data.has_more}
          {:error, reason} -> %{path: path, content: nil, error: reason, truncated: false}
        end
      end)

    {:ok, results}
  end

  # Legacy function for compatibility
  def search_content(base_path, pattern, opts \\ []) do
    search(base_path, pattern, opts)
  end

  # ==========================================================================
  # GLOB OPERATION - Pattern-based file discovery (SPEC-027)
  # ==========================================================================

  @doc """
  Find files matching a glob pattern.

  ## Options
    - `:base_path` - Base directory for search (default: sandbox root)
    - `:exclude` - List of patterns to exclude (e.g., ["node_modules", "dist"])
    - `:limit` - Maximum files to return (default: 100)
    - `:respect_gitignore` - Respect .gitignore patterns (default: true)

  ## Examples
      glob("**/*.ex")
      glob("src/**/*.{ts,tsx}", exclude: ["node_modules"])
  """
  def glob(pattern, opts \\ []) when is_binary(pattern) do
    base_path = Keyword.get(opts, :base_path, ".")
    exclude = Keyword.get(opts, :exclude, [])
    limit = Keyword.get(opts, :limit, 100)
    respect_gitignore = Keyword.get(opts, :respect_gitignore, true)

    with {:ok, safe_base} <- expand_safe(base_path) do
      full_pattern = Path.join(safe_base, pattern)

      # Load gitignore patterns if requested
      gitignore_patterns =
        if respect_gitignore do
          load_gitignore_patterns(safe_base)
        else
          []
        end

      all_matches = Path.wildcard(full_pattern)

      results =
        all_matches
        |> Enum.reject(&should_exclude?(&1, exclude))
        |> Enum.reject(&matches_gitignore?(&1, gitignore_patterns, safe_base))
        |> Enum.take(limit)
        |> Enum.map(&Path.relative_to(&1, safe_base))

      {:ok,
       %{
         pattern: pattern,
         base_path: base_path,
         matches: results,
         count: length(results),
         truncated: length(all_matches) > limit
       }}
    else
      {:error, reason} -> format_file_error(reason, base_path)
    end
  end

  defp should_exclude?(path, excludes) do
    Enum.any?(excludes, fn exclude ->
      String.contains?(path, exclude)
    end)
  end

  defp load_gitignore_patterns(base_path) do
    gitignore_path = Path.join(base_path, ".gitignore")

    if File.exists?(gitignore_path) do
      gitignore_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
      |> Enum.map(&String.trim/1)
    else
      []
    end
  end

  defp matches_gitignore?(path, patterns, base_path) do
    relative = Path.relative_to(path, base_path)

    Enum.any?(patterns, fn pattern ->
      # Simple pattern matching - convert gitignore patterns to simple checks
      cond do
        String.starts_with?(pattern, "/") ->
          # Anchored to root
          String.starts_with?(relative, String.slice(pattern, 1..-1//1))

        String.ends_with?(pattern, "/") ->
          # Directory pattern
          dir_pattern = String.slice(pattern, 0..-2//1)

          String.contains?(relative, "/" <> dir_pattern <> "/") or
            String.starts_with?(relative, dir_pattern <> "/")

        String.contains?(pattern, "*") ->
          # Wildcard - convert to simple regex
          regex_pattern =
            pattern
            |> String.replace(".", "\\.")
            |> String.replace("*", ".*")

          Regex.match?(~r/#{regex_pattern}/, relative)

        true ->
          # Simple contains check
          String.contains?(relative, pattern)
      end
    end)
  end

  # ==========================================================================
  # MULTI-REPLACE OPERATION - Atomic multi-file edits (SPEC-027)
  # ==========================================================================

  @doc """
  Perform atomic multi-file replacements.
  Validates ALL replacements exist before modifying ANY files.

  ## Parameters
    - `replacements` - List of maps with :path, :old, :new keys

  ## Options
    - `:global` - Replace all occurrences (default: false)

  ## Example
      multi_replace([
        %{path: "/app/a.ex", old: "foo", new: "bar"},
        %{path: "/app/b.ex", old: "baz", new: "qux"}
      ])
  """
  def multi_replace(replacements, opts \\ []) when is_list(replacements) do
    global = Keyword.get(opts, :global, false)

    # Phase 1: Expand and group replacements by file path
    grouped =
      Enum.reduce(replacements, %{}, fn r, acc ->
        path = r["path"] || r[:path]
        old_str = r["old"] || r[:old]
        new_str = r["new"] || r[:new]

        case expand_safe(path) do
          {:ok, safe_path} ->
            entry = %{old: old_str, new: new_str}
            Map.update(acc, safe_path, [entry], fn entries -> entries ++ [entry] end)

          {:error, _} ->
            # Track error but continue collecting
            Map.update(acc, {:error, path}, [{:error, :invalid_path}], fn e -> e end)
        end
      end)

    # Separate valid paths from error paths
    {valid_paths, error_paths} =
      Enum.split_with(grouped, fn {k, _} -> is_binary(k) end)

    if error_paths != [] do
      {:error,
       %{
         status: "validation_failed",
         errors: Enum.map(error_paths, fn {{:error, path}, _} -> "Invalid path: #{path}" end)
       }}
    else
      # Phase 2: Validate all patterns exist in their respective files
      validations =
        Enum.map(valid_paths, fn {path, entries} ->
          case File.read(path) do
            {:ok, content} ->
              # Check all patterns exist
              missing =
                Enum.filter(entries, fn %{old: old_str} ->
                  not String.contains?(content, old_str)
                end)

              if missing == [] do
                {:ok, %{path: path, content: content, entries: entries}}
              else
                {:error, {:patterns_not_found, path, Enum.map(missing, & &1.old)}}
              end

            {:error, reason} ->
              {:error, {reason, path}}
          end
        end)

      errors = Enum.filter(validations, &match?({:error, _}, &1))

      if errors != [] do
        {:error,
         %{
           status: "validation_failed",
           errors:
             Enum.map(errors, fn {:error, e} ->
               case e do
                 {:patterns_not_found, path, patterns} ->
                   "Patterns not found in #{path}: #{Enum.map_join(patterns, ", ", &String.slice(&1, 0, 30))}"

                 {reason, path} ->
                   "#{reason}: #{path}"
               end
             end)
         }}
      else
        # Phase 3: Apply all replacements sequentially per file
        results =
          Enum.map(validations, fn {:ok, %{path: path, content: content, entries: entries}} ->
            # Apply all replacements for this file in order
            final_content =
              Enum.reduce(entries, content, fn %{old: old_str, new: new_str}, acc ->
                if global do
                  String.replace(acc, old_str, new_str)
                else
                  String.replace(acc, old_str, new_str, global: false)
                end
              end)

            case File.write(path, final_content) do
              :ok -> {:ok, path}
              error -> error
            end
          end)

        write_errors = Enum.filter(results, &match?({:error, _}, &1))

        if write_errors != [] do
          {:error,
           %{
             status: "partial_failure",
             errors: Enum.map(write_errors, fn {:error, e} -> inspect(e) end),
             successful:
               Enum.filter(results, &match?({:ok, _}, &1)) |> Enum.map(fn {:ok, p} -> p end)
           }}
        else
          {:ok,
           %{
             status: "success",
             files_modified: length(results),
             paths: Enum.map(results, fn {:ok, p} -> p end)
           }}
        end
      end
    end
  end

  # ==========================================================================
  # DIFF OPERATION - Show file differences (SPEC-027)
  # ==========================================================================

  @doc """
  Show differences between files or between file and proposed content.

  ## Usage
      diff(path1: "/app/old.ex", path2: "/app/new.ex")
      diff(path: "/app/file.ex", proposed_content: "new content...")
  """
  def diff(opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :path1) and Keyword.has_key?(opts, :path2) ->
        diff_files(Keyword.get(opts, :path1), Keyword.get(opts, :path2))

      Keyword.has_key?(opts, :path) and Keyword.has_key?(opts, :proposed_content) ->
        diff_with_proposed(Keyword.get(opts, :path), Keyword.get(opts, :proposed_content))

      true ->
        {:error, "Provide path1+path2 or path+proposed_content"}
    end
  end

  defp diff_files(path1, path2) do
    with {:ok, safe_path1} <- expand_safe(path1),
         {:ok, safe_path2} <- expand_safe(path2),
         {:ok, content1} <- File.read(safe_path1),
         {:ok, content2} <- File.read(safe_path2) do
      diff = compute_diff(content1, content2)

      {:ok,
       %{
         path1: path1,
         path2: path2,
         diff: diff,
         summary: diff_summary(content1, content2)
       }}
    else
      {:error, reason} -> format_file_error(reason, "#{path1} or #{path2}")
    end
  end

  defp diff_with_proposed(path, proposed_content) do
    with {:ok, safe_path} <- expand_safe(path),
         {:ok, current_content} <- File.read(safe_path) do
      diff = compute_diff(current_content, proposed_content)

      {:ok,
       %{
         path: path,
         diff: diff,
         summary: diff_summary(current_content, proposed_content)
       }}
    else
      {:error, reason} -> format_file_error(reason, path)
    end
  end

  defp compute_diff(content1, content2) do
    # Line-based diff for better readability
    lines1 = String.split(content1, "\n")
    lines2 = String.split(content2, "\n")

    format_line_diff(lines1, lines2)
  end

  defp format_line_diff(lines1, lines2) do
    # Simple line-by-line comparison
    max_len = max(length(lines1), length(lines2))

    0..(max_len - 1)
    |> Enum.flat_map(fn i ->
      line1 = Enum.at(lines1, i)
      line2 = Enum.at(lines2, i)

      cond do
        line1 == line2 ->
          []

        is_nil(line1) ->
          ["+ #{line2}"]

        is_nil(line2) ->
          ["- #{line1}"]

        true ->
          ["- #{line1}", "+ #{line2}"]
      end
    end)
    |> Enum.join("\n")
  end

  defp diff_summary(content1, content2) do
    lines1 = String.split(content1, "\n")
    lines2 = String.split(content2, "\n")

    # Count actual changes
    max_len = max(length(lines1), length(lines2))

    {additions, deletions} =
      0..(max_len - 1)
      |> Enum.reduce({0, 0}, fn i, {adds, dels} ->
        line1 = Enum.at(lines1, i)
        line2 = Enum.at(lines2, i)

        cond do
          line1 == line2 -> {adds, dels}
          is_nil(line1) -> {adds + 1, dels}
          is_nil(line2) -> {adds, dels + 1}
          true -> {adds + 1, dels + 1}
        end
      end)

    %{
      lines_before: length(lines1),
      lines_after: length(lines2),
      additions: additions,
      deletions: deletions
    }
  end

  # ==========================================================================
  # PATH SECURITY
  # ==========================================================================

  defp expand_safe(path) do
    roots = allowed_roots()

    expanded =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, sandbox_root())
      end

    # Resolve symlinks
    resolved =
      case File.read_link(expanded) do
        {:ok, link_target} -> Path.expand(link_target, Path.dirname(expanded))
        {:error, _} -> expanded
      end

    # Check if resolved path is within any allowed root
    if Enum.any?(roots, fn root -> String.starts_with?(resolved, root) end) do
      {:ok, resolved}
    else
      {:error, :path_outside_allowed_roots}
    end
  end
end
