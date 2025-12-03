# Changelog

All notable changes to Mimo-MCP Gateway will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.7.0] - 2025-12-03

**Major Release** - Tool Consolidation (Phases 1-4): Unified tools for simpler orchestration.

### Changed
- **Tool Consolidation** - Reduced from 29+ tools to 17 primary tools with 12 deprecated aliases
  - `web` - **UNIFIED** web operations (fetch, search, blink, browser, vision, sonar, extract, parse)
  - `code` - **UNIFIED** code intelligence (symbols, library_get, library_search, diagnose, check, lint, typecheck)
  - `meta` - **UNIFIED** composite operations (analyze_file, debug_error, prepare_context, suggest_next_tool)

### Deprecated
- `fetch`, `search`, `blink`, `browser`, `vision`, `sonar`, `web_extract`, `web_parse` → Use `web` instead
- `code_symbols`, `library`, `diagnostics` → Use `code` instead
- `graph` → Use `knowledge` instead

### Technical Details
- All deprecated tools continue to work (redirect to unified tools)
- Documentation updated to reflect consolidation
- 1007 tests passing, 0 failures

---

## [2.6.0] - 2025-12-01

**Major Release** - HNSW index, binary quantization, Temporal Memory Chains, and project onboarding.

### Added
- **HNSW Index (SPEC-033 Phase 3b)**
  - O(log n) approximate nearest neighbor search using USearch
  - Auto-indexing of new memories in background
  - Configurable connectivity and expansion parameters
  - Automatic strategy selection based on corpus size:
    - <500 memories: exact int8 search
    - 500-999: binary pre-filter → int8 rescore
    - ≥1000: HNSW approximate search

- **Binary Quantization (SPEC-033 Phase 3a)**
  - 32x memory reduction (256-dim → 32 bytes)
  - Ultra-fast Hamming distance pre-filtering
  - Two-stage search: binary filter → int8 rescore

- **Int8 Quantization (SPEC-031)**
  - 16x memory reduction vs float32
  - `embedding_int8` binary storage in SQLite
  - Scale/offset dequantization support

- **Temporal Memory Chains (TMC) (SPEC-034)**
  - Memory versioning with supersession tracking
  - Novelty detection for similar memories
  - Memory merging and conflict resolution
  - Chain traversal and history queries
  - Supersession types: update, correction, refinement, merge

- **Project Onboarding Tool**
  - `onboard` operation for new project setup
  - Auto-indexes code symbols, dependencies, and knowledge graph
  - Fingerprint-based caching to skip re-indexing

- **Memory Surgery & Repair**
  - `Mimo.Brain.Surgery` for memory database operations
  - `mix mimo.repair_embeddings` - fix corrupted embeddings
  - `mix mimo.truncate_embeddings` - reduce embedding dimensions
  - `mix mimo.quantize_embeddings` - convert float32 to int8
  - `mix mimo.vectorize_binary` - generate binary embeddings
  - `mix mimo.build_hnsw` - rebuild HNSW index

- **Composite Tools**
  - `analyze_file` - unified file analysis (read + symbols + diagnostics + knowledge)
  - `debug_error` - error debugging assistant (memory + symbols + diagnostics)

- **Library Fetcher Improvements**
  - `Mimo.Library.Fetchers.Common` - shared HTTP client for all fetchers
  - Improved error handling and retry logic

- **Health Monitor** (`Mimo.Brain.HealthMonitor`)
  - Memory store health checks
  - Embedding consistency validation
  - Index integrity monitoring

### Changed
- **CI Updated to Elixir 1.19 / OTP 27** (from 1.16 / OTP 26)
- Excluded HNSW NIF tests in CI (`:hnsw_nif` tag)
- Improved agent documentation for balanced tool workflow
- Enhanced cognitive agent mode with mandatory tool distribution targets

### Fixed
- Test category string/atom mismatch - Engram expects string categories
- HNSW test skip logic to use proper ExUnit patterns
- Code formatting issues for CI compliance

### Performance
- 10-20x faster memory search with binary pre-filtering
- Sub-millisecond similarity computation with Rust NIFs
- Automatic strategy selection based on corpus size:
  - Exact search for small datasets (<500)
  - Binary+rescore for medium (500-999)
  - HNSW for large (≥1000)

