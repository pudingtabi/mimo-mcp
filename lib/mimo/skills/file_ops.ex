defmodule Mimo.Skills.FileOps do
  @moduledoc """
  Sandboxed file operations with path traversal prevention.
  Supports full-file and line-level operations.
  """

  @max_file_size 10 * 1024 * 1024

  defp sandbox_root do
    (System.get_env("MIMO_ROOT") || File.cwd!()) |> Path.expand()
  end

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

  def write(path, content) when is_binary(path) and is_binary(content) do
    with {:ok, safe_path} <- expand_safe(path) do
      safe_path |> Path.dirname() |> File.mkdir_p()
      File.write(safe_path, content)
    end
  end

  def ls(path \\ ".") when is_binary(path) do
    with {:ok, safe_path} <- expand_safe(path) do
      File.ls(safe_path)
    end
  end

  def exists?(path) when is_binary(path) do
    case expand_safe(path) do
      {:ok, safe_path} -> File.exists?(safe_path)
      {:error, _} -> false
    end
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
