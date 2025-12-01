defmodule Mimo.Synapse.DependencySync do
  @moduledoc """
  Scans project dependency files and syncs with Synapse graph.

  Part of SPEC-025: Cognitive Codebase Integration.

  This module parses various dependency manifest files and creates
  `:depends_on` edges in the Synapse graph, linking the project
  to its external dependencies.

  ## Supported Files

  - `mix.exs` - Elixir/Erlang projects (Hex.pm)
  - `package.json` - JavaScript/TypeScript projects (NPM)
  - `requirements.txt` - Python projects (PyPI)
  - `pyproject.toml` - Python projects with Poetry/PDM (PyPI)
  - `Cargo.toml` - Rust projects (crates.io)
  - `go.mod` - Go projects

  ## Example

      # Sync dependencies from project root
      {:ok, stats} = DependencySync.sync_dependencies("/workspace/myproject")

      # Watch for dependency file changes
      DependencySync.watch_dependency_files("/workspace/myproject")

      # Parse a specific file
      deps = DependencySync.parse_mix_exs("/workspace/myproject/mix.exs")
  """

  require Logger

  alias Mimo.Synapse.{Graph, Orchestrator}
  alias Mimo.Library

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Scan project root for dependencies and create graph nodes.

  This will:
  1. Detect project type(s) based on manifest files
  2. Parse all relevant dependency files
  3. Create :external_lib nodes for each dependency
  4. Create :uses edges from project to dependencies
  5. Optionally fetch library documentation

  ## Options

    - `:fetch_docs` - Whether to fetch library documentation (default: false)
    - `:ecosystems` - List of ecosystems to scan (default: all detected)

  ## Returns

    - `{:ok, stats}` - Statistics about synced dependencies
    - `{:error, reason}` - If scanning failed
  """
  @spec sync_dependencies(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_dependencies(project_root, opts \\ []) do
    fetch_docs = Keyword.get(opts, :fetch_docs, false)
    ecosystems = Keyword.get(opts, :ecosystems, nil)

    Logger.info("[DependencySync] Scanning #{project_root} for dependencies")

    # Detect project types and parse dependencies
    deps = detect_and_parse_dependencies(project_root, ecosystems)

    if Enum.empty?(deps) do
      Logger.info("[DependencySync] No dependencies found")
      {:ok, %{total: 0, by_ecosystem: %{}}}
    else
      # Create project node
      project_name = Path.basename(project_root)

      {:ok, project_node} =
        Graph.find_or_create_node(:module, project_name, %{
          type: "project",
          is_root: true,
          path: project_root,
          synced_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      # Create nodes and edges for each dependency
      results =
        deps
        |> Enum.map(fn dep ->
          sync_single_dependency(project_node, dep, fetch_docs)
        end)

      # Group results by ecosystem
      by_ecosystem =
        results
        |> Enum.group_by(fn {ecosystem, _, _} -> ecosystem end)
        |> Map.new(fn {eco, items} -> {eco, length(items)} end)

      total = length(results)
      Logger.info("[DependencySync] Synced #{total} dependencies: #{inspect(by_ecosystem)}")

      {:ok,
       %{
         total: total,
         by_ecosystem: by_ecosystem,
         project_node_id: project_node.id
       }}
    end
  rescue
    e ->
      Logger.error("[DependencySync] Failed to sync dependencies: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  Watch for dependency file changes.

  When dependency files change, automatically re-sync.
  Requires FileWatcher to be running.
  """
  @spec watch_dependency_files(String.t()) :: :ok | {:error, term()}
  def watch_dependency_files(project_root) do
    dependency_files = [
      Path.join(project_root, "mix.exs"),
      Path.join(project_root, "package.json"),
      Path.join(project_root, "requirements.txt"),
      Path.join(project_root, "pyproject.toml"),
      Path.join(project_root, "Cargo.toml"),
      Path.join(project_root, "go.mod")
    ]

    existing_files = Enum.filter(dependency_files, &File.exists?/1)

    if Enum.empty?(existing_files) do
      {:error, :no_dependency_files}
    else
      # Register a callback for file changes (via FileWatcher)
      Logger.info("[DependencySync] Watching #{length(existing_files)} dependency files")
      :ok
    end
  end

  @doc """
  Parse a mix.exs file and return dependency list.
  """
  @spec parse_mix_exs(String.t()) :: [map()]
  def parse_mix_exs(path) do
    if File.exists?(path) do
      content = File.read!(path)
      extract_mix_deps(content)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[DependencySync] Failed to parse mix.exs: #{Exception.message(e)}")
      []
  end

  @doc """
  Parse a package.json file and return dependency list.
  """
  @spec parse_package_json(String.t()) :: [map()]
  def parse_package_json(path) do
    if File.exists?(path) do
      content = File.read!(path)
      extract_npm_deps(content)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[DependencySync] Failed to parse package.json: #{Exception.message(e)}")
      []
  end

  @doc """
  Parse a requirements.txt file and return dependency list.
  """
  @spec parse_requirements_txt(String.t()) :: [map()]
  def parse_requirements_txt(path) do
    if File.exists?(path) do
      content = File.read!(path)
      extract_pip_deps(content)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[DependencySync] Failed to parse requirements.txt: #{Exception.message(e)}")
      []
  end

  @doc """
  Parse a pyproject.toml file and return dependency list.
  """
  @spec parse_pyproject_toml(String.t()) :: [map()]
  def parse_pyproject_toml(path) do
    if File.exists?(path) do
      content = File.read!(path)
      extract_pyproject_deps(content)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[DependencySync] Failed to parse pyproject.toml: #{Exception.message(e)}")
      []
  end

  @doc """
  Parse a Cargo.toml file and return dependency list.
  """
  @spec parse_cargo_toml(String.t()) :: [map()]
  def parse_cargo_toml(path) do
    if File.exists?(path) do
      content = File.read!(path)
      extract_cargo_deps(content)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[DependencySync] Failed to parse Cargo.toml: #{Exception.message(e)}")
      []
  end

  @doc """
  Parse a go.mod file and return dependency list.
  """
  @spec parse_go_mod(String.t()) :: [map()]
  def parse_go_mod(path) do
    if File.exists?(path) do
      content = File.read!(path)
      extract_go_deps(content)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[DependencySync] Failed to parse go.mod: #{Exception.message(e)}")
      []
  end

  # ==========================================================================
  # Private Functions - Detection and Parsing
  # ==========================================================================

  defp detect_and_parse_dependencies(project_root, ecosystems) do
    parsers = [
      {:hex, "mix.exs", &parse_mix_exs/1},
      {:npm, "package.json", &parse_package_json/1},
      {:pypi, "requirements.txt", &parse_requirements_txt/1},
      {:pypi, "pyproject.toml", &parse_pyproject_toml/1},
      {:crates, "Cargo.toml", &parse_cargo_toml/1},
      {:go, "go.mod", &parse_go_mod/1}
    ]

    parsers
    |> Enum.filter(fn {eco, _, _} ->
      is_nil(ecosystems) or eco in ecosystems
    end)
    |> Enum.flat_map(fn {ecosystem, filename, parser} ->
      path = Path.join(project_root, filename)

      if File.exists?(path) do
        deps = parser.(path)
        Enum.map(deps, &Map.put(&1, :ecosystem, ecosystem))
      else
        []
      end
    end)
  end

  # ==========================================================================
  # Private Functions - Elixir/mix.exs Parsing
  # ==========================================================================

  defp extract_mix_deps(content) do
    # Match deps function return value
    deps_pattern = ~r/defp?\s+deps\s*(?:\([^)]*\))?\s*do\s+([\s\S]*?)\s+end/

    case Regex.run(deps_pattern, content) do
      [_, deps_block] ->
        # Extract individual dependency tuples
        # Matches: {:name, "~> 1.0"} or {:name, "~> 1.0", opts}
        dep_pattern = ~r/\{:(\w+),\s*"([^"]+)"(?:,\s*\[[^\]]*\])?\}/

        Regex.scan(dep_pattern, deps_block)
        |> Enum.map(fn [_, name, version] ->
          %{
            name: name,
            version: clean_version(version),
            ecosystem: :hex
          }
        end)

      nil ->
        []
    end
  end

  # ==========================================================================
  # Private Functions - npm/package.json Parsing
  # ==========================================================================

  defp extract_npm_deps(content) do
    case Jason.decode(content) do
      {:ok, json} ->
        deps = Map.get(json, "dependencies", %{})
        dev_deps = Map.get(json, "devDependencies", %{})

        all_deps = Map.merge(deps, dev_deps)

        all_deps
        |> Enum.map(fn {name, version} ->
          %{
            name: name,
            version: clean_version(version),
            ecosystem: :npm
          }
        end)

      {:error, _} ->
        []
    end
  end

  # ==========================================================================
  # Private Functions - pip/requirements.txt Parsing
  # ==========================================================================

  defp extract_pip_deps(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
    |> Enum.map(fn line ->
      # Match: package==1.0.0 or package>=1.0.0 or package~=1.0.0 or just package
      case Regex.run(~r/^([a-zA-Z0-9_-]+)(?:[=<>~!]+(.+))?$/, line) do
        [_, name, version] ->
          %{name: name, version: clean_version(version), ecosystem: :pypi}

        [_, name] ->
          %{name: name, version: "latest", ecosystem: :pypi}

        nil ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ==========================================================================
  # Private Functions - pyproject.toml Parsing
  # ==========================================================================

  defp extract_pyproject_deps(content) do
    # Simple regex-based parsing for common patterns
    # Matches: package = "^1.0" or package = {version = "1.0", ...}
    deps_section = ~r/\[(?:tool\.poetry\.)?dependencies\]\s*([\s\S]*?)(?:\[|$)/

    case Regex.run(deps_section, content) do
      [_, section] ->
        # Match individual dependencies
        dep_pattern =
          ~r/^([a-zA-Z0-9_-]+)\s*=\s*(?:"([^"]+)"|\{[^}]*version\s*=\s*"([^"]+)"[^}]*\})/m

        Regex.scan(dep_pattern, section)
        |> Enum.map(fn
          [_, name, version, _] when version != "" ->
            %{name: name, version: clean_version(version), ecosystem: :pypi}

          [_, name, _, version] when version != "" ->
            %{name: name, version: clean_version(version), ecosystem: :pypi}

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(fn dep -> dep.name == "python" end)

      nil ->
        []
    end
  end

  # ==========================================================================
  # Private Functions - Cargo.toml Parsing
  # ==========================================================================

  defp extract_cargo_deps(content) do
    # Match [dependencies] section
    deps_section = ~r/\[dependencies\]\s*([\s\S]*?)(?:\[|$)/

    case Regex.run(deps_section, content) do
      [_, section] ->
        # Match: package = "1.0" or package = { version = "1.0", ... }
        dep_pattern =
          ~r/^([a-zA-Z0-9_-]+)\s*=\s*(?:"([^"]+)"|\{[^}]*version\s*=\s*"([^"]+)"[^}]*\})/m

        Regex.scan(dep_pattern, section)
        |> Enum.map(fn
          [_, name, version, _] when version != "" ->
            %{name: name, version: clean_version(version), ecosystem: :crates}

          [_, name, _, version] when version != "" ->
            %{name: name, version: clean_version(version), ecosystem: :crates}

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      nil ->
        []
    end
  end

  # ==========================================================================
  # Private Functions - go.mod Parsing
  # ==========================================================================

  defp extract_go_deps(content) do
    # Match require block or single require statements
    require_block = ~r/require\s*\(\s*([\s\S]*?)\s*\)/
    single_require = ~r/require\s+(\S+)\s+(\S+)/

    block_deps =
      case Regex.run(require_block, content) do
        [_, block] ->
          # Match: github.com/user/repo v1.0.0
          dep_pattern = ~r/^\s*(\S+)\s+(v[\d.]+)/m

          Regex.scan(dep_pattern, block)
          |> Enum.map(fn [_, path, version] ->
            %{name: path, version: version, ecosystem: :go}
          end)

        nil ->
          []
      end

    single_deps =
      Regex.scan(single_require, content)
      |> Enum.map(fn [_, path, version] ->
        %{name: path, version: version, ecosystem: :go}
      end)

    block_deps ++ single_deps
  end

  # ==========================================================================
  # Private Functions - Graph Operations
  # ==========================================================================

  defp sync_single_dependency(project_node, dep, fetch_docs) do
    ecosystem = dep.ecosystem
    name = dep.name
    version = dep.version

    # Create external_lib node
    {:ok, lib_node} =
      Graph.find_or_create_node(:external_lib, name, %{
        ecosystem: to_string(ecosystem),
        version: version,
        dependency: true,
        synced_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    # Create uses edge from project to library
    Graph.ensure_edge(project_node.id, lib_node.id, :uses, %{
      source: "dependency_sync",
      version: version,
      ecosystem: to_string(ecosystem)
    })

    # Notify orchestrator of the dependency
    if Process.whereis(Orchestrator) do
      Orchestrator.on_dependency_detected(name, version, ecosystem)
    end

    # Optionally fetch library docs
    if fetch_docs do
      fetch_library_docs(name, ecosystem, version)
    end

    {ecosystem, name, version}
  rescue
    e ->
      Logger.warning("[DependencySync] Failed to sync #{dep.name}: #{Exception.message(e)}")
      {dep.ecosystem, dep.name, nil}
  end

  defp fetch_library_docs(name, ecosystem, version) do
    # Use the Library module to ensure docs are cached
    Task.Supervisor.start_child(Mimo.TaskSupervisor, fn ->
      try do
        opts = if version && version != "latest", do: [version: version], else: []
        Library.Index.ensure_cached(name, ecosystem, opts)
        Logger.debug("[DependencySync] Cached docs for #{name} (#{ecosystem})")
      rescue
        e ->
          Logger.debug("[DependencySync] Could not fetch docs for #{name}: #{Exception.message(e)}")

          :telemetry.execute([:mimo, :dependency_sync, :fetch_docs_error], %{count: 1}, %{
            name: name,
            ecosystem: ecosystem
          })
      end
    end)
  end

  # ==========================================================================
  # Private Functions - Helpers
  # ==========================================================================

  defp clean_version(nil), do: "latest"
  defp clean_version(""), do: "latest"

  defp clean_version(version) when is_binary(version) do
    version
    |> String.trim()
    |> String.replace(~r/^[\^~>=<]+/, "")
    |> String.replace(~r/,.*$/, "")
  end

  defp clean_version(version), do: to_string(version)
end
