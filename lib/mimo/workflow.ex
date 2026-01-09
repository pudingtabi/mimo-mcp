defmodule Mimo.Workflow do
  @moduledoc """
  Workflow Orchestration - Main Facade Module.

  Implements SPEC-053 (Intelligent Tool Orchestration & Auto-Chaining) and
  SPEC-054 (Adaptive Workflow Engine for Model Optimization).

  ## Overview

  The workflow system provides:
  - **Pattern Recognition**: Learns common tool usage sequences
  - **Workflow Prediction**: Suggests optimal workflows for tasks
  - **Model Adaptation**: Adjusts workflows based on AI model capabilities
  - **Execution Engine**: Runs workflows with monitoring and learning

  ## Architecture

                         User Task
                              │
                              ▼
      ┌───────────────────────────────────────────────────────┐
      │                    Mimo.Workflow                       │
      │  ┌─────────────────────────────────────────────────┐  │
      │  │              MetaCognitiveRouter                │  │
      │  │        (classify + suggest_workflow)           │  │
      │  └────────────────────┬────────────────────────────┘  │
      │                       │                               │
      │        ┌──────────────┼──────────────┐                │
      │        ▼              ▼              ▼                │
      │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐    │
      │  │ Predictor│  │ Executor │  │ TemplateAdapter  │    │
      │  └────┬─────┘  └────┬─────┘  └────────┬─────────┘    │
      │       │             │                 │               │
      │       ▼             ▼                 ▼               │
      │  ┌──────────┐  ┌──────────┐  ┌──────────────────┐    │
      │  │ Pattern  │  │  Step    │  │  Model           │    │
      │  │ Registry │  │  Runner  │  │  Profiler        │    │
      │  └──────────┘  └──────────┘  └──────────────────┘    │
      │                       │                               │
      │                       ▼                               │
      │  ┌─────────────────────────────────────────────────┐  │
      │  │            LearningTracker                      │  │
      │  │    (feedback loop for continuous improvement)   │  │
      │  └─────────────────────────────────────────────────┘  │
      └───────────────────────────────────────────────────────┘

  ## Quick Start

      # Suggest a workflow for a task
      {:ok, suggestion} = Mimo.Workflow.suggest("Fix the undefined function error in auth.ex")

      # Execute the suggested workflow
      {:ok, result} = Mimo.Workflow.execute(suggestion.pattern, suggestion.bindings)

      # Or do both in one step
      {:ok, result} = Mimo.Workflow.auto_execute("Fix the undefined function error in auth.ex")

  ## Model-Aware Workflows

  For smaller models, use model-aware execution:

      # Adapt workflow for a specific model
      {:ok, adapted} = Mimo.Workflow.adapt_for_model("debug_error", "claude-3-haiku")
      {:ok, result} = Mimo.Workflow.execute(adapted)

  """

  alias Clusterer

  alias Mimo.AdaptiveWorkflow.{
    LearningTracker,
    ModelProfiler,
    TemplateAdapter
  }

  alias Mimo.MetaCognitiveRouter

  alias Mimo.Workflow.{
    Executor,
    Pattern,
    PatternExtractor,
    PatternRegistry,
    Telemetry
  }

  @doc """
  Suggest a workflow for a task description.

  Analyzes the task and returns the best matching workflow pattern
  with resolved bindings and confidence score.

  ## Options
  - `:context` - Additional context for binding resolution
  - `:model_id` - Model identifier for model-aware suggestions
  - `:auto_threshold` - Confidence threshold for auto-execution (default: 0.85)

  ## Examples

      iex> Mimo.Workflow.suggest("Fix the compile error in auth.ex")
      {:ok, %{
        type: :auto_execute,
        pattern: %Pattern{name: "debug_error", ...},
        confidence: 0.92,
        bindings: %{"error_message" => "compile error", "file" => "auth.ex"}
      }}

  """
  @spec suggest(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def suggest(task_description, opts \\ [])
  def suggest(nil, _opts), do: {:error, :nil_task_description}
  def suggest("", _opts), do: {:error, :empty_task_description}

  def suggest(task_description, opts) when is_binary(task_description) do
    MetaCognitiveRouter.suggest_workflow(task_description, opts)
  end

  @doc """
  Execute a workflow pattern.

  Runs the pattern with resolved bindings through the execution engine.

  ## Options
  - `:context` - Additional context merged with bindings
  - `:async` - Return immediately with execution_id (default: true)
  - `:model_id` - Model ID for adaptive execution
  - `:confirm` - Return execution plan without running

  ## Examples

      iex> Mimo.Workflow.execute(pattern, %{"file" => "auth.ex"})
      {:ok, %{execution_id: "wfexec_abc123", status: :running}}

  """
  @spec execute(Pattern.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(%Pattern{} = pattern, bindings \\ %{}, opts \\ []) do
    model_id = Keyword.get(opts, :model_id)

    # Adapt pattern for model if specified
    pattern_to_execute =
      if model_id do
        case TemplateAdapter.adapt(pattern, model_id: model_id) do
          {:ok, adapted} -> adapted
          {:error, _} -> pattern
        end
      else
        pattern
      end

    Executor.execute(pattern_to_execute, bindings, opts)
  end

  @doc """
  Execute a workflow by pattern name.

  Looks up the pattern and executes it.

  ## Examples

      iex> Mimo.Workflow.execute_by_name("debug_error", %{"error" => "undefined function"})
      {:ok, %{execution_id: "wfexec_abc123", status: :running}}

  """
  @spec execute_by_name(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_by_name(pattern_name, bindings \\ %{}, opts \\ []) do
    Executor.execute_by_name(pattern_name, bindings, opts)
  end

  @doc """
  Suggest and execute in one step (auto-pilot mode).

  For high-confidence matches, executes immediately.
  For lower confidence, returns suggestion for confirmation.

  ## Options
  - `:auto_threshold` - Execute automatically above this confidence (default: 0.85)
  - `:model_id` - Model for adaptive execution

  ## Examples

      iex> Mimo.Workflow.auto_execute("Fix the bug in auth module")
      {:ok, %{executed: true, result: %{...}}}

      iex> Mimo.Workflow.auto_execute("Do something vague")
      {:ok, %{executed: false, suggestion: %{...}}}

  """
  @spec auto_execute(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def auto_execute(task_description, opts \\ []) do
    {:ok, suggestion} = suggest(task_description, opts)

    case suggestion do
      %{type: :auto_execute, pattern: pattern, bindings: bindings} ->
        case execute(pattern, bindings, opts) do
          {:ok, result} -> {:ok, %{executed: true, result: result}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:ok, %{executed: false, suggestion: suggestion}}
    end
  end

  @doc """
  List all available workflow patterns.

  ## Options
  - `:category` - Filter by category
  - `:min_success_rate` - Minimum success rate filter

  """
  @spec list_patterns(keyword()) :: [Pattern.t()]
  def list_patterns(opts \\ []) do
    patterns = PatternRegistry.list_patterns()

    patterns
    |> maybe_filter_category(opts[:category])
    |> maybe_filter_success_rate(opts[:min_success_rate])
  end

  @doc """
  Get a specific pattern by name.
  """
  @spec get_pattern(String.t()) :: {:ok, Pattern.t()} | {:error, :not_found}
  def get_pattern(name) do
    PatternRegistry.get_pattern(name)
  end

  @doc """
  Save or update a workflow pattern.
  """
  @spec save_pattern(Pattern.t()) :: {:ok, Pattern.t()} | {:error, term()}
  def save_pattern(%Pattern{} = pattern) do
    PatternRegistry.save_pattern(pattern)
  end

  @doc """
  Extract patterns from recent tool usage.

  Analyzes tool usage logs and extracts common patterns.
  """
  @spec extract_patterns(keyword()) :: {:ok, [Pattern.t()]} | {:error, term()}
  def extract_patterns(opts \\ []) do
    session_id = Keyword.get(opts, :session_id)
    min_support = Keyword.get(opts, :min_support, 3)

    PatternExtractor.extract_patterns(session_id: session_id, min_support: min_support)
  end

  @doc """
  Cluster similar patterns together.

  Reduces pattern redundancy by grouping similar sequences.
  """
  @spec cluster_patterns(keyword()) :: {:ok, [[Pattern.t()]]} | {:error, term()}
  def cluster_patterns(opts \\ []) do
    patterns = list_patterns()
    threshold = Keyword.get(opts, :threshold, 0.3)

    clusters = Mimo.Workflow.Clusterer.cluster_patterns(patterns, threshold: threshold)
    {:ok, clusters}
  end

  @doc """
  Adapt a pattern for a specific model.

  Applies transformations based on model capabilities.

  ## Examples

      iex> Mimo.Workflow.adapt_for_model("debug_error", "claude-3-haiku")
      {:ok, %Pattern{steps: [prepare_context, ..., original_steps...]}}

  """
  @spec adapt_for_model(String.t() | Pattern.t(), String.t(), keyword()) ::
          {:ok, Pattern.t()} | {:error, term()}
  def adapt_for_model(pattern_or_name, model_id, opts \\ [])

  def adapt_for_model(pattern_name, model_id, opts) when is_binary(pattern_name) do
    case get_pattern(pattern_name) do
      {:ok, pattern} -> adapt_for_model(pattern, model_id, opts)
      {:error, _} = error -> error
    end
  end

  def adapt_for_model(%Pattern{} = pattern, model_id, opts) do
    TemplateAdapter.adapt(pattern, Keyword.put(opts, :model_id, model_id))
  end

  @doc """
  Get model profile and capabilities.
  """
  @spec get_model_profile(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def get_model_profile(nil), do: get_model_profile("unknown")
  def get_model_profile(""), do: get_model_profile("unknown")

  def get_model_profile(model_id) when is_binary(model_id) do
    ModelProfiler.get_profile(model_id)
  end

  @doc """
  Get workflow recommendations for a model.

  Returns adaptation recommendations based on model capabilities.
  """
  @spec get_model_recommendations(String.t() | nil) :: map()
  def get_model_recommendations(nil), do: get_model_recommendations("unknown")
  def get_model_recommendations(""), do: get_model_recommendations("unknown")

  def get_model_recommendations(model_id) when is_binary(model_id) do
    ModelProfiler.get_workflow_recommendations(model_id)
  end

  @doc """
  Record execution outcome for learning.

  Used to improve pattern recommendations over time.

  ## Examples

      iex> Mimo.Workflow.record_outcome("execution_123", :success)
      :ok

  """
  @spec record_outcome(String.t(), :success | :failure, keyword()) :: :ok
  def record_outcome(execution_id, outcome, opts \\ []) do
    Executor.record_result(execution_id, outcome, Map.new(opts))
  end

  @doc """
  Log tool usage for pattern extraction.

  Tools should call this to contribute to pattern learning.
  """
  @spec log_tool_usage(String.t(), String.t(), map()) :: :ok
  def log_tool_usage(session_id, tool_name, args) do
    PatternExtractor.log_tool_usage(%{
      session_id: session_id,
      tool: tool_name,
      args: args,
      timestamp: DateTime.utc_now()
    })
  end

  @doc """
  Get learning statistics.
  """
  @spec learning_stats() :: map()
  def learning_stats do
    LearningTracker.stats()
  end

  @doc """
  Get pattern-model affinity scores.
  """
  @spec get_affinity(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_affinity(model_id, pattern_name) do
    LearningTracker.get_affinity(model_id, pattern_name)
  end

  @doc """
  Get status of a running execution.
  """
  @spec get_execution_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_execution_status(execution_id) do
    Executor.get_execution_status(execution_id)
  end

  @doc """
  Cancel a running execution.
  """
  @spec cancel_execution(String.t(), String.t()) :: :ok | {:error, term()}
  def cancel_execution(execution_id, reason \\ "user_cancelled") do
    Executor.cancel_execution(execution_id, reason)
  end

  @doc """
  List recent executions for a pattern.
  """
  @spec list_executions(String.t(), keyword()) :: [map()]
  def list_executions(pattern_name, opts \\ []) do
    Executor.list_executions(pattern_name, opts)
  end

  @doc """
  Attach telemetry handlers for workflow monitoring.
  """
  def attach_telemetry do
    Telemetry.attach()
  end

  @doc """
  Detach telemetry handlers.
  """
  def detach_telemetry do
    Telemetry.detach()
  end

  @doc """
  Initialize the workflow system.

  Seeds patterns, starts required processes, and attaches telemetry.
  Call this from your application supervision tree.
  """
  def init do
    # Seed patterns if needed
    PatternRegistry.seed_patterns()

    # Attach telemetry
    attach_telemetry()

    :ok
  end

  defp maybe_filter_category(patterns, nil), do: patterns

  defp maybe_filter_category(patterns, category) do
    Enum.filter(patterns, fn p -> p.category == category end)
  end

  defp maybe_filter_success_rate(patterns, nil), do: patterns

  defp maybe_filter_success_rate(patterns, min_rate) do
    Enum.filter(patterns, fn p -> (p.success_rate || 0.5) >= min_rate end)
  end
end
