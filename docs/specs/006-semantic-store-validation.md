# SPEC-006: Semantic Store Production Validation

## Overview

**Goal**: Prove Semantic Store is production-ready through comprehensive testing and benchmarking.

**Current Status**: ⚠️ Beta (Core Ready)  
**Target Status**: ✅ Production Ready

## Production Readiness Criteria

### 1. Functional Completeness

| Feature | Required | Current | Test Coverage |
|---------|----------|---------|---------------|
| Triple CRUD | ✅ | ✅ | Needs validation |
| Graph traversal | ✅ | ✅ | Needs validation |
| Recursive CTEs | ✅ | ✅ | Needs validation |
| Entity resolution | ✅ | ✅ | Needs validation |
| Inference engine | ✅ | ✅ | Needs validation |
| Bulk ingestion | ✅ | ✅ | Needs validation |

### 2. Performance Benchmarks

| Metric | Target | Test Method |
|--------|--------|-------------|
| Triple insert | < 10ms | Benchmark 1000 inserts |
| Single lookup | < 5ms | Benchmark 1000 lookups |
| 2-hop traversal | < 50ms | Benchmark with 10K triples |
| 3-hop traversal | < 200ms | Benchmark with 10K triples |
| Bulk insert (1000) | < 5s | Benchmark batch ingestion |

### 3. Scale Testing

| Scale | Triples | Entities | Test Scenario |
|-------|---------|----------|---------------|
| Small | 1,000 | 500 | Basic operations |
| Medium | 10,000 | 2,000 | Typical usage |
| Large | 50,000 | 10,000 | Stress test |

### 4. Reliability Tests

- [ ] Concurrent read/write safety
- [ ] Transaction rollback on failure
- [ ] Recovery from corrupted state
- [ ] Memory usage under load
- [ ] No memory leaks over time

---

## Test Implementation

### Task 1: Unit Test Coverage

**File**: `test/mimo/semantic_store/repository_test.exs`

```elixir
defmodule Mimo.SemanticStore.RepositoryTest do
  use Mimo.DataCase, async: true
  alias Mimo.SemanticStore.Repository

  describe "create/1" do
    test "creates a triple with valid attributes" do
      attrs = %{
        subject_id: "user:1",
        subject_type: "user",
        predicate: "knows",
        object_id: "user:2",
        object_type: "user",
        confidence: 0.9
      }
      
      assert {:ok, triple} = Repository.create(attrs)
      assert triple.subject_id == "user:1"
      assert triple.predicate == "knows"
    end

    test "rejects invalid confidence" do
      attrs = %{
        subject_id: "a",
        predicate: "b",
        object_id: "c",
        confidence: 1.5  # Invalid
      }
      
      assert {:error, _} = Repository.create(attrs)
    end
  end

  describe "get_relationships/2" do
    test "returns all relationships for entity" do
      # Setup
      Repository.create(%{subject_id: "a", predicate: "knows", object_id: "b"})
      Repository.create(%{subject_id: "a", predicate: "likes", object_id: "c"})
      
      relationships = Repository.get_relationships("a", "entity")
      assert length(relationships) == 2
    end
  end
end
```

### Task 2: Query Engine Tests

**File**: `test/mimo/semantic_store/query_test.exs`

```elixir
defmodule Mimo.SemanticStore.QueryTest do
  use Mimo.DataCase, async: true
  alias Mimo.SemanticStore.{Repository, Query}

  describe "transitive_closure/3" do
    setup do
      # Create chain: A -> B -> C -> D
      Repository.create(%{subject_id: "A", predicate: "parent_of", object_id: "B"})
      Repository.create(%{subject_id: "B", predicate: "parent_of", object_id: "C"})
      Repository.create(%{subject_id: "C", predicate: "parent_of", object_id: "D"})
      :ok
    end

    test "finds all descendants" do
      result = Query.transitive_closure("A", "entity", "parent_of")
      
      ids = Enum.map(result, & &1.id)
      assert "B" in ids
      assert "C" in ids
      assert "D" in ids
    end

    test "respects max depth" do
      result = Query.transitive_closure("A", "entity", "parent_of", max_depth: 1)
      
      ids = Enum.map(result, & &1.id)
      assert "B" in ids
      refute "C" in ids
    end
  end

  describe "find_path/3" do
    test "finds shortest path between entities" do
      # A -> B -> C, A -> D -> C
      Repository.create(%{subject_id: "A", predicate: "links", object_id: "B"})
      Repository.create(%{subject_id: "B", predicate: "links", object_id: "C"})
      Repository.create(%{subject_id: "A", predicate: "links", object_id: "D"})
      Repository.create(%{subject_id: "D", predicate: "links", object_id: "C"})
      
      {:ok, path} = Query.find_path("A", "C")
      assert length(path) == 2  # Shortest path
    end
  end
end
```

