# ADR 003: Why SQLite for Local-First

## Status
Accepted

## Context
Mimo needs persistent storage for:
- Episodic memories (vector embeddings)
- Semantic triples (knowledge graph)
- Procedural definitions (state machines)

Options considered:
1. PostgreSQL - Full-featured but requires external service
2. SQLite - Embedded, zero-config, portable
3. Mnesia - Built into Erlang but complex clustering
4. ETS/DETS - Fast but limited query capabilities

## Decision
Use **SQLite via Ecto** for all persistent storage.

### Rationale

1. **Zero Configuration**
   - No database server to install
   - Works immediately after `mix deps.get`
   - Database file is portable

2. **Local-First Architecture**
   - Works offline by default
   - No network latency for queries
   - Full ACID compliance

3. **Developer Experience**
   - Single file to backup/restore
   - Easy to inspect with standard tools
   - Familiar SQL interface

4. **Ecto Integration**
   - Full migration support
   - Query composition
   - Transaction handling
   - Schema validation

### Configuration

```elixir
# config/config.exs
config :mimo_mcp, Mimo.Repo,
  database: "priv/mimo_mcp.db",
  pool_size: 10

# For vector storage (embeddings are stored as JSON arrays)
config :mimo_mcp, :embedding_dim, 768
```

### Limitations Accepted

1. **Single-Node Only** - SQLite doesn't support distributed writes
2. **Concurrent Writes** - Limited to one writer at a time (WAL mode helps)
3. **Large Datasets** - Performance degrades beyond ~1M rows per table

### Migration Path

When scaling beyond SQLite capabilities:
1. Use PostgreSQL with pgvector for production
2. Keep SQLite for development/testing
3. Ecto makes adapter switching straightforward

## Consequences

### Positive
- Instant setup for new developers
- Works in CI without services
- Portable database file
- Strong consistency guarantees

### Negative
- No horizontal scaling
- Limited concurrent write throughput
- No built-in vector search (pure Elixir fallback)

### Risks
- Large embeddings increase database size
- WAL file growth under high write load
- VACUUM needed periodically

## Notes
- Vector similarity is computed in-memory (streamed from DB)
- Rust NIFs provide SIMD acceleration for similarity calculations
- Consider pgvector migration for production deployments > 100K memories
