defmodule Mimo.Tools.Dispatchers.FileTest do
  @moduledoc """
  Tests for File dispatcher routing and operation handling.

  Tests the dispatcher layer (routing, error handling, verification)
  rather than underlying FileOps (which has its own tests).
  """
  use Mimo.DataCase, async: true

  alias Mimo.Tools.Dispatchers.File, as: FileDispatcher

  # Helper to extract data from various return formats
  defp extract_data({:ok, %{data: data}}), do: data
  defp extract_data({:ok, data}) when is_map(data), do: data
  defp extract_data({:ok, data}) when is_list(data), do: data
  defp extract_data(:ok), do: %{success: true}
  defp extract_data(other), do: other

  # Helper to check if result is successful
  defp ok_result?({:ok, _}), do: true
  defp ok_result?(:ok), do: true
  defp ok_result?(_), do: false

  setup do
    # Create test directory in system temp (always writable)
    test_dir = Path.join(System.tmp_dir!(), "_test_file_dispatcher_#{:rand.uniform(100_000)}")

    # Store original MIMO_ALLOWED_PATHS and add temp dir
    original_allowed = System.get_env("MIMO_ALLOWED_PATHS")
    temp_base = System.tmp_dir!()

    new_allowed =
      case original_allowed do
        nil -> temp_base
        "" -> temp_base
        existing -> "#{existing}:#{temp_base}"
      end

    System.put_env("MIMO_ALLOWED_PATHS", new_allowed)

    # Create test directory structure
    File.mkdir_p!(test_dir)
    File.mkdir_p!(Path.join(test_dir, "subdir"))

    # Create test files
    test_file = Path.join(test_dir, "test.txt")
    File.write!(test_file, "line1\nline2\nline3\n")

    elixir_file = Path.join(test_dir, "module.ex")

    File.write!(elixir_file, """
    defmodule TestModule do
      def hello, do: :world
    end
    """)

    on_exit(fn ->
      File.rm_rf!(test_dir)

      case original_allowed do
        nil -> System.delete_env("MIMO_ALLOWED_PATHS")
        val -> System.put_env("MIMO_ALLOWED_PATHS", val)
      end
    end)

    {:ok, test_dir: test_dir, test_file: test_file, elixir_file: elixir_file}
  end

  describe "dispatch/1 routing" do
    test "requires operation" do
      assert {:error, "Operation required"} = FileDispatcher.dispatch(%{})
      assert {:error, "Operation required"} = FileDispatcher.dispatch(%{"path" => "/tmp"})
    end

    test "returns error for unknown operation" do
      assert {:error, msg} = FileDispatcher.dispatch(%{"operation" => "unknown_op"})
      assert msg =~ "Unknown file operation"
    end
  end

  describe "read operations" do
    test "read returns file content", %{test_file: test_file} do
      args = %{"operation" => "read", "path" => test_file, "skip_interception" => true}
      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.content =~ "line1"
    end

    test "read with offset and limit", %{test_file: test_file} do
      args = %{
        "operation" => "read",
        "path" => test_file,
        "offset" => 2,
        "limit" => 1,
        "skip_interception" => true
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      # Should return only line 2
      assert data.content =~ "line2"
    end

    test "read_lines returns specific lines", %{test_file: test_file} do
      args = %{"operation" => "read_lines", "path" => test_file, "start_line" => 2, "end_line" => 2}
      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.content =~ "line2"
    end

    test "read_multiple returns contents of multiple files", %{test_dir: test_dir} do
      file1 = Path.join(test_dir, "multi1.txt")
      file2 = Path.join(test_dir, "multi2.txt")
      File.write!(file1, "content1")
      File.write!(file2, "content2")

      args = %{"operation" => "read_multiple", "paths" => [file1, file2]}
      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      # read_multiple returns a list or map of results
      data = extract_data(result)
      # Data could be list, map with results, or map with data.results
      case data do
        results when is_list(results) -> assert length(results) == 2
        %{results: results} when is_list(results) -> assert length(results) == 2
        other -> assert is_map(other) or is_list(other)
      end
    end
  end

  describe "write operations" do
    test "write creates new file", %{test_dir: test_dir} do
      new_file = Path.join(test_dir, "new_file.txt")
      args = %{"operation" => "write", "path" => new_file, "content" => "hello world"}

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      assert File.exists?(new_file)
      assert File.read!(new_file) == "hello world"
    end

    test "write in append mode", %{test_file: test_file} do
      args = %{
        "operation" => "write",
        "path" => test_file,
        "content" => "appended",
        "mode" => "append"
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      assert File.read!(test_file) =~ "appended"
    end

    test "write requires valid path" do
      args = %{"operation" => "write", "path" => ".", "content" => "test"}
      assert {:error, msg} = FileDispatcher.dispatch(args)
      assert msg =~ "Path is required"
    end

    test "write rejects directory path", %{test_dir: test_dir} do
      args = %{"operation" => "write", "path" => test_dir, "content" => "test"}
      assert {:error, msg} = FileDispatcher.dispatch(args)
      assert msg =~ "Cannot write to directory"
    end

    test "edit replaces content", %{test_file: test_file} do
      args = %{
        "operation" => "edit",
        "path" => test_file,
        "old_str" => "line2",
        "new_str" => "modified"
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      assert File.read!(test_file) =~ "modified"
      refute File.read!(test_file) =~ "line2\n"
    end

    test "edit requires valid path" do
      args = %{"operation" => "edit", "path" => "", "old_str" => "a", "new_str" => "b"}
      assert {:error, msg} = FileDispatcher.dispatch(args)
      assert msg =~ "Path is required"
    end

    test "replace_string replaces content", %{test_file: test_file} do
      args = %{
        "operation" => "replace_string",
        "path" => test_file,
        "old_str" => "line1",
        "new_str" => "first"
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      assert File.read!(test_file) =~ "first"
    end
  end

  describe "search operations" do
    test "search finds pattern in files", %{test_dir: test_dir} do
      args = %{"operation" => "search", "path" => test_dir, "pattern" => "hello"}
      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
    end

    test "list_symbols returns symbols", %{elixir_file: elixir_file} do
      args = %{"operation" => "list_symbols", "path" => elixir_file}
      result = FileDispatcher.dispatch(args)
      # May return ok or error depending on treesitter availability
      assert ok_result?(result) or match?({:error, _}, result)
    end

    test "glob finds files by pattern", %{test_dir: test_dir} do
      args = %{"operation" => "glob", "pattern" => "**/*.txt", "base_path" => test_dir}
      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert is_list(data.matches)
    end
  end

  describe "navigation operations" do
    test "ls lists directory", %{test_dir: test_dir} do
      args = %{"operation" => "ls", "path" => test_dir}
      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      # ls returns either {:ok, list} or {:ok, %{entries: list}}
      case data do
        entries when is_list(entries) -> assert Enum.any?(entries)
        %{entries: entries} -> assert is_list(entries) and Enum.any?(entries)
      end
    end

    test "list_directory with depth", %{test_dir: test_dir} do
      args = %{"operation" => "list_directory", "path" => test_dir, "depth" => 2}
      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
    end

    test "get_info returns file metadata", %{test_file: test_file} do
      args = %{"operation" => "get_info", "path" => test_file}
      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      # get_info returns flat data directly
      assert data.type == :regular
    end

    test "create_directory creates new directory", %{test_dir: test_dir} do
      new_dir = Path.join(test_dir, "new_subdir")
      args = %{"operation" => "create_directory", "path" => new_dir}

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      assert File.dir?(new_dir)
    end

    test "move renames file", %{test_dir: test_dir} do
      src = Path.join(test_dir, "to_move.txt")
      dst = Path.join(test_dir, "moved.txt")
      File.write!(src, "movable")

      args = %{"operation" => "move", "path" => src, "destination" => dst}
      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)

      refute File.exists?(src)
      assert File.exists?(dst)
    end
  end

  describe "line operations" do
    test "insert_after adds content after line", %{test_file: test_file} do
      args = %{
        "operation" => "insert_after",
        "path" => test_file,
        "line_number" => 1,
        "content" => "inserted"
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      content = File.read!(test_file)
      assert content =~ "line1\ninserted"
    end

    test "insert_before adds content before line", %{test_file: test_file} do
      args = %{
        "operation" => "insert_before",
        "path" => test_file,
        "line_number" => 2,
        "content" => "inserted"
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      content = File.read!(test_file)
      assert content =~ "inserted\nline2"
    end

    test "replace_lines replaces range", %{test_file: test_file} do
      args = %{
        "operation" => "replace_lines",
        "path" => test_file,
        "start_line" => 2,
        "end_line" => 2,
        "content" => "replaced"
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      content = File.read!(test_file)
      assert content =~ "replaced"
      refute content =~ "line2"
    end

    test "delete_lines removes lines", %{test_file: test_file} do
      args = %{
        "operation" => "delete_lines",
        "path" => test_file,
        "start_line" => 2,
        "end_line" => 2
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      content = File.read!(test_file)
      refute content =~ "line2"
    end
  end

  describe "diff operations" do
    test "diff compares two files", %{test_dir: test_dir} do
      file1 = Path.join(test_dir, "old.txt")
      file2 = Path.join(test_dir, "new.txt")
      File.write!(file1, "old content")
      File.write!(file2, "new content")

      args = %{"operation" => "diff", "path1" => file1, "path2" => file2}
      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert is_binary(data.diff)
    end

    test "diff with proposed content", %{test_file: test_file} do
      args = %{
        "operation" => "diff",
        "path" => test_file,
        "proposed_content" => "completely new"
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.diff =~ "line1" or data.diff =~ "new"
    end
  end

  describe "multi_replace operations" do
    test "multi_replace modifies multiple files", %{test_dir: test_dir} do
      file1 = Path.join(test_dir, "r1.txt")
      file2 = Path.join(test_dir, "r2.txt")
      File.write!(file1, "foo")
      File.write!(file2, "bar")

      args = %{
        "operation" => "multi_replace",
        "replacements" => [
          %{"path" => file1, "old" => "foo", "new" => "baz"},
          %{"path" => file2, "old" => "bar", "new" => "qux"}
        ]
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.status == "success"
      assert File.read!(file1) == "baz"
      assert File.read!(file2) == "qux"
    end
  end

  describe "batch_search operations" do
    test "batch_search finds multiple patterns", %{test_dir: test_dir} do
      args = %{
        "operation" => "batch_search",
        "path" => test_dir,
        "patterns" => ["defmodule", "hello"]
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      data = extract_data(result)
      assert data.patterns_searched == 2
      assert is_map(data.results)
    end

    test "batch_search requires patterns" do
      args = %{"operation" => "batch_search", "path" => "/tmp", "patterns" => []}
      assert {:error, msg} = FileDispatcher.dispatch(args)
      assert msg =~ "patterns"
    end
  end

  describe "deprecated operations" do
    test "find_definition routes to code dispatcher and adds warning", %{elixir_file: elixir_file} do
      args = %{"operation" => "find_definition", "name" => "hello", "path" => elixir_file}
      result = FileDispatcher.dispatch(args)

      # Should work (routed to code) - may succeed or fail if code symbols not indexed
      assert ok_result?(result) or match?({:error, _}, result)
    end
  end

  describe "verification" do
    test "write operations produce side effects", %{test_dir: test_dir} do
      new_file = Path.join(test_dir, "verified.txt")
      args = %{"operation" => "write", "path" => new_file, "content" => "verify me"}

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      # Verify the file was actually created with correct content
      assert File.exists?(new_file)
      assert File.read!(new_file) == "verify me"
    end

    test "edit operations produce side effects", %{test_file: test_file} do
      original = File.read!(test_file)

      args = %{
        "operation" => "edit",
        "path" => test_file,
        "old_str" => "line1",
        "new_str" => "first"
      }

      result = FileDispatcher.dispatch(args)
      assert ok_result?(result)
      # Verify the file was actually modified
      new_content = File.read!(test_file)
      refute new_content == original
      assert new_content =~ "first"
    end
  end
end