### Technical Details
- 125 files changed, 16,000+ insertions
- 8 new test files for new features
- 4 new database migrations
- Native HNSW Rust NIF integration

---

## [2.5.0] - 2025-11-30

**Tool Enhancements** - Comprehensive improvements to terminal, file, library, and diagnostics tools based on SPEC-026 through SPEC-029.

### Added
- **Terminal Enhancements (SPEC-026)**
  - `cwd` option - Execute commands in specified working directory
  - `env` option - Set environment variables for command execution
  - `shell` option - Shell selection (bash, sh, zsh, powershell, cmd)
  - `name` option - Named terminal sessions for background processes
  - Output truncation at 60KB (matches VS Code behavior)

- **File Enhancements (SPEC-027)**
  - `glob` operation - Pattern-based file discovery with gitignore respect
  - `multi_replace` operation - Atomic multi-file replacements with validation-first approach
  - `diff` operation - Show differences between files or proposed content
  - `respect_gitignore` option for glob/search operations
  - `exclude` patterns for glob operation

- **Library Auto-Discovery (SPEC-028)**
  - `Mimo.Library.AutoDiscovery` module for automatic dependency detection
  - `discover_and_cache/1` - Scan project and pre-cache all dependency docs
  - `detect_ecosystems/1` - Detect project type from manifest files
  - `extract_dependencies/2` - Parse mix.exs, package.json, requirements.txt, Cargo.toml
  - `Mimo.Library.ImportWatcher` for import-based library caching
  - Added `discover` operation to library tool

- **Diagnostics Tool (SPEC-029)**
  - `Mimo.Skills.Diagnostics` module for compile/lint/typecheck diagnostics
  - Multi-language support: Elixir, Python, JavaScript/TypeScript, Rust
  - Operations: `check` (compiler), `lint` (linter), `typecheck` (type checker), `all`
  - Parallel tool execution for faster results
  - Smart output parsing for each language

### Fixed
- **Multi-Replace Same-File Bug** - Fixed issue where multiple replacements on the same file would overwrite each other; now groups by file and applies sequentially
- **Shell Path Resolution** - Shell commands now use full paths (/usr/bin/bash) for reliability

### Technical Details
- 32 new tests (17 terminal + 15 file operations)
- All tests passing
- New modules: `diagnostics.ex`, `auto_discovery.ex`, `import_watcher.ex`

---

## [2.4.0] - 2025-11-28

**Cognitive Memory Systems** - Complete implementation of human-inspired memory architecture based on cognitive science research.

### Added
- **Working Memory Buffer** (`Mimo.Brain.WorkingMemory`) - ETS-backed short-term memory with configurable TTL (default 5 min)
  - `store/2` - Store items with automatic expiration
  - `get/1`, `get_recent/1` - Retrieve items by ID or recency
  - `WorkingMemoryCleaner` GenServer for automatic TTL cleanup
- **Memory Consolidation** (`Mimo.Brain.Consolidator`) - Automatic transfer from working to long-term memory
  - Importance-based consolidation threshold (default 0.7)
  - Configurable batch size and intervals
  - Telemetry integration for monitoring consolidation events
- **Forgetting & Decay System** (`Mimo.Brain.Forgetting`, `Mimo.Brain.DecayScorer`)
  - Exponential decay formula: `score = importance × e^(-λ×age_days) × (1 + log(1+access_count)×0.1)`
  - Access count boosting to preserve frequently-used memories
  - Protection flag for critical memories
  - Scheduled pruning with configurable thresholds
- **Hybrid Retrieval** (`Mimo.Brain.HybridScorer`, `Mimo.Brain.HybridRetriever`)
  - Multi-factor scoring combining semantic similarity, recency, importance, and popularity
  - Configurable weight presets: `balanced`, `semantic`, `recent`, `important`, `popular`
  - `rank/3` - Score and sort memories by combined factors
