defmodule Mimo.Library.AutoDiscovery do
  @moduledoc """
  Automatically discover and cache library documentation based on project dependencies.

  Scans project files (mix.exs, package.json, requirements.txt, Cargo.toml) to detect
  dependencies and pre-cache their documentation for faster lookups.

  ## Usage

      # Discover all dependencies in a project
      {:ok, results} = AutoDiscovery.discover_and_cache("/path/to/project")
      
      # Detect ecosystems in a project
      ecosystems = AutoDiscovery.detect_ecosystems("/path/to/project")
      
      # Extract dependencies for a specific ecosystem
      deps = AutoDiscovery.extract_dependencies("/path/to/project", :hex)
  """

  alias Mimo.Library.Index
  require Logger

  @doc """
  Scan a project and pre-cache documentation for all dependencies.

  Returns a list of results for each dependency caching attempt.
  """
  @spec discover_and_cache(String.t()) :: {:ok, list(map())}
  def discover_and_cache(project_path) do
    project_path = Path.expand(project_path)

    if File.dir?(project_path) do
      ecosystems = detect_ecosystems(project_path)

      Logger.info("[AutoDiscovery] Found #{length(ecosystems)} ecosystems: #{inspect(ecosystems)}")

      results =
        Enum.flat_map(ecosystems, fn ecosystem ->
          deps = extract_dependencies(project_path, ecosystem)

          Logger.info("[AutoDiscovery] Found #{length(deps)} #{ecosystem} dependencies")

          Enum.map(deps, fn {name, version} ->
            cache_dependency(ecosystem, name, version)
          end)
        end)

      {:ok,
       %{
         ecosystems: ecosystems,
         total_dependencies: length(results),
         cached_successfully: Enum.count(results, &match?({:ok, _}, &1)),
         failed: Enum.count(results, &match?({:error, _}, &1)),
         details: results
       }}
    else
      {:error, "Path is not a directory: #{project_path}"}
    end
  end

  @doc """
  Detect which ecosystems are used in a project based on marker files.
  """
  @spec detect_ecosystems(String.t()) :: [atom()]
  def detect_ecosystems(path) do
    path = Path.expand(path)

    files =
      case File.ls(path) do
        {:ok, f} -> f
        {:error, _} -> []
      end

    ecosystems = []
    ecosystems = if "mix.exs" in files, do: [:hex | ecosystems], else: ecosystems
    ecosystems = if "package.json" in files, do: [:npm | ecosystems], else: ecosystems

    ecosystems =
      if "requirements.txt" in files or "pyproject.toml" in files or "setup.py" in files,
        do: [:pypi | ecosystems],
        else: ecosystems

    ecosystems = if "Cargo.toml" in files, do: [:crates | ecosystems], else: ecosystems

    Enum.reverse(ecosystems)
  end

  @doc """
  Extract dependencies from a project for a specific ecosystem.

  Returns a list of `{name, version}` tuples.
  """
  @spec extract_dependencies(String.t(), atom()) :: [{String.t(), String.t()}]
  def extract_dependencies(path, :hex) do
    mix_path = Path.join(path, "mix.exs")

    if File.exists?(mix_path) do
      content = File.read!(mix_path)
      parse_mix_deps(content)
    else
      []
    end
  end

  def extract_dependencies(path, :npm) do
    package_path = Path.join(path, "package.json")

    if File.exists?(package_path) do
      content = File.read!(package_path)
      parse_npm_deps(content)
    else
      []
    end
  end

  def extract_dependencies(path, :pypi) do
    # Try requirements.txt first
    req_path = Path.join(path, "requirements.txt")

    if File.exists?(req_path) do
      content = File.read!(req_path)
      parse_requirements_txt(content)
    else
      # Try pyproject.toml
      pyproject_path = Path.join(path, "pyproject.toml")

      if File.exists?(pyproject_path) do
        content = File.read!(pyproject_path)
        parse_pyproject_deps(content)
      else
        []
      end
    end
  end

  def extract_dependencies(path, :crates) do
    cargo_path = Path.join(path, "Cargo.toml")

    if File.exists?(cargo_path) do
      content = File.read!(cargo_path)
      parse_cargo_deps(content)
    else
      []
    end
  end

  def extract_dependencies(_, _), do: []

  # ==========================================================================
  # Dependency Parsers
  # ==========================================================================

  defp parse_mix_deps(content) do
    # Match patterns like {:phoenix, "~> 1.7"} or {:ecto, ">= 3.0.0"}
    # Also handles {:dep, "~> 1.0", only: :dev}
    Regex.scan(~r/\{:(\w+),\s*"([^"]+)"/, content)
    |> Enum.map(fn [_, name, version] -> {name, clean_version(version)} end)
    |> Enum.uniq_by(fn {name, _} -> name end)
  end

  defp parse_npm_deps(content) do
    case Jason.decode(content) do
      {:ok, pkg} ->
        deps = Map.get(pkg, "dependencies", %{})
        dev_deps = Map.get(pkg, "devDependencies", %{})

        Map.merge(deps, dev_deps)
        |> Enum.map(fn {name, version} -> {name, clean_version(version)} end)
        |> Enum.reject(fn {name, _} -> String.starts_with?(name, "@types/") end)

      _ ->
        []
    end
  end

  defp parse_requirements_txt(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn line ->
      line == "" or String.starts_with?(line, "#") or String.starts_with?(line, "-")
    end)
    |> Enum.map(&parse_python_requirement/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_python_requirement(line) do
    # Handle various formats: package==1.0, package>=1.0, package~=1.0, package
    cond do
      String.contains?(line, "==") ->
        [name, version] = String.split(line, "==", parts: 2)
        {String.trim(name), String.trim(version)}

      String.contains?(line, ">=") ->
        [name, _] = String.split(line, ">=", parts: 2)
        {String.trim(name), "latest"}

      String.contains?(line, "~=") ->
        [name, version] = String.split(line, "~=", parts: 2)
        {String.trim(name), String.trim(version)}

      String.contains?(line, "[") ->
        # package[extra] format
        [name | _] = String.split(line, "[")
        {String.trim(name), "latest"}

      true ->
        # Just package name
        name = String.split(line) |> List.first()
        if name && name != "", do: {name, "latest"}, else: nil
    end
  end

  defp parse_pyproject_deps(content) do
    # Simple parsing for pyproject.toml dependencies
    # Format: dependencies = ["package>=1.0", ...]
    case Regex.run(~r/dependencies\s*=\s*\[([\s\S]*?)\]/m, content) do
      [_, deps_str] ->
        Regex.scan(~r/"([^"]+)"/, deps_str)
        |> Enum.map(fn [_, dep] -> parse_python_requirement(dep) end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_cargo_deps(content) do
    # Parse [dependencies] section in Cargo.toml
    # Handles both: dep = "1.0" and dep = { version = "1.0", ... }

    # Simple format: name = "version"
    simple_deps =
      Regex.scan(~r/^(\w[\w-]*)\s*=\s*"([^"]+)"/m, content)
      |> Enum.map(fn [_, name, version] -> {name, version} end)

    # Complex format: name = { version = "1.0", ... }
    complex_deps =
      Regex.scan(~r/^(\w[\w-]*)\s*=\s*\{[^}]*version\s*=\s*"([^"]+)"/m, content)
      |> Enum.map(fn [_, name, version] -> {name, version} end)

    (simple_deps ++ complex_deps)
    |> Enum.uniq_by(fn {name, _} -> name end)
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp cache_dependency(ecosystem, name, version) do
    opts = if version != "latest" && version != "", do: [version: version], else: []

    case Index.ensure_cached(name, ecosystem, opts) do
      :ok ->
        {:ok, %{ecosystem: ecosystem, name: name, version: version, cached: true}}

      {:error, reason} ->
        {:error, %{ecosystem: ecosystem, name: name, version: version, error: reason}}
    end
  rescue
    e ->
      {:error, %{ecosystem: ecosystem, name: name, version: version, error: Exception.message(e)}}
  end

  defp clean_version(version) do
    # Remove version prefix operators
    version
    |> String.replace(~r/^[\^~>=<]+/, "")
    |> String.trim()
  end
end
