---
applyTo: "**/*.ex,**/*.exs"
---

# Elixir Development Instructions

## Code Style

- Use pattern matching over conditionals
- Prefer `with` for happy path, handle errors explicitly
- Use `|>` pipelines for data transformations
- Document public functions with `@doc` and `@spec`

## Error Handling

```elixir
# Return tuples, pattern match at call site
{:ok, result} | {:error, reason}

# Use with for multi-step operations
with {:ok, a} <- step_one(),
     {:ok, b} <- step_two(a) do
  {:ok, b}
end
```

## Testing

- Tests mirror `lib/` structure under `test/`
- Use `Mimo.DataCase` for DB tests
- Name test files `*_test.exs`

## Module Organization

- Main modules: `lib/mimo/<feature>.ex`
- Sub-modules: `lib/mimo/<feature>/<component>.ex`
- Skills (tools): `lib/mimo/skills/<skill>.ex`

## Commands

```bash
mix test                    # Run tests
mix test path/to_test.exs   # Specific test
mix credo                   # Code quality
mix format                  # Format code
```
