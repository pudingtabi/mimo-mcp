defmodule Mimo.Brain.EngramTemporalValidityTest do
  @moduledoc """
  SPEC-060 Enhancement: DateTime boundary tests for temporal validity.

  Tests edge cases identified in skeptical analysis:
  - Timezone edge cases
  - Exact boundary conditions for valid_from and valid_until
  - Nil field handling (open-ended validity)
  """
  use Mimo.DataCase, async: true

  alias Mimo.Brain.Engram

  describe "valid_at?/2 boundary conditions" do
    setup do
      # Create a base engram for testing
      base_time = ~U[2025-06-15 12:00:00Z]
      valid_from = ~U[2025-06-01 00:00:00Z]
      valid_until = ~U[2025-06-30 23:59:59Z]

      engram = %Engram{
        id: 1,
        content: "Test temporal validity",
        category: "fact",
        valid_from: valid_from,
        valid_until: valid_until,
        validity_source: "explicit"
      }

      {:ok, engram: engram, base_time: base_time, valid_from: valid_from, valid_until: valid_until}
    end

    # ===== valid_from boundary tests =====

    test "datetime exactly equals valid_from is VALID (inclusive start)", %{
      engram: engram,
      valid_from: valid_from
    } do
      # Boundary: datetime == valid_from should be valid
      assert Engram.valid_at?(engram, valid_from) == true
    end

    test "datetime 1 microsecond before valid_from is INVALID", %{
      engram: engram,
      valid_from: valid_from
    } do
      one_microsecond_before = DateTime.add(valid_from, -1, :microsecond)
      assert Engram.valid_at?(engram, one_microsecond_before) == false
    end

    test "datetime 1 second after valid_from is VALID", %{engram: engram, valid_from: valid_from} do
      one_second_after = DateTime.add(valid_from, 1, :second)
      assert Engram.valid_at?(engram, one_second_after) == true
    end

    # ===== valid_until boundary tests =====

    test "datetime exactly equals valid_until is INVALID (exclusive end)", %{
      engram: engram,
      valid_until: valid_until
    } do
      # Boundary: datetime == valid_until should be INVALID (exclusive upper bound)
      assert Engram.valid_at?(engram, valid_until) == false
    end

    test "datetime 1 microsecond before valid_until is VALID", %{
      engram: engram,
      valid_until: valid_until
    } do
      one_microsecond_before = DateTime.add(valid_until, -1, :microsecond)
      assert Engram.valid_at?(engram, one_microsecond_before) == true
    end

    test "datetime 1 second after valid_until is INVALID", %{
      engram: engram,
      valid_until: valid_until
    } do
      one_second_after = DateTime.add(valid_until, 1, :second)
      assert Engram.valid_at?(engram, one_second_after) == false
    end

    # ===== Nil field handling (open-ended validity) =====

    test "nil valid_from means valid from beginning of time", %{valid_until: valid_until} do
      engram = %Engram{
        id: 2,
        content: "No start bound",
        category: "fact",
        valid_from: nil,
        valid_until: valid_until
      }

      # Should be valid at any time before valid_until
      ancient_time = ~U[1900-01-01 00:00:00Z]
      assert Engram.valid_at?(engram, ancient_time) == true

      # Should still respect valid_until
      future_time = ~U[2025-07-01 00:00:00Z]
      assert Engram.valid_at?(engram, future_time) == false
    end

    test "nil valid_until means never expires", %{valid_from: valid_from} do
      engram = %Engram{
        id: 3,
        content: "No end bound",
        category: "fact",
        valid_from: valid_from,
        valid_until: nil
      }

      # Should be valid at any time after valid_from
      far_future = ~U[2999-12-31 23:59:59Z]
      assert Engram.valid_at?(engram, far_future) == true

      # Should still respect valid_from
      past_time = ~U[2025-05-01 00:00:00Z]
      assert Engram.valid_at?(engram, past_time) == false
    end

    test "both nil means always valid (unbounded)", %{} do
      engram = %Engram{
        id: 4,
        content: "Eternal fact",
        category: "fact",
        valid_from: nil,
        valid_until: nil
      }

      # Should be valid at any time
      assert Engram.valid_at?(engram, ~U[1900-01-01 00:00:00Z]) == true
      assert Engram.valid_at?(engram, ~U[2025-06-15 12:00:00Z]) == true
      assert Engram.valid_at?(engram, ~U[2999-12-31 23:59:59Z]) == true
    end

    # ===== Within bounds test =====

    test "datetime clearly within bounds is VALID", %{engram: engram, base_time: base_time} do
      assert Engram.valid_at?(engram, base_time) == true
    end
  end

  describe "currently_valid?/1" do
    test "returns true for unbounded engram" do
      engram = %Engram{
        id: 5,
        content: "Current test",
        category: "fact",
        valid_from: nil,
        valid_until: nil
      }

      assert Engram.currently_valid?(engram) == true
    end

    test "returns true for future-expiring engram" do
      engram = %Engram{
        id: 6,
        content: "Future expiry",
        category: "fact",
        valid_from: ~U[2020-01-01 00:00:00Z],
        valid_until: ~U[2030-01-01 00:00:00Z]
      }

      assert Engram.currently_valid?(engram) == true
    end

    test "returns false for already-expired engram" do
      engram = %Engram{
        id: 7,
        content: "Expired fact",
        category: "fact",
        valid_from: ~U[2020-01-01 00:00:00Z],
        valid_until: ~U[2024-01-01 00:00:00Z]
      }

      assert Engram.currently_valid?(engram) == false
    end

    test "returns false for not-yet-valid engram" do
      engram = %Engram{
        id: 8,
        content: "Future fact",
        category: "fact",
        valid_from: ~U[2030-01-01 00:00:00Z],
        valid_until: nil
      }

      assert Engram.currently_valid?(engram) == false
    end
  end

  describe "invalidate/2" do
    test "sets valid_until to current time and updates validity_source" do
      engram = %Engram{
        id: 9,
        content: "To be invalidated",
        category: "fact",
        valid_from: ~U[2020-01-01 00:00:00Z],
        valid_until: nil,
        validity_source: "explicit"
      }

      before_invalidation = DateTime.utc_now()
      changeset = Engram.invalidate(engram, "corrected")
      after_invalidation = DateTime.utc_now()

      # Check validity_source changed
      assert Ecto.Changeset.get_change(changeset, :validity_source) == "corrected"

      # Check valid_until is set to approximately now
      valid_until = Ecto.Changeset.get_change(changeset, :valid_until)
      assert DateTime.compare(valid_until, before_invalidation) != :lt
      assert DateTime.compare(valid_until, after_invalidation) != :gt
    end

    test "uses 'superseded' as default reason" do
      engram = %Engram{id: 10, content: "Default reason test", category: "fact"}

      changeset = Engram.invalidate(engram)

      assert Ecto.Changeset.get_change(changeset, :validity_source) == "superseded"
    end
  end

  describe "timezone handling" do
    test "UTC times compare correctly" do
      engram = %Engram{
        id: 11,
        content: "UTC test",
        category: "fact",
        valid_from: ~U[2025-06-01 00:00:00Z],
        valid_until: ~U[2025-06-30 23:59:59Z]
      }

      # Mid-month UTC should be valid
      assert Engram.valid_at?(engram, ~U[2025-06-15 12:00:00Z]) == true
    end

    test "different timezone representations compare correctly" do
      # Note: Elixir DateTime with Z suffix is always UTC
      # This test verifies consistent behavior with explicit UTC times
      engram = %Engram{
        id: 12,
        content: "Timezone consistency",
        category: "fact",
        valid_from: DateTime.from_naive!(~N[2025-06-01 00:00:00], "Etc/UTC"),
        valid_until: DateTime.from_naive!(~N[2025-06-30 23:59:59], "Etc/UTC")
      }

      query_time = DateTime.from_naive!(~N[2025-06-15 12:00:00], "Etc/UTC")
      assert Engram.valid_at?(engram, query_time) == true
    end
  end
end
