---
applyTo: "**/test/**/*.exs"
---

# Test Writing Instructions

## Test Structure

```elixir
defmodule Mimo.FeatureTest do
  use Mimo.DataCase  # NOT ExUnit.Case for DB tests

  describe "function_name/2" do
    test "succeeds with valid input" do
      assert {:ok, result} = Module.function_name(arg1, arg2)
      assert result.field == expected
    end

    test "fails with invalid input" do
      assert {:error, reason} = Module.function_name(nil, nil)
    end
  end
end
```

## Naming Conventions

- File: `test/mimo/feature_test.exs`
- Module: `Mimo.FeatureTest`
- Tests: descriptive, starts with verb

## Assertions

```elixir
assert value           # Truthy
refute value           # Falsy
assert_receive msg     # Process messages
assert_raise Error, fn -> ... end
```

## Setup

```elixir
setup do
  user = insert(:user)
  {:ok, user: user}
end

test "uses setup", %{user: user} do
  # use user
end
```
