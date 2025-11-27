# ADR 001: Universal Aperture Pattern

## Status
Accepted

## Context
Mimo needs to be accessible from multiple client types:
- Claude Desktop (MCP stdio protocol)
- VS Code Copilot (MCP stdio protocol)
- HTTP clients (REST API)
- LangChain/AutoGPT (OpenAI-compatible API)
- Real-time applications (WebSocket)

Each client type has different protocol requirements, authentication needs, and response format expectations.

## Decision
Implement a **Universal Aperture** architecture with protocol-specific adapters that all communicate with a shared core.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Client Layer                              │
├─────────────┬─────────────┬─────────────┬───────────────────────┤
│ Claude      │ VS Code     │ curl/HTTP   │ LangChain             │
│ Desktop     │ Copilot     │ clients     │                       │
└──────┬──────┴──────┬──────┴──────┬──────┴───────────┬───────────┘
       │ stdio       │ stdio       │ HTTP             │ HTTP
       ▼             ▼             ▼                  ▼
┌─────────────────────────────────────────────────────────────────┐
│              Universal Aperture: Protocol Adapters               │
├─────────────────────────┬───────────────────────────────────────┤
│ MCP Adapter (stdio)     │ HTTP Gateway (Phoenix)                │
│ lib/mimo/mcp_server     │ Port 4000                             │
└───────────┬─────────────┴───────────────────┬───────────────────┘
            └─────────────┬───────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Core Layer                               │
│                   (Memory, Tools, Routing)                       │
└─────────────────────────────────────────────────────────────────┘
```

### Key Principles

1. **Protocol adapters are thin** - They only translate between external protocols and internal interfaces
2. **Core is protocol-agnostic** - Business logic doesn't know about MCP, HTTP, or WebSocket
3. **Shared tool registry** - All adapters use the same ToolRegistry
4. **Unified memory access** - All adapters access the same Brain.Memory

## Consequences

### Positive
- Single codebase serves all client types
- Consistent behavior regardless of access method
- Easy to add new protocols (gRPC, etc.)
- Testing can focus on core logic

### Negative
- Protocol translation adds latency (~1-5ms)
- Error handling must map between protocol-specific codes
- Some protocol features may not map cleanly to internal representations

### Risks
- Protocol adapters could become too complex
- Feature drift between adapters
- Performance bottlenecks at adapter layer

## Notes
- MCP stdio adapter: `lib/mimo/mcp_server/stdio.ex`
- HTTP adapter: `lib/mimo_web/`
- WebSocket adapter: `lib/mimo/synapse/`
