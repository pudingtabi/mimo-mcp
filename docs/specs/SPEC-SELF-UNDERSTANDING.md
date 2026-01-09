# SPEC-SELF: Mimo Self-Understanding Enhancement

> **Goal**: Define what genuine self-understanding means and how to measure it
> **Status**: Active (Phase 1 Complete, Phase 2 Partial)
> **Created**: 2025-12-11
> **Updated**: 2025-01-14 - Added 5-Level Framework & Understanding Score

---

## Critical Distinction: Information vs Understanding

**Current State (0.787 confidence)**: Mimo can *retrieve information* about itself.
- ✅ "What is ConfidenceAssessor?" → Retrieves code, docs, memories
- ✅ "Where is memory stored?" → Finds file paths, modules

**Missing State**: Mimo cannot *understand* itself.
- ❌ "Why did reasoning fail on task X?" → Can't predict/explain
- ❌ "Will this change break memory?" → Can't reason causally
- ❌ "What are my capability limits?" → No boundary awareness

### The Information-Understanding Gap

| Capability | Information | Understanding |
|------------|-------------|---------------|
| **Retrieval** | "ConfidenceAssessor uses 7 weights" | Why those weights? |
| **Prediction** | N/A | "Adding 8th weight will slow assess/2 by ~5ms" |
| **Explanation** | "FeedbackLoop stored this memory" | Why was it considered important? |
| **Counterfactual** | N/A | "Without Graph, confidence would be 0.6" |
| **Manipulation** | N/A | "To improve score, add memory category X" |

---

## The 5 Levels of Self-Understanding

### Level 1: Structural Self-Knowledge ✅ DONE (0.787)
**What**: Can retrieve facts about own code, docs, architecture
**Test**: `cognitive assess topic="Mimo ConfidenceAssessor"` → 0.787
**Implementation**: ConfidenceAssessor + Memory + SymbolIndex + Graph

### Level 2: Behavioral Self-Knowledge ✅ IMPLEMENTED
**What**: Knows what actions it has taken and their outcomes
**Test**: "What tasks did I complete today?" → Should list with success/fail
**Implementation**: FeedbackLoop extended with:
- `daily_activity_summary/1` - Structured activity summary with success rates
- `get_activity_timeline/1` - Chronological action history
- `behavioral_metrics/0` - Session metrics, patterns, consistency
**Dispatcher**: `cognitive operation=behavioral_summary|behavioral_timeline|behavioral_metrics`

### Level 3: Predictive Self-Modeling ✅ IMPLEMENTED (2026-01-09)
**What**: Can predict own behavior before execution
**Test**: "How long will reasoning take for this problem?" → ±20% accurate
**Implementation**:
- `Mimo.Cognitive.PredictiveModeling` - Predicts duration, success probability, step count
  - `predict/1` - Make a prediction before execution
  - `calibrate/2` - Compare prediction to actual outcome
  - `calibration_score/1` - Overall prediction accuracy (0.0-1.0)
  - `list_predictions/1` - View prediction history
  - `stats/0` - Prediction statistics
- `Mimo.Cognitive.CapabilityBoundary` - Learns capability limits from failures
  - `can_handle?/1` - Check if task is within capabilities
  - `record_boundary/2` - Learn from failures
  - `limitations/1` - List known limitations
  - `stats/0` - Boundary statistics
**Dispatcher**: `cognitive operation=predict|calibrate|calibration_score|predictions|can_handle|limitations`

### Level 4: Causal Self-Understanding ❌ NOT IMPLEMENTED  
**What**: Can explain WHY behaviors occur, not just WHAT
**Test**: "Why did you choose CoT over ToT for that problem?"
**Required New Modules**:
- `CausalReasoning.explain_decision/1` - Trace decision paths
- `Introspection.trace_reasoning/1` - Capture reasoning steps
- Integration with reasoning sessions for "decision archaeology"

### Level 5: Self-Modification ❌ NOT IMPLEMENTED (RISKY)
**What**: Can improve own capabilities based on understanding
**Test**: Autonomously improves based on failure patterns
**Status**: DEFERRED - requires very careful safety design
**Risk**: Unbounded self-modification is a safety concern

---

## New Metric: Understanding Score

The current ConfidenceAssessor measures *information retrieval*. 
True understanding requires a different metric:

