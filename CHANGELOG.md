# Changelog

All notable changes to Mimo-MCP Gateway will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.10.0] - 2026-01-11

### Fixed

- **Memory Time Filter** - Time filtering now works correctly for all queries
  - Root cause: time_filter was applied POST-retrieval after HybridRetriever's internal limits
  - Fix: Pushed time filter INTO HybridRetriever pipeline, applied before scoring/limiting
  - Added `from_date`/`to_date` options to HybridRetriever.search()
  - Added `apply_time_filter/3` helper for NaiveDateTime/DateTime comparison
  - Increased search limit 5x when time filter is active to ensure enough candidates

- **Memory List Sort Order** - `sort=recent` now correctly returns newest first
  - Fixed `order_by: [desc: e.id]` in list query

### Added

- **LLM-Enhanced Query Understanding** (Phase 1b P1)
  - New `analyze_with_llm/1` in MemoryRouter for intelligent query parsing
  - Extracts: query_type, intent, time_context, entities, confidence
  - Falls back to keyword-based analysis if LLM unavailable or fails
  - New `:aggregation` route for count/stats queries
  - Added `aggregation_route/2` for queries like "how many memories"

### Changed

- **Security** - Added `priv/db_maintenance.json` to .gitignore (user-specific timestamps)
- **Documentation** - Updated README.md for public release

## [2.9.0] - 2026-01-07

**Major Release** - Phase 3-6 Complete: Learning Loop + True Emergence + Evolution + Self-Directed Learning

### Added

