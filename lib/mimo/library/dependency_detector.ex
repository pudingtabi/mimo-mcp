defmodule Mimo.Library.DependencyDetector do
  @moduledoc """
  Detects project dependencies from various package manifest files.

  Supports:
  - Elixir: mix.exs
  - Python: requirements.txt, pyproject.toml, setup.py
  - JavaScript/Node: package.json
  """

  require Logger

  @type dependency :: %{
          name: String.t(),
          version: String.t() | nil,
          ecosystem: :hex | :pypi | :npm,
          dev: boolean()
        }

  @doc """
  Scan a project directory to detect all dependencies.
  """
  @spec scan(String.t()) :: [dependency()]
  def scan(project_path) do
    project_path = Path.expand(project_path)

    []
    |> maybe_add_elixir_deps(project_path)
    |> maybe_add_python_deps(project_path)
    |> maybe_add_node_deps(project_path)
    |> Enum.uniq_by(fn dep -> {dep.name, dep.ecosystem} end)
  end

  @doc """
  Detect the primary ecosystem of a project.
  """
  @spec detect_ecosystem(String.t()) :: :hex | :pypi | :npm | :unknown
  def detect_ecosystem(project_path) do
    project_path = Path.expand(project_path)

    cond do
      File.exists?(Path.join(project_path, "mix.exs")) -> :hex
      File.exists?(Path.join(project_path, "requirements.txt")) -> :pypi
      File.exists?(Path.join(project_path, "pyproject.toml")) -> :pypi
      File.exists?(Path.join(project_path, "package.json")) -> :npm
      true -> :unknown
    end
  end

  # Elixir dependency detection

  defp maybe_add_elixir_deps(deps, project_path) do
    mix_path = Path.join(project_path, "mix.exs")

    if File.exists?(mix_path) do
      case parse_mix_exs(mix_path) do
        {:ok, elixir_deps} -> deps ++ elixir_deps
        {:error, _} -> deps
      end
    else
      deps
    end
  end

  defp parse_mix_exs(path) do
    with {:ok, content} <- File.read(path) do
      # Extract deps from the deps function
      # This is a simplified parser - handles common patterns
      deps =
        content
        |> extract_deps_block()
        |> parse_dep_tuples()
        |> Enum.map(fn {name, version, opts} ->
          %{
            name: to_string(name),
            version: normalize_version(version),
            ecosystem: :hex,
            dev: Keyword.get(opts, :only) == :dev or Keyword.get(opts, :only) == [:dev, :test]
          }
        end)

      {:ok, deps}
    end
  end

  defp extract_deps_block(content) do
    # Match the deps function and extract the list
    case Regex.run(~r/defp?\s+deps\s*(?:\(\))?\s*do\s*\[([\s\S]*?)\]\s*end/m, content) do
      [_, deps_content] -> deps_content
      _ -> ""
    end
  end

  defp parse_dep_tuples(content) do
    # Match dependency tuples like {:phoenix, "~> 1.6"} or {:ecto, "~> 3.0", only: :test}
    regex = ~r/\{:(\w+)\s*,\s*"([^"]+)"(?:\s*,\s*([^\}]+))?\}/

    Regex.scan(regex, content)
    |> Enum.map(fn
      [_, name, version, opts_str] ->
        opts = parse_opts(opts_str)
        {name, version, opts}

      [_, name, version] ->
        {name, version, []}
    end)
  end

  defp parse_opts(nil), do: []
  defp parse_opts(""), do: []

  defp parse_opts(opts_str) do
    if String.contains?(opts_str, "only:") do
      cond do
        String.contains?(opts_str, ":dev") and String.contains?(opts_str, ":test") ->
          [only: [:dev, :test]]

        String.contains?(opts_str, ":dev") ->
          [only: :dev]

        String.contains?(opts_str, ":test") ->
          [only: :test]

        true ->
          []
      end
    else
      []
    end
  end

  # Python dependency detection

  defp maybe_add_python_deps(deps, project_path) do
    deps
    |> maybe_add_requirements_txt(project_path)
    |> maybe_add_pyproject_toml(project_path)
  end

  defp maybe_add_requirements_txt(deps, project_path) do
    req_path = Path.join(project_path, "requirements.txt")

    if File.exists?(req_path) do
      case parse_requirements_txt(req_path) do
        {:ok, python_deps} -> deps ++ python_deps
        {:error, _} -> deps
      end
    else
      deps
    end
  end

  defp parse_requirements_txt(path) do
    with {:ok, content} <- File.read(path) do
      deps =
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
        |> Enum.map(&parse_python_requirement/1)
        |> Enum.reject(&is_nil/1)

      {:ok, deps}
    end
  end

  defp parse_python_requirement(line) do
    # Handle: package==1.0, package>=1.0, package~=1.0, package[extra]==1.0
    case Regex.run(~r/^([a-zA-Z0-9_-]+)(?:\[[\w,]+\])?(?:([=<>~!]+)(.+))?$/, line) do
      [_, name, _op, version] ->
        %{
          name: name,
          version: String.trim(version),
          ecosystem: :pypi,
          dev: false
        }

      [_, name] ->
        %{
          name: name,
          version: nil,
          ecosystem: :pypi,
          dev: false
        }

      _ ->
        nil
    end
  end

  defp maybe_add_pyproject_toml(deps, project_path) do
    toml_path = Path.join(project_path, "pyproject.toml")

    if File.exists?(toml_path) do
      case parse_pyproject_toml(toml_path) do
        {:ok, python_deps} -> deps ++ python_deps
        {:error, _} -> deps
      end
    else
      deps
    end
  end

  defp parse_pyproject_toml(path) do
    with {:ok, content} <- File.read(path) do
      # Simple TOML parsing for dependencies section
      deps =
        content
        |> extract_toml_dependencies()
        |> Enum.map(fn {name, version} ->
          %{
            name: name,
            version: version,
            ecosystem: :pypi,
            dev: false
          }
        end)

      {:ok, deps}
    end
  end

  defp extract_toml_dependencies(content) do
    # Look for dependencies = [...] or [project.dependencies]
    case Regex.run(~r/dependencies\s*=\s*\[([\s\S]*?)\]/m, content) do
      [_, deps_block] ->
        deps_block
        |> String.split(~r/[,\n]/)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.trim(&1, "\""))
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&parse_python_requirement/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn dep -> {dep.name, dep.version} end)

      _ ->
        []
    end
  end

  # Node.js dependency detection

  defp maybe_add_node_deps(deps, project_path) do
    pkg_path = Path.join(project_path, "package.json")

    if File.exists?(pkg_path) do
      case parse_package_json(pkg_path) do
        {:ok, node_deps} -> deps ++ node_deps
        {:error, _} -> deps
      end
    else
      deps
    end
  end

  defp parse_package_json(path) do
    with {:ok, content} <- File.read(path),
         {:ok, json} <- Jason.decode(content) do
      prod_deps =
        json
        |> Map.get("dependencies", %{})
        |> Enum.map(fn {name, version} ->
          %{
            name: name,
            version: normalize_version(version),
            ecosystem: :npm,
            dev: false
          }
        end)

      dev_deps =
        json
        |> Map.get("devDependencies", %{})
        |> Enum.map(fn {name, version} ->
          %{
            name: name,
            version: normalize_version(version),
            ecosystem: :npm,
            dev: true
          }
        end)

      {:ok, prod_deps ++ dev_deps}
    end
  end

  # Helpers

  defp normalize_version(version) when is_binary(version) do
    version
    |> String.replace(~r/^[\^~>=<]+/, "")
    |> String.trim()
  end

  defp normalize_version(_), do: nil
end
