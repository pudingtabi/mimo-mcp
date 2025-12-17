defmodule Mimo.Brain.AccessTrackerTest do
  @moduledoc """
  Tests for AccessTracker including neuroscience-inspired spacing effect.
  """
  use Mimo.DataCase

  alias Mimo.Brain.{AccessTracker, Engram}

  describe "spacing effect (neuroscience feature)" do
    test "accessing a memory reduces its decay_rate" do
      # Create a memory with known decay_rate
      initial_decay_rate = 0.05

      {:ok, engram} =
        %Engram{}
        |> Engram.changeset(%{
          content: "Test memory for spacing effect",
          category: "fact",
          importance: 0.5,
          decay_rate: initial_decay_rate
        })
        |> Repo.insert()

      # Track access to this memory
      AccessTracker.track(engram.id)

      # Force flush to apply the update
      AccessTracker.flush()

      # Reload the engram
      updated_engram = Repo.get(Engram, engram.id)

      # Verify decay_rate was reduced (spacing effect)
      # Expected: decay_rate * 0.95 = 0.05 * 0.95 = 0.0475
      assert updated_engram.decay_rate < initial_decay_rate
      assert_in_delta updated_engram.decay_rate, initial_decay_rate * 0.95, 0.0001
    end

    test "multiple accesses compound decay reduction" do
      initial_decay_rate = 0.1

      {:ok, engram} =
        %Engram{}
        |> Engram.changeset(%{
          content: "Test memory for compound spacing effect",
          category: "fact",
          importance: 0.5,
          decay_rate: initial_decay_rate
        })
        |> Repo.insert()

      # Track multiple accesses
      for _ <- 1..10 do
        AccessTracker.track(engram.id)
      end

      AccessTracker.flush()

      updated_engram = Repo.get(Engram, engram.id)

      # Expected: decay_rate * 0.95^10 = 0.1 * 0.5987 ≈ 0.0599
      expected_decay = initial_decay_rate * :math.pow(0.95, 10)
      assert_in_delta updated_engram.decay_rate, expected_decay, 0.001
    end

    test "decay_rate does not go below minimum" do
      # Start with very low decay rate
      initial_decay_rate = 0.0002

      {:ok, engram} =
        %Engram{}
        |> Engram.changeset(%{
          content: "Test memory for minimum decay floor",
          category: "fact",
          importance: 0.5,
          decay_rate: initial_decay_rate
        })
        |> Repo.insert()

      # Track many accesses
      for _ <- 1..100 do
        AccessTracker.track(engram.id)
      end

      AccessTracker.flush()

      updated_engram = Repo.get(Engram, engram.id)

      # Decay rate should be clamped to minimum (0.0001)
      assert updated_engram.decay_rate >= 0.0001
    end
  end

  describe "track/1" do
    test "increments access_count" do
      {:ok, engram} =
        %Engram{}
        |> Engram.changeset(%{
          content: "Test memory for access count",
          category: "fact",
          importance: 0.5
        })
        |> Repo.insert()

      initial_count = engram.access_count || 0

      AccessTracker.track(engram.id)
      AccessTracker.flush()

      updated_engram = Repo.get(Engram, engram.id)
      assert updated_engram.access_count == initial_count + 1
    end

    test "updates last_accessed_at" do
      {:ok, engram} =
        %Engram{}
        |> Engram.changeset(%{
          content: "Test memory for last_accessed_at",
          category: "fact",
          importance: 0.5
        })
        |> Repo.insert()

      AccessTracker.track(engram.id)
      AccessTracker.flush()

      updated_engram = Repo.get(Engram, engram.id)
      assert updated_engram.last_accessed_at != nil
    end
  end

  describe "stats/0" do
    test "returns tracking statistics" do
      stats = AccessTracker.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_tracked) or Map.has_key?(stats, :status)
    end
  end
end