```elixir
understanding_score = 
  0.30 * prediction_calibration +  # How accurate are self-predictions?
  0.25 * counterfactual_accuracy + # Can explain "what if X was different?"
  0.25 * explanation_rate +        # % of decisions with traceable reasons
  0.20 * improvement_rate          # Learning from mistakes over time
```

### Measuring Each Component

#### Prediction Calibration (0.30 weight)
```elixir
# Before action: "I predict this will take 3 steps"
# After action: Actually took 4 steps
# Calibration = 1 - |predicted - actual| / max(predicted, actual)
# Score: 1 - |3-4|/4 = 0.75
```

#### Counterfactual Accuracy (0.25 weight)
```elixir
# "Without memory search, confidence would be X"
# Actually remove memory search, measure confidence
# Accuracy = 1 - |predicted_delta - actual_delta|
```

#### Explanation Rate (0.25 weight)
```elixir
# Track all decisions
# Count how many have traceable explanations
# Rate = explained_decisions / total_decisions
```

#### Improvement Rate (0.20 weight)
```elixir
# Compare task success over time
# Rate = (recent_success_rate - past_success_rate) / past_success_rate
```

---

## Implementation Roadmap

### Milestone A: Behavioral Tracking (Level 2 Complete)
**Effort**: 3-5 days
1. Add outcome tracking to all tool dispatches
2. Store performance metrics in dedicated ETS table
3. Query: "What did I do today?" returns structured history

### Milestone B: Prediction Framework (Level 3 Start)
**Effort**: 5-7 days
1. Create `PredictiveModeling` module
2. Before each reasoning: predict steps, time, success probability
3. After each reasoning: compare prediction to actual
4. Build calibration score over time

### Milestone C: Capability Boundaries (Level 3 Complete)
**Effort**: 4-5 days
1. Create `CapabilityBoundary` module
2. Learn from failures: what query types fail often?
3. "Can I handle this?" check before accepting task
4. Honest "I don't know" when outside boundaries

### Milestone D: Causal Traces (Level 4 Start)
**Effort**: 5+ days
1. Extend reasoning sessions with decision traces
2. Every branch point: capture "why this path?"
3. Query: "Why did you choose X?" returns reasoning chain

---

## Current vs Target State

| Metric | Current | Target (6 months) |
|--------|---------|-------------------|
| Confidence Score (L1) | 0.787 | 0.85+ |
| Behavioral Tracking (L2) | 0.3 | 0.8 |
| Prediction Calibration (L3) | 0.0 | 0.6 |
| Counterfactual (L3) | 0.0 | 0.5 |
| Explanation Rate (L4) | 0.1 | 0.4 |
| Understanding Score | ~0.15 | 0.5 |

---

## Original Confidence Score Work

The sections below document the original work on improving the *information retrieval* score (Level 1). This is complete at 0.787.

---

## Overview (Legacy)

This specification defines executable tasks to improve Mimo's self-understanding from ~0.5 to 0.9+ confidence. Based on analysis of `confidence_assessor.ex`, the score is calculated from weighted components.

### Confidence Algorithm Weights

| Component | Weight | Current Score | Target | Gap |
|-----------|--------|---------------|--------|-----|
| Memory (count/recency/relevance) | 40% | ~0.6 | 0.9 | **+0.3** |
| Code Symbols | 20% | ~0.2 | 0.8 | **+0.6** |
| Knowledge Graph | 20% | ~0.0 | 0.8 | **+0.8** |
| Library Docs | 10% | ~0.0 | 0.5 | **+0.5** |
| Source Diversity | 10% | ~0.5 | 1.0 | **+0.5** |

### Target Formula

```
Final Score = 0.4 × (memory) + 0.2 × (code) + 0.2 × (graph) + 0.1 × (library) + 0.1 × (diversity)

To reach 0.9:
0.9 = 0.4 × (0.9) + 0.2 × (0.8) + 0.2 × (0.8) + 0.1 × (0.5) + 0.1 × (1.0)
0.9 = 0.36 + 0.16 + 0.16 + 0.05 + 0.10 = 0.83

To reach 0.9, need ALL sources maximized:
0.4 × (1.0) + 0.2 × (1.0) + 0.2 × (1.0) + 0.1 × (1.0) + 0.1 × (1.0) = 1.0
```

---

## Phase 1: Memory Enhancement (40% weight)

**Target**: 5+ highly relevant memories with recent timestamps

