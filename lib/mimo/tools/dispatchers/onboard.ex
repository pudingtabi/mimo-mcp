defmodule Mimo.Tools.Dispatchers.Onboard do
  @moduledoc """
  Project onboarding meta-tool dispatcher.

  SPEC-031 Phase 3: Orchestrates project initialization by running multiple
  indexing operations in PARALLEL via an Async Tracker (fast response system):

  1. Check memory for project fingerprint (hash of file tree)
  2. If exists & !force → return cached profile
  3. Run IN BACKGROUND via Tracker:
     - code_symbols operation=index
     - library operation=discover
     - knowledge operation=link
  4. Return immediate "started" status
  5. User can check status via `onboard status=true`

  This prevents timeouts on large projects.
  """

  require Logger

  alias Mimo.Brain.Memory
  alias Mimo.Tools.Dispatchers.Onboard.Tracker

  @doc """
  Dispatch onboard operation.

  ## Options
    - path: Project root path (default: ".")
    - force: Re-index even if already done (default: false)
    - status: Check status of running onboarding (default: false)
  """
  def dispatch(args) do
    # Ensure tracker is running (hot-fix for running system if not in supervision tree yet)
    if Process.whereis(Tracker) == nil do
      Tracker.start_link([])
    end

    if Map.get(args, "operation") == "status" or Map.get(args, "status") == "true" or Map.get(args, "status") == true do
      status = Tracker.get_status()
      {:ok, format_status(status)}
    else
      path = args["path"] || "."
      force = Map.get(args, "force", false)

      # Resolve to absolute path
      abs_path = Path.expand(path)

      if File.dir?(abs_path) do
        fingerprint = compute_fingerprint(abs_path)

        # Check if already indexed (unless force)
        if !force && already_indexed?(fingerprint) do
          return_cached_profile(abs_path, fingerprint)
        else
          case Tracker.start_onboarding(abs_path, fingerprint) do
            :ok ->
              {:ok, %{
                status: "started",
                message: "🚀 Onboarding started in background.",
                suggestion: "Use `onboard status=true` to check progress.",
                fingerprint: fingerprint
              }}
            {:error, :already_running} ->
              {:ok, %{
                status: "running",
                message: "⚠️ Onboarding already in progress.",
                suggestion: "Use `onboard status=true` to check progress."
              }}
          end
        end
      else
        {:error, "Path does not exist or is not a directory: #{abs_path}"}
      end
    end
  end

  defp format_status(status) do
    symbols = status.progress.symbols
    deps = status.progress.deps
    graph = status.progress.graph
    
    overall = status.status # :idle, :running, :completed, :partial
    
    summary = case overall do
      :idle -> "Idle"
      :running -> "Running (#{status.duration_ms}ms)"
      :completed -> "Completed in #{status.duration_ms}ms"
      :partial -> "Completed (Partial) in #{status.duration_ms}ms"
      :failed -> "Failed"
    end
    
    emoji = case overall do
      :running -> "🔄"
      :completed -> "✅"
      :partial -> "⚠️"
      _ -> "ℹ️"
    end
    
    %{
      status: overall,
      message: "#{emoji} #{summary}",
      progress: %{
        code_symbols: symbols,
        library: deps,
        knowledge_graph: graph
      },
      results: status.results
    }
  end

  # ==========================================================================
  # FINGERPRINT MANAGEMENT
  # ==========================================================================

  defp compute_fingerprint(path) do
    # Create fingerprint from directory structure
    files =
      try do
        path
        |> File.ls!()
        |> Enum.sort()
        |> Enum.take(100)
        |> Enum.join(",")
      rescue
        _ -> "empty"
      end

    # Include key project files in fingerprint
    project_indicators = [
      "mix.exs",
      "package.json",
      "Cargo.toml",
      "requirements.txt",
      "pyproject.toml",
      "go.mod"
    ]

    indicator_hashes =
      project_indicators
      |> Enum.map(fn file ->
        full_path = Path.join(path, file)

        if File.exists?(full_path) do
          case File.stat(full_path) do
            {:ok, stat} ->
              # Convert mtime tuple to string - mtime is {{year, month, day}, {hour, min, sec}}
              mtime_str = format_mtime(stat.mtime)
              "#{file}:#{mtime_str}"

            _ ->
              nil
          end
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("|")

    # Compute hash
    data = "#{path}|#{files}|#{indicator_hashes}"
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp already_indexed?(fingerprint) do
    # Search memory for this fingerprint
    results =
      Memory.search_memories("project fingerprint #{fingerprint}", limit: 1, min_similarity: 0.9)

    length(results) > 0
  end

  defp return_cached_profile(path, fingerprint) do
    {:ok,
     %{
       status: "cached",
       path: path,
       fingerprint: fingerprint,
       message: "✅ Project already indexed. Use force=true to re-index.",
       suggestion: "💡 Project context is ready. Use code_symbols, knowledge, and library tools."
     }}
  end

  # Convert Erlang datetime tuple to string
  defp format_mtime({{year, month, day}, {hour, min, sec}}) do
    "#{year}-#{pad(month)}-#{pad(day)}T#{pad(hour)}:#{pad(min)}:#{pad(sec)}"
  end

  defp format_mtime(other), do: inspect(other)

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end