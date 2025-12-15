defmodule Mimo.Workflow.PatternExtractor do
  @moduledoc """
  SPEC-053 Phase 1: Pattern Extraction & Tool Usage Logging

  Extracts workflow patterns from tool usage logs using:
  - Sliding window sequence detection
  - Frequent subsequence mining (simplified PrefixSpan)
  - Session-based pattern grouping

  ## Features

  - Real-time tool usage logging with async writes
  - Configurable time window for sequence detection (default: 5 minutes)
  - Automatic pattern deduplication
  - Success/failure tracking per pattern

  ## Usage

      # Log a tool usage event
      PatternExtractor.log_tool_usage(%{
        session_id: "session_123",
        tool: "file",
        operation: "read",
        params: %{path: "/app/src/main.ts"},
        success: true,
        duration_ms: 45
      })

      # Extract patterns from logs
      patterns = PatternExtractor.extract_patterns(min_support: 3)
  """
  use GenServer
  require Logger

  alias Mimo.Repo
  alias Mimo.Workflow.{Pattern, ToolLog}

  import Ecto.Query

  # Default time window for sequence detection (5 minutes in milliseconds)
  @default_window_ms 5 * 60 * 1000

  # Minimum sequence length for pattern extraction
  @min_sequence_length 2

  # Maximum sequence length to consider
  @max_sequence_length 10

  # Batch size for async log writes
  @log_batch_size 100

  # Batch flush interval (ms)
  @batch_flush_interval 5_000

  defstruct log_buffer: [],
            patterns_cache: %{},
            last_flush: nil

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the PatternExtractor GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a tool usage event.

  This is the primary entry point for tool logging. Called after each tool execution.

  ## Options

    * `:async` - Whether to buffer the log (default: true)
  """
  @spec log_tool_usage(map(), keyword()) :: :ok
  def log_tool_usage(attrs, opts \\ []) do
    async = Keyword.get(opts, :async, true)

    log_entry = %{
      session_id: attrs[:session_id] || attrs["session_id"],
      tool: attrs[:tool] || attrs["tool"],
      operation: attrs[:operation] || attrs["operation"],
      params: attrs[:params] || attrs["params"],
      success: attrs[:success] || attrs["success"],
      duration_ms: attrs[:duration_ms] || attrs["duration_ms"],
      token_usage: attrs[:token_usage] || attrs["token_usage"],
      context_snapshot: attrs[:context_snapshot] || attrs["context_snapshot"],
      timestamp: attrs[:timestamp] || DateTime.utc_now()
    }

    if async do
      GenServer.cast(__MODULE__, {:log, log_entry})
    else
      do_write_log(log_entry)
    end
  end

  @doc """
  Extracts workflow patterns from historical tool logs.

  ## Options

    * `:min_support` - Minimum occurrences for a pattern (default: 3)
    * `:window_ms` - Time window for sequence detection (default: 5 minutes)
    * `:since` - Only analyze logs after this datetime
    * `:session_ids` - Only analyze specific sessions
  """
  @spec extract_patterns(keyword()) :: {:ok, [Pattern.t()]} | {:error, term()}
  def extract_patterns(opts \\ []) do
    min_support = Keyword.get(opts, :min_support, 3)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    since = Keyword.get(opts, :since)
    session_ids = Keyword.get(opts, :session_ids)

    try do
      # Step 1: Fetch tool logs
      logs = fetch_logs(since, session_ids)

      # Step 2: Group by session and detect sequences
      sequences = detect_sequences(logs, window_ms)

      # Step 3: Mine frequent subsequences
      frequent_patterns = mine_frequent_patterns(sequences, min_support)

      # Step 4: Convert to Pattern structs
      patterns = Enum.map(frequent_patterns, &build_pattern/1)

      {:ok, patterns}
    rescue
      e ->
        Logger.error("Pattern extraction failed: #{inspect(e)}")
        {:error, {:extraction_failed, e}}
    end
  end

  @doc """
  Extracts workflow patterns from a provided tool log list.

  Unlike `extract_patterns/1` which fetches from the database, this function
  accepts a pre-fetched list of tool log entries.

  ## Options

    * `:min_support` - Minimum occurrences for a pattern (default: 3)
    * `:window_ms` - Time window for sequence detection (default: 5 minutes)

  ## Examples

      PatternExtractor.extract_from_tool_log([
        %{tool: "file", args: %{operation: "read"}, duration_ms: 50},
        %{tool: "code", args: %{operation: "definition"}, duration_ms: 100}
      ])
  """
  @spec extract_from_tool_log([map()], keyword()) :: {:ok, [Pattern.t()]} | {:error, term()}
  def extract_from_tool_log(log_entries, opts \\ [])
  def extract_from_tool_log([], _opts), do: {:ok, []}

  def extract_from_tool_log(log_entries, opts) when is_list(log_entries) do
    # Lower default for direct input
    min_support = Keyword.get(opts, :min_support, 1)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)

    try do
      # Convert log entries to expected format
      logs = normalize_log_entries(log_entries)

      # Group by session and detect sequences
      sequences = detect_sequences(logs, window_ms)

      # Mine frequent subsequences
      frequent_patterns = mine_frequent_patterns(sequences, min_support)

      # Convert to Pattern structs
      patterns = Enum.map(frequent_patterns, &build_pattern/1)

      {:ok, patterns}
    rescue
      e ->
        Logger.error("Pattern extraction from log failed: #{inspect(e)}")
        {:error, {:extraction_failed, e}}
    end
  end

  # Normalize various log entry formats to consistent structure
  defp normalize_log_entries(entries) do
    Enum.map(entries, fn entry ->
      %{
        session_id: entry[:session_id] || entry["session_id"] || "default_session",
        tool: entry[:tool] || entry["tool"] || "unknown",
        operation: get_operation(entry),
        success: entry[:success] || entry["success"] || true,
        duration_ms: entry[:duration_ms] || entry["duration_ms"] || 0,
        timestamp: entry[:timestamp] || entry["timestamp"] || DateTime.utc_now()
      }
    end)
  end

  defp get_operation(entry) do
    do_get_operation(
      entry[:operation],
      entry["operation"],
      entry[:args],
      entry["args"]
    )
  end

  # Multi-head operation lookup
  defp do_get_operation(op, _string_op, _args, _string_args) when not is_nil(op), do: op

  defp do_get_operation(_op, string_op, _args, _string_args) when not is_nil(string_op),
    do: string_op

  defp do_get_operation(_op, _string_op, args, _string_args) when is_map(args) do
    args[:operation] || args["operation"] || "default"
  end

  defp do_get_operation(_op, _string_op, _args, string_args) when is_map(string_args) do
    string_args["operation"] || "default"
  end

  defp do_get_operation(_op, _string_op, _args, _string_args), do: "default"

  @doc """
  Gets sequences for a specific session.
  """
  @spec get_session_sequences(String.t(), keyword()) :: {:ok, [list()]} | {:error, term()}
  def get_session_sequences(session_id, opts \\ []) do
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)

    logs = fetch_logs(nil, [session_id])
    sequences = detect_sequences(logs, window_ms)

    {:ok, Map.get(sequences, session_id, [])}
  end

  @doc """
  Flushes any buffered log entries to the database.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush, 10_000)
  end

  @doc """
  Returns current buffer stats.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Schedule periodic flush
    schedule_flush()

    {:ok,
     %__MODULE__{
       log_buffer: [],
       patterns_cache: %{},
       last_flush: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_cast({:log, entry}, state) do
    new_buffer = [entry | state.log_buffer]

    if length(new_buffer) >= @log_batch_size do
      do_flush_buffer(new_buffer)
      {:noreply, %{state | log_buffer: [], last_flush: DateTime.utc_now()}}
    else
      {:noreply, %{state | log_buffer: new_buffer}}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    do_flush_buffer(state.log_buffer)
    {:reply, :ok, %{state | log_buffer: [], last_flush: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      buffer_size: length(state.log_buffer),
      patterns_cached: map_size(state.patterns_cache),
      last_flush: state.last_flush
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:periodic_flush, state) do
    if length(state.log_buffer) > 0 do
      do_flush_buffer(state.log_buffer)
      schedule_flush()
      {:noreply, %{state | log_buffer: [], last_flush: DateTime.utc_now()}}
    else
      schedule_flush()
      {:noreply, state}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_flush do
    Process.send_after(self(), :periodic_flush, @batch_flush_interval)
  end

  defp do_write_log(entry) do
    changeset = ToolLog.new(entry)

    case Repo.insert(changeset) do
      {:ok, _} -> :ok
      {:error, e} -> Logger.warning("Failed to write tool log: #{inspect(e)}")
    end
  end

  defp do_flush_buffer([]), do: :ok

  defp do_flush_buffer(entries) do
    now = DateTime.utc_now()

    records =
      Enum.map(entries, fn entry ->
        %{
          session_id: entry.session_id,
          tool: entry.tool,
          operation: entry.operation,
          params: entry.params,
          success: entry.success,
          duration_ms: entry.duration_ms,
          token_usage: entry.token_usage,
          context_snapshot: entry.context_snapshot,
          timestamp: entry.timestamp || now
        }
      end)

    try do
      Repo.insert_all(ToolLog, records)
      Logger.debug("Flushed #{length(records)} tool logs")
    rescue
      e ->
        Logger.error("Failed to flush tool logs: #{inspect(e)}")
    end
  end

  defp fetch_logs(since, session_ids) do
    query =
      from(l in ToolLog,
        order_by: [asc: l.session_id, asc: l.timestamp]
      )

    query =
      if since do
        from(l in query, where: l.timestamp >= ^since)
      else
        query
      end

    query =
      if session_ids && length(session_ids) > 0 do
        from(l in query, where: l.session_id in ^session_ids)
      else
        query
      end

    Repo.all(query)
  end

  defp detect_sequences(logs, window_ms) do
    # Group logs by session
    logs
    |> Enum.group_by(& &1.session_id)
    |> Enum.map(fn {session_id, session_logs} ->
      sequences = extract_session_sequences(session_logs, window_ms)
      {session_id, sequences}
    end)
    |> Map.new()
  end

  defp extract_session_sequences(logs, window_ms) do
    # Sort by timestamp
    sorted = Enum.sort_by(logs, & &1.timestamp, DateTime)

    # Use sliding window to detect sequences
    detect_windows(sorted, window_ms, [])
  end

  defp detect_windows([], _window_ms, acc), do: Enum.reverse(acc)

  defp detect_windows([head | tail], window_ms, acc) do
    # Find all logs within the time window
    window_end = DateTime.add(head.timestamp, window_ms, :millisecond)

    window_logs =
      [
        head
        | Enum.take_while(tail, fn log -> DateTime.compare(log.timestamp, window_end) != :gt end)
      ]

    if length(window_logs) >= @min_sequence_length do
      sequence = Enum.map(window_logs, &tool_signature/1)

      # Only add if sequence is unique in current accumulator
      if Enum.member?(acc, sequence) do
        detect_windows(tail, window_ms, acc)
      else
        detect_windows(tail, window_ms, [sequence | acc])
      end
    else
      detect_windows(tail, window_ms, acc)
    end
  end

  defp tool_signature(log) do
    %{
      tool: log.tool,
      operation: log.operation,
      success: log.success
    }
  end

  defp mine_frequent_patterns(sequences_by_session, min_support) do
    # Flatten all sequences
    all_sequences =
      sequences_by_session
      |> Map.values()
      |> List.flatten()

    # Generate all subsequences of valid lengths
    subsequences =
      all_sequences
      |> Enum.flat_map(fn seq ->
        for len <- @min_sequence_length..min(length(seq), @max_sequence_length),
            subseq <- subsequences(seq, len),
            do: subseq
      end)

    # Count occurrences
    freq_map =
      subsequences
      |> Enum.reduce(%{}, fn subseq, acc ->
        key = normalize_sequence(subseq)
        Map.update(acc, key, 1, &(&1 + 1))
      end)

    # Filter by minimum support
    freq_map
    |> Enum.filter(fn {_key, count} -> count >= min_support end)
    |> Enum.sort_by(fn {_key, count} -> -count end)
    |> Enum.map(fn {key, count} ->
      %{
        sequence: key,
        support: count,
        sessions: find_supporting_sessions(key, sequences_by_session)
      }
    end)
  end

  defp subsequences(seq, len) when length(seq) < len, do: []

  defp subsequences(seq, len) do
    # Generate contiguous subsequences
    0..(length(seq) - len)
    |> Enum.map(fn start -> Enum.slice(seq, start, len) end)
  end

  defp normalize_sequence(seq) do
    # Create a hashable representation
    Enum.map(seq, fn step ->
      "#{step.tool}.#{step.operation}"
    end)
  end

  defp find_supporting_sessions(sequence, sequences_by_session) do
    sequences_by_session
    |> Enum.filter(fn {_session_id, seqs} ->
      Enum.any?(seqs, fn seq ->
        contains_subsequence?(normalize_sequence(seq), sequence)
      end)
    end)
    |> Enum.map(fn {session_id, _} -> session_id end)
  end

  defp contains_subsequence?(seq, subseq) when length(seq) < length(subseq), do: false

  defp contains_subsequence?(seq, subseq) do
    Enum.any?(0..(length(seq) - length(subseq)), fn start ->
      Enum.slice(seq, start, length(subseq)) == subseq
    end)
  end

  defp build_pattern(%{sequence: sequence, support: _support, sessions: sessions}) do
    steps =
      Enum.map(sequence, fn tool_op ->
        [tool, operation] = String.split(tool_op, ".", parts: 2)

        %{
          "tool" => tool,
          "operation" => operation,
          "params" => %{},
          "dynamic_bindings" => []
        }
      end)

    name = generate_pattern_name(sequence)
    id = generate_pattern_id(name)

    %Pattern{
      id: id,
      name: name,
      description: "Auto-extracted pattern: #{Enum.join(sequence, " -> ")}",
      steps: steps,
      success_rate: 0.0,
      usage_count: 0,
      confidence_threshold: 0.7,
      tags: ["auto-extracted"],
      created_from: sessions,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  defp generate_pattern_name(sequence) do
    # Generate a descriptive name based on the sequence
    tools = sequence |> Enum.map(&(String.split(&1, ".") |> hd())) |> Enum.uniq()

    case length(tools) do
      1 -> "#{hd(tools)}_workflow"
      _ -> "#{hd(tools)}_to_#{List.last(tools)}_workflow"
    end
  end

  defp generate_pattern_id(name) do
    timestamp = System.os_time(:millisecond)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
    "#{slug}_#{timestamp}_#{random}"
  end
end
