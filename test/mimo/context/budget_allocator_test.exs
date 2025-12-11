defmodule Mimo.Context.BudgetAllocatorTest do
  use ExUnit.Case, async: true

  alias Mimo.Context.BudgetAllocator

  describe "allocate/2" do
    test "allocates budgets for small models" do
      budget = BudgetAllocator.allocate(:small, 2000)

      assert budget.tier1 == 100  # 5%
      assert budget.tier2 == 300  # 15%
      assert budget.tier3 == 1600 # 80%
      assert budget.total == 2000
    end

    test "allocates budgets for medium models" do
      budget = BudgetAllocator.allocate(:medium, 8000)

      assert budget.tier1 == 640   # 8%
      assert budget.tier2 == 1600  # 20%
      assert budget.tier3 == 5760  # 72%
      assert budget.total == 8000
    end

    test "allocates budgets for large models" do
      budget = BudgetAllocator.allocate(:large, 40000)

      assert budget.tier1 == 4000   # 10%
      assert budget.tier2 == 10000  # 25%
      assert budget.tier3 == 26000  # 65%
      assert budget.total == 40000
    end

    test "accepts model name strings" do
      budget_haiku = BudgetAllocator.allocate("haiku", 2000)
      budget_opus = BudgetAllocator.allocate("opus", 8000)
      budget_gpt4 = BudgetAllocator.allocate("gpt-4-turbo-128k", 40000)

      # Haiku is small
      assert budget_haiku.tier1 == 100

      # Opus is medium
      assert budget_opus.tier1 == 640

      # GPT-4-turbo-128k is large
      assert budget_gpt4.tier1 == 4000
    end

    test "uses default max_tokens when not provided" do
      budget = BudgetAllocator.allocate(:small)

      assert budget.total == 2000  # Default for small
      assert budget.tier1 == 100
    end

    test "normalizes model name strings" do
      # Test various formats are normalized
      assert BudgetAllocator.model_type("haiku") == :small
      assert BudgetAllocator.model_type("HAIKU") == :small
      assert BudgetAllocator.model_type("claude-3-haiku") == :small
      assert BudgetAllocator.model_type("claude_3_haiku") == :small
    end

    test "unknown model defaults to medium" do
      budget = BudgetAllocator.allocate("unknown-model", 8000)

      # Should use medium percentages
      assert budget.tier1 == 640
    end
  end

  describe "model_type/1" do
    test "returns correct type for known models" do
      assert BudgetAllocator.model_type("haiku") == :small
      assert BudgetAllocator.model_type("gpt-4-mini") == :small
      assert BudgetAllocator.model_type("gemini-flash") == :small

      assert BudgetAllocator.model_type("opus") == :medium
      assert BudgetAllocator.model_type("sonnet") == :medium
      assert BudgetAllocator.model_type("gpt-4") == :medium

      assert BudgetAllocator.model_type("claude-3-opus") == :large
      assert BudgetAllocator.model_type("gpt-4-turbo-128k") == :large
    end

    test "accepts atoms" do
      assert BudgetAllocator.model_type(:small) == :small
      assert BudgetAllocator.model_type(:medium) == :medium
      assert BudgetAllocator.model_type(:large) == :large
    end
  end

  describe "percentages/1" do
    test "returns correct percentages for each model type" do
      small = BudgetAllocator.percentages(:small)
      assert small.tier1 == 0.05
      assert small.tier2 == 0.15
      assert small.tier3 == 0.80

      medium = BudgetAllocator.percentages(:medium)
      assert medium.tier1 == 0.08
      assert medium.tier2 == 0.20
      assert medium.tier3 == 0.72

      large = BudgetAllocator.percentages(:large)
      assert large.tier1 == 0.10
      assert large.tier2 == 0.25
      assert large.tier3 == 0.65
    end
  end

  describe "fit_to_budget/2" do
    test "fits items within budget" do
      items = [
        %{content: "Short item", tokens: 10},
        %{content: "Medium item with more text", tokens: 50},
        %{content: "Large item with lots of content", tokens: 100}
      ]

      {fitting, remaining} = BudgetAllocator.fit_to_budget(items, 70)

      assert length(fitting) == 2
      assert remaining == 10  # 70 - 10 - 50 = 10
    end

    test "estimates tokens from content when not provided" do
      items = [
        %{content: "Hello world!"},  # ~3 tokens
        %{content: String.duplicate("x", 100)}  # ~25 tokens
      ]

      {fitting, remaining} = BudgetAllocator.fit_to_budget(items, 30)

      assert length(fitting) == 2
      assert remaining >= 0
    end

    test "returns empty list when budget is zero" do
      items = [%{content: "test", tokens: 10}]
      {fitting, remaining} = BudgetAllocator.fit_to_budget(items, 0)

      assert fitting == []
      assert remaining == 0
    end

    test "handles empty item list" do
      {fitting, remaining} = BudgetAllocator.fit_to_budget([], 100)

      assert fitting == []
      assert remaining == 100
    end
  end

  describe "estimate_item_tokens/1" do
    test "uses tokens field when available" do
      assert BudgetAllocator.estimate_item_tokens(%{tokens: 42}) == 42
    end

    test "estimates from content field" do
      item = %{content: String.duplicate("x", 100)}
      tokens = BudgetAllocator.estimate_item_tokens(item)
      
      # 100 chars / 4 = 25 tokens
      assert tokens == 25
    end

    test "handles missing content" do
      # Empty content string returns 0
      assert BudgetAllocator.estimate_item_tokens(%{content: ""}) == 0
      # Missing content field returns minimum 1 (for non-nil inspection)
      assert BudgetAllocator.estimate_item_tokens(%{}) >= 0
    end
  end

  describe "estimate_string_tokens/1" do
    test "estimates tokens from string length" do
      assert BudgetAllocator.estimate_string_tokens("Hello") == 1  # 5 chars / 4 = 1
      assert BudgetAllocator.estimate_string_tokens(String.duplicate("x", 100)) == 25
      assert BudgetAllocator.estimate_string_tokens("") == 0
    end

    test "handles non-string input" do
      assert BudgetAllocator.estimate_string_tokens(nil) == 0
      assert BudgetAllocator.estimate_string_tokens(123) == 0
    end
  end
end
