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

  defp sandbox_root do
    (System.get_env("MIMO_ROOT") || File.cwd!()) |> Path.expand()
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
         true <- stat.size <= @max_file_size do
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
      content = lines |> Enum.map(fn {line, _idx} -> line end) |> Enum.join()

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
      {:error, _} = err -> err
      false -> {:error, :file_too_large}
    end
  end

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
  # PATH SECURITY
  # ==========================================================================

  defp expand_safe(relative_path) do
    root = sandbox_root()

    if Path.type(relative_path) == :absolute do
      {:error, :absolute_path_not_allowed}
    else
      expanded = Path.expand(relative_path, root)

      resolved =
        case File.read_link(expanded) do
          {:ok, link_target} -> Path.expand(link_target, root)
          {:error, _} -> expanded
        end

      if String.starts_with?(resolved, root) do
        {:ok, resolved}
      else
        {:error, :path_traversal_attempt}
      end
    end
  end
end