### Task 3: Performance Benchmarks

**File**: `bench/semantic_store_bench.exs`

```elixir
defmodule SemanticStoreBench do
  alias Mimo.SemanticStore.{Repository, Query}

  def run do
    IO.puts("=== Semantic Store Benchmarks ===\n")
    
    bench_inserts()
    bench_lookups()
    bench_traversals()
    bench_scale()
  end

  defp bench_inserts do
    IO.puts("## Insert Performance")
    
    {time, _} = :timer.tc(fn ->
      for i <- 1..1000 do
        Repository.create(%{
          subject_id: "entity:#{i}",
          predicate: "relates_to",
          object_id: "entity:#{rem(i, 100)}"
        })
      end
    end)
    
    avg_ms = time / 1000 / 1000
    IO.puts("1000 inserts: #{Float.round(time/1000, 2)}ms (avg: #{Float.round(avg_ms, 3)}ms)")
    IO.puts("Target: < 10ms per insert")
    IO.puts("Status: #{if avg_ms < 10, do: "✅ PASS", else: "❌ FAIL"}\n")
  end

  defp bench_lookups do
    IO.puts("## Lookup Performance")
    
    # Ensure data exists
    for i <- 1..100 do
      Repository.create(%{subject_id: "lookup:#{i}", predicate: "test", object_id: "target"})
    end
    
    {time, _} = :timer.tc(fn ->
      for i <- 1..1000 do
        Repository.get_relationships("lookup:#{rem(i, 100)}", "entity")
      end
    end)
    
    avg_ms = time / 1000 / 1000
    IO.puts("1000 lookups: #{Float.round(time/1000, 2)}ms (avg: #{Float.round(avg_ms, 3)}ms)")
    IO.puts("Target: < 5ms per lookup")
    IO.puts("Status: #{if avg_ms < 5, do: "✅ PASS", else: "❌ FAIL"}\n")
  end

  defp bench_traversals do
    IO.puts("## Graph Traversal Performance")
    
    # Create a tree: 1 -> 10 -> 100 nodes
    for i <- 1..10 do
      Repository.create(%{subject_id: "root", predicate: "parent", object_id: "level1:#{i}"})
      for j <- 1..10 do
        Repository.create(%{subject_id: "level1:#{i}", predicate: "parent", object_id: "level2:#{i}:#{j}"})
      end
    end
    
    {time_2hop, _} = :timer.tc(fn ->
      Query.transitive_closure("root", "entity", "parent", max_depth: 2)
    end)
    
    {time_3hop, _} = :timer.tc(fn ->
      Query.transitive_closure("root", "entity", "parent", max_depth: 3)
    end)
    
    IO.puts("2-hop traversal: #{Float.round(time_2hop/1000, 2)}ms (target: < 50ms)")
    IO.puts("3-hop traversal: #{Float.round(time_3hop/1000, 2)}ms (target: < 200ms)")
    IO.puts("Status: #{if time_2hop/1000 < 50 and time_3hop/1000 < 200, do: "✅ PASS", else: "❌ FAIL"}\n")
  end

  defp bench_scale do
    IO.puts("## Scale Test (10K triples)")
    
    {insert_time, _} = :timer.tc(fn ->
      for i <- 1..10_000 do
        Repository.create(%{
          subject_id: "scale:#{rem(i, 1000)}",
          predicate: Enum.random(["knows", "likes", "works_with", "reports_to"]),
          object_id: "scale:#{rem(i + 1, 1000)}"
        })
      end
    end)
    
    IO.puts("10K inserts: #{Float.round(insert_time/1000/1000, 2)}s")
    
    {query_time, results} = :timer.tc(fn ->
      Query.transitive_closure("scale:0", "entity", "knows", max_depth: 3)
    end)
    
    IO.puts("3-hop query on 10K graph: #{Float.round(query_time/1000, 2)}ms")
    IO.puts("Results found: #{length(results)}")
    IO.puts("Status: #{if query_time/1000 < 500, do: "✅ PASS", else: "⚠️ SLOW"}\n")
  end
end

# Run with: mix run bench/semantic_store_bench.exs
SemanticStoreBench.run()
```

