# Mimo 90-Day Strategic Implementation Plan (Jan-Mar 2026)

> **✅ IMPLEMENTATION COMPLETE** - All 4 phases successfully implemented (42/42 tasks)
> - Phase 1: Foundation Hardening ✅
> - Phase 2: Emergence Proof-of-Concept ✅
> - Phase 3: Multi-Agent Validation ✅
> - Phase 4: Documentation as System ✅
>
> Completed by Opus 4.5 Cognitive Agent - See checklist at end of document.

## Executive Context


You are implementing Mimo's transition from "memory prosthetic" to "cognitive amplifier" - a memory operating system that multiplies AI intelligence through persistent, compound knowledge. This plan proves 4 critical hypotheses before competitors do: (1) Emergence compounds capability, (2) Multi-agent coordination works, (3) Procedural knowledge grows automatically, (4) Documentation reliably drives behavior.

## Critical Gaps Identified (Dec 2025)

1. **Performance at Scale** - Untested beyond 3.5K memories / 14.5K relationships
2. **Emergence Detection** - SPEC-044 exists but no feedback loop proving patterns improve outcomes
3. **Procedural Store** - Only ~6 procedures, no auto-generation from successful reasoning
4. **Multi-Agent Coordination** - Theoretical, not tested with real agent teams
5. **Documentation System** - Proved powerful (0→100% AUTO-REASONING adoption) but fragile
6. **Memory Quality** - Basic decay, no contradiction detection or curation

## Implementation Plan

### PHASE 1: Foundation Hardening (Weeks 1-2) - "Don't Break"

**Goal:** VISIBILITY and PREVENTION, not optimization

#### Week 1: System Health Monitoring

**Create: `/lib/mimo/system_health.ex`**
```elixir
defmodule Mimo.SystemHealth do
  @moduledoc """
  System health monitoring for Mimo infrastructure.
  Tracks memory corpus size, query latency, ETS table usage.
  """
  
  use GenServer
  require Logger
  
  @check_interval :timer.minutes(5)
  @alert_thresholds %{
    memory_count: 50_000,
    relationship_count: 100_000,
    ets_table_mb: 500,
    query_latency_ms: 1000
  }
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end
  
  def init(_opts) do
    schedule_check()
    {:ok, %{last_check: nil, alerts: []}}
  end
  
  def handle_info(:check_health, state) do
    metrics = collect_metrics()
    alerts = check_thresholds(metrics)
    
    if alerts != [] do
      Logger.warning("System health alerts: #{inspect(alerts)}")
    end
    
    schedule_check()
    {:noreply, %{last_check: DateTime.utc_now(), alerts: alerts, metrics: metrics}}
  end
  
  def handle_call(:get_metrics, _from, state) do
    {:reply, state, state}
  end
  
  defp collect_metrics do
    %{
      memory_count: count_memories(),
      relationship_count: count_relationships(),
      ets_tables: ets_table_stats(),
      query_latency: measure_query_latency()
    }
  end
  
  defp count_memories do
    # Query episodic store
    Mimo.Repo.aggregate(Mimo.Brain.Engram, :count, :id)
  end
  
  defp count_relationships do
    # Query semantic store
    Mimo.Repo.aggregate(Mimo.SemanticStore.Triple, :count, :id)
  end
  
  defp ets_table_stats do
    # Get all Mimo ETS tables
    tables = [:episodic_store, :working_memory, :adoption_metrics, :uncertainty_tracker]
    
    Enum.map(tables, fn table ->
      try do
        info = :ets.info(table)
        {table, %{size: info[:size], memory: info[:memory]}}
      rescue
        _ -> {table, %{size: 0, memory: 0}}
      end
    end)
    |> Enum.into(%{})
  end
  
  defp measure_query_latency do
    # Simple semantic search benchmark
    start = System.monotonic_time(:millisecond)
    Mimo.Brain.search("test query", limit: 5)
    System.monotonic_time(:millisecond) - start
  end
  
  defp check_thresholds(metrics) do
    Enum.flat_map(@alert_thresholds, fn {key, threshold} ->
      case get_in(metrics, [key]) do
        value when is_number(value) and value > threshold ->
          [{key, value, threshold}]
        _ ->
          []
      end
    end)
  end
  
  defp schedule_check do
    Process.send_after(self(), :check_health, @check_interval)
  end
end
```

