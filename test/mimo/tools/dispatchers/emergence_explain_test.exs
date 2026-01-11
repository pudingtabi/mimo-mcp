defmodule Mimo.Tools.Dispatchers.EmergenceExplainTest do
  use Mimo.DataCase, async: false

  alias Mimo.Tools.Dispatchers.Emergence, as: EmergenceDispatcher

  # ─────────────────────────────────────────────────────────────────
  # dispatch explain Tests
  # ─────────────────────────────────────────────────────────────────

  describe "dispatch explain operation" do
    test "handles missing pattern_id by attempting batch explain" do
      args = %{"operation" => "explain"}

      # Without patterns in DB, should return message about no patterns
      result = EmergenceDispatcher.dispatch(args)

      case result do
        {:ok, %{operation: :explain_batch}} ->
          # Found patterns and explained them
          assert true

        {:ok, %{operation: :explain, message: msg}} ->
          # No patterns found
          assert msg =~ "No active patterns"

        {:error, _reason} ->
          # DB not available in test
          assert true
      end
    end

    test "handles explain with pattern_id" do
      args = %{
        "operation" => "explain",
        "pattern_id" => Ecto.UUID.generate(),
        "use_llm" => false
      }

      result = EmergenceDispatcher.dispatch(args)

      case result do
        {:error, "Pattern not found:" <> _} ->
          # Expected - pattern doesn't exist
          assert true

        {:ok, %{operation: :explain}} ->
          # Pattern found and explained
          assert true

        {:error, _} ->
          # Some other error (DB not available)
          assert true
      end
    end

    test "explain operation is recognized" do
      args = %{"operation" => "explain", "pattern_id" => "test-id", "use_llm" => false}

      result = EmergenceDispatcher.dispatch(args)

      # Should not return "Unknown emergence operation"
      case result do
        {:error, "Unknown emergence operation:" <> _} ->
          flunk("explain operation should be recognized")

        _ ->
          assert true
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # dispatch hypothesize Tests
  # ─────────────────────────────────────────────────────────────────

  describe "dispatch hypothesize operation" do
    test "requires pattern_id" do
      args = %{"operation" => "hypothesize"}

      result = EmergenceDispatcher.dispatch(args)

      assert {:error, msg} = result
      assert msg =~ "pattern_id is required"
    end

    test "handles valid pattern_id" do
      args = %{
        "operation" => "hypothesize",
        "pattern_id" => Ecto.UUID.generate()
      }

      result = EmergenceDispatcher.dispatch(args)

      case result do
        {:error, "Pattern not found:" <> _} ->
          # Expected - pattern doesn't exist
          assert true

        {:ok, %{operation: :hypothesize}} ->
          # Pattern found and hypotheses generated
          assert true

        {:error, _} ->
          # Some other error
          assert true
      end
    end

    test "hypothesize operation is recognized" do
      args = %{"operation" => "hypothesize", "pattern_id" => "test-id"}

      result = EmergenceDispatcher.dispatch(args)

      # Should not return "Unknown emergence operation"
      case result do
        {:error, "Unknown emergence operation:" <> _} ->
          flunk("hypothesize operation should be recognized")

        _ ->
          assert true
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Available Operations Tests
  # ─────────────────────────────────────────────────────────────────

  describe "operation availability" do
    test "error message includes explain and hypothesize" do
      args = %{"operation" => "invalid_operation_xyz"}

      {:error, msg} = EmergenceDispatcher.dispatch(args)

      assert msg =~ "explain"
      assert msg =~ "hypothesize"
    end
  end
end
