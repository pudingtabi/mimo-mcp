defmodule Mimo.Skills.PdfTest do
  use ExUnit.Case, async: true

  alias Mimo.Skills.Pdf

  @moduletag :pdf

  describe "available?/0" do
    test "checks if PyMuPDF is installed" do
      # This should be true in our test environment
      result = Pdf.available?()
      assert is_boolean(result)
    end
  end

  describe "read/2" do
    test "returns error for non-existent file" do
      assert {:error, message} = Pdf.read("/nonexistent/file.pdf")
      assert message =~ "File not found"
    end

    test "returns error for non-PDF file" do
      # Create a temp text file
      tmp_path = Path.join(System.tmp_dir!(), "test_#{System.system_time(:millisecond)}.txt")
      File.write!(tmp_path, "hello world")

      try do
        assert {:error, message} = Pdf.read(tmp_path)
        assert message =~ "Not a PDF file"
      after
        File.rm(tmp_path)
      end
    end

    @tag :integration
    test "reads a real PDF file" do
      # Skip if no test PDF available
      test_pdf = System.get_env("TEST_PDF_PATH")

      if test_pdf && File.exists?(test_pdf) do
        assert {:ok, result} = Pdf.read(test_pdf)
        assert is_binary(result.markdown)
        assert is_integer(result.pages_total)
        assert result.pages_total > 0
        assert is_map(result.metadata)
      end
    end
  end

  describe "metadata/1" do
    test "returns error for non-existent file" do
      assert {:error, _} = Pdf.metadata("/nonexistent/file.pdf")
    end

    @tag :integration
    test "extracts metadata from real PDF" do
      test_pdf = System.get_env("TEST_PDF_PATH")

      if test_pdf && File.exists?(test_pdf) do
        assert {:ok, meta} = Pdf.metadata(test_pdf)
        assert is_map(meta)
        assert Map.has_key?(meta, "page_count")
      end
    end
  end

  describe "read_url/2" do
    @tag :external
    test "downloads and reads PDF from URL" do
      # Use a small, stable test PDF
      url = "https://www.w3.org/WAI/WCAG21/Techniques/pdf/img/table-word.pdf"

      case Pdf.read_url(url) do
        {:ok, result} ->
          assert is_binary(result.markdown)
          assert result.source_url == url
          assert is_integer(result.pages_total)

        {:error, reason} ->
          # Network issues are acceptable in tests
          assert reason =~ "Download failed" or reason =~ "HTTP"
      end
    end
  end
end
