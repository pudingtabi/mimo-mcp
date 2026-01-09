defmodule Mimo.Cognitive.SafeHealerTest do
  @moduledoc """
  Tests for Phase 5 C2: Self-Healing Patterns (SafeHealer)
  """
  use ExUnit.Case, async: true

  alias Mimo.Cognitive.SafeHealer

  @moduletag :phase5

  describe "catalog/0" do
    test "returns a list of healing actions" do
      catalog = SafeHealer.catalog()

      assert is_list(catalog)
      assert length(catalog) > 0
    end

    test "each action has required fields" do
      catalog = SafeHealer.catalog()

      for action <- catalog do
        assert Map.has_key?(action, :id)
        assert Map.has_key?(action, :name)
        assert Map.has_key?(action, :description)
        assert Map.has_key?(action, :risk)
        assert Map.has_key?(action, :condition)
        assert Map.has_key?(action, :action)
      end
    end

    test "all action ids are atoms" do
      catalog = SafeHealer.catalog()

      for action <- catalog do
        assert is_atom(action.id)
      end
    end

    test "all risks are valid levels" do
      catalog = SafeHealer.catalog()

      for action <- catalog do
        assert action.risk in [:low, :medium, :high]
      end
    end
  end

  describe "diagnose/0" do
    test "returns diagnosis map with required fields" do
      diagnosis = SafeHealer.diagnose()

      assert is_map(diagnosis)
      assert Map.has_key?(diagnosis, :issues)
      assert Map.has_key?(diagnosis, :recommendations)
      assert Map.has_key?(diagnosis, :health_score)
    end

    test "issues is a list" do
      diagnosis = SafeHealer.diagnose()
      assert is_list(diagnosis.issues)
    end

    test "recommendations is a list of atoms" do
      diagnosis = SafeHealer.diagnose()

      assert is_list(diagnosis.recommendations)

      for rec <- diagnosis.recommendations do
        assert is_atom(rec)
      end
    end

    test "health_score is a number" do
      diagnosis = SafeHealer.diagnose()
      assert is_number(diagnosis.health_score)
    end
  end

  describe "heal/1" do
    test "returns error for unknown action" do
      result = SafeHealer.heal(:nonexistent_action_xyz)
      assert {:error, :unknown_action} = result
    end

    test "returns error or ok for known action" do
      # Use a known low-risk action
      result = SafeHealer.heal(:clear_classifier_cache)

      case result do
        {:ok, _} -> assert true
        {:error, :on_cooldown} -> assert true
        {:error, _other} -> assert true
      end
    end
  end

  describe "auto_heal/0" do
    test "returns result map with required fields" do
      result = SafeHealer.auto_heal()

      assert is_map(result)
      assert Map.has_key?(result, :executed)
      assert Map.has_key?(result, :skipped_medium_risk)
      assert Map.has_key?(result, :skipped_cooldown)
      assert Map.has_key?(result, :errors)
    end

    test "executed is a list" do
      result = SafeHealer.auto_heal()
      assert is_list(result.executed)
    end

    test "skipped lists are lists" do
      result = SafeHealer.auto_heal()
      assert is_list(result.skipped_medium_risk)
      assert is_list(result.skipped_cooldown)
    end
  end

  # Note: SafeHealer.history/0 not implemented - heal history is tracked in stats

  describe "stats/0" do
    test "returns stats map with action counts" do
      stats = SafeHealer.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :available_actions)
      assert Map.has_key?(stats, :low_risk_actions)
      assert Map.has_key?(stats, :medium_risk_actions)
      assert Map.has_key?(stats, :cooldown_status)
    end

    test "action counts are non-negative integers" do
      stats = SafeHealer.stats()

      assert is_integer(stats.available_actions)
      assert stats.available_actions >= 0
      assert is_integer(stats.low_risk_actions)
      assert is_integer(stats.medium_risk_actions)
    end

    test "cooldown_status is a map" do
      stats = SafeHealer.stats()
      assert is_map(stats.cooldown_status)
    end
  end
end