- **Memory Router** (`Mimo.Brain.MemoryRouter`) - Unified API for all memory stores
  - `query/2` - Route queries to appropriate store (working, episodic, semantic, procedural)
  - `store/2` - Intelligent storage routing based on memory type
  - `episodic/2`, `semantic/2`, `procedural/2` - Direct store access
- **Access Tracking** (`Mimo.Brain.AccessTracker`) - Track memory access patterns for decay scoring
- **Database Migration** - Added `access_count`, `last_accessed_at`, `decay_rate`, `protected` fields to engrams

### Changed
- Updated architecture diagram to show cognitive memory layer
- Enhanced `Mimo.Brain.Memory` with `hybrid_search/2` wrapper
- Added facade modules for `SemanticStore` and `ProceduralStore`
- Supervision tree now includes new GenServers: `WorkingMemoryCleaner`, `Consolidator`, `Forgetting`, `AccessTracker`
- **Promoted to Production Ready**: Semantic Store v3.0, Procedural Store, Rust NIFs, WebSocket Synapse
- Updated README.md with accurate tool counts (8 core + 4 internal = 12 total), file structure, and version references

### Technical Details
- 91 source files in lib/
- Full test suite: 652 tests, 0 failures (552 unit + 100 integration)
- Rust NIF performance: 3-7x speedup over pure Elixir for vector operations
- All new modules follow OTP patterns with proper supervision

---

## [2.3.4] - 2025-11-28

**Native Tool Consolidation** - Removed all external NPX dependencies and consolidated 37 tools into 8 powerful native Elixir tools.

### Added
- **Consolidated Native Tools** - 8 unified tools replacing 37 external NPX-based tools:
  - `file` - All file operations (read, write, ls, search, replace, move, etc.)
  - `terminal` - Command execution and process management
  - `fetch` - HTTP requests with multiple formats (text, html, json, markdown, raw)
  - `think` - Cognitive operations (thought, plan, sequential thinking)
  - `web_parse` - HTML to Markdown conversion
  - `search` - Web search via Exa AI
  - `sonar` - UI accessibility scanner (Linux native + macOS support)
  - `knowledge` - Knowledge graph operations (query, teach)
- **Linux Sonar Support** - Native Linux accessibility scanning using xdotool, wmctrl, xprop, and AT-SPI
- **Headless Server Support** - Sonar fallback showing process/session info on servers without display
- **.env Auto-Loading** - MCP wrapper now automatically loads environment variables from `.env`

### Fixed
- **Tool Registry Classification** - All 8 consolidated tools now properly classified as `mimo_core`
- **Floki HTML Parsing** - Robust error handling with fallback for edge cases
- **Telemetry Float.round** - Fixed integer-to-float conversion in telemetry handlers
- **Exile Process API** - Changed from `.stop/1` to `.kill/2` for process termination
- **Task.yield Timeout** - Added nil timeout handling in tool dispatch

### Changed
- **Zero External Dependencies** - Removed NPX requirements for desktop_commander, fetch, sequential_thinking, exa_search
- **Skill Architecture** - Tools now dispatch via operation parameter for multiple functions per tool
- **MCP Server Cleanup** - Removed dead code from mcp_server.ex (stdio handled by Stdio module)

### Removed
- External NPX skill dependencies from `priv/skills.json`
- Legacy tool definitions from `priv/skills_manifest.json`
- 29 granular tools replaced by 8 consolidated tools

---

## [2.3.3] - 2025-11-28

**VS Code MCP Integration Fix** - Resolved critical issues preventing MCP tools from being accessible in VS Code Copilot Chat.

### Fixed
- **Empty Schema Validation** - Fixed `desktop_commander_set_config_value.value` having empty schema `{}` which caused VS Code validation failure
- **Stale Tool Classification** - Updated `tool_registry.ex` to classify `http_request` instead of legacy `fetch` tool name
- **Process Hang on EOF** - Added `System.halt(0)` in stdio loop so Elixir VM exits cleanly when stdin closes, preventing tool call timeouts
- **Node Wrapper EOF Handling** - Added stdin `end` and `close` event handlers for proper process termination

### Changed
- All 50 MCP tools now accessible and working in VS Code Copilot Chat
- Tool calls complete within seconds instead of timing out

---

## [2.3.2] - 2025-11-27

