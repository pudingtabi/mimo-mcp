defmodule Mimo.Library.AutoDiscoveryTest do
  use ExUnit.Case, async: true

  alias Mimo.Library.AutoDiscovery
  alias Mimo.Library.ImportWatcher

  # Use workspace-relative paths
  @test_dir Path.expand("../../../_test_autodiscovery_#{:rand.uniform(100_000)}", __DIR__)

  setup do
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    {:ok, test_dir: @test_dir}
  end

  describe "detect_ecosystems/1" do
    test "detects Elixir ecosystem from mix.exs" do
      # Use the actual project directory
      ecosystems = AutoDiscovery.detect_ecosystems(File.cwd!())
      assert :hex in ecosystems
    end

    test "returns empty list for non-existent path" do
      ecosystems = AutoDiscovery.detect_ecosystems("/nonexistent/path")
      assert ecosystems == []
    end

    test "detects multiple ecosystems", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "mix.exs"), "defp deps do [] end")
      File.write!(Path.join(test_dir, "package.json"), "{}")

      ecosystems = AutoDiscovery.detect_ecosystems(test_dir)

      assert :hex in ecosystems
      assert :npm in ecosystems
    end
  end

  describe "extract_dependencies/2" do
    test "extracts Elixir dependencies from mix.exs" do
      deps = AutoDiscovery.extract_dependencies(File.cwd!(), :hex)

      # The mimo-mcp project has dependencies
      dep_names = Enum.map(deps, fn {name, _} -> name end)

      refute Enum.empty?(dep_names)
    end

    test "parses mix.exs dependency format", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "mix.exs"), """
      defmodule Test.MixProject do
        defp deps do
          [
            {:phoenix, "~> 1.7"},
            {:ecto, ">= 3.0.0"},
            {:jason, "~> 1.4", only: :dev}
          ]
        end
      end
      """)

      deps = AutoDiscovery.extract_dependencies(test_dir, :hex)
      dep_names = Enum.map(deps, fn {name, _} -> name end)

      assert "phoenix" in dep_names
      assert "ecto" in dep_names
      assert "jason" in dep_names
    end

    test "parses package.json dependencies", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "package.json"), """
      {
        "dependencies": {
          "express": "^4.18.0",
          "lodash": "~4.17.0"
        },
        "devDependencies": {
          "jest": "^29.0.0"
        }
      }
      """)

      deps = AutoDiscovery.extract_dependencies(test_dir, :npm)
      dep_names = Enum.map(deps, fn {name, _} -> name end)

      assert "express" in dep_names
      assert "lodash" in dep_names
      assert "jest" in dep_names
    end

    test "parses requirements.txt", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "requirements.txt"), """
      requests==2.28.0
      flask>=2.0.0
      numpy
      # comment line
      -r other-requirements.txt
      """)

      deps = AutoDiscovery.extract_dependencies(test_dir, :pypi)
      dep_names = Enum.map(deps, fn {name, _} -> name end)

      assert "requests" in dep_names
      assert "flask" in dep_names
      assert "numpy" in dep_names
    end

    test "parses Cargo.toml dependencies", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "Cargo.toml"), """
      [dependencies]
      serde = "1.0"
      tokio = { version = "1.0", features = ["full"] }
      """)

      deps = AutoDiscovery.extract_dependencies(test_dir, :crates)
      dep_names = Enum.map(deps, fn {name, _} -> name end)

      assert "serde" in dep_names
      assert "tokio" in dep_names
    end

    test "returns empty list for missing project file" do
      deps = AutoDiscovery.extract_dependencies("/nonexistent", :hex)
      assert deps == []
    end
  end

  describe "discover_and_cache/1" do
    test "discovers dependencies from current project" do
      {:ok, result} = AutoDiscovery.discover_and_cache(File.cwd!())

      assert :hex in result.ecosystems
      assert result.total_dependencies > 0
    end

    test "returns error for non-directory path" do
      {:error, message} = AutoDiscovery.discover_and_cache("/nonexistent/file.ex")
      assert message =~ "not a directory"
    end
  end

  describe "ImportWatcher.extract_imports/2" do
    test "extracts Elixir imports" do
      code = """
      defmodule Test do
        import Enum
        alias Phoenix.Controller
        require Logger
        use GenServer
      end
      """

      imports = ImportWatcher.extract_imports(code, :elixir)

      # Should extract module names
      refute Enum.empty?(imports)
    end

    test "extracts Python imports" do
      code = """
      import requests
      from flask import Flask
      import numpy as np
      """

      imports = ImportWatcher.extract_imports(code, :python)

      assert "requests" in imports
      assert "flask" in imports
      assert "numpy" in imports
    end

    test "extracts JavaScript imports" do
      code = """
      import express from 'express';
      import { useState } from 'react';
      const lodash = require('lodash');
      """

      imports = ImportWatcher.extract_imports(code, :javascript)

      assert "express" in imports
      assert "react" in imports
      assert "lodash" in imports
    end

    test "ignores relative imports in JavaScript" do
      code = """
      import foo from './foo';
      import bar from '../bar';
      import express from 'express';
      """

      imports = ImportWatcher.extract_imports(code, :javascript)

      refute "./foo" in imports
      refute "../bar" in imports
      assert "express" in imports
    end

    test "handles scoped npm packages" do
      code = """
      import { something } from '@org/package';
      import other from '@scope/other-pkg';
      """

      imports = ImportWatcher.extract_imports(code, :javascript)

      assert "@org/package" in imports
      assert "@scope/other-pkg" in imports
    end
  end

  describe "ImportWatcher.language_to_ecosystem/1" do
    test "maps languages to ecosystems" do
      assert ImportWatcher.language_to_ecosystem(:elixir) == :hex
      assert ImportWatcher.language_to_ecosystem(:python) == :pypi
      assert ImportWatcher.language_to_ecosystem(:javascript) == :npm
      assert ImportWatcher.language_to_ecosystem(:typescript) == :npm
      assert ImportWatcher.language_to_ecosystem(:rust) == :crates
      assert ImportWatcher.language_to_ecosystem(:unknown) == nil
    end
  end
end
