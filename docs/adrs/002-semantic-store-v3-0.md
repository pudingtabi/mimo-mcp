# ADR 002: Semantic Store v3.0

## Status
Accepted

## Context
Episodic memory (vector similarity search) is great for fuzzy matching but lacks precision for exact relationships. We needed a way to store and query precise facts like:
- "Alice reports to Bob"
- "Project X uses Technology Y"
- "Entity A is related to Entity B"

Vector similarity cannot reliably answer questions like "Who does Alice report to?" because it matches based on semantic similarity, not exact relationships.

## Decision
Implement a **Semantic Store** using a triple-based knowledge graph stored in SQLite.

### Data Model

Triples follow the Subject-Predicate-Object (SPO) pattern:

```
Subject → Predicate → Object
Alice   → reports_to → Bob
Project → uses       → React
API     → depends_on → Database
```

### Schema

```sql
CREATE TABLE semantic_triples (
  id INTEGER PRIMARY KEY,
  subject_id TEXT NOT NULL,
  subject_type TEXT NOT NULL,
  predicate TEXT NOT NULL,
  object_id TEXT NOT NULL,
  object_type TEXT NOT NULL,
  confidence REAL DEFAULT 1.0,
  graph_id TEXT DEFAULT 'global',
  metadata TEXT,  -- JSON
  inserted_at DATETIME,
  updated_at DATETIME
);

-- Critical indexes for O(log n) queries
CREATE INDEX semantic_triples_spo_idx ON semantic_triples(subject_id, predicate, object_id);
CREATE INDEX semantic_triples_osp_idx ON semantic_triples(object_id, subject_id, predicate);
CREATE INDEX semantic_triples_predicate_idx ON semantic_triples(predicate);
```

### Query Capabilities

1. **Forward Chain**: Given subject, find all objects via predicate
2. **Backward Chain**: Given object, find all subjects via predicate
3. **Transitive Closure**: Multi-hop traversal (e.g., full reporting chain)
4. **Pattern Matching**: Find triples matching partial patterns

### Implementation

- `Mimo.SemanticStore.Triple` - Ecto schema
- `Mimo.SemanticStore.Entity` - Entity resolution
- `Mimo.SemanticStore.Query` - Query interface with SQLite CTEs
- `Mimo.SemanticStore.Repository` - CRUD operations
- `Mimo.SemanticStore.Dreamer` - Background inference
- `Mimo.SemanticStore.Observer` - Proactive context

## Consequences

### Positive
- Exact relationship queries with O(log n) performance
- Multi-hop traversal via recursive CTEs
- Clear separation from fuzzy episodic memory
- Graph visualization possible

### Negative
- Additional complexity vs simple vector store
- Requires explicit relationship extraction from text
- Schema migrations needed for new relationship types

### Risks
- SQLite may not scale beyond ~50K triples efficiently
- CTE depth limits in SQLite (default 1000)
- Memory usage for large graph traversals

## Migration Path

For scaling beyond 50K entities:
1. Export to dedicated graph database (Neo4j, DGraph)
2. Use Ecto adapter for graph DB
3. Keep SQLite for local/offline use

## Notes
- Migration: `20251126000001_create_semantic_store.exs`
- Indexes: `20251127080000_add_semantic_indexes_v3.exs`