**CI & Documentation Release** - CI pipeline fixes, documentation cleanup, and codebase organization.

### Fixed
- **CI Pipeline** - Fixed test database configuration using file-based SQLite instead of in-memory
- **Compiler Warnings** - Resolved 10 unused variable warnings across the codebase
- **Git Push** - Fixed rebase conflicts and pushed successfully to GitHub

### Changed
- **Documentation** - Moved 11 development/verification docs to `docs/archive/`
- **Code Quality** - Updated 8 TODOs with v3.0 Roadmap context for future tracking
- **Test Suite** - Expanded to 370 tests (all passing)
- **.gitignore** - Added `docs/` directory to prevent accidental commits of generated docs

### Removed
- Temporary debugging files (`debug_stream.py`, `extract_pdf.py`, `erl_crash.dump`)
- Obsolete documentation files from project root

---

## [2.3.1] - 2025-11-26

**Security & Stability Release** - This release addresses critical security vulnerabilities and stability issues identified during code review.

### Fixed
- **Authentication handling** - Replaced naive string comparison with constant-time token comparison for improved security
- **Command injection** - SecureExecutor now validates metacharacters and forbidden args BEFORE pattern matching
- **Path traversal** - Command parsing extracts basename to prevent `../../../bin/bash` attacks
- **Memory exhaustion** - Implemented O(1) streaming with `Repo.stream/2` and automatic TTL cleanup (30 days default, 100K limit)
- **Race conditions** - ToolRegistry uses GenServer with atomic operations to prevent TOCTOU vulnerabilities
- **Test database errors** - Fixed DBConnection ownership errors in cleanup tests by using proper Ecto Sandbox mode

### Added
- `Mimo.ToolRegistry` - Thread-safe GenServer with distributed coordination via `:pg`
- `Mimo.Skills.SecureExecutor` - Command whitelist (npx, docker, node, python), argument sanitization, environment variable filtering
- `Mimo.Skills.Validator` - JSON schema validation with dangerous pattern detection
- `Mimo.Brain.Cleanup` - Automatic memory cleanup service with configurable TTL
- `Mix.Tasks.Mimo.Keys.Generate` - CLI for secure API key generation
- `Mix.Tasks.Mimo.Keys.Verify` - CLI for API key validation
- `Mix.Tasks.Mimo.Keys.Hash` - CLI for generating key hashes for logging
- Hot reload with distributed locking (`Mimo.Skills.HotReload`)
- Security event telemetry for audit trails
- Comprehensive test suite (370 tests passing)
- README "What Works" section for transparency about production-ready vs experimental features

### Changed
- Authentication plug now uses constant-time comparison and emits telemetry events
- Memory persistence uses ACID transactions with proper error handling
- All tool operations route through `Mimo.ToolRegistry` instead of direct ETS access

### Known Issues
- Hot reload integration tests pending (unit tests pass, full integration testing recommended)
- Semantic Store remains experimental (basic implementation present)
- Procedural Store remains experimental (basic implementation present)
- WebSocket Synapse infrastructure present but not fully tested

## [2.3.0] - 2025-11-25

### Added
- Synthetic Cortex Phase 2 & 3 modules (experimental)
- Semantic Store with triple-based knowledge graph
- Procedural Store with state machine execution
- Rust NIFs for SIMD-accelerated vector operations
- WebSocket Synapse for real-time cognitive signaling
- Meta-Cognitive Router for query classification

### Changed
- Upgraded to Universal Aperture architecture
- MCP protocol v2024-11-05 compatibility for GitHub Copilot

## [2.2.0] - 2025-11-20

### Added
- Episodic memory with SQLite + Ollama embeddings
- Rate limiting (60 req/min per IP)
- API key authentication
- Tool catalog with lazy-loading

## [2.1.0] - 2025-11-15

### Added
- MCP stdio protocol support
- Claude Desktop integration
- VS Code Copilot compatibility

## [2.0.0] - 2025-11-10

### Added
- Phoenix HTTP gateway
- OpenAI-compatible API endpoints
- Basic tool execution

## [1.0.0] - 2025-11-01

### Added
- Initial release
- Basic MCP gateway functionality