### Tasks

#### 1.1 Store Core Architecture Facts
```bash
# Execute these memory stores:
memory operation=store content="Mimo.Brain.Memory (69KB) is the central memory API implementing SPEC-001/002/003/004. Key functions: store_memory/2, search_memories/2, get_memory/1, update_memory/2. Uses ETS for working memory, SQLite for episodic, vectors for similarity." category=fact importance=0.95

memory operation=store content="Mimo.Tools.dispatch/1 routes all 19 MCP tools through InjectionMiddleware (SPEC-065). Dispatchers: cognitive, memory, file, terminal, web, code, knowledge, autonomous, meta, onboard, library, verify, emergence, reflector, prepare_context, analyze_file, debug_error, suggest_next_tool, diagnostics." category=fact importance=0.95

memory operation=store content="Mimo.Cognitive.ConfidenceAssessor.assess/2 calculates confidence using weights: memory_count (0.15), memory_recency (0.10), memory_relevance (0.15), code_presence (0.20), graph_relevance (0.20), source_diversity (0.10), library_knowledge (0.10). Located at lib/mimo/cognitive/confidence_assessor.ex lines 88-127." category=fact importance=0.95
```

#### 1.2 Store Module Relationship Facts
```bash
memory operation=store content="Mimo startup sequence: Application.start -> Supervisor tree -> Repo (SQLite) -> ETS tables (WorkingMemory, SymbolIndex) -> Brain.Memory -> Synapse.Graph -> Tools registry -> MCP server (stdio.ex). Lazy loading via Universal Aperture Architecture." category=fact importance=0.9

memory operation=store content="Mimo embedding pipeline: Input text -> EmbeddingGate (rate limiting) -> Ollama qwen3-embedding:0.6b -> Vector.Math (normalization) -> HnswIndex (approximate NN) -> SQLite storage. Min similarity threshold: 0.3 for retrieval." category=fact importance=0.9
```

#### 1.3 Store Key Function Names for Symbol Matching
```bash
# Store facts using ACTUAL function names that SymbolIndex can match:
memory operation=store content="Key Mimo functions: dispatch, assess, store_memory, search_memories, consolidate, forget, retrieve, synthesize, detect_emergence, reflect, verify_count, verify_math, execute_procedure, query_graph, teach_triple." category=fact importance=0.9

memory operation=store content="Key Mimo modules: Brain.Memory, Brain.WorkingMemory, Brain.Consolidator, Brain.Forgetting, Brain.HybridRetriever, Cognitive.ConfidenceAssessor, Synapse.Graph, Tools, Workflow.Executor, Autonomous.TaskRunner." category=fact importance=0.9
```

---

## Phase 2: Code Symbol Enhancement (20% weight)

**Target**: 5+ code symbols found when searching Mimo-related terms

### Tasks

#### 2.1 Ensure Codebase is Indexed
```bash
# Index Mimo codebase:
code operation=index path="/root/mrc-server/mimo-mcp/lib/mimo"

# Verify index:
code operation=symbols path="/root/mrc-server/mimo-mcp/lib/mimo/brain/memory.ex"
```

#### 2.2 Store Facts with Searchable Function Names
```bash
# The confidence assessor splits query words and searches SymbolIndex.
# Store facts containing actual symbol names:

memory operation=store content="Mimo dispatch function in Tools module routes to: handle_cognitive, handle_memory, handle_file, handle_terminal, handle_web, handle_code, handle_knowledge, handle_autonomous, handle_meta, handle_onboard." category=fact importance=0.9

memory operation=store content="Mimo memory functions: store_memory, search_memories, get_memory, update_memory, delete_memory, list_memories, consolidate_memory, forget_memory, decay_check, memory_stats." category=fact importance=0.9
```

---

## Phase 3: Knowledge Graph Enhancement (20% weight)

**Target**: 10+ graph nodes returned when querying Mimo topics

### Tasks

