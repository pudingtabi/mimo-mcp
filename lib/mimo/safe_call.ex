defmodule Mimo.SafeCall do
  @moduledoc """
  Defensive wrapper module that prevents crashes from propagating.
  
  Part of the Grandmaster Architecture - Pillar 3: Resilience Layer.
  
  ## Philosophy
  
  "Never crash the user" - Every external call should have a fallback.
  When things fail, degrade gracefully rather than explode.
  
  ## Usage
  
      # Safe GenServer call with fallback
      SafeCall.genserver(Mimo.Brain.WorkingMemory, {:search, query}, 
        fallback: [],
        timeout: 5000
      )
      
      # Safe task spawning (falls back to sync if supervisor down)
      SafeCall.task(fn -> expensive_work() end)
      
      # Safe embedding with multi-backend fallback
      SafeCall.embedding("some text")
  
  ## Design Principles
  
  1. Never raise - always return {:ok, result} or {:error, reason}
  2. Always have a sensible fallback value
  3. Log degradation transparently for observability
  4. Support circuit breaker integration
  """

  require Logger

  @default_timeout 5_000
  @task_supervisor Mimo.TaskSupervisor

  # ============================================================================
  # GenServer Calls
  # ============================================================================

  @doc """
  Safely call a GenServer, returning fallback if process is down or times out.
  
  ## Options
  
    - `:fallback` - Value to return if call fails (default: {:error, :unavailable})
    - `:timeout` - Call timeout in ms (default: 5000)
    - `:silent` - Don't log failures (default: false)
  
  ## Examples
  
      SafeCall.genserver(WorkingMemory, {:search, "query"}, fallback: [])
      SafeCall.genserver(SomeServer, :get_state, timeout: 1000)
  """
  @spec genserver(atom() | pid(), term(), keyword()) :: {:ok, term()} | {:error, term()} | term()
  def genserver(name, message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    fallback = Keyword.get(opts, :fallback, {:error, :unavailable})
    silent = Keyword.get(opts, :silent, false)
    return_raw = Keyword.get(opts, :raw, false)

    result = 
      case Process.whereis(name) do
        nil ->
          unless silent, do: Logger.debug("[SafeCall] Process #{inspect(name)} not running, using fallback")
          {:fallback, :not_running}
          
        _pid ->
          try do
            {:ok, GenServer.call(name, message, timeout)}
          catch
            :exit, {:noproc, _} ->
              unless silent, do: Logger.debug("[SafeCall] Process #{inspect(name)} died during call")
              {:fallback, :noproc}
              
            :exit, {:timeout, _} ->
              unless silent, do: Logger.warning("[SafeCall] Timeout calling #{inspect(name)}")
              {:fallback, :timeout}
              
            :exit, {:shutdown, _} ->
              {:fallback, :shutdown}
              
            :exit, reason ->
              unless silent, do: Logger.warning("[SafeCall] Exit calling #{inspect(name)}: #{inspect(reason)}")
              {:fallback, {:exit, reason}}
          end
      end

    case result do
      {:ok, value} -> if return_raw, do: value, else: {:ok, value}
      {:fallback, _reason} -> if return_raw, do: fallback, else: fallback
    end
  end

  @doc """
  Safely call a GenServer, returning the raw result or fallback (no :ok/:error wrapper).
  
  Convenience wrapper for `genserver/3` with `raw: true`.
  """
  @spec call(atom() | pid(), term(), keyword()) :: term()
  def call(name, message, opts \\ []) do
    genserver(name, message, Keyword.put(opts, :raw, true))
  end

  # ============================================================================
  # Task Spawning
  # ============================================================================

  @doc """
  Safely spawn an async task, falling back to synchronous execution if supervisor is down.
  
  ## Options
  
    - `:supervisor` - Task supervisor to use (default: Mimo.TaskSupervisor)
    - `:sync_fallback` - Run synchronously if supervisor down (default: true)
    - `:timeout` - Task timeout for await (default: 5000)
  
  ## Examples
  
      {:ok, task} = SafeCall.task(fn -> expensive_work() end)
      result = Task.await(task)
      
      # Or with immediate await
      {:ok, result} = SafeCall.task_await(fn -> work() end, timeout: 10_000)
  """
  @spec task((() -> term()), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def task(fun, opts \\ []) when is_function(fun, 0) do
    supervisor = Keyword.get(opts, :supervisor, @task_supervisor)
    sync_fallback = Keyword.get(opts, :sync_fallback, true)

    case Process.whereis(supervisor) do
      nil when sync_fallback ->
        # Supervisor down - run in a bare task (less supervision but still async)
        Logger.debug("[SafeCall] TaskSupervisor down, using bare Task.async")
        {:ok, Task.async(fun)}
        
      nil ->
        {:error, :supervisor_down}
        
      _pid ->
        try do
          {:ok, Task.Supervisor.async(supervisor, fun)}
        catch
          :exit, reason ->
            if sync_fallback do
              Logger.debug("[SafeCall] Task.Supervisor.async failed, using bare Task")
              {:ok, Task.async(fun)}
            else
              {:error, {:task_failed, reason}}
            end
        end
    end
  end

  @doc """
  Spawn a task and immediately await the result.
  
  ## Options
  
    - `:timeout` - Await timeout (default: 5000)
    - `:fallback` - Value if task fails (default: nil)
  
  ## Examples
  
      {:ok, result} = SafeCall.task_await(fn -> compute() end)
      {:ok, data} = SafeCall.task_await(fn -> fetch() end, fallback: %{}, timeout: 10_000)
  """
  @spec task_await((() -> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def task_await(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    fallback = Keyword.get(opts, :fallback, nil)

    case task(fun, opts) do
      {:ok, task} ->
        try do
          {:ok, Task.await(task, timeout)}
        catch
          :exit, {:timeout, _} ->
            Task.shutdown(task, :brutal_kill)
            if fallback, do: {:ok, fallback}, else: {:error, :timeout}
            
          :exit, reason ->
            if fallback, do: {:ok, fallback}, else: {:error, {:task_exit, reason}}
        end
        
      {:error, reason} ->
        if fallback, do: {:ok, fallback}, else: {:error, reason}
    end
  end

  @doc """
  Fire-and-forget task execution. Never fails, never blocks.
  
  Use for side effects that shouldn't affect the caller:
  - Telemetry/metrics
  - Background memory storage
  - Cache warming
  """
  @spec fire_and_forget((() -> term())) :: :ok
  def fire_and_forget(fun) when is_function(fun, 0) do
    case task(fun, sync_fallback: false) do
      {:ok, _task} -> :ok
      {:error, _} ->
        # Last resort: spawn a bare process
        spawn(fn ->
          try do
            fun.()
          rescue
            e -> Logger.debug("[SafeCall] Fire-and-forget failed: #{Exception.message(e)}")
          end
        end)
        :ok
    end
  end

  # ============================================================================
  # Database Operations
  # ============================================================================

  @doc """
  Safely execute a database operation with timeout and error handling.
  
  ## Examples
  
      SafeCall.repo(fn -> Repo.all(Engram) end, fallback: [])
      SafeCall.repo(fn -> Repo.insert(changeset) end)
  """
  @spec repo((() -> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def repo(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    fallback = Keyword.get(opts, :fallback, nil)

    task = Task.async(fun)
    
    try do
      {:ok, Task.await(task, timeout)}
    rescue
      e in Ecto.QueryError ->
        Logger.warning("[SafeCall] Query error: #{Exception.message(e)}")
        if fallback, do: {:ok, fallback}, else: {:error, {:query_error, e}}
        
      e ->
        Logger.warning("[SafeCall] DB error: #{Exception.message(e)}")
        if fallback, do: {:ok, fallback}, else: {:error, {:exception, e}}
    catch
      :exit, {:timeout, _} ->
        Task.shutdown(task, :brutal_kill)
        if fallback, do: {:ok, fallback}, else: {:error, :db_timeout}
        
      :exit, reason ->
        if fallback, do: {:ok, fallback}, else: {:error, {:db_error, reason}}
    end
  end

  # ============================================================================
  # Embedding Operations
  # ============================================================================

  @doc """
  Generate embedding with multi-backend fallback.
  
  Tries backends in order:
  1. Ollama (local, fast)
  2. Cached similar embedding
  3. Zero vector (last resort)
  
  ## Options
  
    - `:model` - Embedding model (default: configured model)
    - `:dimension` - Vector dimension for zero fallback (default: 1024)
  
  ## Examples
  
      {:ok, embedding} = SafeCall.embedding("some text to embed")
  """
  @spec embedding(String.t(), keyword()) :: {:ok, list(float())} | {:error, term()}
  def embedding(text, opts \\ []) do
    dimension = Keyword.get(opts, :dimension, 1024)
    
    with {:ok, sanitized} <- sanitize_for_embedding(text),
         {:ok, result} <- try_embedding_backends(sanitized, opts) do
      {:ok, result}
    else
      {:error, :all_backends_failed} ->
        Logger.warning("[SafeCall] All embedding backends failed, using zero vector")
        {:ok, zero_vector(dimension)}
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sanitize_for_embedding(text) when is_binary(text) do
    # Ensure valid UTF-8
    sanitized = 
      text
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")  # Control chars
      |> String.slice(0, 8000)  # Limit length
      
    case String.valid?(sanitized) do
      true -> {:ok, sanitized}
      false -> 
        # Force valid UTF-8
        {:ok, sanitized |> :unicode.characters_to_binary(:utf8, :utf8) |> elem(1) |> to_string()}
    end
  rescue
    _ -> {:ok, ""}
  end
  defp sanitize_for_embedding(_), do: {:ok, ""}

  defp try_embedding_backends(text, opts) do
    backends = [
      fn -> try_ollama(text, opts) end,
      fn -> try_cached_similar(text) end
    ]
    
    Enum.reduce_while(backends, {:error, :all_backends_failed}, fn backend, _acc ->
      case backend.() do
        {:ok, embedding} when is_list(embedding) and length(embedding) > 0 ->
          {:halt, {:ok, embedding}}
        _ ->
          {:cont, {:error, :all_backends_failed}}
      end
    end)
  end

  defp try_ollama(text, _opts) do
    # Use existing Ollama integration with timeout
    try do
      case Mimo.Brain.LLM.get_embedding(text) do
        {:ok, embedding} -> {:ok, embedding}
        error -> error
      end
    rescue
      _ -> {:error, :ollama_error}
    catch
      :exit, _ -> {:error, :ollama_timeout}
    end
  end

  defp try_cached_similar(_text) do
    # Future: look up similar text in cache and return its embedding
    {:error, :no_cache}
  end

  defp zero_vector(dimension) do
    List.duplicate(0.0, dimension)
  end

  # ============================================================================
  # Utility Functions
  # ============================================================================

  @doc """
  Check if a named process is alive and responsive.
  """
  @spec alive?(atom()) :: boolean()
  def alive?(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc """
  Wrap any function in try/rescue, returning {:ok, result} or {:error, reason}.
  """
  @spec safely((() -> term())) :: {:ok, term()} | {:error, term()}
  def safely(fun) when is_function(fun, 0) do
    try do
      {:ok, fun.()}
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
      :throw, value -> {:error, {:throw, value}}
    end
  end

  @doc """
  Execute with a timeout, returning fallback if exceeded.
  """
  @spec with_timeout((() -> term()), non_neg_integer(), term()) :: term()
  def with_timeout(fun, timeout_ms, fallback \\ nil) do
    task = Task.async(fun)
    
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> fallback
    end
  end
end
