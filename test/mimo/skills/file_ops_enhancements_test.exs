defmodule Mimo.Skills.FileOpsEnhancementsTest do
  @moduledoc """
  Tests for File operations enhancements from SPEC-027.
  Tests glob, multi_replace, and diff operations.
  """
  use ExUnit.Case, async: true

  alias Mimo.Skills.FileOps

  # Use workspace-relative path for sandbox compatibility
  @test_dir Path.expand("../../../_test_file_ops_#{:rand.uniform(100_000)}", __DIR__)

  setup do
    # Create test directory structure inside workspace
    File.mkdir_p!(@test_dir)
    File.mkdir_p!(Path.join(@test_dir, "src"))
    File.mkdir_p!(Path.join(@test_dir, "lib"))
    File.mkdir_p!(Path.join(@test_dir, "node_modules/pkg"))

    # Create test files
    File.write!(Path.join(@test_dir, "src/app.ts"), "const foo = 1;")
    File.write!(Path.join(@test_dir, "src/utils.ts"), "export function bar() {}")
    File.write!(Path.join(@test_dir, "lib/main.ex"), "defmodule Main do\nend")
    File.write!(Path.join(@test_dir, "lib/helper.ex"), "defmodule Helper do\nend")
    File.write!(Path.join(@test_dir, "node_modules/pkg/index.js"), "// pkg")

    # Create .gitignore
    File.write!(Path.join(@test_dir, ".gitignore"), """
    node_modules/
    *.log
    dist/
    """)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    {:ok, test_dir: @test_dir}
  end

  describe "glob/2" do
    test "finds files by pattern", %{test_dir: test_dir} do
      {:ok, result} = FileOps.glob("**/*.ex", base_path: test_dir)

      assert length(result.matches) == 2
      assert Enum.all?(result.matches, &String.ends_with?(&1, ".ex"))
    end

    test "finds TypeScript files", %{test_dir: test_dir} do
      {:ok, result} = FileOps.glob("**/*.ts", base_path: test_dir)

      assert length(result.matches) == 2
      assert "src/app.ts" in result.matches
      assert "src/utils.ts" in result.matches
    end

    test "respects exclude patterns", %{test_dir: test_dir} do
      {:ok, result} = FileOps.glob("**/*.js", base_path: test_dir, exclude: ["node_modules"])

      refute Enum.any?(result.matches, &String.contains?(&1, "node_modules"))
    end

    test "respects gitignore by default", %{test_dir: test_dir} do
      {:ok, result} = FileOps.glob("**/*.js", base_path: test_dir, respect_gitignore: true)

      refute Enum.any?(result.matches, &String.contains?(&1, "node_modules"))
    end

    test "ignores gitignore when disabled", %{test_dir: test_dir} do
      {:ok, result} = FileOps.glob("**/*.js", base_path: test_dir, respect_gitignore: false)

      # Should find the file in node_modules
      assert Enum.any?(result.matches, &String.contains?(&1, "node_modules"))
    end

    test "respects limit", %{test_dir: test_dir} do
      {:ok, result} = FileOps.glob("**/*", base_path: test_dir, limit: 2)

      assert length(result.matches) == 2
      assert result.truncated == true
    end

    test "returns metadata", %{test_dir: test_dir} do
      {:ok, result} = FileOps.glob("**/*.ex", base_path: test_dir)

      assert result.pattern == "**/*.ex"
      assert is_list(result.matches)
      assert is_integer(result.count)
      assert is_boolean(result.truncated)
    end
  end

  describe "multi_replace/2" do
    test "replaces in multiple files atomically", %{test_dir: test_dir} do
      file1 = Path.join(test_dir, "src/app.ts")
      file2 = Path.join(test_dir, "lib/main.ex")

      {:ok, result} =
        FileOps.multi_replace([
          %{path: file1, old: "foo", new: "baz"},
          %{path: file2, old: "Main", new: "MainModule"}
        ])

      assert result.status == "success"
      assert result.files_modified == 2

      assert File.read!(file1) =~ "baz"
      assert File.read!(file2) =~ "MainModule"
    end

    test "validates all files before changing any", %{test_dir: test_dir} do
      file1 = Path.join(test_dir, "src/app.ts")
      file2 = Path.join(test_dir, "lib/main.ex")

      # Save original content
      original1 = File.read!(file1)

      {:error, result} =
        FileOps.multi_replace([
          %{path: file1, old: "foo", new: "baz"},
          %{path: file2, old: "NOT_FOUND_PATTERN", new: "replacement"}
        ])

      assert result.status == "validation_failed"
      # file1 should be unchanged due to validation failure
      assert File.read!(file1) == original1
    end

    test "handles empty replacements list" do
      {:ok, result} = FileOps.multi_replace([])

      assert result.status == "success"
      assert result.files_modified == 0
    end

    test "supports global replacement", %{test_dir: test_dir} do
      file = Path.join(test_dir, "src/multi.ts")
      File.write!(file, "foo foo foo")

      {:ok, _result} =
        FileOps.multi_replace(
          [%{path: file, old: "foo", new: "bar"}],
          global: true
        )

      assert File.read!(file) == "bar bar bar"
    end
  end

  describe "diff/1" do
    test "shows diff between two files", %{test_dir: test_dir} do
      file1 = Path.join(test_dir, "old.txt")
      file2 = Path.join(test_dir, "new.txt")

      File.write!(file1, "line1\nline2\nline3")
      File.write!(file2, "line1\nmodified\nline3")

      {:ok, result} = FileOps.diff(path1: file1, path2: file2)

      assert result.diff =~ "line2"
      assert result.diff =~ "modified"
      assert result.summary.lines_before == 3
      assert result.summary.lines_after == 3
    end

    test "shows diff with proposed content", %{test_dir: test_dir} do
      file = Path.join(test_dir, "current.txt")
      File.write!(file, "original content")

      {:ok, result} = FileOps.diff(path: file, proposed_content: "new content")

      assert result.diff =~ "original"
      assert result.diff =~ "new"
    end

    test "returns error for missing parameters" do
      {:error, msg} = FileOps.diff([])

      assert msg =~ "path1+path2 or path+proposed_content"
    end

    test "returns error for non-existent file", %{test_dir: test_dir} do
      {:error, _} =
        FileOps.diff(
          path1: Path.join(test_dir, "nonexistent1.txt"),
          path2: Path.join(test_dir, "nonexistent2.txt")
        )
    end
  end
end