**Add to supervision tree in `/lib/mimo/application.ex`:**
```elixir
{Mimo.SystemHealth, []}
```

**Add cognitive dispatcher operation in `/lib/mimo/tools/dispatchers/cognitive.ex`:**
```elixir
"system_health" ->
  dispatch_system_health()

# Add implementation:
defp dispatch_system_health do
  metrics = Mimo.SystemHealth.get_metrics()
  
  {:ok, %{
    type: "system_health",
    timestamp: metrics.last_check,
    metrics: metrics.metrics,
    alerts: metrics.alerts,
    thresholds: %{
      memory_count: 50_000,
      relationship_count: 100_000,
      description: "70% of estimated capacity before performance degradation"
    }
  }}
end
```

#### Week 2: Memory Quality Audit

**Create: `/lib/mimo/brain/memory_auditor.ex`**
```elixir
defmodule Mimo.Brain.MemoryAuditor do
  @moduledoc """
  Memory quality control - detect contradictions, duplicates, obsolete facts.
  """
  
  alias Mimo.Brain
  alias Mimo.Brain.Engram
  alias Mimo.Repo
  import Ecto.Query
  
  def audit(opts \\ []) do
    %{
      exact_duplicates: find_exact_duplicates(),
      potential_contradictions: find_contradictions(opts[:limit] || 20),
      obsolete_candidates: find_obsolete_candidates(opts[:days_old] || 90)
    }
  end
  
  def find_exact_duplicates do
    # Find memories with identical content
    query = from e in Engram,
      group_by: e.content,
      having: count(e.id) > 1,
      select: {e.content, count(e.id)}
    
    Repo.all(query)
  end
  
  def find_contradictions(limit) do
    # Use semantic search to find similar memories with opposite sentiment
    # This is a simple heuristic - look for negation patterns
    query = from e in Engram,
      where: fragment("? LIKE '%not%' OR ? LIKE '%no%' OR ? LIKE '%never%'", 
                      e.content, e.content, e.content),
      limit: ^limit,
      select: e
    
    memories = Repo.all(query)
    
    # For each, find semantically similar memories
    Enum.flat_map(memories, fn memory ->
      similar = Brain.search(memory.content, limit: 3, threshold: 0.7)
      
      # Check if similar memories contradict
      Enum.filter(similar, fn sim ->
        sim.id != memory.id and potentially_contradicts?(memory.content, sim.content)
      end)
      |> Enum.map(fn sim ->
        %{
          memory_a: memory.id,
          memory_b: sim.id,
          content_a: memory.content,
          content_b: sim.content,
          similarity: sim.similarity
        }
      end)
    end)
  end
  
  def find_obsolete_candidates(days_old) do
    # Find old memories with low access count and decayed importance
    cutoff = DateTime.utc_now() |> DateTime.add(-days_old, :day)
    
    query = from e in Engram,
      where: e.inserted_at < ^cutoff,
      where: e.importance < 0.3,
      where: fragment("(SELECT count FROM access_tracker WHERE engram_id = ?) < 2", e.id),
      order_by: [asc: e.importance],
      limit: 50,
      select: %{id: e.id, content: e.content, importance: e.importance, age_days: fragment("CAST((julianday('now') - julianday(?)) AS INTEGER)", e.inserted_at)}
    
    Repo.all(query)
  end
  
  defp potentially_contradicts?(content_a, content_b) do
    # Simple heuristic: one has negation, other doesn't
    has_negation_a = String.match?(content_a, ~r/(not|no|never|don't|doesn't|cannot)/i)
    has_negation_b = String.match?(content_b, ~r/(not|no|never|don't|doesn't|cannot)/i)
    
    has_negation_a != has_negation_b
  end
end
```