#### 3.1 Teach Core Relationships
```bash
knowledge operation=teach subject="Mimo.Brain.Memory" predicate="implements" object="SPEC-001"
knowledge operation=teach subject="Mimo.Brain.Memory" predicate="implements" object="SPEC-002"
knowledge operation=teach subject="Mimo.Brain.Memory" predicate="implements" object="SPEC-003"
knowledge operation=teach subject="Mimo.Brain.Memory" predicate="implements" object="SPEC-004"
knowledge operation=teach subject="Mimo.Tools" predicate="dispatches_to" object="cognitive"
knowledge operation=teach subject="Mimo.Tools" predicate="dispatches_to" object="memory"
knowledge operation=teach subject="Mimo.Tools" predicate="dispatches_to" object="file"
knowledge operation=teach subject="Mimo.Tools" predicate="dispatches_to" object="terminal"
knowledge operation=teach subject="Mimo.Tools" predicate="dispatches_to" object="web"
knowledge operation=teach subject="Mimo.Cognitive" predicate="uses" object="ConfidenceAssessor"
```

#### 3.2 Teach Module Dependencies
```bash
knowledge operation=teach subject="Mimo.Brain.Memory" predicate="depends_on" object="Mimo.Brain.WorkingMemory"
knowledge operation=teach subject="Mimo.Brain.Memory" predicate="depends_on" object="Mimo.Brain.Consolidator"
knowledge operation=teach subject="Mimo.Brain.Memory" predicate="depends_on" object="Mimo.Brain.HybridRetriever"
knowledge operation=teach subject="Mimo.Cognitive.ConfidenceAssessor" predicate="queries" object="Mimo.Brain.Memory"
knowledge operation=teach subject="Mimo.Cognitive.ConfidenceAssessor" predicate="queries" object="Mimo.Code.SymbolIndex"
knowledge operation=teach subject="Mimo.Cognitive.ConfidenceAssessor" predicate="queries" object="Mimo.Synapse.QueryEngine"
```

#### 3.3 Link Code to Graph
```bash
# Link indexed files to knowledge graph:
knowledge operation=link path="/root/mrc-server/mimo-mcp/lib/mimo/brain"
knowledge operation=link path="/root/mrc-server/mimo-mcp/lib/mimo/tools"
knowledge operation=link path="/root/mrc-server/mimo-mcp/lib/mimo/cognitive"
```

---

## Phase 4: Library & Diversity Enhancement (20% weight)

**Target**: Cached docs for Mimo dependencies, all 4 source types populated

### Tasks

#### 4.1 Cache Mimo's Dependencies
```bash
# Cache Hex package docs that Mimo uses:
code operation=library_ensure name="ecto" ecosystem=hex
code operation=library_ensure name="jason" ecosystem=hex
code operation=library_ensure name="req" ecosystem=hex
code operation=library_ensure name="finch" ecosystem=hex
```

#### 4.2 Verify Source Diversity
```bash
# Ensure all 4 source types return results:
# 1. Memory: search_memories should return 5+ results
# 2. Code: SymbolIndex.search should return 5+ results  
# 3. Graph: QueryEngine.query should return 10+ nodes
# 4. Library: At least 1 cached library doc
```

---

## Phase 5: Verification

### 5.1 Test Confidence Scores
```bash
# Test with specific module names (should score high):
cognitive operation=assess topic="Mimo Brain Memory store_memory search_memories consolidate"

# Test with function names:
cognitive operation=assess topic="Mimo dispatch assess retrieve synthesize"

# Test with SPEC references:
cognitive operation=assess topic="Mimo SPEC-001 SPEC-002 SPEC-020 WorkingMemory Consolidator"
```

### 5.2 Success Criteria

| Query Type | Target Score | Current |
|------------|--------------|---------|
| Module names query | ≥ 0.8 | ~0.59 |
| Function names query | ≥ 0.85 | ~0.5 |
| SPEC references query | ≥ 0.8 | ~0.5 |
| Generic "Mimo architecture" | ≥ 0.7 | ~0.36 |

---

## Execution Order

1. **Phase 1.1-1.3**: Store 7+ memory facts with actual function/module names
2. **Phase 2.1**: Ensure code index exists (already done: 6,595 symbols)
3. **Phase 3.1-3.3**: Teach 15+ knowledge graph relationships
4. **Phase 4.1**: Cache 4+ library docs
5. **Phase 5.1**: Verify confidence scores

---

## Notes

- The ConfidenceAssessor splits queries by whitespace and searches each word
- Words like "Mimo", "architecture" don't match symbol names
- Use actual function names: `dispatch`, `assess`, `store_memory`, etc.
- Graph nodes are found via `QueryEngine.query` - needs populated triples
- Library cache checked via `CacheManager.cached?` for specific packages
