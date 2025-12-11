defmodule Mimo.Skills.FileContentCache do
  @moduledoc """
  SPEC-064: Automatic caching of file content for future interception.

  After reading certain file types, extract and store key content
  in memory for future retrieval without re-reading.

  ## How It Works

  1. After a file is read, this module extracts key information:
     - Module/class definitions
     - Public function signatures
     - Documentation strings
     - Important comments

  2. The extracted summary is stored in memory with metadata:
     - File path
     - Extraction timestamp
     - Type (file_content_cache)

  3. On future reads, FileReadInterceptor can find this cached
     summary and return it instead of reading the file again.

  ## Supported Languages

  - Elixir (.ex, .exs)
  - JavaScript/TypeScript (.js, .jsx, .ts, .tsx)
  - Python (.py)
  - Ruby (.rb)
  - Go (.go)
  - Rust (.rs)
  - Markdown (.md)

  ## Configuration

  Caching can be disabled per-file by passing `skip_auto_cache: true`
  to the file read operation.
  """

  alias Mimo.Brain.Memory
  require Logger

  # File types worth auto-caching
  @cacheable_extensions ~w(.ex .exs .ts .tsx .js .jsx .py .rb .go .rs .md)

  # Content patterns to extract and store by language
  @extract_patterns %{
    elixir: [
      # Module definitions
      ~r/defmodule\s+([A-Z][A-Za-z0-9._]+)\s+do/,
      # Public function definitions with args
      ~r/def\s+([a-z_][a-z0-9_?!]*)\s*\([^)]*\)/,
      # Macro definitions
      ~r/defmacro\s+([a-z_][a-z0-9_?!]*)\s*\(/,
      # Moduledoc (first 200 chars)
      ~r/@moduledoc\s+"""(.{1,200})/s,
      # Doc strings (first 100 chars)
      ~r/@doc\s+"""(.{1,100})/s
    ],
    javascript: [
      # Class definitions
      ~r/class\s+([A-Z][A-Za-z0-9_]*)/,
      # Function declarations
      ~r/function\s+([a-z_][a-zA-Z0-9_]*)\s*\(/,
      # Arrow functions assigned to const
      ~r/const\s+([a-z_][a-zA-Z0-9_]*)\s*=\s*(?:\([^)]*\)|[a-z_][a-zA-Z0-9_]*)\s*=>/,
      # Export statements
      ~r/export\s+(?:default\s+)?(?:function|class|const)\s+([A-Za-z_][A-Za-z0-9_]*)/
    ],
    python: [
      # Class definitions
      ~r/class\s+([A-Z][A-Za-z0-9_]*)/,
      # Function definitions
      ~r/def\s+([a-z_][a-z0-9_]*)\s*\(/,
      # Async functions
      ~r/async\s+def\s+([a-z_][a-z0-9_]*)\s*\(/,
      # Docstrings (first 100 chars)
      ~r/"""(.{1,100})/s
    ],
    ruby: [
      # Class definitions
      ~r/class\s+([A-Z][A-Za-z0-9_]*)/,
      # Module definitions
      ~r/module\s+([A-Z][A-Za-z0-9_]*)/,
      # Method definitions
      ~r/def\s+([a-z_][a-z0-9_?!]*)/
    ],
    go: [
      # Package declaration
      ~r/package\s+([a-z][a-z0-9_]*)/,
      # Function declarations
      ~r/func\s+(?:\([^)]+\)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(/,
      # Type declarations
      ~r/type\s+([A-Z][A-Za-z0-9_]*)\s+(?:struct|interface)/
    ],
    rust: [
      # Module declarations
      ~r/mod\s+([a-z_][a-z0-9_]*)/,
      # Function declarations
      ~r/(?:pub\s+)?fn\s+([a-z_][a-z0-9_]*)\s*[<(]/,
      # Struct declarations
      ~r/(?:pub\s+)?struct\s+([A-Z][A-Za-z0-9_]*)/,
      # Impl blocks
      ~r/impl(?:<[^>]+>)?\s+([A-Z][A-Za-z0-9_]*)/
    ],
    markdown: [
      # Headers
      ~r/^#+\s+(.+)$/m
    ]
  }

  # ============================================================================
  # PUBLIC API
  # ============================================================================

  @doc """
  After a file read, optionally cache key content for future interception.

  ## Parameters

  - `path` - File path that was read
  - `content` - File content

  ## Returns

  - `{:ok, summary}` - Content was cached
  - `{:skipped, reason}` - Content was not cached (wrong type, too small, etc.)
  - `{:error, reason}` - Caching failed
  """
  def maybe_cache_content(path, content) when is_binary(path) and is_binary(content) do
    ext = Path.extname(path)

    cond do
      ext not in @cacheable_extensions ->
        {:skipped, :unsupported_extension}

      byte_size(content) < 100 ->
        {:skipped, :content_too_small}

      byte_size(content) > 100_000 ->
        {:skipped, :content_too_large}

      true ->
        do_cache_content(path, content, ext)
    end
  end

  def maybe_cache_content(_, _), do: {:error, :invalid_args}

  @doc """
  Check if a file extension is cacheable.
  """
  def cacheable?(path) when is_binary(path) do
    Path.extname(path) in @cacheable_extensions
  end

  def cacheable?(_), do: false

  @doc """
  Get the list of cacheable extensions.
  """
  def cacheable_extensions, do: @cacheable_extensions

  # ============================================================================
  # PRIVATE
  # ============================================================================

  defp do_cache_content(path, content, ext) do
    language = extension_to_language(ext)
    extracts = extract_key_content(content, language)

    if length(extracts) > 0 do
      summary = build_summary(path, extracts, language)

      case store_in_memory(path, summary) do
        {:ok, _} ->
          Logger.debug("FileContentCache: Cached #{length(extracts)} extracts from #{path}")
          {:ok, summary}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:skipped, :no_extracts}
    end
  end

  defp extension_to_language(ext) do
    case ext do
      e when e in [".ex", ".exs"] -> :elixir
      e when e in [".js", ".jsx", ".ts", ".tsx"] -> :javascript
      ".py" -> :python
      ".rb" -> :ruby
      ".go" -> :go
      ".rs" -> :rust
      ".md" -> :markdown
      _ -> :unknown
    end
  end

  defp extract_key_content(content, language) do
    patterns = Map.get(@extract_patterns, language, [])

    patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, content)
      |> Enum.map(fn
        [_full, capture] -> String.trim(capture)
        [full] -> String.trim(full)
      end)
    end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "" or byte_size(&1) > 200))
    |> Enum.take(15)
  end

  defp build_summary(path, extracts, language) do
    filename = Path.basename(path)
    dir = Path.dirname(path)

    """
    File: #{filename}
    Path: #{path}
    Directory: #{dir}
    Language: #{language}
    Key elements: #{Enum.join(extracts, ", ")}
    Extracted at: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    """
  end

  defp store_in_memory(path, summary) do
    Memory.store(%{
      content: summary,
      category: :fact,
      importance: 0.6,
      metadata: %{
        type: "file_content_cache",
        path: path,
        extracted_at: DateTime.utc_now()
      }
    })
  rescue
    e ->
      Logger.warning("FileContentCache: Failed to store in memory: #{inspect(e)}")
      {:error, :memory_store_failed}
  end
end
