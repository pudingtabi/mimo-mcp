## Task 1: Wire Semantic Store to QueryInterface

**Goal:** Connect the existing `Mimo.SemanticStore.Query` module to the query routing layer.

**File:** `lib/mimo/ports/query_interface.ex`

**Instructions:**
1. Find the `search_semantic/2` function that returns `%{status: "not_implemented"}`
2. Replace it with a call to `Mimo.SemanticStore.Query` functions:
   - Use `pattern_match/2` for triple pattern queries
   - Use `find_path/3` for relationship path queries  
   - Use `transitive_closure/2` for hierarchical queries
3. Add fallback to `search_episodic_fallback/2` on error
4. Return results in format: `{:ok, :semantic, %{triples: triples}}`

---

## Task 2: Wire Procedural Store to ToolInterface

**Goal:** Implement the `recall_procedure` tool using existing loader.

**File:** `lib/mimo/tool_interface.ex`

**Instructions:**
1. Find `execute("recall_procedure", %{"name" => _name})` that returns "not_implemented"
2. Extract `name` and optional `version` from args (default version: "latest")
3. Call `Mimo.ProceduralStore.Loader.load(name, version)`
4. On `{:ok, procedure}` — return success with procedure data
5. On `{:error, reason}` — return error with descriptive message
6. Preserve the existing response structure with `tool_call_id`, `status`, `data`

---

## Task 3: Wire Cortex Channel Store Integration

**Goal:** Connect semantic and procedural queries in the WebSocket channel.

**File:** `lib/mimo_web/channels/cortex_channel.ex`

**Instructions:**
1. Find handlers that return empty `[]` for semantic/procedural queries (look for TODO comments mentioning "Integrate with Semantic Store" and "Integrate with Procedural Store")
2. For semantic queries: call `Mimo.SemanticStore.Query.pattern_match/2`
3. For procedural queries: call `Mimo.ProceduralStore.Loader.load/2`
4. Format results consistently with existing channel response patterns
5. Add error handling that returns `{:error, %{reason: message}}`

---

## Task 4: Disambiguate Tool Descriptions

**Goal:** Add guidance to built-in tool descriptions to reduce agent confusion.

**File:** `lib/mimo/tools.ex`

**Instructions:**
1. Find the `@tool_definitions` list
2. Update the `fetch` tool description to:
   ```
   Advanced HTTP client supporting POST, PUT, DELETE, custom headers, timeout control, and streaming responses. For simple GET-only requests, external fetch_* tools may be simpler.
   ```
3. Update the `terminal` tool description to:
   ```
   Execute sandboxed single commands with security allowlist. For interactive sessions with process management and pid tracking, use desktop_commander_* tools.
   ```
4. Update `consult_graph` description to clarify it queries the semantic knowledge graph for entity relationships
5. Ensure each built-in tool description mentions when an external alternative might be preferred

---

## Task 5: Replace Observability Proxy with Real Metrics

**Goal:** Use actual telemetry p99 instead of BEAM scheduler proxy.

**File:** `lib/mimo/skill_backpressure.ex`

**Instructions:**
1. Find the latency check that uses BEAM scheduler run queue as proxy (look for TODO about "actual p99 tracking")
2. Replace with call to `:telemetry.execute/3` or query from `TelemetryMetricsPrometheus` if available
3. If telemetry metrics aren't being collected, add a simple ETS-based sliding window for p99 calculation:
   - Store last 100 request latencies
   - Calculate 99th percentile on demand
4. Keep the scheduler check as a secondary signal for overall system load

---

## Execution Order

1. **Task 2** (Procedural Store) — Smallest change, isolated, easy to verify
2. **Task 1** (Semantic Store) — Similar pattern, slightly more complex query routing
3. **Task 3** (Cortex Channel) — Depends on Tasks 1 & 2 being done first
4. **Task 4** (Tool Descriptions) — No dependencies, can be done in parallel
5. **Task 5** (Observability) — Lowest priority, independent of others
