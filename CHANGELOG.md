# Changelog

All notable changes to Mimo-MCP Gateway will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- 79 new tests (101 total, all passing)
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
