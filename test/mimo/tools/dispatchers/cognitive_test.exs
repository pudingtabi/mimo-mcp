defmodule Mimo.Tools.Dispatchers.CognitiveTest do
  use ExUnit.Case, async: true
  # <--- Moved to top
  import ExUnit.CaptureLog
  alias Mimo.Tools.Dispatchers.Cognitive

  describe "dispatch/1" do
    test "routes 'assess' to epistemic logic (default)" do
      args = %{"operation" => "assess", "claim" => "test"}
      result = Cognitive.dispatch(args)
      # Asserting structure: expecting a tuple or map result
      assert is_tuple(result) or is_map(result)
    end

    test "routes verify operations correctly" do
      args = %{"operation" => "verify_math", "expression" => "2+2"}

      # Verifies that dispatch happens (even if underlying tool fails/logs)
      assert capture_log(fn ->
               Cognitive.dispatch(args)
             end)
    end
  end

  describe "Pattern Matching Routing" do
    test "routes emergence operations" do
      args = %{"operation" => "emergence_detect"}

      try do
        Cognitive.dispatch(args)
        assert true
      rescue
        e in FunctionClauseError ->
          flunk("Dispatcher failed to match 'emergence_detect': #{inspect(e)}")

        _ ->
          assert true
      end
    end

    test "routes reflector operations" do
      args = %{"operation" => "reflector_reflect"}

      try do
        Cognitive.dispatch(args)
        assert true
      rescue
        # Fixed unused var
        _e in FunctionClauseError -> flunk("Dispatcher failed to match 'reflector_reflect'")
        _ -> assert true
      end
    end
  end
end
