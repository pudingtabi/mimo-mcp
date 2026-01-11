# Emergence Research Roadmap

> Compounding external research with Mimo's emergence system - SPEC-044 Evolution

## Current State Analysis

### What Mimo Already Has (Phase 4 Foundation)

| Capability | Implementation | Status |
|------------|----------------|--------|
| Pattern Detection | `Emergence.detect_patterns/1` | ✅ Working (2,351 patterns) |
| Pattern Promotion | `Emergence.promote_eligible/0` | ✅ Working (96% rate) |
| Type Classification | workflow/heuristic/inference/skill | ✅ Working |
| Success Tracking | `record_occurrence/record_outcome` | ✅ Working (95% avg) |
| Dashboard | `Emergence.dashboard/0` | ✅ Working |
| Alerts | `Emergence.check_alerts/0` | ✅ Working |
| Capability Suggestions | `suggest_capabilities/1` | ✅ Working |

### Current Emergence Statistics

```
Total Patterns: 2,351
Promoted: 2,248 (96% rate)
├── Workflows: 2,123 (95% success rate)
├── Heuristics: 114 (100% success rate)  
├── Skills: 11 (84% success rate)
└── Inferences: ~4
```

---

## External Research Insights

### 1. ACD - Automated Capability Discovery (arXiv:2502.07577)

**Key Concepts:**
- Uses one foundation model as "scientist" to probe capabilities of "subject" model
- Generates thousands of distinct tasks automatically
- Tasks are clustered into **capability areas**
- Self-exploration approach - model discovers what it CAN do, not just what it HAS done

**Relevance to Mimo:**
- Mimo currently does **passive observation** (watches what agent does)
- ACD suggests **active probing** (generate tasks to test edge capabilities)
- Could discover latent capabilities before they're naturally exercised

### 2. Abductive AI for Emergence (Nature Reviews Physics 2025)

**Key Concepts:**
- Traditional complexity science **struggles** with emergent phenomena
- Abductive reasoning (computationally feasible via AI) offers new pathway
- "More is different" - emergent properties aren't predictable from components alone
- References: Reservoir computing, sparse identification of dynamical systems

**Relevance to Mimo:**
- Mimo observes patterns but doesn't **explain** why they work
- Abductive layer could generate hypotheses: "This skill works because..."
- Could predict emergence before it happens based on trajectory

---

## Proposed Evolution: Three New Capabilities

### Capability 1: Active Probing (ACD-inspired)

**Concept:** Don't just watch what agent does - actively test capabilities

```elixir
# New operation: emergence_probe
defmodule Mimo.Brain.Emergence.Prober do
  @moduledoc """
  Active capability discovery through self-probing.
  
  Instead of waiting for patterns to naturally occur,
  generate synthetic tasks to test edge capabilities.
  """
  
  def probe_capabilities(domain \\ :all) do
    # 1. Analyze existing skills
    existing = Pattern.list(filters: [promoted: true, type: :skill])
    
    # 2. Identify gaps - what domains are under-explored?
    gaps = find_capability_gaps(existing)
    
    # 3. Generate probe tasks for gaps
    probe_tasks = generate_probe_tasks(gaps)
    
    # 4. Execute probes and measure results
    results = execute_probes(probe_tasks)
    
    # 5. Surface newly discovered capabilities
    %{
      gaps_found: length(gaps),
      probes_executed: length(probe_tasks),
      capabilities_discovered: extract_discoveries(results)
    }
  end
  
  defp find_capability_gaps(existing_skills) do
    # Compare existing skills against known capability taxonomy
    all_domains = [:file_ops, :code_analysis, :web, :memory, :reasoning, ...]
    covered = Enum.map(existing_skills, & &1.domain) |> Enum.uniq()
    all_domains -- covered
  end
end
```

**Value:** Proactive discovery vs reactive observation

### Capability 2: Abductive Explanation Layer

**Concept:** Generate hypotheses about WHY patterns work

```elixir
# New operation: emergence_explain
defmodule Mimo.Brain.Emergence.Explainer do
  @moduledoc """
  Abductive reasoning for emergence.
  
  Don't just detect patterns - explain WHY they're effective.
  Generate testable hypotheses about capability relationships.
  """
  
  def explain_pattern(pattern_id) do
    pattern = Pattern.get(pattern_id)
    
    # 1. Gather context about the pattern
    context = gather_pattern_context(pattern)
    
    # 2. Generate hypotheses about why it works
    hypotheses = generate_hypotheses(pattern, context)
    
    # 3. Rank hypotheses by plausibility
    ranked = rank_by_evidence(hypotheses, context)
    
    # 4. Return explanation with confidence
    %{
      pattern: pattern.description,
      primary_explanation: hd(ranked),
      alternative_hypotheses: tl(ranked),
      confidence: calculate_confidence(ranked)
    }
  end
  
  defp generate_hypotheses(pattern, context) do
    # Use LLM to generate possible explanations
    # Why does "reason before file edit" lead to better outcomes?
    # Possible: reduces errors, improves context, forces planning...
  end
end
```

**Value:** Understanding not just WHAT works, but WHY

### Capability 3: Emergence Prediction

**Concept:** Forecast skill emergence before it happens