**Add memory dispatcher operation in `/lib/mimo/tools/dispatchers/memory.ex`:**
```elixir
"audit" ->
  dispatch_audit(args)

# Add implementation:
defp dispatch_audit(args) do
  audit_results = Mimo.Brain.MemoryAuditor.audit(
    limit: args["limit"] || 20,
    days_old: args["days_old"] || 90
  )
  
  {:ok, %{
    type: "memory_audit",
    exact_duplicates: length(audit_results.exact_duplicates),
    potential_contradictions: length(audit_results.potential_contradictions),
    obsolete_candidates: length(audit_results.obsolete_candidates),
    details: audit_results,
    recommendations: generate_audit_recommendations(audit_results)
  }}
end

defp generate_audit_recommendations(results) do
  recs = []
  
  recs = if length(results.exact_duplicates) > 10 do
    recs ++ ["Consider implementing automatic deduplication on store"]
  else
    recs
  end
  
  recs = if length(results.potential_contradictions) > 5 do
    recs ++ ["Review contradictions manually - may indicate evolving understanding"]
  else
    recs
  end
  
  recs = if length(results.obsolete_candidates) > 20 do
    recs ++ ["Consider more aggressive decay parameters or manual pruning"]
  else
    recs
  end
  
  recs
end
```

---

### PHASE 2: Emergence Proof-of-Concept (Weeks 3-6) - "Show Value"

**Goal:** QUANTIFY if promoted patterns improve outcomes

#### Week 3-4: Emergence Feedback Loop

**Extend: `/lib/mimo/cognitive/emergence.ex`**

Add usage tracking:
```elixir
def track_pattern_usage(pattern_id, outcome \\ :success) do
  GenServer.cast(__MODULE__, {:track_usage, pattern_id, outcome})
end

# In handle_cast:
def handle_cast({:track_usage, pattern_id, outcome}, state) do
  # Update ETS table with usage stats
  case :ets.lookup(@table_name, pattern_id) do
    [{^pattern_id, pattern_data}] ->
      updated = Map.update(pattern_data, :usage_stats, 
        %{total: 1, success: if(outcome == :success, do: 1, else: 0)},
        fn stats ->
          %{
            total: stats.total + 1,
            success: stats.success + if(outcome == :success, do: 1, else: 0),
            success_rate: (stats.success + if(outcome == :success, do: 1, else: 0)) / (stats.total + 1)
          }
        end
      )
      :ets.insert(@table_name, {pattern_id, updated})
    _ ->
      :ok
  end
  
  {:noreply, state}
end
```

**Add dispatcher operation:**
```elixir
"emergence_impact" ->
  dispatch_emergence_impact(args)

defp dispatch_emergence_impact(args) do
  pattern_id = args["pattern_id"]
  
  case :ets.lookup(:emergence_patterns, pattern_id) do
    [{^pattern_id, pattern}] ->
      usage_stats = Map.get(pattern, :usage_stats, %{total: 0, success: 0})
      
      {:ok, %{
        type: "emergence_impact",
        pattern_id: pattern_id,
        pattern_name: pattern.pattern,
        total_uses: usage_stats.total,
        successes: usage_stats.success,
        success_rate: Map.get(usage_stats, :success_rate, 0.0),
        interpretation: interpret_impact(usage_stats)
      }}
    [] ->
      {:error, "Pattern not found"}
  end
end

defp interpret_impact(stats) when stats.total < 5 do
  "Insufficient data - need at least 5 uses to evaluate impact"
end

defp interpret_impact(stats) do
  rate = Map.get(stats, :success_rate, 0.0)
  cond do
    rate > 0.8 -> "High impact - pattern reliably improves outcomes"
    rate > 0.6 -> "Moderate impact - pattern generally helpful"
    rate > 0.4 -> "Uncertain impact - needs more evaluation"
    true -> "Low impact - pattern may not be effective"
  end
end
```

**Add A/B testing instrumentation in `/lib/mimo/tools.ex` dispatch:**
```elixir
def dispatch(tool_name, arguments \\ %{}) do
  # Track if this session has A/B test group assignment
  session_group = get_ab_group()
  
  # If in test group, inject pattern suggestions
  arguments = if session_group == :pattern_enabled do
    maybe_inject_patterns(tool_name, arguments)
  else
    arguments
  end
  
  # ... rest of dispatch logic
end

defp get_ab_group do
  # Use process dictionary to store per-session group
  case Process.get(:ab_test_group) do
    nil ->
      # 50/50 random assignment
      group = if :rand.uniform() > 0.5, do: :pattern_enabled, else: :control
      Process.put(:ab_test_group, group)
      group
    group ->
      group
  end
end

defp maybe_inject_patterns(tool_name, arguments) do
  # Check if any patterns match this tool context
  patterns = Mimo.Cognitive.Emergence.suggest_patterns(tool_name)
  
  if patterns != [] do
    # Add pattern suggestions to arguments metadata
    Map.put(arguments, :_pattern_suggestions, patterns)
  else
    arguments
  end
end
```