- **ARCHITECTURE.md** - Canonical documentation for Tools vs Skills distinction
  - Tools = MCP-exposed interfaces (14 core tools)
  - Skills = Elixir implementation modules (lib/mimo/skills/*.ex)
  - Dispatchers = Routing logic (lib/mimo/tools/dispatchers/*.ex)
  - Clear layered architecture diagram
  - Human memory model comparison (65-70% toward vision)

- **Phase 6 S1: Learning Objective Generator**
  - New `Mimo.Cognitive.LearningObjectives` GenServer for proactive goal setting
  - Added to supervision tree for automatic startup
  - `generate/0` creates objectives from calibration, meta-learning, evolution, and error data
  - `prioritized/0` sorts objectives by urgency and impact
  - `mark_addressed/1` and `current_focus/0` for tracking
  - Four objective types: calibration, strategy, knowledge, skill_gap

- **Phase 6 S2: Autonomous Learning Executor**
  - New `Mimo.Cognitive.LearningExecutor` GenServer for autonomous learning
  - Checks for learning opportunities every 5 minutes
  - Executes up to 3 actions per cycle (research, synthesis, consolidation, practice)
  - Cooldown management prevents action spam
  - `execute_now/0`, `pause/0`, `resume/0` for control

- **Phase 6 S3: Learning Progress Tracker**
  - New `Mimo.Cognitive.LearningProgress` module for effectiveness tracking
  - `summary/0` provides overall learning health status
  - `detailed_metrics/0` shows execution stats and type distribution
  - `stuck_objectives/0` identifies objectives active > 1 hour
  - `strategy_recommendations/0` suggests improvements
  - `learning_velocity/0` tracks learning rate over time

- **Phase 5 C1: Autonomous Health Monitoring**
  - New `Mimo.Cognitive.HealthWatcher` GenServer for proactive monitoring
  - Added to supervision tree for automatic startup
  - 5-minute health check intervals via `@check_interval_ms`
  - 12-check history window for trend analysis (1 hour)
  - Detects degradation (20% drop) and critical issues (40% drop)
  - Auto-triggers SafeHealer interventions on critical drop
  - APIs: `status/0`, `history/0`, `alerts/0`, `check_now/0`

- **Phase 5 C2: Self-Healing Patterns**
  - New `Mimo.Cognitive.SafeHealer` module for autonomous healing
  - Catalog of 6 healing actions with risk levels (low/medium)
  - Condition-based triggers (cache bloated, breakers tripped, etc.)
  - Cooldown management prevents healing storms
  - `diagnose/0` - Analyzes current state, recommends actions
  - `heal/1` - Executes specific healing action
  - `auto_heal/0` - Runs all low-risk interventions automatically
  - Available actions: cache clearing, circuit breaker reset, maintenance cycles

- **Phase 5 C3: Evolution Metrics Dashboard**
  - New `Mimo.Cognitive.EvolutionDashboard` for unified metrics
  - `snapshot/0` - Complete cognitive evolution report
  - `memory_evolution/0` - Memory stats, growth, quality
  - `learning_evolution/0` - Strategy effectiveness, calibration
  - `emergence_evolution/0` - Pattern detection and promotion metrics
  - `health_evolution/0` - System stability and uptime
  - `evolution_score/0` - Single 0-1 score with level interpretation
  - Evolution levels: initializing → nascent → developing → learning → evolved → transcendent

- **Phase 3 L5: Confidence Calibration (SPEC-074 extension)**
  - New `@calibration_table` ETS in FeedbackLoop for tracking predicted vs actual confidence
  - `get_calibration/1` returns calibration factor, per-bucket analysis, and recommendations
  - `calibrated_confidence/2` applies calibration to raw confidence scores (clamps to [0,1])
  - `calibration_warnings/0` surfaces categories with significant miscalibration
  - Per-bucket tracking divides [0,1] into 10 buckets for granular calibration
  - Calibration factors: < 1.0 = overconfident, > 1.0 = underconfident

- **Phase 3 L6: Meta-Learning**
  - New `Mimo.Cognitive.MetaLearner` module for learning about learning
  - `analyze_strategy_effectiveness/0` - Compares all learning strategies
  - `recommend_parameter_adjustments/0` - Suggests parameter changes based on data
  - `detect_meta_patterns/0` - Finds patterns in how patterns emerge
  - `meta_insights/0` - Synthesizes high-level learning insights
  - Added `Pattern.stats/0` and `Promoter.stats/0` for meta-learning data
  - Added `Detector.available_modes/0` for mode enumeration

- **Calibration Integration**
  - MetaCognitiveRouter.classify/1 now applies calibration before returning
  - Response includes both `confidence` (calibrated) and `raw_confidence`
  - record_outcome passes predicted_confidence for tracking
  - SystemHealth.quality_metrics/0 includes calibration summary and warnings

- **Phase 4 E1: LLM-Enhanced Pattern Detection (SPEC-044)**
  - New `:semantic_clustering` detection mode in Detector
  - Uses LLM embeddings for semantic similarity instead of string matching
  - Clusters interactions by meaning using cosine similarity (threshold: 0.85)
  - Batch embedding via `LLM.get_embeddings/1` for efficiency
  - Greedy clustering algorithm with centroid computation

- **Phase 4 E2: Promoter→Skill Bridge**
  - Promoted patterns now actually register as callable procedures
  - `:workflow` patterns → Procedural store registration
  - `:skill` patterns → Procedure registration with tool chain
  - Patterns become callable via `orchestrate operation=run_procedure name="..."`
  - Returns `callable_as` field showing how to invoke the promoted pattern

- **Phase 4 E3: Cross-Session Pattern Tracking**
  - New `:cross_session` detection mode in Detector
  - Detects patterns that persist across multiple sessions
  - N-gram analysis (2-gram and 3-gram) for tool sequences
  - Session derivation from timestamps when session_id not available
  - Patterns marked with `cross_session: true` metadata

### Technical Details
- Emergence moves from GROUP BY counting to semantic understanding
- Promoted patterns are now genuinely callable, not just stored
- Cross-session patterns weighted higher for promotion (more reliable)
- All new detection modes integrate with existing Scheduler

### Fixed
- **Critical: Dispatcher return type mismatches in cognitive.ex**
  - `dispatch_health_status` accessed non-existent map keys (`.status`, `.score`, `.trend`)
  - `dispatch_health_check_now` expected `{:ok, result}` but module returns map directly
  - `dispatch_heal_auto` expected `{:ok, result}` but module returns map directly
  - `dispatch_learning_objectives_generate` expected tuple but module returns list directly

- **Critical: ETS table crash on GenServer restart (LearningObjectives)**
  - `init/1` called `:ets.new` without checking if table exists
  - Added `:ets.whereis` check to prevent `badarg` crash on GenServer restart

- **Critical: Deadlock between HealthWatcher and SafeHealer**
  - `HealthWatcher.handle_info` → `SafeHealer.auto_heal()` → `HealthWatcher.alerts()` caused deadlock
  - Wrapped intervention execution in `Task.start` to prevent GenServer self-blocking

- **Bug: Catalog evolution field type mismatch**
  - `catalog.ex` accessed `pattern.evolution["key"]` but evolution is a list, not a map
  - Changed to use `metadata` field which is the correct map type

- **Compiler Warnings (Clean Build)**
  - Fixed unused variable `context` in `confidence_estimator.ex:406`
  - Fixed unused variable `trend` in `meta_learner.ex:158`
  - Fixed variable shadowing for `insights` in `meta_learner.ex:331,362` (was also a logic bug)
  - Removed unused `@calibration_decay_factor` module attribute in `feedback_loop.ex`
  - Fixed emit_telemetry/4 unused default parameter in `meta_cognitive_router.ex`
  - Fixed run_stage/1 clause grouping in `sleep_cycle.ex:423` (moved catch-all to proper location)
  - Fixed distinct type comparison warning in `meta_learner.ex:121` (emergence_data != %{})
  - Commented out preserved decay functions in `background_cognition.ex` (Elixir 1.19 @compile issue)

- **Defensive: Pattern match in emergence dispatcher**
  - Changed `{:ok, result} = Emergence.detect_patterns(opts)` to proper case statement
  - Handles potential {:error, reason} return gracefully

- **ETS Table Restart Crash Prevention (4 additional modules)**
  - `gateway/session.ex`: Agent init now checks `:ets.whereis` before creating table
  - `knowledge/refresher.ex`: GenServer init now checks `:ets.whereis` before creating table
  - `cognitive/feedback_bridge.ex`: GenServer init now checks `:ets.whereis` before creating table
  - `cognitive/feedback_loop.ex`: GenServer init now checks `:ets.whereis` for all 3 tables

### Tests Added
- `test/mimo/cognitive/health_watcher_test.exs` - 11 tests for Phase 5 C1
- `test/mimo/cognitive/safe_healer_test.exs` - 15 tests for Phase 5 C2
- `test/mimo/cognitive/learning_objectives_test.exs` - 10 tests for Phase 6 S1
- `test/mimo/cognitive/learning_executor_test.exs` - 10 tests for Phase 6 S2
- `test/mimo/cognitive/learning_progress_test.exs` - 14 tests for Phase 6 S3

---

## [2.8.0] - 2026-01-06

**Major Release** - Phase 3 Learning Loop: Closed-loop cognitive learning system.

### Added
- **Phase 3 L2: Router Adjustment**
  - MetaCognitiveRouter now applies feedback-based boosts to classification
  - `get_feedback_boosts/0` queries FeedbackLoop for accuracy data
  - Boost weights configurable via `@feedback_boost_weight` (default 0.2)
  - Results include `feedback_boosts` field showing adjustments applied

- **Phase 3 L3: Experience Integration**
  - `FeedbackLoop.tool_execution_stats/1` for tool-specific success rates
  - `ToolInterface.add_experience_context/2` enriches results with historical data
  - Results include `_experience_context` when ≥5 past executions exist
  - Trend calculation (improving/stable/declining) included

- **Phase 3 L4: Tool Selection Learning**
  - `SuggestNextTool` enhanced with experience-based insights
  - `get_tool_experience_insight/2` queries historical success rates
  - Returns confidence levels and alternative recommendations
  - Low success tools (<60%) trigger alternative suggestions

- **Phase 3 L5: Confidence Calibration**
  - `ConfidenceEstimator.apply_calibration/2` uses FeedbackLoop data
  - Historical accuracy adjusts confidence scores
  - Overconfident predictions get reduced scores
  - Accurate predictions get slight boost

- **Phase 3 L6: Meta-Learning**
  - `FeedbackLoop.learning_effectiveness/0` for introspection
  - Reports prediction, classification, and tool learning effectiveness
  - Computes overall learning health (excellent/healthy/needs_attention/struggling)
  - Generates actionable recommendations based on patterns

### Technical Details
- FeedbackLoop (SPEC-074) now actively applies learning to behavior
- First closed-loop learning system in Mimo
- All learning is self-adjusting based on actual outcomes
- Memory integration persists learning across sessions

---

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
