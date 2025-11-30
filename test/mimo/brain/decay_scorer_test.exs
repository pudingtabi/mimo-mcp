defmodule Mimo.Brain.DecayScorerTest do
  use ExUnit.Case, async: true

  alias Mimo.Brain.DecayScorer

  describe "calculate_score/1" do
    test "returns score between 0 and 1" do
      engram = %{
        importance: 0.5,
        access_count: 5,
        decay_rate: 0.1,
        last_accessed_at: NaiveDateTime.utc_now(),
        protected: false
      }

      score = DecayScorer.calculate_score(engram)
      assert score >= 0.0
      assert score <= 1.0
    end

    test "higher importance increases score" do
      base = %{
        access_count: 0,
        decay_rate: 0.1,
        last_accessed_at: NaiveDateTime.utc_now(),
        protected: false
      }

      low_importance = DecayScorer.calculate_score(Map.put(base, :importance, 0.2))
      high_importance = DecayScorer.calculate_score(Map.put(base, :importance, 0.9))

      assert high_importance > low_importance
    end

    test "more accesses increases score" do
      base = %{
        importance: 0.5,
        decay_rate: 0.1,
        last_accessed_at: NaiveDateTime.utc_now(),
        protected: false
      }

      few_accesses = DecayScorer.calculate_score(Map.put(base, :access_count, 1))
      many_accesses = DecayScorer.calculate_score(Map.put(base, :access_count, 20))

      assert many_accesses > few_accesses
    end

    test "older memories have lower scores" do
      base = %{
        importance: 0.5,
        access_count: 1,
        decay_rate: 0.1,
        protected: false
      }

      now = NaiveDateTime.utc_now()
      recent = DecayScorer.calculate_score(Map.put(base, :last_accessed_at, now))

      thirty_days_ago = NaiveDateTime.add(now, -30 * 24 * 60 * 60, :second)
      old = DecayScorer.calculate_score(Map.put(base, :last_accessed_at, thirty_days_ago))

      assert recent >= old
    end
  end

  describe "should_forget?/2" do
    test "returns true for low score memories" do
      engram = %{
        importance: 0.1,
        access_count: 0,
        decay_rate: 0.5,
        last_accessed_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -30 * 24 * 60 * 60, :second),
        protected: false
      }

      assert DecayScorer.should_forget?(engram, 0.3) == true
    end

    test "protected memories are never forgotten" do
      engram = %{
        importance: 0.01,
        access_count: 0,
        decay_rate: 1.0,
        last_accessed_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -365 * 24 * 60 * 60, :second),
        protected: true
      }

      assert DecayScorer.should_forget?(engram) == false
    end
  end

  describe "predict_forgetting/2" do
    test "returns :never for protected memories" do
      engram = %{
        importance: 0.5,
        access_count: 0,
        decay_rate: 0.1,
        protected: true
      }

      assert DecayScorer.predict_forgetting(engram) == :never
    end

    test "returns :never for very high importance" do
      engram = %{
        importance: 0.99,
        access_count: 0,
        decay_rate: 0.1,
        protected: false
      }

      assert DecayScorer.predict_forgetting(engram) == :never
    end

    test "returns days for normal memories" do
      engram = %{
        importance: 0.5,
        access_count: 0,
        decay_rate: 0.1,
        protected: false,
        last_accessed_at: NaiveDateTime.utc_now()
      }

      days = DecayScorer.predict_forgetting(engram)
      assert is_float(days)
      assert days > 0
    end
  end

  describe "filter_forgettable/2" do
    test "filters memories below threshold" do
      now = NaiveDateTime.utc_now()
      old = NaiveDateTime.add(now, -100 * 24 * 60 * 60, :second)

      engrams = [
        %{importance: 0.9, access_count: 10, last_accessed_at: now, protected: false},
        %{importance: 0.1, access_count: 0, last_accessed_at: old, protected: false},
        %{importance: 0.8, access_count: 5, last_accessed_at: now, protected: false}
      ]

      forgettable = DecayScorer.filter_forgettable(engrams, 0.3)

      # Only low-importance old memory should be forgettable
      assert length(forgettable) == 1
      assert hd(forgettable).importance == 0.1
    end
  end

  describe "stats/1" do
    test "returns statistical summary" do
      engrams = [
        %{importance: 0.5, access_count: 0, last_accessed_at: NaiveDateTime.utc_now()},
        %{importance: 0.8, access_count: 5, last_accessed_at: NaiveDateTime.utc_now()},
        %{importance: 0.3, access_count: 1, last_accessed_at: NaiveDateTime.utc_now()}
      ]

      stats = DecayScorer.stats(engrams)

      assert stats.count == 3
      assert is_float(stats.avg_score)
      assert is_float(stats.min_score)
      assert is_float(stats.max_score)
      assert is_integer(stats.at_risk_count)
      assert is_integer(stats.forgettable_count)
    end
  end
end