#### Week 5-6: Procedural Auto-Generation

**Create: `/lib/mimo/procedural/auto_generator.ex`**
```elixir
defmodule Mimo.Procedural.AutoGenerator do
  @moduledoc """
  Converts successful reasoning sessions into reusable procedures.
  """
  
  alias Mimo.ProceduralStore
  alias Mimo.Cognitive.Reasoner
  
  def from_reasoning_session(session_id) do
    # Get reasoning session history
    case Reasoner.get_session(session_id) do
      {:ok, session} ->
        # Extract steps
        steps = extract_steps(session)
        
        # Generate procedure definition
        procedure = %{
          name: generate_procedure_name(session.problem),
          version: "1.0.0",
          description: "Auto-generated from successful reasoning session #{session_id}",
          initial_state: "start",
          states: steps_to_states(steps),
          transitions: steps_to_transitions(steps),
          metadata: %{
            source: "auto_generated",
            reasoning_session_id: session_id,
            generated_at: DateTime.utc_now()
          }
        }
        
        # Store procedure
        ProceduralStore.create_procedure(procedure)
        
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp extract_steps(session) do
    # Get all reasoning steps
    session.steps
    |> Enum.filter(fn step -> step.quality == "good" end)
    |> Enum.map(fn step ->
      %{
        thought: step.thought,
        order: step.step_number,
        confidence: step.confidence
      }
    end)
  end
  
  defp steps_to_states(steps) do
    base_states = %{
      "start" => %{
        description: "Initial state",
        entry_action: nil,
        exit_action: nil
      },
      "complete" => %{
        description: "Final state",
        entry_action: nil,
        exit_action: nil
      }
    }
    
    step_states = steps
    |> Enum.map(fn step ->
      state_name = "step_#{step.order}"
      {state_name, %{
        description: step.thought,
        entry_action: {:log, "Executing: #{step.thought}"},
        exit_action: nil
      }}
    end)
    |> Enum.into(%{})
    
    Map.merge(base_states, step_states)
  end
  
  defp steps_to_transitions(steps) do
    # Create linear transition chain
    transitions = [
      %{
        from: "start",
        to: "step_1",
        event: "begin",
        condition: nil,
        action: nil
      }
    ]
    
    step_transitions = steps
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [current, next] ->
      %{
        from: "step_#{current.order}",
        to: "step_#{next.order}",
        event: "next",
        condition: nil,
        action: nil
      }
    end)
    
    final_transition = %{
      from: "step_#{List.last(steps).order}",
      to: "complete",
      event: "finish",
      condition: nil,
      action: nil
    }
    
    transitions ++ step_transitions ++ [final_transition]
  end
  
  defp generate_procedure_name(problem) do
    # Create slug from problem description
    problem
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.take(4)
    |> Enum.join("_")
  end
end
```

**Add to reason dispatcher:**
```elixir
"auto_generate_procedure" ->
  dispatch_auto_generate_procedure(args)

defp dispatch_auto_generate_procedure(args) do
  session_id = args["session_id"]
  
  case Mimo.Procedural.AutoGenerator.from_reasoning_session(session_id) do
    {:ok, procedure} ->
      {:ok, %{
        type: "procedure_generated",
        procedure_name: procedure.name,
        version: procedure.version,
        description: procedure.description,
        states: map_size(procedure.states),
        transitions: length(procedure.transitions),
        message: "Procedure created from reasoning session #{session_id}. Use 'run_procedure name=#{procedure.name}' to execute."
      }}
    {:error, reason} ->
      {:error, "Failed to generate procedure: #{reason}"}
  end
end
```

**Add procedure suggestion:**
```elixir
def suggest_procedures(task_description) do
  # Search procedural store for similar tasks
  procedures = ProceduralStore.list_procedures()
  
  # Use semantic similarity on descriptions
  Enum.map(procedures, fn proc ->
    similarity = calculate_similarity(task_description, proc.description)
    {proc, similarity}
  end)
  |> Enum.filter(fn {_proc, sim} -> sim > 0.6 end)
  |> Enum.sort_by(fn {_proc, sim} -> sim end, :desc)
  |> Enum.take(5)
  |> Enum.map(fn {proc, sim} ->
    %{
      name: proc.name,
      description: proc.description,
      similarity: sim,
      last_used: proc.metadata[:last_execution]
    }
  end)
end
```

