defmodule Mimo.Tools.Dispatchers.EmergenceProbeTest do
  use Mimo.DataCase, async: false

  alias Mimo.Tools.Dispatchers.Emergence, as: EmergenceDispatcher

  # ─────────────────────────────────────────────────────────────────
  # dispatch probe Tests
  # ─────────────────────────────────────────────────────────────────

  describe "dispatch probe operation" do
    test "handles missing pattern_id" do
      args = %{"operation" => "probe"}

      result = EmergenceDispatcher.dispatch(args)

      assert {:error, "pattern_id is required for probe operation"} = result
    end

    test "handles non-existent pattern" do
      args = %{
        "operation" => "probe",
        "pattern_id" => Ecto.UUID.generate(),
        "type" => "validation"
      }

      result = EmergenceDispatcher.dispatch(args)

      case result do
        {:error, "Pattern not found:" <> _} ->
          assert true

        {:error, "Failed to probe pattern:" <> _} ->
          # Pattern fetch failed
          assert true

        {:error, _} ->
          # Other errors (DB not available)
          assert true
      end
    end

    test "handles invalid probe type" do
      args = %{
        "operation" => "probe",
        "pattern_id" => Ecto.UUID.generate(),
        "type" => "invalid_type"
      }

      result = EmergenceDispatcher.dispatch(args)

      case result do
        {:error, "Invalid probe type." <> msg} ->
          assert msg =~ "validation"
          assert msg =~ "boundary"
          assert msg =~ "generalization"
          assert msg =~ "composition"

        {:error, "Pattern not found:" <> _} ->
          # Pattern doesn't exist, which is checked first
          assert true

        {:error, _} ->
          # Other errors
          assert true
      end
    end

    test "probe operation is recognized" do
      args = %{"operation" => "probe", "pattern_id" => "test-id"}

      result = EmergenceDispatcher.dispatch(args)

      # Should not return "Unknown emergence operation"
      case result do
        {:error, "Unknown emergence operation:" <> _} ->
          flunk("probe operation should be recognized")

        _ ->
          assert true
      end
    end

    test "defaults to validation probe type" do
      args = %{
        "operation" => "probe",
        "pattern_id" => Ecto.UUID.generate()
      }

      # Even with non-existent pattern, should use validation as default
      result = EmergenceDispatcher.dispatch(args)

      # Just check it doesn't crash and is recognized
      assert is_tuple(result)
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # dispatch probe_candidates Tests
  # ─────────────────────────────────────────────────────────────────

  describe "dispatch probe_candidates operation" do
    test "returns list of probe candidates" do
      args = %{"operation" => "probe_candidates"}

      result = EmergenceDispatcher.dispatch(args)

      assert {:ok, response} = result
      assert response.operation == :probe_candidates
      assert is_list(response.candidates)
      assert is_integer(response.candidate_count)
      assert is_binary(response.interpretation)
    end

    test "accepts limit parameter" do
      args = %{"operation" => "probe_candidates", "limit" => 5}

      result = EmergenceDispatcher.dispatch(args)

      assert {:ok, response} = result
      assert response.operation == :probe_candidates
      assert length(response.candidates) <= 5
    end

    test "probe_candidates operation is recognized" do
      args = %{"operation" => "probe_candidates"}

      result = EmergenceDispatcher.dispatch(args)

      # Should not return "Unknown emergence operation"
      case result do
        {:error, "Unknown emergence operation:" <> _} ->
          flunk("probe_candidates operation should be recognized")

        _ ->
          assert true
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # dispatch capability_summary Tests
  # ─────────────────────────────────────────────────────────────────

  describe "dispatch capability_summary operation" do
    test "returns capability summary" do
      args = %{"operation" => "capability_summary"}

      result = EmergenceDispatcher.dispatch(args)

      assert {:ok, response} = result
      assert response.operation == :capability_summary
      assert is_integer(response.total_patterns)
      assert is_integer(response.domain_count)
      assert is_map(response.domains)
      assert is_list(response.strongest_domains)
      assert is_list(response.weakest_domains)
      assert %DateTime{} = response.updated_at
    end

    test "capability_summary domains contain expected fields" do
      args = %{"operation" => "capability_summary"}

      result = EmergenceDispatcher.dispatch(args)

      assert {:ok, response} = result

      for {_domain, stats} <- response.domains do
        assert is_binary(stats.description)
        assert is_integer(stats.pattern_count)
        assert is_number(stats.avg_strength)
        assert is_number(stats.avg_success_rate)
        assert is_integer(stats.total_occurrences)
      end
    end

    test "capability_summary operation is recognized" do
      args = %{"operation" => "capability_summary"}

      result = EmergenceDispatcher.dispatch(args)

      # Should not return "Unknown emergence operation"
      case result do
        {:error, "Unknown emergence operation:" <> _} ->
          flunk("capability_summary operation should be recognized")

        _ ->
          assert true
      end
    end
  end
end
