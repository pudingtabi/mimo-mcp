# Changelog

All notable changes to Mimo-MCP Gateway will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **Authentication bypass** - Replaced naive string comparison with constant-time token comparison to prevent timing attacks
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