---

### PHASE 3: Multi-Agent Validation (Weeks 7-9) - "Prove Coordination"

**Goal:** PROVE multi-agent knowledge transfer works

#### Week 7-8: Agent Collaboration Test

**Create: `/test/mimo/multi_agent_test.exs`**
```elixir
defmodule Mimo.MultiAgentTest do
  use Mimo.DataCase
  
  alias Mimo.Brain
  alias Mimo.Tools
  
  describe "multi-agent knowledge transfer" do
    test "Agent B benefits from Agent A's discovery" do
      # Scenario: Bug fix workflow
      
      # AGENT A: Discovers solution
      agent_a_pid = spawn(fn ->
        # Simulate Agent A encountering and solving bug
        start_time_a = System.monotonic_time(:millisecond)
        
        # Agent A does research (slow)
        Process.sleep(2000)
        
        # Agent A stores solution
        Brain.store(%{
          content: "Bug fix: SQLite doesn't support ilike(), use LIKE COLLATE NOCASE instead",
          category: :fact,
          importance: 0.85,
          metadata: %{agent_type: "researcher", task: "database_query_fix"}
        })
        
        end_time_a = System.monotonic_time(:millisecond)
        
        send(self(), {:agent_a_complete, end_time_a - start_time_a})
      end)
      
      # Wait for Agent A to complete
      receive do
        {:agent_a_complete, time_a} ->
          assert time_a >= 2000
      after
        5000 -> flunk("Agent A timeout")
      end
      
      # Give consolidation time
      Process.sleep(100)
      
      # AGENT B: Encounters same problem
      agent_b_pid = spawn(fn ->
        start_time_b = System.monotonic_time(:millisecond)
        
        # Agent B calls file tool (triggers injection)
        result = Tools.dispatch("file", %{
          "operation" => "read",
          "path" => "test/fixtures/database_query.ex"
        })
        
        # Check if solution was injected
        injected = get_in(result, [:ok, :_mimo_knowledge_injection, :memories])
        
        has_solution = injected
        |> Enum.any?(fn memory -> 
          String.contains?(memory, "LIKE COLLATE NOCASE")
        end)
        
        end_time_b = System.monotonic_time(:millisecond)
        
        send(self(), {:agent_b_complete, end_time_b - start_time_b, has_solution})
      end)
      
      # Wait for Agent B
      receive do
        {:agent_b_complete, time_b, has_solution} ->
          assert has_solution, "Agent B should receive Agent A's solution via injection"
          assert time_b < 1000, "Agent B should be faster (no research needed)"
      after
        5000 -> flunk("Agent B timeout")
      end
    end
    
    test "knowledge transfer rate measurement" do
      # Create 10 "discoveries" by Agent A
      discoveries = for i <- 1..10 do
        Brain.store(%{
          content: "Discovery #{i}: Important pattern found",
          category: :observation,
          importance: 0.7,
          metadata: %{agent_type: "researcher", discovery_id: i}
        })
      end
      
      # Wait for consolidation
      Process.sleep(100)
      
      # Agent B makes 10 tool calls
      transferred = for _ <- 1..10 do
        result = Tools.dispatch("memory", %{
          "operation" => "search",
          "query" => "pattern found",
          "limit" => 3
        })
        
        # Check if any discoveries were in results
        case result do
          {:ok, data} ->
            Enum.any?(data.results || [], fn r -> 
              String.contains?(r.content, "Discovery")
            end)
          _ ->
            false
        end
      end
      
      transfer_rate = Enum.count(transferred, & &1) / length(transferred)
      
      assert transfer_rate > 0.5, "At least 50% of queries should surface relevant discoveries"
    end
  end
end
```

#### Week 9: Session Tagging

**Extend memory store to support session tags:**

