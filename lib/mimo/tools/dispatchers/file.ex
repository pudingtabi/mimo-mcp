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

  All operations map to FileOps.* functions.

  ## SPEC-064: Structural Token Optimization

  File read operations are intercepted by `FileReadInterceptor` to check
  memory and cache before hitting the filesystem. This reduces redundant
  reads and token usage.

  To skip interception, pass `skip_interception: true` in the args.
  """

  alias Mimo.Cognitive.{FeedbackLoop, OutcomeDetector}
  alias Mimo.Skills.FileOps
  alias Mimo.Tools.Dispatchers.Code, as: CodeDispatcher
  alias Mimo.Skills.{FileContentCache, FileReadCache, FileReadInterceptor}
  alias Mimo.Tools.{Helpers, Suggestions}
  alias Mimo.Verification.ActionVerifier

  require Logger

  # Operation categories:
  # - Read: read, read_lines, read_multiple, read_symbol
  # - Write: write, edit, replace_string, multi_replace
  # - Search: search, list_symbols, search_symbols, glob
  # - Nav: ls, list_directory, get_info, move, create_directory
  # - Line: insert_after, insert_before, replace_lines, delete_lines
  # - Diff: diff

  @doc """
  Dispatch file operation based on args.
  """
  def dispatch(%{"operation" => op} = args) do
    path = args["path"] || "."
    skip_context = Map.get(args, "skip_memory_context", true)

    # SPEC-2026-001: Capture state before write operations for verification
    before_state = maybe_capture_before_state(op, path)

    result = do_dispatch(op, path, args, skip_context)

    # SPEC-2026-001: Verify actual change for write operations
    verification = maybe_verify_action(op, path, before_state, result)

    # SPEC-087: Record outcome for write operations
    record_file_outcome(op, path, result, verification)

    # Add cross-tool suggestions (SPEC-031 Phase 2)
    result_with_verification = add_verification_to_result(result, verification)
    Suggestions.maybe_add_suggestion(result_with_verification, "file", args)
  end

  def dispatch(_), do: {:error, "Operation required"}

  # Capture state before write operations for verification
  @write_ops_to_verify ~w(write edit replace_string multi_replace)

  defp maybe_capture_before_state(op, path) when op in @write_ops_to_verify do
    ActionVerifier.capture_state(:file_edit, path)
  end

  defp maybe_capture_before_state(_op, _path), do: nil

  # Verify action after write operations
  defp maybe_verify_action(op, path, before_state, result)
       when op in @write_ops_to_verify and not is_nil(before_state) do
    ActionVerifier.verify(:file_edit, path, before_state, result)
  end

  defp maybe_verify_action(_op, _path, _before_state, _result), do: nil

  # Add verification result to response
  defp add_verification_to_result({:ok, data}, {:phantom_success, details}) do
    Logger.warning("[Agent Verification] Phantom success detected: #{inspect(details)}")

    {:ok,
     Map.merge(data, %{
       verification: %{
         status: :phantom_success,
         warning: "Action succeeded but no change detected",
         details: details
       }
     })}
  end

  defp add_verification_to_result({:ok, data}, {:verified, details}) do
    {:ok, Map.put(data, :verification, %{status: :verified, details: details})}
  end

  defp add_verification_to_result(result, _), do: result

  # Read operations
  defp do_dispatch("read", path, args, skip_context), do: dispatch_read(path, args, skip_context)

  defp do_dispatch("read_lines", path, args, _skip_context) do
    start_line = args["start_line"] || 1
    end_line = args["end_line"] || -1
    FileOps.read_lines(path, start_line, end_line)
  end

  defp do_dispatch("read_multiple", _path, args, _skip_context) do
    FileOps.read_multiple(args["paths"] || [])
  end

  defp do_dispatch("read_symbol", path, args, _skip_context), do: dispatch_read_symbol(path, args)

  # Write operations
  defp do_dispatch("write", path, args, _skip_context) do
    content = args["content"] || ""
    mode = if args["mode"] == "append", do: :append, else: :rewrite
    result = FileOps.write(path, content, mode: mode)
    FileReadCache.invalidate(path)
    result
  end

  defp do_dispatch("edit", path, args, skip_context), do: dispatch_edit(path, args, skip_context)

  defp do_dispatch("replace_string", path, args, _skip_context) do
    result = FileOps.replace_string(path, args["old_str"] || "", args["new_str"] || "")
    FileReadCache.invalidate(path)
    result
  end

  defp do_dispatch("multi_replace", _path, args, _skip_context), do: dispatch_multi_replace(args)

  # Search operations
  defp do_dispatch("search", path, args, _skip_context) do
    opts = [max_results: args["max_results"] || 50]
    FileOps.search(path, args["pattern"] || "", opts)
  end

  defp do_dispatch("list_symbols", path, _args, _skip_context) do
    FileOps.list_symbols(path)
  end

  defp do_dispatch("search_symbols", path, args, _skip_context) do
    opts = [max_results: args["max_results"] || 50]
    FileOps.search_symbols(path, args["pattern"] || "", opts)
  end

  defp do_dispatch("glob", _path, args, _skip_context), do: dispatch_glob(args)

  # Navigation operations
  defp do_dispatch("ls", path, _args, _skip_context), do: FileOps.ls(path)

  defp do_dispatch("list_directory", path, args, _skip_context) do
    FileOps.list_directory(path, depth: args["depth"] || 1)
  end

  defp do_dispatch("get_info", path, _args, _skip_context), do: FileOps.get_info(path)

  defp do_dispatch("move", path, args, _skip_context) do
    result = FileOps.move(path, args["destination"] || "")
    FileReadCache.invalidate(path)
    if args["destination"], do: FileReadCache.invalidate(args["destination"])
    result
  end

  defp do_dispatch("create_directory", path, _args, _skip_context) do
    FileOps.create_directory(path)
  end

  # Line operations
  defp do_dispatch("insert_after", path, args, _skip_context) do
    result =
      FileOps.insert_after_line(path, args["line_number"] || 0, args["content"] || "")

    FileReadCache.invalidate(path)
    result
  end

  defp do_dispatch("insert_before", path, args, _skip_context) do
    result =
      FileOps.insert_before_line(path, args["line_number"] || 1, args["content"] || "")

    FileReadCache.invalidate(path)
    result
  end

  defp do_dispatch("replace_lines", path, args, _skip_context) do
    start_line = args["start_line"] || 1
    end_line = args["end_line"] || start_line
    result = FileOps.replace_lines(path, start_line, end_line, args["content"] || "")
    FileReadCache.invalidate(path)
    result
  end

  defp do_dispatch("delete_lines", path, args, _skip_context) do
    start_line = args["start_line"] || 1
    end_line = args["end_line"] || start_line
    result = FileOps.delete_lines(path, start_line, end_line)
    FileReadCache.invalidate(path)
    result
  end

  # Diff operations
  defp do_dispatch("diff", _path, args, _skip_context), do: dispatch_diff(args)

  # Find where a function/class/module is defined
  defp do_dispatch("find_definition", _path, args, _skip_context) do
    CodeDispatcher.dispatch(Map.put(args, "operation", "definition"))
    |> add_deprecation_warning("find_definition", "code operation=definition")
  end

  # Find all usages/references to a symbol
  defp do_dispatch("find_references", _path, args, _skip_context) do
    CodeDispatcher.dispatch(Map.put(args, "operation", "references"))
    |> add_deprecation_warning("find_references", "code operation=references")
  end

  # List all symbols in a file (functions, classes, modules)
  defp do_dispatch("symbols", path, args, _skip_context) do
    CodeDispatcher.dispatch(
      Map.put(args, "operation", "symbols")
      |> Map.put("path", path)
    )
    |> add_deprecation_warning("symbols", "code operation=symbols")
  end

  # Search symbols by pattern
  defp do_dispatch("find_symbol", _path, args, _skip_context) do
    CodeDispatcher.dispatch(Map.put(args, "operation", "search"))
    |> add_deprecation_warning("find_symbol", "code operation=search")
  end

  # Get call graph for a function
  defp do_dispatch("call_graph", _path, args, _skip_context) do
    CodeDispatcher.dispatch(Map.put(args, "operation", "call_graph"))
    |> add_deprecation_warning("call_graph", "code operation=call_graph")
  end

  # Batch search - search for multiple patterns in one call
  defp do_dispatch("batch_search", path, args, _skip_context) do
    patterns = args["patterns"] || []
    max_results = args["max_results"] || 20

    if patterns == [] do
      {:error, "Missing required argument: 'patterns' (list of search patterns)"}
    else
      results =
        patterns
        |> Enum.map(fn pattern ->
          case FileOps.search(path, pattern, max_results: max_results) do
            {:ok, matches} -> {pattern, matches}
            {:error, reason} -> {pattern, {:error, reason}}
          end
        end)
        |> Enum.into(%{})

      total_matches =
        results
        |> Enum.reduce(0, fn
          {_, matches}, acc when is_list(matches) -> acc + length(matches)
          {_, _}, acc -> acc
        end)

      {:ok,
       %{
         results: results,
         patterns_searched: length(patterns),
         total_matches: total_matches,
         path: path
       }}
    end
  end

  # Unknown operation
  defp do_dispatch(op, _path, _args, _skip_context), do: {:error, "Unknown file operation: #{op}"}

  # Adds deprecation warning to successful results, guiding users to the new tool
  defp add_deprecation_warning({:ok, result}, old_op, new_tool) do
    warning =
      "⚠️ DEPRECATED: `file operation=#{old_op}` is deprecated. Use `#{new_tool}` instead."

    {:ok,
     Map.update(result, :data, %{}, fn data ->
       Map.put(data, :deprecation_warning, warning)
     end)}
  end

  defp add_deprecation_warning({:error, _} = error, _old_op, _new_tool), do: error
  defp add_deprecation_warning(other, _old_op, _new_tool), do: other

  # SPEC-064: File read with interception
  defp dispatch_read(path, args, skip_context) do
    skip_interception = Map.get(args, "skip_interception", false)

    # Check interception first
    case FileReadInterceptor.intercept(path, skip_interception: skip_interception) do
      {:memory_hit, content, metadata} ->
        # Return directly from memory - massive token savings!
        {:ok,
         %{
           data: %{
             content: content,
             source: "memory",
             intercepted: true,
             path: path
           },
           suggestion: Map.get(metadata, :suggestion)
         }}

      {:cache_hit, content, metadata} ->
        # Return from LRU cache
        {:ok,
         %{
           data: %{
             content: content,
             source: "cache",
             intercepted: true,
             path: path,
             cache_age: Map.get(metadata, :age_seconds)
           },
           suggestion: Map.get(metadata, :suggestion)
         }}

      {:symbol_hit, symbols, metadata} ->
        # We have symbols - proceed with read but add strong suggestion
        result = do_actual_read(path, args, skip_context)
        add_symbol_suggestion(result, symbols, metadata)

      {:partial_hit, hints, :proceed} ->
        # Proceed with read, include memory hint
        result = do_actual_read(path, args, skip_context)
        add_partial_hint(result, hints)

      {:miss, :proceed} ->
        # Standard file read - cache result for future
        do_actual_read(path, args, skip_context)
    end
  end

  # Actual file read operation
  defp do_actual_read(path, args, skip_context) do
    opts = []
    opts = if args["offset"], do: Keyword.put(opts, :offset, args["offset"]), else: opts
    opts = if args["limit"], do: Keyword.put(opts, :limit, args["limit"]), else: opts

    case FileOps.read(path, opts) do
      {:ok, %{data: %{content: content}} = data} ->
        # Cache the content for future reads
        cache_read_content(path, content, args)

        # Enrich response with memory context if needed
        Helpers.enrich_file_response({:ok, data}, path, skip_context)

      other ->
        Helpers.enrich_file_response(other, path, skip_context)
    end
  end

  # Cache content after successful read
  defp cache_read_content(path, content, args) do
    skip_auto_cache = Map.get(args, "skip_auto_cache", false)

    # Add to LRU cache
    FileReadCache.put(path, content)

    # Maybe extract and store key content in memory
    unless skip_auto_cache do
      Task.start(fn ->
        FileContentCache.maybe_cache_content(path, content)
      end)
    end
  rescue
    _ -> :ok
  end

  # Add symbol suggestion to result
  defp add_symbol_suggestion({:ok, result}, symbols, metadata) do
    symbol_names = symbols |> Enum.take(5) |> Enum.map_join(", ", & &1.name)

    suggestion =
      Map.get(metadata, :suggestion, "") <>
        "\nIndexed symbols: #{symbol_names}..."

    {:ok, Map.put(result, :suggestion, suggestion)}
  end

  defp add_symbol_suggestion(other, _, _), do: other

  # Add partial hint to result
  defp add_partial_hint({:ok, result}, hints) do
    suggestion =
      Map.get(result, :suggestion, "") <>
        "\n📝 " <> Map.get(hints, :suggestion, "Related memory found.")

    {:ok, Map.put(result, :suggestion, suggestion)}
  end

  defp add_partial_hint(other, _), do: other

  defp dispatch_edit(path, args, skip_context) do
    opts = []
    opts = if args["global"], do: Keyword.put(opts, :global, args["global"]), else: opts

    opts =
      if args["expected_count"],
        do: Keyword.put(opts, :expected_count, args["expected_count"]),
        else: opts

    opts = if args["dry_run"], do: Keyword.put(opts, :dry_run, args["dry_run"]), else: opts

    result = FileOps.edit(path, args["old_str"] || "", args["new_str"] || "", opts)

    # Invalidate cache on edit (unless dry run)
    unless args["dry_run"] do
      FileReadCache.invalidate(path)
    end

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

    FileOps.read_symbol(path, args["symbol_name"] || "", opts)
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

    FileOps.glob(args["pattern"] || "**/*", opts)
  end

  defp dispatch_multi_replace(args) do
    replacements = args["replacements"] || []
    opts = []
    opts = if args["global"], do: Keyword.put(opts, :global, args["global"]), else: opts

    result = FileOps.multi_replace(replacements, opts)

    # Invalidate cache for all modified files
    Enum.each(replacements, fn r ->
      if path = r["path"], do: FileReadCache.invalidate(path)
    end)

    result
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

    FileOps.diff(opts)
  end

  @write_operations ~w(write edit replace_string multi_replace insert_after insert_before replace_lines delete_lines move create_directory)

  # SPEC-2026-001: Updated to accept verification result
  defp record_file_outcome(op, path, result, verification) when op in @write_operations do
    # Convert result to outcome detection format
    detection_result =
      case result do
        {:ok, %{success: true}} -> %{success: true}
        {:ok, %{data: %{success: true}}} -> %{success: true}
        {:ok, _} -> %{success: true}
        {:error, reason} -> %{error: reason}
        _ -> %{}
      end

    detection = OutcomeDetector.detect_file_operation(String.to_atom(op), detection_result)

    # SPEC-2026-001: Adjust outcome based on verification
    verified_outcome = adjust_outcome_for_verification(detection.outcome, verification)

    # Build context for FeedbackLoop
    context = %{
      operation: op,
      path: path,
      signal_type: :file
    }

    # Build outcome for FeedbackLoop (includes verification status)
    outcome = %{
      success: verified_outcome == :success,
      outcome: verified_outcome,
      confidence: detection.confidence,
      signals: detection.signals,
      details: Map.merge(detection.details, verification_details(verification)),
      verification: verification_status(verification)
    }

    # Record asynchronously (non-blocking)
    FeedbackLoop.record_outcome(:tool_execution, context, outcome)

    # SPEC-096 P3 Synergy: Auto-diagnose after code file edits
    maybe_auto_diagnose(op, path, result)
  rescue
    # Don't let outcome detection failures break tool execution
    _ -> :ok
  end

  # Read/search operations - don't record (too noisy, low signal)
  defp record_file_outcome(_op, _path, _result, _verification), do: :ok

  # SPEC-2026-001: Adjust outcome based on verification result
  defp adjust_outcome_for_verification(_outcome, {:phantom_success, _}) do
    :phantom_success
  end

  defp adjust_outcome_for_verification(outcome, _), do: outcome

  # Extract verification details for outcome
  defp verification_details({:verified, details}), do: %{verification: details}

  defp verification_details({:phantom_success, details}),
    do: %{verification: details, phantom: true}

  defp verification_details(_), do: %{}

  # Get verification status for outcome
  defp verification_status({:verified, _}), do: :verified
  defp verification_status({:phantom_success, _}), do: :phantom_success
  defp verification_status({:verification_error, _}), do: :error
  defp verification_status(_), do: :not_verified

  # SPEC-096 P3: Run diagnostics in background after code file write
  defp maybe_auto_diagnose(op, path, {:ok, _}) when op in ~w(edit replace_string write) do
    # Only for code files that might have syntax issues
    if code_file?(path) do
      Task.start(fn ->
        case Mimo.Tools.Dispatchers.Diagnostics.dispatch(%{"operation" => "check", "path" => path}) do
          {:ok, %{error_count: count}} when count > 0 ->
            # Store diagnostic hint in memory for quick lookup
            Logger.debug("[P3 Synergy] Auto-diagnosed #{path}: #{count} errors")

          _ ->
            :ok
        end
      end)
    end
  end

  defp maybe_auto_diagnose(_, _, _), do: :ok

  # Check if file is a code file that benefits from diagnostics
  defp code_file?(path) do
    ext = Path.extname(path)
    ext in ~w(.ex .exs .ts .tsx .js .jsx .py .rs .go)
  end
end