```elixir
# New operation: emergence_predict
defmodule Mimo.Brain.Emergence.Predictor do
  @moduledoc """
  Predict when patterns will graduate to skills.
  
  Track velocity and trajectory toward promotion thresholds.
  Alert when new capabilities are about to emerge.
  """
  
  def predict_emergence(opts \\ []) do
    window = Keyword.get(opts, :window, 7) # days
    threshold = Keyword.get(opts, :threshold, 0.8) # confidence
    
    # 1. Get patterns approaching promotion
    candidates = Pattern.promotion_candidates(limit: 100)
    
    # 2. Calculate trajectory for each
    trajectories = Enum.map(candidates, fn pattern ->
      velocity = calculate_velocity(pattern, window)
      eta = estimate_time_to_promotion(pattern, velocity)
      confidence = trajectory_confidence(pattern, velocity)
      
      %{
        pattern: pattern,
        velocity: velocity,
        eta_days: eta,
        confidence: confidence
      }
    end)
    
    # 3. Filter high-confidence predictions
    predictions = Enum.filter(trajectories, & &1.confidence >= threshold)
    
    # 4. Return ranked by ETA
    Enum.sort_by(predictions, & &1.eta_days)
  end
  
  def predict_impact(predicted_skill) do
    # What changes when this skill emerges?
    # Which workflows will it affect?
    # What new capabilities will it unlock?
  end
end
```

**Value:** Anticipate growth, prepare for new capabilities

---

## Existing Infrastructure Discovery

**Surprisingly, ~70% of prediction infrastructure already exists!**

### Already Implemented in Metrics Module
- `pattern_velocity/1` - Daily counts, trends, averages
- `evolution_metrics/1` - Multi-day pattern evolution analysis  
- `calculate_velocity_trend/1` - Detects accelerating/decelerating/stable
- `calculate_pattern_trend/1` - Individual pattern trajectory
- `patterns_strengthening/patterns_weakening` - Evolution tracking

### Already Implemented in Detector Module
- `detect_predictions/1` - Finds verified predictions
- `prediction_verified?/1` - Checks confirmation status
- Creates heuristic patterns from validated predictions

### What's Missing (Incremental Additions)
1. **ETA calculation** for pattern → skill promotion
2. **Confidence scoring** for predictions
3. **Hypothesis generation** for why patterns work
4. **Active probing** for latent capabilities

---

## Implementation Phases

### Phase 4.1: Foundation Enhancement (Current) ✅ MOSTLY DONE
- ✅ Skills visibility in awakening context (SPEC-044 v1.3)
- ✅ Velocity tracking in metrics module (already exists!)
- ✅ Evolution tracking in metrics module (already exists!)
- [ ] Surface velocity in awakening context

### Phase 4.2: Prediction Layer (~30% new code)
- [ ] Add `predict_emergence/1` to Metrics module
  - Use existing velocity + trend data
  - Add ETA calculation
  - Add confidence scoring
- [ ] Add `emergence_predict` MCP operation
- [ ] Create prediction accuracy feedback loop
- [ ] Build emergence alerts for predicted skills

### Phase 4.3: Explanation Layer (~60% new code)
- [ ] Implement `Emergence.Explainer` module
- [ ] Add `emergence_explain` MCP operation
- [ ] Integrate with reasoning engine for hypothesis generation
- [ ] Store explanations in knowledge graph

### Phase 4.4: Active Probing (~80% new code)
- [ ] Implement `Emergence.Prober` module
- [ ] Define capability taxonomy
- [ ] Add `emergence_probe` MCP operation
- [ ] Build probe task generator
- [ ] Create discovery feedback loop

---

## Research References

1. **Automated Capability Discovery via Foundation Model Self-Exploration**
   - arXiv:2502.07577
   - Key insight: Model as scientist probing subject model
   - Generates thousands of tasks clustered into capability areas

2. **Understanding emergence in complex systems using abductive AI**
   - Nature Reviews Physics 7, 675–677 (2025)
   - DOI: 10.1038/s42254-025-00895-5
   - Key insight: Abductive reasoning for emergent phenomena

3. **More is Different** (Anderson 1972)
   - Science 177, 393–396
   - Foundational paper on emergence in complex systems

4. **Discovering governing equations from data by sparse identification**
   - PNAS 113, 3932–3937 (2016)
   - SINDy approach to pattern extraction

---

## Success Metrics

| Metric | Current | Target (Phase 4.4) |
|--------|---------|---------------------|
| Pattern Detection Rate | 96% | 98% |
| Skills Emerged | 11 | 25+ |
| Prediction Accuracy | N/A | 80% |
| Explanation Coverage | 0% | 70% |
| Proactive Discoveries | 0 | 10+ |

---

## Connection to Mimo Vision

From [VISION.md](../VISION.md):

> Emergence is the crown jewel - skills that arise spontaneously from agent behavior

These research-backed enhancements move Mimo from:
- **Reactive** (observes what happened) → **Predictive** (forecasts what will happen)
- **Descriptive** (records patterns) → **Explanatory** (understands why)
- **Passive** (waits for usage) → **Active** (probes for capabilities)

This evolution transforms emergence from pattern recording to true capability discovery.
