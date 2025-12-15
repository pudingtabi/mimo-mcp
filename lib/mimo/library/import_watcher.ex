defmodule Mimo.Library.ImportWatcher do
  @moduledoc """
  Watch for import statements in code and auto-cache relevant library docs.

  Extracts import/require statements from code files and triggers background
  caching of the referenced libraries.

  ## Usage

      # Extract imports from file content
      imports = ImportWatcher.extract_imports(code, :elixir)
      
      # Cache imports from a file (runs in background)
      ImportWatcher.cache_imports_from_file("/path/to/file.ex")
  """

  alias Mimo.Library.Index
  require Logger

  @import_patterns %{
    elixir: [
      ~r/(?:import|alias|require|use)\s+([A-Z][\w.]+)/,
      # Mix deps
      ~r/\{:(\w+),\s*"[^"]+"\}/
    ],
    python: [
      ~r/^import\s+([\w.]+)/m,
      ~r/^from\s+([\w.]+)\s+import/m
    ],
    javascript: [
      ~r/import\s+.*\s+from\s+['"]([^'"]+)['"]/,
      ~r/require\s*\(\s*['"]([^'"]+)['"]\s*\)/
    ],
    typescript: [
      ~r/import\s+.*\s+from\s+['"]([^'"]+)['"]/,
      ~r/require\s*\(\s*['"]([^'"]+)['"]\s*\)/
    ],
    rust: [
      ~r/use\s+([\w:]+)/,
      ~r/extern\s+crate\s+(\w+)/
    ]
  }

  # Known standard library modules to ignore
  @stdlib_modules %{
    elixir: MapSet.new(~w[
      Kernel String Enum List Map MapSet Keyword Tuple
      Integer Float Atom Port Reference Function
      IO File Path System Code Module Process Task Agent GenServer
      Supervisor Application Registry ETS DETS Mnesia
      Logger DateTime Date Time NaiveDateTime Calendar
      Regex URI Base Stream Range Bitwise Access Inspect Protocol
      Exception RuntimeError ArgumentError FunctionClauseError
      Mix ExUnit
    ]),
    python: MapSet.new(~w[
      os sys re json datetime collections itertools functools
      typing pathlib io subprocess threading multiprocessing
      logging argparse unittest pytest math random string
      copy pickle csv http urllib xml html email
    ]),
    javascript: MapSet.new(~w[
      fs path http https url crypto stream util events
      child_process os net dns tls assert buffer
    ]),
    rust: MapSet.new(~w[
      std core alloc
    ])
  }

  @doc """
  Extract import/require statements from code content.

  Returns a list of imported module/package names.
  """
  @spec extract_imports(String.t(), atom()) :: [String.t()]
  def extract_imports(content, language) do
    patterns = Map.get(@import_patterns, language, [])

    patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, content)
      |> Enum.map(fn
        [_, import] -> normalize_import(import, language)
        _ -> nil
      end)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Extract imports from a file and cache relevant library docs in the background.
  """
  @spec cache_imports_from_file(String.t()) :: :ok
  def cache_imports_from_file(path) do
    language = detect_language(path)
    ecosystem = language_to_ecosystem(language)

    if ecosystem do
      cache_file_imports(path, language, ecosystem)
    else
      :ok
    end
  end

  defp cache_file_imports(path, language, ecosystem) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> extract_imports(language)
        |> filter_external_packages(language)
        |> cache_packages(ecosystem, path)

      {:error, _} ->
        :ok
    end
  end

  defp cache_packages(packages, ecosystem, path) do
    Logger.debug("[ImportWatcher] Found #{length(packages)} external imports in #{path}")

    Enum.each(packages, fn pkg ->
      Mimo.Sandbox.run_async(Mimo.Repo, fn ->
        cache_single_package(pkg, ecosystem)
      end)
    end)

    :ok
  end

  defp cache_single_package(pkg, ecosystem) do
    case Index.ensure_cached(pkg, ecosystem) do
      :ok ->
        Logger.debug("[ImportWatcher] Cached #{ecosystem}/#{pkg}")

      {:error, reason} ->
        Logger.warning("[ImportWatcher] Failed to cache #{ecosystem}/#{pkg}: #{inspect(reason)}")

        :telemetry.execute([:mimo, :import_watcher, :cache_error], %{count: 1}, %{
          package: pkg,
          ecosystem: ecosystem
        })
    end
  end

  @doc """
  Get the package ecosystem for a language.
  """
  @spec language_to_ecosystem(atom()) :: atom() | nil
  def language_to_ecosystem(:elixir), do: :hex
  def language_to_ecosystem(:python), do: :pypi
  def language_to_ecosystem(:javascript), do: :npm
  def language_to_ecosystem(:typescript), do: :npm
  def language_to_ecosystem(:rust), do: :crates
  def language_to_ecosystem(_), do: nil

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp normalize_import(import, :elixir) do
    # For Elixir, convert module name to package name
    # e.g., Phoenix.Controller -> phoenix
    import
    |> String.split(".")
    |> List.first()
    |> Macro.underscore()
    |> String.replace("_", "")
  end

  defp normalize_import(import, :python) do
    # For Python, get the top-level package
    # e.g., flask.views -> flask
    import
    |> String.split(".")
    |> List.first()
  end

  defp normalize_import(import, lang) when lang in [:javascript, :typescript] do
    # For JS/TS, handle scoped packages and paths
    cond do
      # Relative import - ignore
      String.starts_with?(import, ".") ->
        nil

      # Scoped package like @org/package
      String.starts_with?(import, "@") ->
        import
        |> String.split("/")
        |> Enum.take(2)
        |> Enum.join("/")

      # Regular package, might have subpath
      true ->
        String.split(import, "/") |> List.first()
    end
  end

  defp normalize_import(import, :rust) do
    # For Rust, get the crate name
    # e.g., serde::Serialize -> serde
    import
    |> String.split("::")
    |> List.first()
  end

  defp normalize_import(import, _), do: import

  defp filter_external_packages(imports, language) do
    stdlib = Map.get(@stdlib_modules, language, MapSet.new())

    imports
    |> Enum.reject(fn pkg ->
      is_nil(pkg) or MapSet.member?(stdlib, pkg) or
        pkg == "" or
        String.length(pkg) < 2 or
        String.starts_with?(pkg, "_") or
        String.starts_with?(pkg, ".")
    end)
  end

  defp detect_language(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ext when ext in [".ex", ".exs"] -> :elixir
      ".py" -> :python
      ext when ext in [".js", ".jsx", ".mjs"] -> :javascript
      ext when ext in [".ts", ".tsx"] -> :typescript
      ".rs" -> :rust
      _ -> :unknown
    end
  end
end