### Task 4: Integration Tests

**File**: `test/integration/semantic_store_integration_test.exs`

```elixir
defmodule Mimo.Integration.SemanticStoreIntegrationTest do
  use Mimo.DataCase
  
  @moduletag :integration

  alias Mimo.SemanticStore.{Repository, Query, Ingestor, InferenceEngine}

  describe "full workflow" do
    test "ingest -> query -> infer cycle" do
      # 1. Ingest facts from text
      {:ok, triples} = Ingestor.extract_and_store(
        "Alice manages Bob. Bob reports to Alice. Carol works with Bob.",
        source: "test"
      )
      
      assert length(triples) >= 2
      
      # 2. Query relationships
      alice_rels = Repository.get_relationships("alice", "person")
      assert length(alice_rels) > 0
      
      # 3. Run inference
      {:ok, inferred} = InferenceEngine.forward_chain("manages")
      
      # Should infer transitive management
      assert is_list(inferred)
    end
  end

  describe "concurrent access" do
    test "handles parallel writes safely" do
      tasks = for i <- 1..100 do
        Task.async(fn ->
          Repository.create(%{
            subject_id: "concurrent:#{i}",
            predicate: "test",
            object_id: "target:#{i}"
          })
        end)
      end
      
      results = Task.await_many(tasks, 5000)
      successes = Enum.count(results, &match?({:ok, _}, &1))
      
      assert successes == 100
    end

    test "handles parallel reads during writes" do
      # Seed data
      for i <- 1..100 do
        Repository.create(%{subject_id: "rw:#{i}", predicate: "test", object_id: "target"})
      end
      
      # Parallel reads and writes
      read_tasks = for _ <- 1..50 do
        Task.async(fn ->
          Repository.get_relationships("rw:#{:rand.uniform(100)}", "entity")
        end)
      end
      
      write_tasks = for i <- 101..150 do
        Task.async(fn ->
          Repository.create(%{subject_id: "rw:#{i}", predicate: "test", object_id: "target"})
        end)
      end
      
      # All should complete without deadlock
      Task.await_many(read_tasks ++ write_tasks, 10_000)
    end
  end
end
```

---

## Acceptance Criteria

### Must Pass for ✅ Production Ready

1. **Unit Tests**: 100% of Repository, Query, Ingestor tests pass
2. **Performance**: All benchmarks meet targets
3. **Scale**: Handles 10K triples without degradation
4. **Concurrency**: No deadlocks or race conditions
5. **Memory**: No leaks under sustained load

### Test Execution

```bash
# Run unit tests
mix test test/mimo/semantic_store/

# Run integration tests  
mix test --only integration test/integration/semantic_store_integration_test.exs

# Run benchmarks
mix run bench/semantic_store_bench.exs

# Run memory leak test (10 min)
mix run bench/semantic_store_memory_test.exs
```

---

## Agent Prompt

```markdown
# Semantic Store Validation Agent

## Mission
Implement and run all tests from SPEC-006 to prove Semantic Store is production-ready.

## Tasks
1. Create test files as specified
2. Run all tests and benchmarks
3. Fix any failures
4. Document results in VALIDATION_REPORT.md

## Success Criteria
- All unit tests pass
- All benchmarks meet targets
- No concurrency issues
- Memory stable under load

## Output
Generate validation report with:
- Test results (pass/fail)
- Benchmark numbers
- Any issues found and fixed
- Final recommendation (✅ Ready / ❌ Not Ready)
```
