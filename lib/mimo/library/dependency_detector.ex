defmodule Mimo.Library.DependencyDetector do
  @moduledoc """
  Detects dependencies in various project types.
  """

  @doc """
  Scan a project directory for dependencies.
  """
  def scan(project_path) do
    []
    |> scan_mix_project(project_path)
    |> scan_npm_project(project_path)
    |> scan_cargo_project(project_path)
    |> scan_requirements_txt(project_path)
  end

  defp scan_mix_project(deps, project_path) do
    mix_file = Path.join(project_path, "mix.exs")

    if File.exists?(mix_file) do
      deps ++ [%{ecosystem: "hex", type: "mix_project", path: mix_file}]
    else
      deps
    end
  end

  defp scan_npm_project(deps, project_path) do
    package_file = Path.join(project_path, "package.json")

    if File.exists?(package_file) do
      deps ++ [%{ecosystem: "npm", type: "npm_project", path: package_file}]
    else
      deps
    end
  end

  defp scan_cargo_project(deps, project_path) do
    cargo_file = Path.join(project_path, "Cargo.toml")

    if File.exists?(cargo_file) do
      deps ++ [%{ecosystem: "crates", type: "cargo_project", path: cargo_file}]
    else
      deps
    end
  end

  defp scan_requirements_txt(deps, project_path) do
    req_file = Path.join(project_path, "requirements.txt")

    if File.exists?(req_file) do
      deps ++ [%{ecosystem: "pypi", type: "requirements_txt", path: req_file}]
    else
      deps
    end
  end
end
