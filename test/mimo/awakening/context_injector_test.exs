defmodule Mimo.Awakening.ContextInjectorTest do
  use ExUnit.Case, async: true

  alias Mimo.Awakening.ContextInjector

  describe "build_emergence_velocity/0" do
    test "returns velocity metrics with required fields" do
      velocity = ContextInjector.build_emergence_velocity()

      assert is_map(velocity)
      assert Map.has_key?(velocity, "period_days")
      assert Map.has_key?(velocity, "new_patterns")
      assert Map.has_key?(velocity, "daily_average")
      assert Map.has_key?(velocity, "trend")
      assert Map.has_key?(velocity, "momentum")
    end

    test "momentum is one of the expected labels" do
      velocity = ContextInjector.build_emergence_velocity()

      valid_labels = [
        "dormant",
        "rapid_learning",
        "accelerating",
        "slowing",
        "consolidating",
        "active",
        "steady",
        "emerging",
        "unknown"
      ]

      assert velocity["momentum"] in valid_labels
    end

    test "period_days defaults to 7" do
      velocity = ContextInjector.build_emergence_velocity()
      assert velocity["period_days"] == 7
    end
  end

  describe "build_emerged_skills/0" do
    test "returns skills info with required fields" do
      skills = ContextInjector.build_emerged_skills()

      assert is_map(skills)
      assert Map.has_key?(skills, "count")
      assert Map.has_key?(skills, "top_skills")
      assert Map.has_key?(skills, "status")
      assert Map.has_key?(skills, "hint")
    end

    test "status is one of active, learning, or error" do
      skills = ContextInjector.build_emerged_skills()
      assert skills["status"] in ["active", "learning", "error"]
    end
  end
end
