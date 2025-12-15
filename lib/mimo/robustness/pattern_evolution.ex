defmodule Mimo.Robustness.PatternEvolution do
  @moduledoc """
  Pattern Evolution System for SPEC-070 Implementation Robustness Framework.

  Manages the lifecycle of robustness patterns:
  - Loading patterns from versioned JSON file
  - A/B testing experimental patterns
  - Promoting successful patterns to active status
  - Deprecating low-value patterns
  - Tracking pattern effectiveness metrics

  ## Pattern Lifecycle

  1. **experimental** - New patterns in A/B testing
  2. **active** - Validated patterns in production use
  3. **deprecated** - Low-value patterns (archived, not applied)

  ## A/B Testing

  Experimental patterns are tested in groups (A/B) with metrics tracked:
  - `sample_count` - How many files analyzed with this pattern
  - `positive_detections` - How many times pattern matched
  - `false_positives` - User-reported false positives

  When sample_count reaches threshold and metrics are good, pattern is promoted.
  """

  alias Mimo.Brain.Memory
  alias Mimo.SemanticStore

  @patterns_path "priv/robustness/patterns.json"
  @default_min_samples 50
  @default_max_fp_rate 0.30
  @default_min_real_bug_rate 0.25

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Load all patterns from the versioned JSON file.
  Returns patterns organized by language and status.
  """
  @spec load_patterns() :: {:ok, map()} | {:error, term()}
  def load_patterns do
    patterns_file = Application.app_dir(:mimo, @patterns_path)

    with {:ok, content} <- File.read(patterns_file),
         {:ok, data} <- Jason.decode(content) do
      {:ok, data}
    else
      {:error, :enoent} ->
        # Fallback to priv directory in dev
        fallback_path = Path.join([File.cwd!(), @patterns_path])

        with {:ok, content} <- File.read(fallback_path) do
          Jason.decode(content)
        end

      error ->
        error
    end
  end

  @doc """
  Get active patterns for a specific language.
  Excludes deprecated and optionally includes experimental based on A/B group.
  """
  @spec get_active_patterns(String.t(), keyword()) :: list(map())
  def get_active_patterns(language, opts \\ []) do
    include_experimental = Keyword.get(opts, :include_experimental, false)
    ab_group = Keyword.get(opts, :ab_group, nil)

    case load_patterns() do
      {:ok, data} ->
        active = get_in(data, ["patterns", language]) || []

        experimental =
          if include_experimental do
            (data["experimental_patterns"] || [])
            |> Enum.filter(&matches_language?(&1, language))
            |> Enum.filter(fn p ->
              is_nil(ab_group) or p["ab_test_group"] == ab_group
            end)
          else
            []
          end

        active ++ experimental

      {:error, _} ->
        []
    end
  end

  @doc """
  Record a pattern detection for metrics tracking.
  Used to evaluate experimental patterns.
  """
  @spec record_detection(String.t(), boolean()) :: :ok | {:error, term()}
  def record_detection(pattern_id, is_true_positive \\ true) do
    case load_patterns() do
      {:ok, data} ->
        # Find and update the experimental pattern
        experimental = data["experimental_patterns"] || []

        updated =
          Enum.map(experimental, fn pattern ->
            if pattern["id"] == pattern_id do
              pattern
              |> Map.update("sample_count", 1, &(&1 + 1))
              |> Map.update("positive_detections", 1, &(&1 + 1))
              |> then(fn p ->
                if is_true_positive do
                  p
                else
                  Map.update(p, "false_positives", 1, &(&1 + 1))
                end
              end)
            else
              pattern
            end
          end)

        updated_data = Map.put(data, "experimental_patterns", updated)
        save_patterns(updated_data)

      error ->
        error
    end
  end

  @doc """
  Report a false positive for a pattern.
  Decreases pattern's effectiveness score.
  """
  @spec report_false_positive(String.t(), String.t()) :: :ok | {:error, term()}
  def report_false_positive(pattern_id, file_path) do
    # Record the false positive
    record_detection(pattern_id, false)

    # Also store in memory for learning
    Memory.store(%{
      content: "Pattern #{pattern_id} had false positive in #{file_path}",
      category: "observation",
      importance: 0.6,
      metadata: %{
        type: "false_positive",
        pattern_id: pattern_id,
        file_path: file_path
      }
    })

    :ok
  end

  @doc """
  Evaluate experimental patterns and promote/deprecate based on metrics.
  Returns list of actions taken.
  """
  @spec evaluate_patterns() :: list(map())
  def evaluate_patterns do
    case load_patterns() do
      {:ok, data} ->
        config = data["evolution_config"] || %{}
        min_samples = config["ab_test_sample_size"] || @default_min_samples
        max_fp_rate = config["max_false_positive_rate"] || @default_max_fp_rate
        min_real_bug_rate = config["min_catches_real_bugs"] || @default_min_real_bug_rate

        experimental = data["experimental_patterns"] || []
        active_patterns = data["patterns"] || %{}
        deprecated = data["deprecated_patterns"] || []

        _actions = []

        # Evaluate experimental patterns
        {to_promote, to_deprecate, remaining} =
          Enum.reduce(experimental, {[], [], []}, fn pattern, {promote, deprecate, keep} ->
            samples = pattern["sample_count"] || 0
            positives = pattern["positive_detections"] || 0
            fps = pattern["false_positives"] || 0

            if samples >= min_samples do
              fp_rate = if positives > 0, do: fps / positives, else: 1.0
              real_bug_rate = if samples > 0, do: (positives - fps) / samples, else: 0

              cond do
                fp_rate <= max_fp_rate and real_bug_rate >= min_real_bug_rate ->
                  {[pattern | promote], deprecate, keep}

                fp_rate > max_fp_rate * 1.5 or real_bug_rate < min_real_bug_rate * 0.5 ->
                  {promote, [pattern | deprecate], keep}

                true ->
                  # Keep testing
                  {promote, deprecate, [pattern | keep]}
              end
            else
              {promote, deprecate, [pattern | keep]}
            end
          end)

        # Apply promotions
        updated_active =
          Enum.reduce(to_promote, active_patterns, fn pattern, acc ->
            language = infer_language(pattern)

            promoted =
              pattern
              |> Map.put("status", "active")
              |> Map.put("promoted_date", Date.to_string(Date.utc_today()))
              |> Map.put("false_positive_rate", calculate_fp_rate(pattern))
              |> Map.put("catches_real_bugs", calculate_real_bug_rate(pattern))

            Map.update(acc, language, [promoted], &[promoted | &1])
          end)

        # Apply deprecations
        updated_deprecated =
          Enum.map(to_deprecate, fn pattern ->
            pattern
            |> Map.put("status", "deprecated")
            |> Map.put("deprecated_date", Date.to_string(Date.utc_today()))
            |> Map.put("deprecation_reason", "Low effectiveness in A/B testing")
          end) ++ deprecated

        # Build actions list
        promotion_actions =
          Enum.map(to_promote, fn p ->
            %{action: "promote", pattern_id: p["id"], reason: "Passed A/B testing"}
          end)

        deprecation_actions =
          Enum.map(to_deprecate, fn p ->
            %{action: "deprecate", pattern_id: p["id"], reason: "Failed A/B testing"}
          end)

        # Save updated data
        updated_data =
          data
          |> Map.put("patterns", updated_active)
          |> Map.put("experimental_patterns", remaining)
          |> Map.put("deprecated_patterns", updated_deprecated)

        save_patterns(updated_data)

        # Store learnings in semantic store
        Enum.each(to_promote, &store_pattern_evolution(&1, :promoted))
        Enum.each(to_deprecate, &store_pattern_evolution(&1, :deprecated))

        promotion_actions ++ deprecation_actions

      {:error, _} ->
        []
    end
  end

  @doc """
  Add a new experimental pattern for A/B testing.
  """
  @spec add_experimental_pattern(map()) :: {:ok, String.t()} | {:error, term()}
  def add_experimental_pattern(pattern_attrs) do
    required_fields = ["name", "regex", "severity", "description"]

    missing = Enum.reject(required_fields, &Map.has_key?(pattern_attrs, &1))

    if missing != [] do
      {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    else
      case load_patterns() do
        {:ok, data} ->
          pattern_id = "exp_" <> generate_pattern_id(pattern_attrs["name"])

          new_pattern = %{
            "id" => pattern_id,
            "name" => pattern_attrs["name"],
            "regex" => pattern_attrs["regex"],
            "severity" => pattern_attrs["severity"],
            "description" => pattern_attrs["description"],
            "recommendation" => pattern_attrs["recommendation"] || "Review this code",
            "status" => "experimental",
            "ab_test_group" => assign_ab_group(data),
            "test_start_date" => Date.to_string(Date.utc_today()),
            "sample_count" => 0,
            "positive_detections" => 0,
            "false_positives" => 0
          }

          experimental = (data["experimental_patterns"] || []) ++ [new_pattern]
          updated_data = Map.put(data, "experimental_patterns", experimental)

          case save_patterns(updated_data) do
            :ok -> {:ok, pattern_id}
            error -> error
          end

        error ->
          error
      end
    end
  end

  @doc """
  Learn a new pattern from an incident post-mortem.
  Adds as experimental pattern for A/B testing.
  """
  @spec learn_from_incident(map()) :: {:ok, String.t()} | {:error, term()}
  def learn_from_incident(incident) do
    # Extract pattern info from incident
    root_cause = incident[:root_cause] || incident["root_cause"] || ""
    prevention = incident[:prevention] || incident["prevention"] || ""

    # Generate pattern attributes
    pattern_attrs = %{
      "name" => "Learned: #{String.slice(root_cause, 0, 50)}",
      "description" => root_cause,
      "recommendation" => prevention,
      "severity" => infer_severity(incident),
      "regex" => incident[:pattern_regex] || incident["pattern_regex"] || ".*",
      "incident_source" => incident[:id] || incident["id"]
    }

    add_experimental_pattern(pattern_attrs)
  end

  @doc """
  Get pattern evolution statistics.
  """
  @spec get_stats() :: map()
  def get_stats do
    case load_patterns() do
      {:ok, data} ->
        patterns = data["patterns"] || %{}
        experimental = data["experimental_patterns"] || []
        deprecated = data["deprecated_patterns"] || []

        active_count =
          patterns
          |> Map.values()
          |> List.flatten()
          |> length()

        %{
          version: data["version"],
          last_updated: data["last_updated"],
          active_patterns: active_count,
          experimental_patterns: length(experimental),
          deprecated_patterns: length(deprecated),
          languages: Map.keys(patterns),
          experimental_in_group_a: Enum.count(experimental, &(&1["ab_test_group"] == "A")),
          experimental_in_group_b: Enum.count(experimental, &(&1["ab_test_group"] == "B"))
        }

      {:error, reason} ->
        %{error: reason}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp save_patterns(data) do
    patterns_file = Path.join([File.cwd!(), @patterns_path])

    updated_data =
      data
      |> Map.put("last_updated", Date.to_string(Date.utc_today()))

    case Jason.encode(updated_data, pretty: true) do
      {:ok, json} ->
        File.write(patterns_file, json)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp matches_language?(pattern, language) do
    # Infer language from pattern regex or id
    pattern_id = pattern["id"] || ""

    cond do
      String.contains?(pattern_id, "elixir") -> language == "elixir"
      String.contains?(pattern_id, "js") -> language == "javascript"
      String.contains?(pattern_id, "typescript") -> language == "javascript"
      # Default: apply to all languages
      true -> true
    end
  end

  defp infer_language(pattern) do
    id = pattern["id"] || ""
    regex = pattern["regex"] || ""

    cond do
      String.contains?(id, "genserver") or String.contains?(regex, "GenServer") ->
        "elixir"

      String.contains?(id, "exec") or String.contains?(regex, "execSync") ->
        "javascript"

      String.contains?(regex, "def ") or String.contains?(regex, "defmodule") ->
        "elixir"

      String.contains?(regex, "async") or String.contains?(regex, "await") ->
        "javascript"

      true ->
        # Default
        "elixir"
    end
  end

  defp calculate_fp_rate(pattern) do
    positives = pattern["positive_detections"] || 0
    fps = pattern["false_positives"] || 0

    if positives > 0, do: Float.round(fps / positives, 2), else: 0.0
  end

  defp calculate_real_bug_rate(pattern) do
    samples = pattern["sample_count"] || 0
    positives = pattern["positive_detections"] || 0
    fps = pattern["false_positives"] || 0

    if samples > 0, do: Float.round((positives - fps) / samples, 2), else: 0.0
  end

  defp generate_pattern_id(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.slice(0, 30)
  end

  defp assign_ab_group(data) do
    experimental = data["experimental_patterns"] || []

    a_count = Enum.count(experimental, &(&1["ab_test_group"] == "A"))
    b_count = Enum.count(experimental, &(&1["ab_test_group"] == "B"))

    if a_count <= b_count, do: "A", else: "B"
  end

  defp infer_severity(incident) do
    impact = incident[:impact] || incident["impact"] || ""

    cond do
      String.contains?(String.downcase(impact), "critical") -> "critical"
      String.contains?(String.downcase(impact), "crash") -> "critical"
      String.contains?(String.downcase(impact), "block") -> "high"
      String.contains?(String.downcase(impact), "slow") -> "medium"
      true -> "low"
    end
  end

  defp store_pattern_evolution(pattern, action) do
    predicate = if action == :promoted, do: "evolved_to_active", else: "deprecated"

    SemanticStore.store_triple(
      pattern["id"],
      predicate,
      Date.to_string(Date.utc_today()),
      source: "pattern_evolution",
      metadata: %{
        samples: pattern["sample_count"],
        fp_rate: calculate_fp_rate(pattern),
        real_bug_rate: calculate_real_bug_rate(pattern)
      }
    )
  end
end
