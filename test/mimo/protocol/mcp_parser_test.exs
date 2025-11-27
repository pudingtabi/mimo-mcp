defmodule Mimo.Protocol.McpParserTest do
  @moduledoc """
  Tests for MCP Protocol Parser module.
  Tests JSON-RPC parsing, serialization, and error handling.
  """
  use ExUnit.Case, async: true

  alias Mimo.Protocol.McpParser

  # ==========================================================================
  # Parsing Tests
  # ==========================================================================

  describe "parse_line/1" do
    test "parses valid initialize request" do
      line = ~s({"jsonrpc":"2.0","method":"initialize","id":1})
      assert {:ok, msg} = McpParser.parse_line(line)
      assert msg["method"] == "initialize"
      assert msg["id"] == 1
    end

    test "parses valid tools/list request" do
      line = ~s({"jsonrpc":"2.0","method":"tools/list","id":2})
      assert {:ok, msg} = McpParser.parse_line(line)
      assert msg["method"] == "tools/list"
    end

    test "parses valid tools/call request" do
      line =
        ~s({"jsonrpc":"2.0","method":"tools/call","params":{"name":"test","arguments":{}},"id":3})

      assert {:ok, msg} = McpParser.parse_line(line)
      assert msg["method"] == "tools/call"
      assert msg["params"]["name"] == "test"
    end

    test "handles empty line" do
      assert {:ok, :empty} = McpParser.parse_line("")
    end

    test "handles whitespace-only line" do
      assert {:ok, :empty} = McpParser.parse_line("   ")
    end

    test "returns parse error for invalid JSON" do
      assert {:error, response} = McpParser.parse_line("not valid json")
      assert response["error"]["code"] == -32700
    end

    test "returns error for non-object JSON" do
      assert {:error, response} = McpParser.parse_line("[1,2,3]")
      assert response["error"]["code"] == -32600
    end
  end

  describe "validate_message/1" do
    test "accepts valid message with method" do
      msg = %{"jsonrpc" => "2.0", "method" => "test", "id" => 1}
      assert {:ok, ^msg} = McpParser.validate_message(msg)
    end

    test "rejects message with wrong jsonrpc version" do
      msg = %{"jsonrpc" => "1.0", "method" => "test", "id" => 1}
      assert {:error, response} = McpParser.validate_message(msg)
      assert response["error"]["code"] == -32600
    end

    test "rejects message without method" do
      msg = %{"jsonrpc" => "2.0", "id" => 1}
      assert {:error, response} = McpParser.validate_message(msg)
      assert response["error"]["code"] == -32600
    end
  end

  describe "find_json_response/1" do
    test "finds response in buffer" do
      buffer = ~s({"jsonrpc":"2.0","id":1,"result":{}})
      assert {:ok, response, _} = McpParser.find_json_response(buffer)
      assert response["id"] == 1
    end

    test "finds response in multi-line buffer" do
      buffer = "debug output\n" <> ~s({"jsonrpc":"2.0","id":1,"result":{}}) <> "\nmore output"
      assert {:ok, response, _} = McpParser.find_json_response(buffer)
      assert response["id"] == 1
    end

    test "returns incomplete for non-JSON buffer" do
      assert :incomplete = McpParser.find_json_response("no json here")
    end
  end

  # ==========================================================================
  # Serialization Tests
  # ==========================================================================

  describe "success_response/2" do
    test "creates valid success response" do
      response = McpParser.success_response(1, %{"data" => "test"})

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["data"] == "test"
      refute Map.has_key?(response, "error")
    end
  end

  describe "error_response/3" do
    test "creates valid error response" do
      response = McpParser.error_response(1, -32600, "Invalid Request")

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == -32600
      assert response["error"]["message"] == "Invalid Request"
    end

    test "includes data when provided" do
      response = McpParser.error_response(1, -32000, "Error", %{details: "extra"})

      assert response["error"]["data"]["details"] == "extra"
    end
  end

  describe "encode_response/1" do
    test "encodes to JSON with newline" do
      response = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      encoded = McpParser.encode_response(response)

      assert String.ends_with?(encoded, "\n")
      assert {:ok, _} = Jason.decode(String.trim(encoded))
    end
  end

  # ==========================================================================
  # Request Building Tests
  # ==========================================================================

  describe "initialize_request/1" do
    test "builds valid initialize request" do
      request = McpParser.initialize_request(1)
      {:ok, parsed} = Jason.decode(String.trim(request))

      assert parsed["method"] == "initialize"
      assert parsed["id"] == 1
      assert parsed["params"]["protocolVersion"] == "2024-11-05"
    end
  end

  describe "tools_list_request/1" do
    test "builds valid tools/list request" do
      request = McpParser.tools_list_request(2)
      {:ok, parsed} = Jason.decode(String.trim(request))

      assert parsed["method"] == "tools/list"
      assert parsed["id"] == 2
    end
  end

  describe "tools_call_request/3" do
    test "builds valid tools/call request" do
      request = McpParser.tools_call_request("ask_mimo", %{"query" => "test"}, 5)
      {:ok, parsed} = Jason.decode(String.trim(request))

      assert parsed["method"] == "tools/call"
      assert parsed["params"]["name"] == "ask_mimo"
      assert parsed["params"]["arguments"]["query"] == "test"
      assert parsed["id"] == 5
    end
  end

  # ==========================================================================
  # Error Helper Tests
  # ==========================================================================

  describe "error codes" do
    test "parse_error_code returns -32700" do
      assert McpParser.parse_error_code() == -32700
    end

    test "invalid_request_code returns -32600" do
      assert McpParser.invalid_request_code() == -32600
    end

    test "method_not_found_code returns -32601" do
      assert McpParser.method_not_found_code() == -32601
    end

    test "internal_error_code returns -32603" do
      assert McpParser.internal_error_code() == -32603
    end

    test "tool_not_found_code returns -32000" do
      assert McpParser.tool_not_found_code() == -32000
    end
  end

  describe "error_for/3" do
    test "creates tool_not_found error" do
      error = McpParser.error_for(:tool_not_found, 1, "test_tool")

      assert error["error"]["code"] == -32000
      assert String.contains?(error["error"]["message"], "test_tool")
    end

    test "creates method_not_found error" do
      error = McpParser.error_for(:method_not_found, 1, "unknown/method")

      assert error["error"]["code"] == -32601
      assert String.contains?(error["error"]["message"], "unknown/method")
    end
  end
end