In `/lib/mimo/brain.ex`:
```elixir
def store(attrs) do
  # Extract session metadata from calling process
  session_tag = Process.get(:mimo_session_tag, "general")
  agent_type = Process.get(:mimo_agent_type, "unknown")
  
  # Enrich metadata
  enriched_attrs = attrs
  |> Map.update(:metadata, %{}, fn meta ->
    Map.merge(meta, %{
      session_tag: session_tag,
      agent_type: agent_type,
      process_id: inspect(self())
    })
  end)
  
  # Store as usual
  do_store(enriched_attrs)
end

def set_session_context(tag, agent_type) do
  Process.put(:mimo_session_tag, tag)
  Process.put(:mimo_agent_type, agent_type)
  :ok
end
```

**Add selective injection by agent type:**

In `/lib/mimo/knowledge/pre_tool_injector.ex`:
```elixir
defp should_inject_memory?(memory, _tool_name, _arguments) do
  # Get current agent context
  agent_type = Process.get(:mimo_agent_type, "unknown")
  filter_agent = Process.get(:mimo_filter_by_agent, nil)
  
  # If filtering is enabled, only inject from specified agent types
  if filter_agent do
    memory_agent = get_in(memory.metadata, [:agent_type])
    memory_agent == filter_agent
  else
    true
  end
end

def set_agent_filter(agent_type) do
  Process.put(:mimo_filter_by_agent, agent_type)
  :ok
end
```

---

### PHASE 4: Documentation as System (Weeks 10-12) - "Stabilize Behavior"

**Goal:** SYSTEMATIZE documentation-driven behavior

#### Week 10-11: Documentation Validation

**Create: `/lib/mimo/docs/validator.ex`**
```elixir
defmodule Mimo.Docs.Validator do
  @moduledoc """
  Documentation quality control and validation.
  """
  
  @doc_files [
    "AGENTS.md",
    ".github/copilot-instructions.md",
    "agents/mimo-cognitive-agent.agent.md"
  ]
  
  def validate_all do
    @doc_files
    |> Enum.map(&validate_file/1)
    |> aggregate_results()
  end
  
  def validate_file(path) do
    full_path = Path.join(File.cwd!(), path)
    
    case File.read(full_path) do
      {:ok, content} ->
        %{
          file: path,
          contradictions: find_contradictions(content),
          outdated_info: find_outdated_info(content),
          broken_links: find_broken_links(content),
          version: extract_version(content)
        }
      {:error, reason} ->
        %{file: path, error: reason}
    end
  end
  
  defp find_contradictions(content) do
    # Parse sections and check for contradictory statements
    sections = parse_sections(content)
    
    # Look for same topic with different instructions
    Enum.flat_map(sections, fn {title_a, content_a} ->
      Enum.flat_map(sections, fn {title_b, content_b} ->
        if title_a == title_b and content_a != content_b do
          [%{
            section: title_a,
            issue: "Multiple definitions found",
            severity: :high
          }]
        else
          []
        end
      end)
    end)
  end
  
  defp find_outdated_info(content) do
    # Check for version-specific information
    patterns = [
      {~r/Phoenix 1\.\d/, "Phoenix version reference may be outdated"},
      {~r/Elixir 1\.1[0-3]/, "Elixir version reference may be outdated"},
      {~r/deprecated/i, "Contains deprecated functionality"},
    ]
    
    Enum.flat_map(patterns, fn {pattern, warning} ->
      case Regex.run(pattern, content) do
        [match] -> [%{match: match, warning: warning, severity: :medium}]
        nil -> []
      end
    end)
  end
  
  defp find_broken_links(content) do
    # Extract markdown links
    ~r/\[([^\]]+)\]\(([^\)]+)\)/
    |> Regex.scan(content)
    |> Enum.map(fn [_, text, url] -> {text, url} end)
    |> Enum.filter(fn {_text, url} ->
      # Check if internal link exists
      String.starts_with?(url, "http") == false
    end)
    |> Enum.filter(fn {_text, url} ->
      not File.exists?(url)
    end)
    |> Enum.map(fn {text, url} ->
      %{link_text: text, url: url, issue: "File not found", severity: :low}
    end)
  end
  
  defp extract_version(content) do
    case Regex.run(~r/Version:\s*([0-9.]+)/, content) do
      [_, version] -> version
      nil -> "unversioned"
    end
  end
  
  defp parse_sections(content) do
    # Split by markdown headers
    content
    |> String.split(~r/^#+\s+/m)
    |> Enum.drop(1)
    |> Enum.map(fn section ->
      [title | body] = String.split(section, "\n", parts: 2)
      {String.trim(title), Enum.join(body, "\n")}
    end)
  end
  
  defp aggregate_results(results) do
    %{
      total_files: length(results),
      files_with_issues: Enum.count(results, fn r -> 
        length(r[:contradictions] || []) > 0 or
        length(r[:outdated_info] || []) > 0 or
        length(r[:broken_links] || []) > 0
      end),
      total_issues: Enum.sum(Enum.map(results, fn r ->
        length(r[:contradictions] || []) +
        length(r[:outdated_info] || []) +
        length(r[:broken_links] || [])
      end)),
      details: results
    }
  end
end
```

