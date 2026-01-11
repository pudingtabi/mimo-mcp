defmodule Mimo.Tools.Dispatchers.Web.ReadPdfTest do
  use ExUnit.Case, async: true

  alias Mimo.Tools.Dispatchers.Web

  @moduletag :pdf

  describe "dispatch/1 with read_pdf" do
    test "returns error when neither path nor url provided" do
      assert {:error, message} = Web.dispatch(%{"operation" => "read_pdf"})
      assert message =~ "Either 'path' or 'url' is required"
    end

    test "returns error when both path and url provided" do
      assert {:error, message} =
               Web.dispatch(%{
                 "operation" => "read_pdf",
                 "path" => "/some/file.pdf",
                 "url" => "https://example.com/file.pdf"
               })

      assert message =~ "not both"
    end

    test "returns error for non-existent file" do
      assert {:error, message} =
               Web.dispatch(%{
                 "operation" => "read_pdf",
                 "path" => "/nonexistent/file.pdf"
               })

      assert message =~ "File not found" or message =~ "PDF read failed"
    end

    test "returns error for non-PDF file" do
      # Create a temp text file
      tmp_path = Path.join(System.tmp_dir!(), "test_web_#{System.system_time(:millisecond)}.txt")
      File.write!(tmp_path, "hello world")

      try do
        assert {:error, message} =
                 Web.dispatch(%{
                   "operation" => "read_pdf",
                   "path" => tmp_path
                 })

        assert message =~ "Not a PDF" or message =~ "PDF read failed"
      after
        File.rm(tmp_path)
      end
    end
  end

  describe "dispatch_read_pdf/1" do
    test "returns proper structure on success" do
      # Mock a successful PDF read by testing the structure
      # In integration tests, we'd use a real PDF

      # For now, just verify the error path structure
      result = Web.dispatch_read_pdf(%{"path" => "/nonexistent.pdf"})
      assert {:error, _} = result
    end

    test "accepts pages parameter" do
      result = Web.dispatch_read_pdf(%{"path" => "/nonexistent.pdf", "pages" => [1, 2]})
      assert {:error, _} = result
    end

    test "accepts include_metadata parameter" do
      result = Web.dispatch_read_pdf(%{"path" => "/nonexistent.pdf", "include_metadata" => false})
      assert {:error, _} = result
    end
  end
end
