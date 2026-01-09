defmodule Mimo.Learning.LibraryLearner do
  @moduledoc """
  SPEC-096: Synergy P1 - Automatic library documentation learning.

  When a project is onboarded, this module:
  1. Detects project dependencies (mix.lock, package.json, etc.)
  2. Fetches documentation for each dependency
  3. Ingests key docs into Mimo's memory (with version tags)

  This enables Mimo to "know" the libraries the project uses.
  """
  require Logger

  alias Mimo.Brain.Memory
  alias Mimo.Tools.Dispatchers.Code

  @doc """
  Learn dependencies for a project path.
  Called after onboarding completes.
  """
  def learn_project_deps(project_path, opts \\ []) do
    max_deps = Keyword.get(opts, :max_deps, 10)

    Logger.info("[LibraryLearner] Starting dependency learning for #{project_path}")

    case detect_ecosystem(project_path) do
      {:ok, ecosystem, lockfile_path} ->
        deps = parse_lockfile(ecosystem, lockfile_path)
        Logger.info("[LibraryLearner] Found #{length(deps)} dependencies (#{ecosystem})")

        # Learn top N dependencies (by importance/usage)
        deps
        |> Enum.take(max_deps)
        |> Enum.map(&learn_dep(&1, ecosystem))
        |> summarize_results()

      {:error, :no_lockfile} ->
        Logger.debug("[LibraryLearner] No lockfile found in #{project_path}")
        {:ok, %{status: "skipped", reason: "no lockfile detected"}}
    end
  end

  @doc """
  Detect project ecosystem from files.
  """
  def detect_ecosystem(path) do
    cond do
      File.exists?(Path.join(path, "mix.lock")) ->
        {:ok, :hex, Path.join(path, "mix.lock")}

      File.exists?(Path.join(path, "package-lock.json")) ->
        {:ok, :npm, Path.join(path, "package-lock.json")}

      File.exists?(Path.join(path, "yarn.lock")) ->
        {:ok, :npm, Path.join(path, "yarn.lock")}

      File.exists?(Path.join(path, "poetry.lock")) ->
        {:ok, :pypi, Path.join(path, "poetry.lock")}

      File.exists?(Path.join(path, "requirements.txt")) ->
        {:ok, :pypi, Path.join(path, "requirements.txt")}

      File.exists?(Path.join(path, "Cargo.lock")) ->
        {:ok, :crates, Path.join(path, "Cargo.lock")}

      true ->
        {:error, :no_lockfile}
    end
  end

  @doc """
  Parse lockfile to extract dependencies.
  """
  def parse_lockfile(:hex, lockfile_path) do
    try do
      content = File.read!(lockfile_path)

      # Parse mix.lock format: "dep_name": {:hex, :name, "version", ...}
      regex = ~r/"([^"]+)":\s*\{:hex,\s*:([^,]+),\s*"([^"]+)"/

      Regex.scan(regex, content)
      |> Enum.map(fn [_, name, _, version] ->
        %{name: name, version: version, ecosystem: :hex}
      end)
      |> Enum.uniq_by(& &1.name)
    rescue
      _ -> []
    end
  end

  def parse_lockfile(:npm, lockfile_path) do
    try do
      # Simplified npm parsing - get top-level deps
      content = File.read!(lockfile_path)

      if String.contains?(lockfile_path, "yarn.lock") do
        # Yarn format: "package@version":
        regex = ~r/^"?([^@"]+)@([^":]+)/m

        Regex.scan(regex, content)
        |> Enum.map(fn [_, name, version] ->
          %{name: name, version: version, ecosystem: :npm}
        end)
        |> Enum.uniq_by(& &1.name)
        |> Enum.take(20)
      else
        # package-lock.json format
        case Jason.decode(content) do
          {:ok, %{"packages" => packages}} when is_map(packages) ->
            packages
            |> Map.keys()
            |> Enum.reject(&(&1 == ""))
            |> Enum.map(fn key ->
              name = String.replace(key, "node_modules/", "")
              version = get_in(packages, [key, "version"]) || "latest"
              %{name: name, version: version, ecosystem: :npm}
            end)
            |> Enum.take(20)

          _ ->
            []
        end
      end
    rescue
      _ -> []
    end
  end

  def parse_lockfile(:pypi, lockfile_path) do
    try do
      content = File.read!(lockfile_path)

      if String.contains?(lockfile_path, "poetry.lock") do
        # Poetry format: [[package]]\nname = "..."
        regex = ~r/\[\[package\]\]\s*name\s*=\s*"([^"]+)"\s*version\s*=\s*"([^"]+)"/

        Regex.scan(regex, content)
        |> Enum.map(fn [_, name, version] ->
          %{name: name, version: version, ecosystem: :pypi}
        end)
      else
        # requirements.txt format: package==version
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
        |> Enum.map(fn line ->
          case String.split(line, "==") do
            [name, version] ->
              %{name: name, version: version, ecosystem: :pypi}

            [name] ->
              %{name: String.replace(name, ~r/[>=<].*/, ""), version: "latest", ecosystem: :pypi}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      end
    rescue
      _ -> []
    end
  end

  def parse_lockfile(:crates, lockfile_path) do
    try do
      content = File.read!(lockfile_path)

      # Cargo.lock format: [[package]]\nname = "..."\nversion = "..."
      regex = ~r/\[\[package\]\]\s*name\s*=\s*"([^"]+)"\s*version\s*=\s*"([^"]+)"/

      Regex.scan(regex, content)
      |> Enum.map(fn [_, name, version] ->
        %{name: name, version: version, ecosystem: :crates}
      end)
    rescue
      _ -> []
    end
  end

  def parse_lockfile(_, _), do: []

  @doc """
  Learn a single dependency by fetching and ingesting its docs.
  """
  def learn_dep(%{name: name, version: version, ecosystem: ecosystem}, ecosystem_atom) do
    eco = ecosystem || ecosystem_atom

    Logger.debug("[LibraryLearner] Learning #{name}@#{version} (#{eco})")

    # First check if already learned
    case Memory.search_memories("library #{name} #{version} documentation",
           limit: 1,
           min_similarity: 0.85
         ) do
      [_existing] ->
        Logger.debug("[LibraryLearner] Already know #{name}@#{version}")
        {:ok, :already_learned}

      _ ->
        # Fetch library info via code tool
        case Code.dispatch(%{
               "operation" => "library_get",
               "name" => name,
               "ecosystem" => to_string(eco)
             }) do
          {:ok, %{description: desc, docs_url: docs_url}} ->
            # Store key info to memory
            content = """
            Library: #{name} v#{version} (#{eco})
            Description: #{desc || "No description"}
            Docs: #{docs_url || "N/A"}

            Key usage patterns will be learned as you use this library.
            """

            Memory.store(%{
              content: content,
              type: "fact",
              metadata: %{
                "importance" => 0.7,
                "tags" => ["library", to_string(name), to_string(version), to_string(eco)]
              }
            })

            Logger.info("[LibraryLearner] Learned #{name}@#{version}")
            {:ok, :learned}

          {:error, reason} ->
            Logger.debug("[LibraryLearner] Could not fetch #{name}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp summarize_results(results) do
    learned = Enum.count(results, fn r -> r == {:ok, :learned} end)
    skipped = Enum.count(results, fn r -> r == {:ok, :already_learned} end)
    failed = Enum.count(results, fn r -> match?({:error, _}, r) end)

    {:ok,
     %{
       status: "completed",
       learned: learned,
       already_known: skipped,
       failed: failed,
       total: length(results)
     }}
  end
end
