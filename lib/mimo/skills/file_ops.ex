defmodule Mimo.Skills.FileOps do
  @moduledoc """
  Sandboxed file operations with path traversal prevention.
  Supports full-file and line-level operations.

  Native replacement for desktop_commander file operations.
  """

  @max_file_size 10 * 1024 * 1024
  @default_read_limit 1000

  defp sandbox_root do
    (System.get_env("MIMO_ROOT") || File.cwd!()) |> Path.expand()
  end

  # ==========================================================================
  # Core File Operations
  # ==========================================================================

  def read(path) when is_binary(path) do
    with {:ok, safe_path} <- expand_safe(path),
         {:ok, stat} <- File.stat(safe_path),
         true <- stat.size <= @max_file_size do
      File.read(safe_path)
    else
      {:error, _} = err -> err
      false -> {:error, :file_too_large}
    end
  end

  @doc """
  Read file with pagination support (offset/length).
  Compatible with desktop_commander read_file.
  """
  def read_paginated(path, opts \\ []) when is_binary(path) do
    offset = Keyword.get(opts, :offset, 0)
    length = Keyword.get(opts, :length, @default_read_limit)

    with {:ok, content} <- read(path) do
      lines = String.split(content, "\n")
      total_lines = length(lines)

      selected = lines |> Enum.drop(offset) |> Enum.take(length)
      remaining = max(0, total_lines - offset - length)

      result = %{
        content: Enum.join(selected, "\n"),
        total_lines: total_lines,
        offset: offset,
        lines_read: length(selected),
        remaining: remaining
      }

      {:ok, result}
    end
  end

  @doc """
  Read multiple files simultaneously.
  Compatible with desktop_commander read_multiple_files.
  """
  def read_multiple(paths) when is_list(paths) do
    results =
      Enum.map(paths, fn path ->
        case read(path) do
          {:ok, content} -> %{path: path, content: content, error: nil}
          {:error, reason} -> %{path: path, content: nil, error: reason}
        end
      end)

    {:ok, results}
  end

  def write(path, content) when is_binary(path) and is_binary(content) do
    with {:ok, safe_path} <- expand_safe(path) do
      safe_path |> Path.dirname() |> File.mkdir_p()
      File.write(safe_path, content)
    end
  end

  @doc """
  Write file with mode support (rewrite/append).
  Compatible with desktop_commander write_file.
  """
  def write_with_mode(path, content, mode \\ :rewrite) when is_binary(path) do
    with {:ok, safe_path} <- expand_safe(path) do
      safe_path |> Path.dirname() |> File.mkdir_p()

      case mode do
        :append -> File.write(safe_path, content, [:append])
        _ -> File.write(safe_path, content)
      end
    end
  end

  def ls(path \\ ".") when is_binary(path) do
    with {:ok, safe_path} <- expand_safe(path) do
      File.ls(safe_path)
    end
  end

  @doc """
  List directory with detailed info and depth control.
  Compatible with desktop_commander list_directory.
  """
  def list_directory(path, opts \\ []) when is_binary(path) do
    depth = Keyword.get(opts, :depth, 1)

    with {:ok, safe_path} <- expand_safe(path) do
      entries = list_recursive(safe_path, depth, 0)
      {:ok, entries}
    end
  end

  defp list_recursive(path, max_depth, current_depth) when current_depth >= max_depth do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.map(entries, fn entry ->
          full_path = Path.join(path, entry)
          type = if File.dir?(full_path), do: :dir, else: :file
          %{name: entry, type: type, path: full_path}
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
            [%{name: entry, type: :dir, path: full_path, children: children}]
          else
            [%{name: entry, type: :file, path: full_path}]
          end
        end)

      {:error, _} ->
        []
    end
  end

  def exists?(path) when is_binary(path) do
    case expand_safe(path) do
      {:ok, safe_path} -> File.exists?(safe_path)
      {:error, _} -> false
    end
  end

  @doc """
  Create directory (mkdir -p style).
  Compatible with desktop_commander create_directory.
  """
  def create_directory(path) when is_binary(path) do
    with {:ok, safe_path} <- expand_safe(path) do
      File.mkdir_p(safe_path)
    end
  end

  @doc """
  Move or rename file/directory.
  Compatible with desktop_commander move_file.
  """
  def move(source, destination) when is_binary(source) and is_binary(destination) do
    with {:ok, safe_source} <- expand_safe(source),
         {:ok, safe_dest} <- expand_safe(destination) do
      File.rename(safe_source, safe_dest)
    end
  end

  @doc """
  Get detailed file info.
  Compatible with desktop_commander get_file_info.
  """
  def get_info(path) when is_binary(path) do
    with {:ok, safe_path} <- expand_safe(path),
         {:ok, stat} <- File.stat(safe_path) do
      line_count =
        if stat.type == :regular do
          case File.read(safe_path) do
            {:ok, content} -> length(String.split(content, "\n"))
            _ -> 0
          end
        else
          0
        end

      {:ok,
       %{
         path: safe_path,
         size: stat.size,
         type: stat.type,
         access: stat.access,
         atime: stat.atime,
         mtime: stat.mtime,
         ctime: stat.ctime,
         mode: stat.mode,
         line_count: line_count,
         is_directory: stat.type == :directory,
         is_file: stat.type == :regular
       }}
    end
  end

  # ==========================================================================
  # Search Operations (replaces desktop_commander search)
  # ==========================================================================

  @doc """
  Search for files by name pattern (glob-style).
  """
  def search_files(base_path, pattern, opts \\ []) when is_binary(base_path) do
    max_results = Keyword.get(opts, :max_results, 100)

    with {:ok, safe_path} <- expand_safe(base_path) do
      results = find_files(safe_path, pattern, max_results, [])
      {:ok, results}
    end
  end

  defp find_files(_path, _pattern, max, acc) when length(acc) >= max, do: Enum.reverse(acc)

  defp find_files(path, pattern, max, acc) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, current_acc ->
          if length(current_acc) >= max do
            current_acc
          else
            full_path = Path.join(path, entry)
            matches = if String.contains?(entry, pattern), do: [full_path], else: []
            new_acc = current_acc ++ matches

            if File.dir?(full_path) do
              find_files(full_path, pattern, max, new_acc)
            else
              new_acc
            end
          end
        end)

      {:error, _} ->
        acc
    end
  end

  @doc """
  Search file contents using grep-style pattern matching.
  """
  def search_content(base_path, pattern, opts \\ []) when is_binary(base_path) do
    max_results = Keyword.get(opts, :max_results, 100)

    with {:ok, safe_path} <- expand_safe(base_path) do
      regex = Regex.compile!(pattern)
      results = grep_files(safe_path, regex, max_results, [])
      {:ok, results}
    end
  end

  defp grep_files(_path, _regex, max, acc) when length(acc) >= max, do: Enum.reverse(acc)

  defp grep_files(path, regex, max, acc) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, current_acc ->
          if length(current_acc) >= max do
            current_acc
          else
            full_path = Path.join(path, entry)

            if File.dir?(full_path) do
              grep_files(full_path, regex, max, current_acc)
            else
              case File.read(full_path) do
                {:ok, content} ->
                  matches = find_line_matches(content, regex, full_path)
                  (current_acc ++ matches) |> Enum.take(max)

                {:error, _} ->
                  current_acc
              end
            end
          end
        end)

      {:error, _} ->
        acc
    end
  end

  defp find_line_matches(content, regex, file_path) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {line, num} -> %{file: file_path, line: num, content: line} end)
  end

  # ==========================================================================
  # Line-Level Operations
  # ==========================================================================

  @doc """
  Reads specific lines from a file.

  ## Parameters
    - `path` - Relative path to file
    - `start_line` - First line to read (1-indexed)
    - `end_line` - Last line to read (inclusive, or -1 for end of file)

  ## Returns
    - `{:ok, lines}` - List of line strings
    - `{:error, reason}` - Error tuple
  """
  def read_lines(path, start_line, end_line \\ -1) when is_binary(path) do
    with {:ok, content} <- read(path) do
      lines = String.split(content, "\n")
      total = length(lines)

      end_idx = if end_line == -1, do: total, else: min(end_line, total)
      start_idx = max(1, start_line)

      if start_idx > total do
        {:ok, []}
      else
        selected = Enum.slice(lines, (start_idx - 1)..(end_idx - 1))
        {:ok, selected}
      end
    end
  end

  @doc """
  Inserts content after a specific line number.

  ## Parameters
    - `path` - Relative path to file
    - `line_number` - Line after which to insert (0 = beginning of file)
    - `content` - Content to insert

  ## Returns
    - `:ok` - Success
    - `{:error, reason}` - Error tuple
  """
  def insert_after_line(path, line_number, content) when is_binary(path) and is_binary(content) do
    with {:ok, existing} <- read(path) do
      lines = String.split(existing, "\n")
      new_lines = content |> String.split("\n")

      {before, after_lines} = Enum.split(lines, line_number)
      result = Enum.join(before ++ new_lines ++ after_lines, "\n")

      write(path, result)
    end
  end

  @doc """
  Inserts content before a specific line number.

  ## Parameters
    - `path` - Relative path to file
    - `line_number` - Line before which to insert (1-indexed)
    - `content` - Content to insert
  """
  def insert_before_line(path, line_number, content) when is_binary(path) and is_binary(content) do
    insert_after_line(path, max(0, line_number - 1), content)
  end

  @doc """
  Replaces specific lines in a file.

  ## Parameters
    - `path` - Relative path to file
    - `start_line` - First line to replace (1-indexed)
    - `end_line` - Last line to replace (inclusive)
    - `content` - Replacement content
  """
  def replace_lines(path, start_line, end_line, content)
      when is_binary(path) and is_binary(content) do
    with {:ok, existing} <- read(path) do
      lines = String.split(existing, "\n")
      new_lines = content |> String.split("\n")

      before = Enum.take(lines, start_line - 1)
      after_lines = Enum.drop(lines, end_line)
      result = Enum.join(before ++ new_lines ++ after_lines, "\n")

      write(path, result)
    end
  end

  @doc """
  Deletes specific lines from a file.

  ## Parameters
    - `path` - Relative path to file
    - `start_line` - First line to delete (1-indexed)
    - `end_line` - Last line to delete (inclusive)
  """
  def delete_lines(path, start_line, end_line) when is_binary(path) do
    with {:ok, existing} <- read(path) do
      lines = String.split(existing, "\n")

      before = Enum.take(lines, start_line - 1)
      after_lines = Enum.drop(lines, end_line)
      result = Enum.join(before ++ after_lines, "\n")

      write(path, result)
    end
  end

  @doc """
  Searches for a pattern and returns matching line numbers.

  ## Parameters
    - `path` - Relative path to file
    - `pattern` - Regex pattern or string to search for

  ## Returns
    - `{:ok, [{line_number, line_content}]}` - List of matches
  """
  def search_lines(path, pattern) when is_binary(path) do
    with {:ok, content} <- read(path) do
      regex = if is_binary(pattern), do: Regex.compile!(Regex.escape(pattern)), else: pattern

      matches =
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _idx} -> Regex.match?(regex, line) end)
        |> Enum.map(fn {line, idx} -> {idx, line} end)

      {:ok, matches}
    end
  end

  @doc """
  Replaces first occurrence of a pattern in the file.

  ## Parameters
    - `path` - Relative path to file
    - `old_str` - String to find
    - `new_str` - Replacement string
  """
  def replace_string(path, old_str, new_str) when is_binary(path) do
    with {:ok, content} <- read(path) do
      if String.contains?(content, old_str) do
        new_content = String.replace(content, old_str, new_str, global: false)
        write(path, new_content)
      else
        {:error, :pattern_not_found}
      end
    end
  end

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
