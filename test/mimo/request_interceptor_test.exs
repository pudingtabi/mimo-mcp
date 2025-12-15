defmodule Mimo.RequestInterceptorTest do
  use ExUnit.Case, async: true

  alias Mimo.RequestInterceptor

  setup do
    RequestInterceptor.reset_session()
    :ok
  end

  test "record_error handles map error messages without raising" do
    # Test with a map that doesn't implement String.Chars
    error_map = %{
      reason: :pattern_not_found,
      suggestion: "Verify the exact text including whitespace and line endings",
      file_size: 13_943,
      searched_for: "some interpolated string content"
    }

    # This should NOT raise Protocol.UndefinedError
    result =
      try do
        RequestInterceptor.record_error("file", error_map)
        :ok
      rescue
        Protocol.UndefinedError -> :protocol_error
        _ -> :other_error
      end

    assert result == :ok

    # Verify the error was recorded
    errors = Process.get(:mimo_session_errors, [])
    assert length(errors) == 1
    assert hd(errors).tool == "file"
    # The message should contain inspected map content
    assert String.contains?(hd(errors).message, "pattern_not_found")
  end

  test "record_error handles binary strings normally" do
    RequestInterceptor.record_error("terminal", "Command failed with exit code 1")

    errors = Process.get(:mimo_session_errors, [])
    assert length(errors) == 1
    assert hd(errors).message == "Command failed with exit code 1"
  end

  test "record_error handles atoms" do
    RequestInterceptor.record_error("code", :timeout)

    errors = Process.get(:mimo_session_errors, [])
    assert length(errors) == 1
    assert hd(errors).message == "timeout"
  end

  test "record_error handles tuples" do
    RequestInterceptor.record_error("web", {:error, :econnrefused})

    errors = Process.get(:mimo_session_errors, [])
    assert length(errors) == 1
    assert String.contains?(hd(errors).message, "econnrefused")
  end

  test "reset_session clears all session state" do
    RequestInterceptor.record_error("file", "error 1")
    RequestInterceptor.record_error("terminal", "error 2")

    errors_before = Process.get(:mimo_session_errors, [])
    assert length(errors_before) == 2

    RequestInterceptor.reset_session()

    errors_after = Process.get(:mimo_session_errors, [])
    assert errors_after == nil or errors_after == []
  end

  test "analyze_and_enrich returns continue for normal requests" do
    result = RequestInterceptor.analyze_and_enrich("memory", %{"operation" => "search"})
    assert result == {:continue, nil}
  end

  test "analyze_and_enrich suggests debugging after multiple errors" do
    # Record 3 errors to trigger debug suggestion
    RequestInterceptor.record_error("file", "error 1")
    RequestInterceptor.record_error("terminal", "error 2")
    RequestInterceptor.record_error("code", "error 3")

    result = RequestInterceptor.analyze_and_enrich("file", %{"operation" => "read"})

    assert {:suggest, "reason", _query, reason} = result
    assert String.contains?(reason, "debugging chain")
  end
end