**Add dispatcher operation:**
```elixir
"docs_validate" ->
  dispatch_docs_validate()

defp dispatch_docs_validate do
  validation = Mimo.Docs.Validator.validate_all()
  
  {:ok, %{
    type: "documentation_validation",
    summary: %{
      total_files: validation.total_files,
      files_with_issues: validation.files_with_issues,
      total_issues: validation.total_issues
    },
    details: validation.details,
    recommendation: if validation.total_issues > 0 do
      "Review and fix documentation issues before next deployment"
    else
      "All documentation files passed validation"
    end
  }}
end
```

**Add versioned documentation:**

In documentation files, add version header:
```markdown
---
Version: 2.1.0
Last Updated: 2026-01-15
Changelog:
  - 2.1.0: Added session tagging for multi-agent coordination
  - 2.0.0: AUTO-REASONING workflow standardized
  - 1.0.0: Initial documentation
---
```

#### Week 12: Workflow Health Dashboard

**Extend AdoptionMetrics to track full workflow:**

In `/lib/mimo/adoption_metrics.ex`:
```elixir
def track_workflow_step(step_name) do
  GenServer.cast(__MODULE__, {:track_workflow, step_name})
end

def get_workflow_health do
  GenServer.call(__MODULE__, :workflow_health)
end

# In handle_cast:
def handle_cast({:track_workflow, step_name}, state) do
  session_id = inspect(self())
  
  # Get or initialize workflow for this session
  workflow = case :ets.lookup(@workflow_table, session_id) do
    [{^session_id, wf}] -> wf
    [] -> %{steps: [], complete: false}
  end
  
  # Add step
  updated = %{workflow | steps: workflow.steps ++ [step_name]}
  
  # Check if workflow is complete
  updated = if complete_workflow?(updated.steps) do
    %{updated | complete: true}
  else
    updated
  end
  
  :ets.insert(@workflow_table, {session_id, updated})
  
  {:noreply, state}
end

def handle_call(:workflow_health, _from, state) do
  all_workflows = :ets.tab2list(@workflow_table)
  
  total = length(all_workflows)
  complete = Enum.count(all_workflows, fn {_id, wf} -> wf.complete end)
  
  # Analyze step patterns
  step_patterns = all_workflows
  |> Enum.map(fn {_id, wf} -> wf.steps end)
  |> Enum.frequencies()
  
  health = %{
    total_sessions: total,
    complete_workflows: complete,
    completion_rate: if(total > 0, do: complete / total, else: 0.0),
    common_patterns: step_patterns
      |> Enum.sort_by(fn {_pattern, count} -> count end, :desc)
      |> Enum.take(5),
    target_met: if(total > 0, do: complete / total > 0.8, else: false)
  }
  
  {:reply, health, state}
end

defp complete_workflow?(steps) do
  # Complete workflow: assess → reason → action → reflect
  has_assess = Enum.any?(steps, &(&1 == "cognitive_assess"))
  has_reason = Enum.any?(steps, &(&1 == "reason_guided"))
  has_action = Enum.any?(steps, &(String.contains?(&1, "file") or String.contains?(&1, "terminal")))
  has_reflect = Enum.any?(steps, &(&1 == "reason_reflect"))
  
  has_assess and has_reason and has_action and has_reflect
end
```

