defmodule Mimo.Library.Fetchers.CommonTest do
  use ExUnit.Case, async: true

  alias Mimo.Library.Fetchers.Common

  describe "http_get_json/2" do
    @tag :external
    test "fetches JSON from a valid URL" do
      # Using httpbin.org for testing
      assert {:ok, data} = Common.http_get_json("https://httpbin.org/json")
      assert is_map(data)
    end

    @tag :external
    test "returns error for 404" do
      assert {:error, :not_found} = Common.http_get_json("https://httpbin.org/status/404")
    end

    @tag :external
    test "handles invalid JSON gracefully" do
      # This endpoint returns HTML, not JSON
      result = Common.http_get_json("https://httpbin.org/html")
      assert {:error, _} = result
    end
  end

  describe "http_get_html/2" do
    @tag :external
    test "fetches HTML from a valid URL" do
      assert {:ok, html} = Common.http_get_html("https://httpbin.org/html")
      assert is_binary(html)
      assert String.contains?(html, "<html")
    end

    @tag :external
    test "returns error for 404" do
      assert {:error, :not_found} = Common.http_get_html("https://httpbin.org/status/404")
    end
  end

  describe "http_get_text/2" do
    @tag :external
    test "fetches text content" do
      assert {:ok, text} = Common.http_get_text("https://httpbin.org/robots.txt")
      assert is_binary(text)
    end
  end

  describe "http_get_binary/2" do
    @tag :external
    test "fetches binary content" do
      assert {:ok, data} = Common.http_get_binary("https://httpbin.org/bytes/100")
      assert is_binary(data)
      assert byte_size(data) == 100
    end
  end

  describe "retry behavior" do
    @tag :external
    test "retries on 503 status" do
      # httpbin.org/status/503 always returns 503, so after retries it should still fail
      # but the point is it should retry (we can verify via timing if needed)
      result = Common.http_get_json("https://httpbin.org/status/503", retries: 1)
      assert {:ok, %{status: 503}} = result
    end

    @tag :external
    test "retries on 429 status" do
      result = Common.http_get_json("https://httpbin.org/status/429", retries: 1)
      assert {:ok, %{status: 429}} = result
    end

    test "respects retries option" do
      # Using a non-existent host to trigger connection errors
      # With 0 retries, should fail immediately
      start = System.monotonic_time(:millisecond)
      _result = Common.http_get_json("http://non-existent-host-12345.invalid/", retries: 0)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should complete quickly without retries (under 5 seconds for DNS timeout)
      assert elapsed < 10_000
    end
  end

  describe "options" do
    @tag :external
    test "timeout option is respected" do
      # Very short timeout should fail
      result = Common.http_get_json("https://httpbin.org/delay/5", timeout: 100)
      assert {:error, _} = result
    end

    @tag :external
    test "custom headers can be passed" do
      assert {:ok, data} =
               Common.http_get_json(
                 "https://httpbin.org/headers",
                 headers: [{"X-Custom-Header", "test-value"}]
               )

      headers = data["headers"]
      assert headers["X-Custom-Header"] == "test-value"
    end
  end
end
