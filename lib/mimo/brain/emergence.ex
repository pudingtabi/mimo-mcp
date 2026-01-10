defmodule Mimo.Brain.Emergence do
  @moduledoc """
  SPEC-044: Emergent Capabilities Framework - Main Facade Module.

  Emergence is the phenomenon where capabilities arise from the interaction
  of simpler components at scale—behaviors not explicitly programmed but
  discovered through system complexity.

  > "The whole is greater than the sum of its parts" - Aristotle

  ## Core Principle

  ```
  PROGRAMMED CAPABILITIES:
    Input → Defined Logic → Expected Output
    Predictable, bounded, designed

  EMERGENT CAPABILITIES:
    Components A, B, C interact
    Interactions create novel capability X
    A+B+C ≠ A+B+C = X
    Unpredictable, unbounded, discovered
  ```

  ## The Five Conditions for Emergence

  1. **Diversity**: Different types of components interacting
  2. **Connectivity**: Rich connections between components
  3. **Feedback Loops**: Outputs influencing inputs
  4. **Persistence**: State maintained across time
  5. **Pressure**: Challenges that drive adaptation

  ## Run Cycle Phases

  The `run_cycle/1` function executes 5 phases:
  1. **Detection**: Find emergent patterns in system behavior
  2. **Amplification**: Strengthen promising patterns
  3. **Promotion**: Graduate mature patterns to capabilities
  4. **Alerts**: Check for patterns needing attention
  5. **Consolidation**: Merge similar memories (SPEC-105)

  ## Pattern Types

  | Type | Description |
  |------|-------------|
  | Workflow | Sequence of actions that achieves a goal |
  | Inference | Conclusion drawn from combining knowledge |
  | Heuristic | Rule of thumb that usually works |
  | Skill | Ability to do something effectively |

  ## Detection Modes

  | Mode | What It Finds |
  |------|---------------|
  | pattern_repetition | Same action sequences recurring |
  | cross_memory_inference | Conclusions from memory combinations |
  | novel_tool_chains | Unexpected tool combinations that work |
  | prediction_success | Anticipations that prove correct |
  | capability_transfer | Skills from one domain to another |

  ## Usage Examples

  ```elixir
  # Run emergence detection
  Mimo.Brain.Emergence.detect_patterns()

  # Get emergence dashboard
  Mimo.Brain.Emergence.dashboard()

  # Check for alerts
  Mimo.Brain.Emergence.check_alerts()

  # Amplify emergence conditions
  Mimo.Brain.Emergence.amplify()

  # Promote eligible patterns
  Mimo.Brain.Emergence.promote_eligible()
  ```

  ## Architecture

  ```
  Interaction Stream → Detector → Pattern Classification → Storage
                                        ↓                      ↓
                                   Amplifier              Catalog
                                        ↓                      ↓
                                   Promoter    ←          Metrics
                                        ↓
                                 Explicit Capabilities
  ```

  ## Integration with Awakening (SPEC-040)

  Emerged capabilities contribute to the agent's power level:
  - Each emerged pattern grants XP
  - Promoted patterns unlock achievements
  - Capability milestones trigger level-ups
  """

  require Logger

  alias Mimo.Brain.Emergence.{
    Alerts,
    Amplifier,
    Catalog,
    Detector,
    Metrics,
    Pattern,
    Promoter
  }

  alias Mimo.Brain.MemoryConsolidator

  # ─────────────────────────────────────────────────────────────────
  # Detection
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Detects emergent patterns from recent system interactions.

  ## Options

  - `:days` - Number of days to analyze (default: 7)
  - `:modes` - Specific detection modes to run (default: all)

  ## Examples

      # Detect patterns from last 7 days
      detect_patterns()

      # Detect from last 30 days
      detect_patterns(days: 30)

      # Only detect workflows
      detect_patterns(modes: [:pattern_repetition, :novel_tool_chains])
  """
  @spec detect_patterns(keyword()) :: {:ok, map()} | {:error, term()}
  def detect_patterns(opts \\ []) do
    Logger.info("[Emergence] Starting pattern detection")
    Detector.analyze_recent(opts)
  end

  @doc """
  Detects patterns of a specific type.

  ## Modes

  - `:pattern_repetition` - Find recurring action sequences
  - `:cross_memory_inference` - Find inferences from memory combinations
  - `:novel_tool_chains` - Find successful tool combinations
  - `:prediction_success` - Find verified predictions
  - `:capability_transfer` - Find cross-domain skill transfers
  """
  @spec detect(atom(), map()) :: {:ok, [Pattern.t()]} | {:error, term()}
  def detect(mode, context \\ %{}) do
    Detector.detect(mode, context)
  end

  # ─────────────────────────────────────────────────────────────────
  # Amplification
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Amplifies conditions that encourage emergence.

  Runs all amplification strategies:
  - Increases connectivity between concepts
  - Encourages diversity in reasoning
  - Strengthens feedback loops
  - Adds creative pressure

  ## Returns

  Map with results from each amplification strategy.
  """
  @spec amplify() :: {:ok, map()} | {:error, term()}
  def amplify do
    Logger.info("[Emergence] Running amplification strategies")
    Amplifier.amplify_conditions()
  end

  # ─────────────────────────────────────────────────────────────────
  # Promotion
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Promotes all patterns that meet promotion thresholds.

  Thresholds:
  - Occurrences: 10+ observations
  - Success rate: 80%+
  - Strength: 0.75+

  ## Options

  - `:min_occurrences` - Override minimum occurrences
  - `:min_success_rate` - Override minimum success rate
  - `:min_strength` - Override minimum strength
  """
  @spec promote_eligible(keyword()) :: {:ok, map()}
  def promote_eligible(opts \\ []) do
    Logger.info("[Emergence] Promoting eligible patterns")
    Promoter.promote_eligible(opts)
  end

  @doc """
  Evaluates a specific pattern for promotion.
  Returns scoring details and recommendation.
  """
  @spec evaluate_for_promotion(Pattern.t(), keyword()) :: {:promote | :pending, map()}
  def evaluate_for_promotion(pattern, opts \\ []) do
    Promoter.evaluate_for_promotion(pattern, opts)
  end

  @doc """
  Gets promotion readiness report for all active patterns.
  """
  @spec promotion_report(keyword()) :: map()
  def promotion_report(opts \\ []) do
    Promoter.promotion_readiness_report(opts)
  end

  # ─────────────────────────────────────────────────────────────────
  # Catalog
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Lists all emerged capabilities.

  ## Options

  - `:limit` - Maximum results (default: 100)
  - `:include_pending` - Include non-promoted patterns (default: false)
  """
  @spec list_capabilities(keyword()) :: [map()]
  def list_capabilities(opts \\ []) do
    Catalog.list_emerged_capabilities(opts)
  end

  @doc """
  Gets a comprehensive capability report.
  """
  @spec capability_report() :: map()
  def capability_report do
    Catalog.capability_report()
  end

  @doc """
  Searches capabilities by description.
  """
  @spec search_capabilities(String.t(), keyword()) :: [map()]
  def search_capabilities(query, opts \\ []) do
    Catalog.search(query, opts)
  end

  @doc """
  Gets capability suggestions based on current context.
  """
  @spec suggest_capabilities(map()) :: [map()]
  def suggest_capabilities(context) do
    Catalog.suggest_capabilities(context)
  end

  # ─────────────────────────────────────────────────────────────────
  # Metrics & Monitoring
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Gets the emergence dashboard with all metrics.

  Returns metrics in five categories:
  - Quantity: patterns detected, promoted, capabilities
  - Quality: success rates, strength distribution
  - Velocity: detection rate, promotion rate
  - Coverage: domains, tool combinations
  - Evolution: strengthening/weakening patterns
  """
  @spec dashboard() :: map()
  def dashboard do
    Metrics.dashboard()
  end

  @doc """
  Gets pattern detection velocity over time.
  """
  @spec pattern_velocity(keyword()) :: map()
  def pattern_velocity(opts \\ []) do
    Metrics.pattern_velocity(opts)
  end

  @doc """
  Gets quality metrics for patterns.
  """
  @spec quality_metrics() :: map()
  def quality_metrics do
    Metrics.quality_metrics()
  end

  @doc """
  Gets evolution metrics.
  """
  @spec evolution_metrics(keyword()) :: map()
  def evolution_metrics(opts \\ []) do
    Metrics.evolution_metrics(opts)
  end

  @doc """
  Gets the promotion funnel metrics.
  """
  @spec promotion_funnel() :: map()
  def promotion_funnel do
    Metrics.promotion_funnel()
  end

  @doc """
  Exports metrics for external monitoring systems.
  """
  @spec export_metrics() :: map()
  def export_metrics do
    Metrics.export_metrics()
  end

  # ─────────────────────────────────────────────────────────────────
  # Alerts
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Checks all alert conditions.

  Returns list of active alerts, sorted by priority.

  Alert types:
  - `:novel_pattern` - New patterns detected
  - `:promotion_ready` - Patterns ready for promotion
  - `:pattern_evolution` - Significant strength changes
  - `:capability_milestone` - Milestones achieved
  - `:system_health` - Detection rate, quality issues
  """
  @spec check_alerts() :: [Alerts.alert()]
  def check_alerts do
    Alerts.check_alerts()
  end

  @doc """
  Gets alert status summary.
  """
  @spec alert_status() :: map()
  def alert_status do
    Alerts.status()
  end

  # ─────────────────────────────────────────────────────────────────
  # Patterns API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Creates a new pattern manually.

  Normally patterns are detected automatically, but this allows
  manual pattern creation for testing or seeding.
  """
  @spec create_pattern(map()) :: {:ok, Pattern.t()} | {:error, term()}
  def create_pattern(attrs) do
    Pattern.create(attrs)
  end

  @doc """
  Gets a pattern by ID.
  """
  @spec get_pattern(String.t()) :: Pattern.t() | nil
  def get_pattern(id) do
    Mimo.Repo.get(Pattern, id)
  end

  @doc """
  Lists patterns with filters.

  ## Options

  - `:type` - Filter by type (:workflow, :inference, :heuristic, :skill)
  - `:status` - Filter by status (:active, :promoted, :dormant, :archived)
  - `:limit` - Maximum results
  - `:order` - Sort order (:asc, :desc)
  """
  @spec list_patterns(keyword()) :: [Pattern.t()]
  def list_patterns(opts \\ []) do
    Pattern.list(opts)
  end

  @doc """
  Records an occurrence of a pattern.
  Called when a pattern is observed again.
  """
  @spec record_occurrence(Pattern.t()) :: {:ok, Pattern.t()} | {:error, term()}
  def record_occurrence(pattern) do
    Pattern.record_occurrence(pattern)
  end

  @doc """
  Records an outcome for a pattern.
  Used to track success/failure for success rate calculation.
  """
  @spec record_outcome(Pattern.t(), boolean()) :: {:ok, Pattern.t()} | {:error, term()}
  def record_outcome(pattern, success?) do
    Pattern.record_outcome(pattern, success?)
  end

  # ─────────────────────────────────────────────────────────────────
  # Scheduled Tasks
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Runs the full emergence cycle.

  This is intended to be called periodically (e.g., daily) to:
  1. Detect new patterns
  2. Amplify emergence conditions
  3. Promote eligible patterns
  4. Check alerts

  ## Returns

  Map with results from each phase.
  """
  @spec run_cycle(keyword()) :: {:ok, map()}
  def run_cycle(opts \\ []) do
    Logger.info("[Emergence] Starting emergence cycle")

    # Phase 1: Detection (graceful on failure)
    detection =
      case detect_patterns(opts) do
        {:ok, result} -> result
        _ -> %{}
      end

    # Phase 2: Amplification (graceful on failure)
    amplification =
      case amplify() do
        {:ok, result} -> result
        _ -> %{}
      end

    # Phase 3: Promotion (graceful on failure)
    promotions =
      case promote_eligible(opts) do
        {:ok, result} -> result
        _ -> %{promoted: 0}
      end

    # Phase 4: Alerts
    alerts = check_alerts()

    # Phase 5: Memory Consolidation (SPEC-105)
    # Consolidate up to 3 clusters per cycle to avoid over-merging
    consolidation =
      case MemoryConsolidator.run(max_clusters: 3) do
        {:ok, result} ->
          result

        {:error, reason} ->
          Logger.debug("[Emergence] Consolidation skipped: #{inspect(reason)}")
          %{consolidated: 0, archived: 0}
      end

    Logger.info(
      "[Emergence] Cycle complete: #{map_size(detection)} detection modes, " <>
        "#{promotions.promoted} promotions, #{length(alerts)} alerts, " <>
        "#{consolidation[:consolidated] || 0} memories consolidated"
    )

    {:ok,
     %{
       detection: detection,
       amplification: amplification,
       promotions: promotions,
       alerts: alerts,
       consolidation: consolidation,
       completed_at: DateTime.utc_now()
     }}
  end

  # ─────────────────────────────────────────────────────────────────
  # Initialization
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Initializes the emergence framework.
  Called during application startup.
  """
  @spec init() :: :ok
  def init do
    Catalog.init()
    Logger.info("[Emergence] Framework initialized")
    :ok
  end
end
