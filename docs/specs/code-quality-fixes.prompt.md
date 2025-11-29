# Code Quality Fixes - Agent Prompts

✅ **STATUS: ALL FIXES COMPLETED** (2025-11-28)

Based on verification of the Code Quality & Inconsistency Report. These prompts are ordered by priority.

---

## Prompt 1: Fix verify.sh Broken Reference (P0)

**Effort:** 5 min | **Risk:** None

Fix broken module reference in verify.sh

**File:** `/workspace/mrc-server/mimo-mcp/verify.sh`

**Problem:** Line 67 references `Mimo.Registry.list_all_tools()` but this module doesn't exist. The correct module is `Mimo.ToolRegistry`.

**Fix:** Change `Mimo.Registry.list_all_tools()` to `Mimo.ToolRegistry.list_all_tools()`

**Verification:** 
```bash
mix run -e 'Mimo.ToolRegistry.list_all_tools() |> length() |> IO.puts()'
```
Should print a number without errors.

---

## Prompt 2: Fix Security Policy Env Var Mismatch (P1)

**Effort:** 10 min | **Risk:** Low | **Impact:** Fixes silent config failures

Sync allowed environment variables between Validator and SecureExecutor

**Problem:** `Mimo.Skills.Validator` allows interpolation of `MEMORY_PATH`, `DATA_DIR`, `CONFIG_DIR` but `Mimo.Skills.SecureExecutor` doesn't have these in its allowlist. This causes silent failures where `${MEMORY_PATH}` gets replaced with empty string.

**File:** `/workspace/mrc-server/mimo-mcp/lib/mimo/skills/secure_executor.ex`

**Current `@allowed_env_vars` (around line 77):**
```elixir
@allowed_env_vars ~w(
  EXA_API_KEY
  GITHUB_TOKEN
  ANTHROPIC_API_KEY
  OPENAI_API_KEY
  GEMINI_API_KEY
  BRAVE_API_KEY
  TAVILY_API_KEY
  HOME
  PATH
  NODE_PATH
  PYTHONPATH
)
```

**Add these three missing vars to match Validator:**
- `MEMORY_PATH`
- `DATA_DIR`
- `CONFIG_DIR`

**Verification:**
1. Ensure the list matches `@allowed_interpolation_vars` in `lib/mimo/skills/validator.ex`
2. Run tests:
```bash
mix test test/mimo/skills/secure_executor_test.exs
```
All tests should pass.

---

## Prompt 3: Secure the spawn_legacy Fallback (P2)

**Effort:** 30 min | **Risk:** Medium | **Impact:** Closes security hole

Remove or secure the insecure spawn_legacy fallback in ProcessManager

**File:** `/workspace/mrc-server/mimo-mcp/lib/mimo/skills/process_manager.ex`

**Problem:** When `SecureExecutor.execute_skill/1` rejects a config, `spawn_secure/1` falls back to `spawn_legacy/1` which has NO security validation — it accepts any command and interpolates any environment variable without filtering.

**Current flow (lines 53-67):**
```elixir
def spawn_secure(config) do
  case SecureExecutor.execute_skill(config) do
    {:ok, port} -> {:ok, port}
    {:error, reason} ->
      Logger.warning("SecureExecutor rejected config: #{inspect(reason)}, falling back")
      spawn_legacy(config)  # DANGEROUS: bypasses all security!
  end
end
```

### Option A (Recommended): Remove fallback entirely

Change `spawn_secure` to just return the error instead of falling back:

```elixir
def spawn_secure(config) do
  SecureExecutor.execute_skill(config)
end
```

### Option B: Make fallback also validate

If fallback is needed for legitimate reasons, it should at minimum check the command allowlist:

```elixir
def spawn_legacy(%{"command" => cmd} = config) do
  allowed = ~w(npx docker node python python3)
  if Path.basename(cmd) in allowed do
    # existing spawn logic
  else
    {:error, {:command_not_allowed, cmd}}
  end
end
```

**Verification:**
1. Run tests:
```bash
mix test test/mimo/skills/process_manager_test.exs
mix test test/mimo/skills/secure_executor_test.exs
```
2. Verify that a config with `"command" => "bash"` is rejected and does NOT spawn a process.

---

## Prompt 4: Clean Up Fallback Wrapper (P3)

**Effort:** 15 min | **Risk:** Low | **Impact:** Removes misleading dead code

Remove misleading McpServer.Fallback module

**Files:**
- `/workspace/mrc-server/mimo-mcp/lib/mimo/mcp_server/fallback.ex` (delete)
- `/workspace/mrc-server/mimo-mcp/lib/mimo/application.ex` (update)

**Problem:** `Mimo.McpServer.Fallback` claims to be a fallback but just calls `Mimo.McpServer.start_link` — it provides no actual fallback behavior.

**Current fallback.ex:**
```elixir
def start_link(opts) do
  _port = Keyword.get(opts, :port, 9000)
  Logger.info("Starting fallback MCP server (stdio mode)")
  Mimo.McpServer.start_link(opts)  # Just calls the same thing!
end
```

### Steps

1. **Delete** `lib/mimo/mcp_server/fallback.ex`

2. **Update** `lib/mimo/application.ex`:
   - Remove the `start_fallback_server/2` function entirely
   - Simplify `start_mcp_server/1` to just log errors (let supervisor handle restarts)

