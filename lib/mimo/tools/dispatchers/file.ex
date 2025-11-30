defmodule Mimo.Tools.Dispatchers.File do
  @moduledoc """
  File operations dispatcher.

  Handles all file system operations:
  - read, write, ls, read_lines
  - insert_after, insert_before, replace_lines, delete_lines
  - search, replace_string, edit
  - list_directory, get_info, move, create_directory
  - read_multiple, list_symbols, read_symbol, search_symbols
  - glob, multi_replace, diff

  All operations map to Mimo.Skills.FileOps.* functions.
  """

  alias Mimo.Tools.Helpers

  @doc """
  Dispatch file operation based on args.
  """
  def dispatch(%{"operation" => op} = args) do
    path = args["path"] || "."
    skip_context = Map.get(args, "skip_memory_context", false)

    case op do
      "read" ->
        dispatch_read(path, args, skip_context)

      "write" ->
        content = args["content"] || ""
        mode = if args["mode"] == "append", do: :append, else: :rewrite
        Mimo.Skills.FileOps.write(path, content, mode: mode)

      "ls" ->
        Mimo.Skills.FileOps.ls(path)

      "read_lines" ->
        start_line = args["start_line"] || 1
        end_line = args["end_line"] || -1
        Mimo.Skills.FileOps.read_lines(path, start_line, end_line)

      "insert_after" ->
        Mimo.Skills.FileOps.insert_after_line(path, args["line_number"] || 0, args["content"] || "")

      "insert_before" ->
        Mimo.Skills.FileOps.insert_before_line(
          path,
          args["line_number"] || 1,
          args["content"] || ""
        )

      "replace_lines" ->
        start_line = args["start_line"] || 1
        end_line = args["end_line"] || start_line
        Mimo.Skills.FileOps.replace_lines(path, start_line, end_line, args["content"] || "")

      "delete_lines" ->
        start_line = args["start_line"] || 1
        end_line = args["end_line"] || start_line
        Mimo.Skills.FileOps.delete_lines(path, start_line, end_line)

      "search" ->
        opts = [max_results: args["max_results"] || 50]
        Mimo.Skills.FileOps.search(path, args["pattern"] || "", opts)

      "replace_string" ->
        Mimo.Skills.FileOps.replace_string(path, args["old_str"] || "", args["new_str"] || "")

      "edit" ->
        dispatch_edit(path, args, skip_context)

      "list_directory" ->
        Mimo.Skills.FileOps.list_directory(path, depth: args["depth"] || 1)

      "get_info" ->
        Mimo.Skills.FileOps.get_info(path)

      "move" ->
        Mimo.Skills.FileOps.move(path, args["destination"] || "")

      "create_directory" ->
        Mimo.Skills.FileOps.create_directory(path)

      "read_multiple" ->
        Mimo.Skills.FileOps.read_multiple(args["paths"] || [])

      "list_symbols" ->
        Mimo.Skills.FileOps.list_symbols(path)

      "read_symbol" ->
        dispatch_read_symbol(path, args)

      "search_symbols" ->
        opts = [max_results: args["max_results"] || 50]
        Mimo.Skills.FileOps.search_symbols(path, args["pattern"] || "", opts)

      "glob" ->
        dispatch_glob(args)

      "multi_replace" ->
        dispatch_multi_replace(args)

      "diff" ->
        dispatch_diff(args)

      _ ->
        {:error, "Unknown file operation: #{op}"}
    end
  end

  def dispatch(_), do: {:error, "Operation required"}

  # ==========================================================================
  # PRIVATE HELPERS
  # ==========================================================================

  defp dispatch_read(path, args, skip_context) do
    opts = []
    opts = if args["offset"], do: Keyword.put(opts, :offset, args["offset"]), else: opts
    opts = if args["limit"], do: Keyword.put(opts, :limit, args["limit"]), else: opts

    result = Mimo.Skills.FileOps.read(path, opts)
    Helpers.enrich_file_response(result, path, skip_context)
  end

  defp dispatch_edit(path, args, skip_context) do
    opts = []
    opts = if args["global"], do: Keyword.put(opts, :global, args["global"]), else: opts

    opts =
      if args["expected_count"],
        do: Keyword.put(opts, :expected_count, args["expected_count"]),
        else: opts

    opts = if args["dry_run"], do: Keyword.put(opts, :dry_run, args["dry_run"]), else: opts

    result = Mimo.Skills.FileOps.edit(path, args["old_str"] || "", args["new_str"] || "", opts)
    Helpers.enrich_file_response(result, path, skip_context)
  end

  defp dispatch_read_symbol(path, args) do
    opts = []

    opts =
      if args["context_before"],
        do: Keyword.put(opts, :context_before, args["context_before"]),
        else: opts

    opts =
      if args["context_after"],
        do: Keyword.put(opts, :context_after, args["context_after"]),
        else: opts

    Mimo.Skills.FileOps.read_symbol(path, args["symbol_name"] || "", opts)
  end

  defp dispatch_glob(args) do
    opts = []
    opts = if args["base_path"], do: Keyword.put(opts, :base_path, args["base_path"]), else: opts
    opts = if args["exclude"], do: Keyword.put(opts, :exclude, args["exclude"]), else: opts
    opts = if args["limit"], do: Keyword.put(opts, :limit, args["limit"]), else: opts

    opts =
      if Map.has_key?(args, "respect_gitignore"),
        do: Keyword.put(opts, :respect_gitignore, args["respect_gitignore"]),
        else: opts

    Mimo.Skills.FileOps.glob(args["pattern"] || "**/*", opts)
  end

  defp dispatch_multi_replace(args) do
    replacements = args["replacements"] || []
    opts = []
    opts = if args["global"], do: Keyword.put(opts, :global, args["global"]), else: opts
    Mimo.Skills.FileOps.multi_replace(replacements, opts)
  end

  defp dispatch_diff(args) do
    opts = []
    opts = if args["path1"], do: Keyword.put(opts, :path1, args["path1"]), else: opts
    opts = if args["path2"], do: Keyword.put(opts, :path2, args["path2"]), else: opts
    opts = if args["path"], do: Keyword.put(opts, :path, args["path"]), else: opts

    opts =
      if args["proposed_content"],
        do: Keyword.put(opts, :proposed_content, args["proposed_content"]),
        else: opts

    Mimo.Skills.FileOps.diff(opts)
  end
end