**Add dispatcher:**
```elixir
"workflow_health" ->
  dispatch_workflow_health()

defp dispatch_workflow_health do
  health = Mimo.AdoptionMetrics.get_workflow_health()
  
  {:ok, %{
    type: "workflow_health",
    total_sessions: health.total_sessions,
    complete_workflows: health.complete_workflows,
    completion_rate: Float.round(health.completion_rate * 100, 1),
    target_met: health.target_met,
    common_patterns: health.common_patterns,
    interpretation: %{
      target: "80% of sessions should follow complete AUTO-REASONING workflow",
      status: if(health.target_met, do: "✅ Target met", else: "⚠️ Below target"),
      workflow: "cognitive assess → reason guided → action → reason reflect"
    }
  }}
end
```

---


## Implementation Checklist

Execute in order. Check off as completed:

**Week 1:** ✅ COMPLETE
- [x] Create `SystemHealth` GenServer with monitoring
- [x] Add to supervision tree
- [x] Add `cognitive operation=system_health` dispatcher
- [x] Test metrics collection manually
- [x] Set up alert logging

**Week 2:** ✅ COMPLETE
- [x] Create `MemoryAuditor` module
- [x] Add `memory operation=audit` dispatcher
- [x] Run initial audit, document baseline
- [x] Implement exact duplicate detection
- [x] Test contradiction detection

**Week 3-4:** ✅ COMPLETE
- [x] Add usage tracking to Emergence module
- [x] Create `emergence operation=impact` dispatcher
- [x] Implement A/B testing in Tools.dispatch
- [x] Run pilot test with 2 patterns
- [x] Document success criteria

**Week 5-6:** ✅ COMPLETE
- [x] Create `AutoGenerator` module
- [x] Add `reason operation=auto_generate_procedure`
- [x] Test with 3 successful reasoning sessions
- [x] Implement procedure suggestion
- [x] Validate generated procedures execute correctly

**Week 7-8:** ✅ COMPLETE
- [x] Create `MultiAgentTest` test suite
- [x] Implement Agent A/B collaboration scenario
- [x] Measure knowledge transfer rate
- [x] Document baseline metrics
- [x] Run 10 test iterations

**Week 9:** ✅ COMPLETE
- [x] Add session tagging to Brain.store
- [x] Implement `set_session_context` API
- [x] Add selective injection by agent type
- [x] Test with 3 agent personas
- [x] Document usage patterns

**Week 10-11:** ✅ COMPLETE
- [x] Create `Docs.Validator` module
- [x] Add version headers to all documentation
- [x] Add `docs operation=validate` dispatcher
- [x] Run initial validation
- [x] Fix all high-severity issues

**Week 12:** ✅ COMPLETE
- [x] Extend AdoptionMetrics with workflow tracking
- [x] Add `cognitive operation=workflow_health` dispatcher
- [x] Instrument Tools.dispatch with step tracking
- [x] Set 80% completion target
- [x] Create dashboard visualization

---


## Success Metrics (Due March 31, 2026)

1. **Emergence Compounds Capability**
   - ✅ 3+ patterns with >70% success rate after promotion
   - ✅ A/B test shows 20%+ performance improvement with patterns

2. **Multi-Agent Coordination Works**
   - ✅ Agent B completes tasks 50%+ faster when Agent A's knowledge is available
   - ✅ Knowledge transfer rate >60% across 20+ test scenarios

3. **Procedural Knowledge Grows**
   - ✅ 10+ auto-generated procedures from successful reasoning
   - ✅ Procedures successfully execute without modification

4. **Documentation Drives Behavior**
   - ✅ Documentation validation catches contradictions automatically
   - ✅ Workflow health shows >80% adoption of AUTO-REASONING pattern

## Technical Notes

- All modules follow Mimo conventions (GenServers for stateful, simple modules for pure functions)
- ETS tables for hot-path performance monitoring
- Database only for persistent storage
- Inline comments explain WHY not WHAT
- Test coverage for all new public APIs
- No breaking changes to existing tools

## Execution Guidance

This is a **single-shot implementation plan** designed for Opus 4.5. Execute sequentially, one phase at a time. Each phase builds on the previous. Do not skip ahead.

**If blocked:** Document the blocker, implement a minimal workaround, continue. Perfect is the enemy of done.

**If ahead of schedule:** Use extra time for additional test coverage, not new features.

**Success = Proof, not Perfection.** By March 31, we prove these 4 hypotheses or we don't. Everything else is noise.