**Updated `start_mcp_server/1`:**
```elixir
defp start_mcp_server(sup) do
  port = mcp_port()
  child_spec = %{
    id: Mimo.McpServer,
    start: {Mimo.McpServer, :start_link, [[port: port]]},
    restart: :permanent
  }

  case Supervisor.start_child(sup, child_spec) do
    {:ok, _pid} ->
      Logger.info("✅ MCP Server started")
    {:error, reason} ->
      Logger.error("❌ MCP Server failed to start: #{inspect(reason)}")
  end
end
```

**Verification:**
```bash
mix compile  # No warnings about missing module
mix test     # All tests pass
```
Start server and verify MCP still works.

---

## Prompt 5: Create SecurityPolicy Module (P4 - Future)

**Effort:** 1 hr | **Risk:** Low | **Impact:** Proper refactor, single source of truth

Consolidate security constants into `Mimo.Skills.SecurityPolicy` module

**Goal:** Single source of truth for security rules used by both Validator and SecureExecutor.

**Create new file:** `/workspace/mrc-server/mimo-mcp/lib/mimo/skills/security_policy.ex`

```elixir
defmodule Mimo.Skills.SecurityPolicy do
  @moduledoc """
  Single source of truth for skill execution security policies.
  Used by Validator (pre-validation) and SecureExecutor (runtime).
  """

  @allowed_commands ~w(npx docker node python python3)

  @allowed_env_vars ~w(
    EXA_API_KEY GITHUB_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY
    GEMINI_API_KEY BRAVE_API_KEY TAVILY_API_KEY
    HOME PATH NODE_PATH PYTHONPATH
    MEMORY_PATH DATA_DIR CONFIG_DIR
  )

  @dangerous_patterns [
    ~r/[;&|`$(){}!<>\\]/,  # Shell metacharacters
    ~r/\.\.\//,            # Path traversal
    ~r/^\/etc\//,          # System config
    ~r/--privileged/,      # Docker privileged
    ~r/--network=host/     # Docker host network
  ]

  def allowed_commands, do: @allowed_commands
  def allowed_env_vars, do: @allowed_env_vars
  def dangerous_patterns, do: @dangerous_patterns

  def command_allowed?(cmd), do: Path.basename(cmd) in @allowed_commands
  def env_var_allowed?(var), do: var in @allowed_env_vars
  
  def pattern_safe?(arg) do
    not Enum.any?(@dangerous_patterns, &Regex.match?(&1, arg))
  end
end
```

**Then update:**

1. `lib/mimo/skills/validator.ex` — Replace `@allowed_commands`, `@allowed_interpolation_vars`, `@dangerous_patterns` with calls to `SecurityPolicy`

2. `lib/mimo/skills/secure_executor.ex` — Replace `@allowed_commands`, `@allowed_env_vars`, `@shell_metacharacters` with calls to `SecurityPolicy`

**Verification:**
```bash
mix compile                                      # No warnings
mix test test/mimo/skills/validator_test.exs     # All pass
mix test test/mimo/skills/secure_executor_test.exs  # All pass
```
Verify both modules reject the same inputs.

---

## Execution Order

| Order | Prompt | Effort | Blocks |
|-------|--------|--------|--------|
| 1 | Prompt 1 (verify.sh) | 5 min | Nothing |
| 2 | Prompt 2 (env vars) | 10 min | Nothing |
| 3 | Prompt 3 (spawn_legacy) | 30 min | Nothing |
| 4 | Prompt 4 (fallback.ex) | 15 min | Nothing |
| 5 | Prompt 5 (SecurityPolicy) | 1 hr | Optional, can defer |

**Total time for P0-P3:** ~1 hour
**Total time including P4:** ~2 hours

---

## Summary

| Finding | Verified | Action | Priority | Status |
|---------|----------|--------|----------|--------|
| Dead `Mimo.Registry` reference | ✅ File doesn't exist, verify.sh broken | Fix verify.sh | P0 | ✅ Done |
| Security env var mismatch | ✅ Real bug, silent failures | Add 3 vars to SecureExecutor | P1 | ✅ Done |
| Insecure spawn_legacy fallback | ✅ Bypasses all security | Remove or secure | P2 | ✅ Done |
| Misleading fallback.ex | ✅ Does nothing different | Delete | P3 | ✅ Done |
| SecurityPolicy consolidation | Refactor for maintainability | Create shared module | P4 | ✅ Done |
| Inconsistent data patterns | ✅ Real but not blocking | Defer to post-v3.0 | P5 | Deferred |

## Test Results

- **SecureExecutor tests:** 19/19 passed ✅
- **ProcessManager tests:** 19/19 passed ✅
- **Validator tests:** 36/36 passed ✅
- **All skills tests:** 91/91 passed ✅
- **ToolRegistry.list_all_tools():** 42 tools ✅

## Files Changed

| File | Change |
|------|--------|
| `verify.sh#67` | Fixed module reference |
| `secure_executor.ex#77-91` | Added missing env vars |
| `process_manager.ex#53-93` | Secured spawn_legacy, removed dangerous fallback |
| `application.ex#80-96` | Removed fallback server logic |
| `fallback.ex` | **Deleted** |
| `security_policy.ex` | **Created** - centralized security policy module |
