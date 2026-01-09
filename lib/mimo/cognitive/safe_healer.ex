defmodule Mimo.Cognitive.SafeHealer do
  @moduledoc """
  Phase 5 C2: Self-Healing Patterns

  Executes safe, low-risk healing interventions when issues are detected.
  This module focuses on OPERATIONAL healing (not parameter tuning, since
  module attributes are compile-time constants in Elixir).

  ## Philosophy

  SafeHealer provides autonomous self-care through:
  1. A catalog of safe healing actions
  2. Condition-based triggers
  3. Logged and trackable interventions
  4. Outcome tracking for learning

  ## Healing Actions

  - Cache clearing: When stale data causes issues
  - Circuit breaker reset: When breakers trip unexpectedly
  - Maintenance cycle: Force SleepCycle for memory consolidation
  - ETS cleanup: Clear corrupted or bloated tables
  - Working memory prune: Clear expired entries

  ## Safety Guarantees

  - All actions are reversible or have no side effects beyond cleanup
  - Actions are logged for auditability
  - Frequency limits prevent runaway healing
  - Outcomes are tracked for learning

  ## Usage

      # Check for healing opportunities
      SafeHealer.diagnose()

      # Apply a specific healing action
      SafeHealer.heal(:clear_classifier_cache)

      # Run auto-healing based on current state
      SafeHealer.auto_heal()
  """

  require Logger

  alias Mimo.Cognitive.{HealthWatcher, EvolutionDashboard}

  # Minimum time between auto-heal runs (10 minutes)
  @auto_heal_cooldown_ms 600_000

  # Track last heal times per action
  @heal_cooldowns %{
    # 5 min
    clear_classifier_cache: 300_000,
    # 5 min
    clear_embedding_cache: 300_000,
    # 5 min
    clear_search_cache: 300_000,
    # 1 min
    reset_circuit_breakers: 60_000,
    # 30 min
    run_maintenance: 1_800_000,
    # 10 min
    prune_working_memory: 600_000
  }

  @doc """
  Returns the catalog of available healing actions with their conditions.
  """
  @spec catalog() :: [map()]
  def catalog do
    [
      %{
        id: :clear_classifier_cache,
        name: "Clear Classifier Cache",
        description: "Clears the LLM classification result cache",
        risk: :low,
        condition: &classifier_cache_bloated?/0,
        action: fn -> Mimo.Cache.Classifier.clear() end
      },
      %{
        id: :clear_embedding_cache,
        name: "Clear Embedding Cache",
        description: "Clears the embedding vector cache",
        risk: :low,
        condition: &embedding_cache_bloated?/0,
        action: fn -> Mimo.Cache.Embedding.clear() end
      },
      %{
        id: :clear_search_cache,
        name: "Clear Search Result Cache",
        description: "Clears the semantic search result cache",
        risk: :low,
        condition: &search_cache_bloated?/0,
        action: fn -> Mimo.Cache.SearchResult.clear() end
      },
      %{
        id: :reset_circuit_breakers,
        name: "Reset Circuit Breakers",
        description: "Resets all tripped circuit breakers",
        risk: :medium,
        condition: &circuit_breakers_tripped?/0,
        action: &reset_all_circuit_breakers/0
      },
      %{
        id: :run_maintenance,
        name: "Run Sleep Cycle Maintenance",
        description: "Forces a full sleep cycle for memory consolidation",
        risk: :low,
        condition: &needs_maintenance?/0,
        action: fn -> Mimo.SleepCycle.run_cycle(force: true) end
      },
      %{
        id: :prune_working_memory,
        name: "Prune Working Memory",
        description: "Triggers working memory cleanup cycle",
        risk: :low,
        # Always safe to trigger
        condition: fn -> true end,
        action: fn ->
          # Send cleanup message to the cleaner process
          send(Mimo.Brain.WorkingMemoryCleaner, :cleanup)
          :ok
        end
      }
    ]
  end

  @doc """
  Diagnoses current system state and returns recommended healing actions.
  """
  @spec diagnose() :: %{
          issues: [map()],
          recommendations: [atom()],
          health_score: float()
        }
  def diagnose do
    # Get current health context
    evolution = safe_call(fn -> EvolutionDashboard.evolution_score() end, %{overall_score: 0.5})
    alerts = safe_call(fn -> HealthWatcher.alerts() end, [])

    # Check each condition
    issues =
      catalog()
      |> Enum.filter(fn action ->
        try do
          action.condition.()
        rescue
          _ -> false
        end
      end)
      |> Enum.map(fn action ->
        %{
          action_id: action.id,
          name: action.name,
          risk: action.risk
        }
      end)

    recommendations = Enum.map(issues, & &1.action_id)

    %{
      issues: issues,
      recommendations: recommendations,
      health_score: Map.get(evolution, :overall_score, 0.5),
      active_alerts: length(alerts)
    }
  end

  @doc """
  Executes a specific healing action.

  Returns {:ok, result} on success, {:error, reason} on failure.
  """
  @spec heal(atom()) :: {:ok, map()} | {:error, atom() | String.t()}
  def heal(action_id) do
    case Enum.find(catalog(), &(&1.id == action_id)) do
      nil ->
        {:error, :unknown_action}

      action ->
        # Check cooldown
        if on_cooldown?(action_id) do
          {:error, :on_cooldown}
        else
          execute_heal(action)
        end
    end
  end

  @doc """
  Runs auto-healing based on current diagnose results.

  Only executes LOW-risk actions automatically.
  Medium/high risk actions are logged but not executed.
  """
  @spec auto_heal() :: %{
          executed: [atom()],
          skipped_medium_risk: [atom()],
          skipped_cooldown: [atom()],
          errors: [map()]
        }
  def auto_heal do
    diagnosis = diagnose()

    result = %{
      executed: [],
      skipped_medium_risk: [],
      skipped_cooldown: [],
      errors: []
    }

    Enum.reduce(diagnosis.recommendations, result, fn action_id, acc ->
      action = Enum.find(catalog(), &(&1.id == action_id))

      cond do
        action == nil ->
          acc

        action.risk in [:medium, :high] ->
          Logger.info("[SafeHealer] Skipping #{action_id} (risk: #{action.risk})")
          %{acc | skipped_medium_risk: [action_id | acc.skipped_medium_risk]}

        on_cooldown?(action_id) ->
          %{acc | skipped_cooldown: [action_id | acc.skipped_cooldown]}

        true ->
          case execute_heal(action) do
            {:ok, _} ->
              %{acc | executed: [action_id | acc.executed]}

            {:error, reason} ->
              %{acc | errors: [%{action: action_id, reason: reason} | acc.errors]}
          end
      end
    end)
  end

  @doc """
  Gets statistics about healing activity.
  """
  @spec stats() :: map()
  def stats do
    %{
      available_actions: length(catalog()),
      low_risk_actions: catalog() |> Enum.count(&(&1.risk == :low)),
      medium_risk_actions: catalog() |> Enum.count(&(&1.risk == :medium)),
      cooldown_status:
        Enum.map(catalog(), fn action ->
          {action.id, !on_cooldown?(action.id)}
        end)
        |> Map.new()
    }
  end

  # ─────────────────────────────────────────────────────────────────
  # Private: Action Execution
  # ─────────────────────────────────────────────────────────────────

  defp execute_heal(action) do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("[SafeHealer] Executing: #{action.name}")

    try do
      result = action.action.()

      duration_ms = System.monotonic_time(:millisecond) - start_time

      # Record the heal time
      record_heal_time(action.id)

      Logger.info("[SafeHealer] Completed: #{action.name} (#{duration_ms}ms)")

      {:ok,
       %{
         action_id: action.id,
         duration_ms: duration_ms,
         result: inspect(result),
         timestamp: DateTime.utc_now()
       }}
    rescue
      e ->
        Logger.warning("[SafeHealer] Failed: #{action.name} - #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Private: Cooldown Management
  # ─────────────────────────────────────────────────────────────────

  defp on_cooldown?(action_id) do
    case :persistent_term.get({:safe_healer_last_heal, action_id}, nil) do
      nil ->
        false

      last_time ->
        cooldown = Map.get(@heal_cooldowns, action_id, @auto_heal_cooldown_ms)
        System.monotonic_time(:millisecond) - last_time < cooldown
    end
  rescue
    ArgumentError -> false
  end

  defp record_heal_time(action_id) do
    :persistent_term.put({:safe_healer_last_heal, action_id}, System.monotonic_time(:millisecond))
  rescue
    _ -> :ok
  end

  # ─────────────────────────────────────────────────────────────────
  # Private: Condition Checks
  # ─────────────────────────────────────────────────────────────────

  defp classifier_cache_bloated? do
    stats = safe_call(fn -> Mimo.Cache.Classifier.stats() end, %{})
    Map.get(stats, :size, 0) > 10_000
  end

  defp embedding_cache_bloated? do
    stats = safe_call(fn -> Mimo.Cache.Embedding.stats() end, %{})
    Map.get(stats, :size, 0) > 50_000
  end

  defp search_cache_bloated? do
    stats = safe_call(fn -> Mimo.Cache.SearchResult.stats() end, %{})
    Map.get(stats, :size, 0) > 5_000
  end

  defp circuit_breakers_tripped? do
    # Check known circuit breakers
    breakers = [:llm_service, :ollama, :web_service]

    Enum.any?(breakers, fn name ->
      case safe_call(fn -> Mimo.ErrorHandling.CircuitBreaker.get_state(name) end, %{}) do
        %{state: :open} -> true
        _ -> false
      end
    end)
  end

  defp needs_maintenance? do
    # Check if we haven't run maintenance recently
    case Mimo.SleepCycle.stats() do
      %{last_cycle: nil} ->
        true

      %{last_cycle: last} when is_struct(last, DateTime) ->
        DateTime.diff(DateTime.utc_now(), last, :hour) > 24

      _ ->
        false
    end
  end

  defp reset_all_circuit_breakers do
    breakers = [:llm_service, :ollama, :web_service]

    results =
      Enum.map(breakers, fn name ->
        result = safe_call(fn -> Mimo.ErrorHandling.CircuitBreaker.reset(name) end, :ok)
        {name, result}
      end)

    %{reset: results}
  end

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
    end
  end
end
