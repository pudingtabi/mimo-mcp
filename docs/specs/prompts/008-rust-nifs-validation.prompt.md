# Agent Prompt: SPEC-008 Rust NIFs Production Validation

## Mission
Validate Rust NIFs for SIMD vector operations. Transform status from "⚠️ Requires Build" to "✅ Production Ready" with automated builds.

## Context
- **Workspace**: `/workspace/mrc-server/mimo-mcp`
- **Spec**: `docs/specs/008-rust-nifs-validation.md`
- **Rust Code**: `native/vector_math/`
- **Elixir Interface**: `lib/mimo/vector/math.ex`

## Phase 1: Build Automation

### Task 1.1: Verify Rust NIF Builds
```bash
cd native/vector_math
cargo build --release
```

Check for:
- [ ] Compiles without errors
- [ ] Produces `.so`/`.dylib`/`.dll`

### Task 1.2: Add Mix Task for NIF Build
Create `lib/mix/tasks/nif.build.ex`:

```elixir
defmodule Mix.Tasks.Nif.Build do
  use Mix.Task
  
  @shortdoc "Build Rust NIFs"
  
  def run(_args) do
    System.cmd("cargo", ["build", "--release"], 
      cd: "native/vector_math",
      into: IO.stream(:stdio, :line)
    )
    
    # Copy to priv/native/
    copy_nif_to_priv()
  end
end
```

### Task 1.3: Add CI Build Step
Create `.github/workflows/nif-build.yml` section:

```yaml
- name: Install Rust
  uses: actions-rs/toolchain@v1
  with:
    toolchain: stable
    
- name: Build NIFs
  run: mix nif.build
```

## Phase 2: Fallback Verification

### Task 2.1: Test Elixir Fallback
Create `test/mimo/vector/fallback_test.exs`:

```elixir
# Force fallback mode
# Verify all operations work without Rust
# Compare results to ensure correctness
```

Test cases:
- [ ] `cosine_similarity/2` fallback works
- [ ] `batch_similarity/2` fallback works
- [ ] `top_k_similar/3` fallback works
- [ ] Results match Rust implementation

### Task 2.2: Auto-Detection Test
Create `test/mimo/vector/autodetect_test.exs`:

```elixir
# Test that system auto-detects NIF availability
# Falls back gracefully if not present
```

## Phase 3: Performance Benchmarking

### Task 3.1: Create Comprehensive Benchmark
Create `bench/vector_math/nif_benchmark.exs`:

```elixir
# Benchmark dimensions:
# - Vector sizes: 384, 768, 1536 (common embedding sizes)
# - Corpus sizes: 100, 1000, 10000 vectors
# - Compare: Rust NIF vs Elixir fallback

# Expected speedup: 10-40x
```

**Targets:**
- [ ] 384-dim cosine: < 1μs (NIF), < 10μs (Elixir)
- [ ] 1000 vector batch: < 1ms (NIF), < 50ms (Elixir)
- [ ] 10K top-k search: < 10ms (NIF), < 500ms (Elixir)

### Task 3.2: Memory Usage Benchmark
```elixir
# Measure memory for:
# - 10K vectors in memory
# - Batch operations
# - Ensure no memory leaks
```

## Phase 4: Correctness Testing

### Task 4.1: Numerical Accuracy Tests
Create `test/mimo/vector/accuracy_test.exs`:

```elixir
# Test edge cases:
# - Zero vectors
# - Identical vectors (similarity = 1.0)
# - Orthogonal vectors (similarity = 0.0)
# - Negative values
# - Very small/large values
# - NaN/Infinity handling
```

### Task 4.2: Cross-Platform Tests
Document and test:
- [ ] Linux x86_64
- [ ] Linux ARM64 (Apple Silicon via Rosetta)
- [ ] macOS x86_64
- [ ] macOS ARM64

## Phase 5: SIMD Verification

### Task 5.1: Verify SIMD Usage
Add to Rust code `native/vector_math/src/lib.rs`:

```rust
// Add compile-time check for SIMD
#[cfg(target_feature = "avx2")]
const SIMD_TYPE: &str = "AVX2";

#[cfg(target_feature = "neon")]
const SIMD_TYPE: &str = "NEON";

#[cfg(not(any(target_feature = "avx2", target_feature = "neon")))]
const SIMD_TYPE: &str = "Scalar";

// Expose to Elixir
#[rustler::nif]
fn simd_info() -> String {
    SIMD_TYPE.to_string()
}
```

### Task 5.2: Runtime SIMD Detection
Create `lib/mimo/vector/simd.ex`:

```elixir
def simd_type do
  case :erlang.system_info(:system_architecture) do
    arch when arch in ["x86_64-pc-linux-gnu", "x86_64-apple-darwin*"] ->
      # Check for AVX2
      :avx2
    arch when arch =~ "aarch64" ->
      :neon
    _ ->
      :scalar
  end
end
```

## Phase 6: Documentation & Validation

### Task 6.1: Build Instructions
Update `README.md` with clear build instructions:

```markdown
## Building Rust NIFs (Optional but Recommended)

### Prerequisites
- Rust 1.70+ (`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`)

### Build
\`\`\`bash
mix nif.build
\`\`\`

### Verify
\`\`\`elixir
iex> Mimo.Vector.Math.nif_loaded?()
true
iex> Mimo.Vector.Math.simd_type()
:avx2
\`\`\`
```

### Task 6.2: Generate Validation Report
Create `docs/verification/rust-nifs-validation-report.md`:

```markdown
# Rust NIFs Production Validation Report

## Build Status
- Linux x86_64: ✅
- macOS ARM64: ✅
- Windows: ⚠️ (untested)

## Performance (384-dim vectors)
| Operation | Rust NIF | Elixir | Speedup |
|-----------|----------|--------|---------|
| cosine_similarity | Xμs | Xμs | Xx |
| batch (1000) | Xms | Xms | Xx |
| top_k (10K) | Xms | Xms | Xx |

## SIMD
- AVX2: ✅ detected and used
- NEON: ✅ detected and used

## Recommendation
[READY/NOT READY] for production
```

## Execution Order

```
1. Phase 1 (Build) - Automate NIF building
2. Phase 2 (Fallback) - Verify graceful degradation
3. Phase 3 (Performance) - Benchmark speedup
4. Phase 4 (Correctness) - Verify accuracy
5. Phase 5 (SIMD) - Confirm hardware acceleration
6. Phase 6 (Documentation) - Generate report
```

## Success Criteria

All must be GREEN:
- [ ] NIF builds automatically via mix task
- [ ] Fallback works correctly without Rust
- [ ] 10x+ speedup over Elixir fallback
- [ ] All accuracy tests pass
- [ ] SIMD detection works
- [ ] Build instructions documented
- [ ] Validation report generated

## Commands

```bash
# Build NIF
mix nif.build

# Run vector tests
mix test test/mimo/vector/

# Run benchmark
mix run bench/vector_math/nif_benchmark.exs

# Check NIF status in IEx
iex -S mix
Mimo.Vector.Math.nif_loaded?()
```

## Notes for Agent

1. **Check if Rust is installed first**: `rustc --version`
2. **If NIF fails to build, focus on fallback tests**
3. **Document actual speedup numbers**
4. **Test on available platforms only**
5. **Update README.md with build status**
