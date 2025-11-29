defmodule Mimo.IngestTest do
  @moduledoc """
  Tests for Mimo.Ingest module.
  Tests file ingestion with various chunking strategies.
  """
  use Mimo.DataCase, async: false

  alias Mimo.Ingest
  alias Mimo.Brain.Engram
  alias Mimo.Repo

  @test_dir Path.join(System.tmp_dir!(), "mimo_ingest_test")

  setup do
    # Create test directory
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  describe "ingest_file/2 - paragraphs strategy" do
    test "ingests text file with paragraph splitting" do
      content = """
      This is the first paragraph.
      It has multiple lines.

      This is the second paragraph.
      Also has multiple lines.

      And a third paragraph here.
      """

      path = Path.join(@test_dir, "test.txt")
      File.write!(path, content)

      {:ok, result} = Ingest.ingest_file(path, strategy: :paragraphs)

      assert result.chunks_created == 3
      assert result.strategy_used == :paragraphs
      assert length(result.ids) == 3
      assert result.source_file == path
    end

    test "filters out tiny chunks" do
      content = """
      Good paragraph with content.

      x

      Another good paragraph.
      """

      path = Path.join(@test_dir, "small_chunks.txt")
      File.write!(path, content)

      {:ok, result} = Ingest.ingest_file(path, strategy: :paragraphs)

      # Should skip the single "x" chunk
      assert result.chunks_created == 2
    end
  end

  describe "ingest_file/2 - markdown strategy" do
    test "ingests markdown file with header splitting" do
      content = """
      # Introduction

      This is the intro section.

      ## Section One

      Content for section one.

      ## Section Two

      Content for section two.
      """

      path = Path.join(@test_dir, "test.md")
      File.write!(path, content)

      {:ok, result} = Ingest.ingest_file(path, strategy: :markdown)

      assert result.chunks_created >= 3
      assert result.strategy_used == :markdown
    end

    test "auto-detects markdown from extension" do
      content = "# Header\n\nContent here.\n\n## Another\n\nMore content."
      path = Path.join(@test_dir, "auto.md")
      File.write!(path, content)

      {:ok, result} = Ingest.ingest_file(path, strategy: :auto)

      assert result.strategy_used == :markdown
    end
  end

  describe "ingest_file/2 - whole strategy" do
    test "stores entire file as one memory" do
      content = "This is a small JSON config file content."
      path = Path.join(@test_dir, "config.json")
      File.write!(path, content)

      {:ok, result} = Ingest.ingest_file(path, strategy: :whole)

      assert result.chunks_created == 1
      assert result.strategy_used == :whole
    end
  end

  describe "ingest_file/2 - with options" do
    test "applies category and importance to chunks" do
      content = "Test content paragraph one.\n\nTest content paragraph two."
      path = Path.join(@test_dir, "opts_test.txt")
      File.write!(path, content)

      {:ok, result} = Ingest.ingest_file(path,
        category: "observation",
        importance: 0.9
      )

      assert result.chunks_created == 2

      # Verify stored engrams have correct metadata
      engram = Repo.get(Engram, hd(result.ids))
      assert engram.category == "observation"
      assert engram.importance == 0.9
    end

    test "applies tags to chunks" do
      content = "Tagged content here."
      path = Path.join(@test_dir, "tagged.txt")
      File.write!(path, content)

      {:ok, result} = Ingest.ingest_file(path,
        tags: ["test", "ingestion"]
      )

      engram = Repo.get(Engram, hd(result.ids))
      assert engram.metadata["tags"] == ["test", "ingestion"]
    end
  end

  describe "ingest_file/2 - error cases" do
    test "returns error for non-existent file" do
      {:error, reason} = Ingest.ingest_file("/nonexistent/path.txt")
      assert reason == {:file_error, :enoent}
    end

    test "returns error for directory" do
      {:error, {:not_a_file, :directory}} = Ingest.ingest_file(@test_dir)
    end

    @tag :skip
    test "returns error for file too large" do
      # This test would require creating a 10MB+ file
      # Skipped for performance reasons
    end
  end

  describe "ingest_file/2 - sandbox" do
    setup do
      # Set sandbox directory
      old_sandbox = System.get_env("SANDBOX_DIR")
      System.put_env("SANDBOX_DIR", @test_dir)

      on_exit(fn ->
        if old_sandbox do
          System.put_env("SANDBOX_DIR", old_sandbox)
        else
          System.delete_env("SANDBOX_DIR")
        end
      end)

      :ok
    end

    test "allows files within sandbox" do
      content = "Sandbox content."
      path = Path.join(@test_dir, "sandbox_test.txt")
      File.write!(path, content)

      {:ok, _result} = Ingest.ingest_file(path)
    end

    test "rejects files outside sandbox" do
      {:error, reason} = Ingest.ingest_file("/etc/passwd")
      assert is_binary(reason)
      assert reason =~ "outside sandbox"
    end
  end

  describe "ingest_text/2" do
    test "ingests text directly without file" do
      content = "Direct text paragraph one.\n\nDirect text paragraph two."

      {:ok, result} = Ingest.ingest_text(content, strategy: :paragraphs)

      assert result.chunks_created == 2
      assert result.strategy_used == :paragraphs
    end

    test "applies options to direct text" do
      content = "Direct text content."

      {:ok, result} = Ingest.ingest_text(content,
        category: "plan",
        importance: 0.8
      )

      engram = Repo.get(Engram, hd(result.ids))
      assert engram.category == "plan"
      assert engram.importance == 0.8
    end
  end

  describe "strategy detection" do
    test "detects .txt as paragraphs" do
      File.write!(Path.join(@test_dir, "test.txt"), "Content")
      {:ok, result} = Ingest.ingest_file(Path.join(@test_dir, "test.txt"))
      assert result.strategy_used == :paragraphs
    end

    test "detects .md as markdown" do
      File.write!(Path.join(@test_dir, "test.md"), "# Header\nContent")
      {:ok, result} = Ingest.ingest_file(Path.join(@test_dir, "test.md"))
      assert result.strategy_used == :markdown
    end

    test "detects .json as whole" do
      File.write!(Path.join(@test_dir, "test.json"), "{\"key\": \"value\"}")
      {:ok, result} = Ingest.ingest_file(Path.join(@test_dir, "test.json"))
      assert result.strategy_used == :whole
    end

    test "detects .yaml as whole" do
      File.write!(Path.join(@test_dir, "test.yaml"), "key: value")
      {:ok, result} = Ingest.ingest_file(Path.join(@test_dir, "test.yaml"))
      assert result.strategy_used == :whole
    end
  end
end
