defmodule Mimo.Skills.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Mimo.Skills.Diagnostics

  # Use workspace-relative paths for sandbox compatibility
  @test_dir Path.expand("../../../_test_diagnostics_#{:rand.uniform(100_000)}", __DIR__)

  setup do
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    {:ok, test_dir: @test_dir}
  end

  describe "check/2" do
    test "returns diagnostics for valid Elixir file", %{test_dir: test_dir} do
      # Create a valid Elixir file
      path = Path.join(test_dir, "valid_module.ex")

      File.write!(path, """
      defmodule ValidModule do
        def foo, do: :ok
      end
      """)

      {:ok, result} = Diagnostics.check(path, operation: :check)

      assert result.language == :elixir
      assert is_list(result.diagnostics)
    end

    test "auto-detects language from file extension", %{test_dir: test_dir} do
      # Test Elixir
      ex_path = Path.join(test_dir, "test.ex")
      File.write!(ex_path, "defmodule Test do end")
      {:ok, result} = Diagnostics.check(ex_path)
      assert result.language == :elixir

      # Test TypeScript
      ts_path = Path.join(test_dir, "test.ts")
      File.write!(ts_path, "const x = 1;")
      {:ok, result} = Diagnostics.check(ts_path)
      assert result.language == :typescript

      # Test Python
      py_path = Path.join(test_dir, "test.py")
      File.write!(py_path, "x = 1")
      {:ok, result} = Diagnostics.check(py_path)
      assert result.language == :python

      # Test Rust
      rs_path = Path.join(test_dir, "test.rs")
      File.write!(rs_path, "fn main() {}")
      {:ok, result} = Diagnostics.check(rs_path)
      assert result.language == :rust
    end

    test "returns unknown language for unsupported files", %{test_dir: test_dir} do
      path = Path.join(test_dir, "test.xyz")
      File.write!(path, "unknown content")
      {:ok, result} = Diagnostics.check(path)
      assert result.language == :unknown
      assert result.message =~ "Could not detect language"
    end

    test "returns counts by severity", %{test_dir: test_dir} do
      path = Path.join(test_dir, "test_counts.ex")
      File.write!(path, "defmodule Test do end")
      {:ok, result} = Diagnostics.check(path)

      assert is_integer(result.error_count)
      assert is_integer(result.warning_count)
      assert is_integer(result.info_count)
    end
  end

  describe "operations" do
    test "check operation runs compiler", %{test_dir: test_dir} do
      path = Path.join(test_dir, "check_op.ex")
      File.write!(path, "defmodule CheckOp do\n  def foo, do: :ok\nend")

      {:ok, result} = Diagnostics.check(path, operation: :check)

      assert result.language == :elixir
      assert is_list(result.diagnostics)
    end

    test "lint operation runs linter", %{test_dir: test_dir} do
      path = Path.join(test_dir, "lint_op.ex")
      File.write!(path, "defmodule LintOp do\n  def foo, do: :ok\nend")

      {:ok, result} = Diagnostics.check(path, operation: :lint)

      assert result.language == :elixir
      assert is_list(result.diagnostics)
    end

    test "all operation runs all diagnostics", %{test_dir: test_dir} do
      path = Path.join(test_dir, "all_op.ex")
      File.write!(path, "defmodule AllOp do\n  def foo, do: :ok\nend")

      {:ok, result} = Diagnostics.check(path, operation: :all)

      assert result.language == :elixir
      assert is_list(result.diagnostics)
    end
  end

  describe "result format" do
    test "diagnostics have required fields when present", %{test_dir: test_dir} do
      # Create file with unused variable to generate warning
      path = Path.join(test_dir, "format_test.ex")

      File.write!(path, """
      defmodule FormatTest do
        def foo do
          x = 1
          :ok
        end
      end
      """)

      {:ok, result} = Diagnostics.check(path, operation: :check)

      for diagnostic <- result.diagnostics do
        assert Map.has_key?(diagnostic, :file)
        assert Map.has_key?(diagnostic, :line)
        assert Map.has_key?(diagnostic, :column)
        assert Map.has_key?(diagnostic, :severity)
        assert Map.has_key?(diagnostic, :message)
        assert Map.has_key?(diagnostic, :source)
        assert diagnostic.severity in [:error, :warning, :info]
      end
    end

    test "result includes path and language", %{test_dir: test_dir} do
      path = Path.join(test_dir, "result_format.py")
      File.write!(path, "x = 1")
      {:ok, result} = Diagnostics.check(path)

      assert Map.has_key?(result, :path)
      assert Map.has_key?(result, :language)
      assert Map.has_key?(result, :diagnostics)
      assert Map.has_key?(result, :error_count)
      assert Map.has_key?(result, :warning_count)
      assert Map.has_key?(result, :info_count)
    end
  end
end
