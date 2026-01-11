defmodule Mimo.Skills.Pdf do
  @moduledoc """
  PDF reading and text extraction using PyMuPDF (fitz).

  Provides PDF-to-Markdown conversion for local files and URLs.
  Part of Track 6: PDF/Document Integration.

  ## Features

  - Extract text from PDF files
  - Convert PDF pages to Markdown format
  - Support for both local files and URLs
  - Page-by-page or full document extraction
  - Metadata extraction (title, author, etc.)

  ## Usage

      # Read entire PDF
      {:ok, %{markdown: text, pages: 10}} = Pdf.read("/path/to/document.pdf")

      # Read specific pages
      {:ok, result} = Pdf.read("/path/to/document.pdf", pages: [1, 2, 3])

      # Read from URL
      {:ok, result} = Pdf.read_url("https://example.com/document.pdf")
  """

  require Logger

  @timeout 60_000

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Read a PDF file and convert to Markdown.

  ## Options
  - `:pages` - List of page numbers to extract (1-indexed), or `:all` (default)
  - `:include_metadata` - Include document metadata (default: true)
  - `:format` - Output format: `:markdown` (default) or `:text`

  ## Returns
  - `{:ok, %{markdown: text, pages: count, metadata: map}}`
  - `{:error, reason}`
  """
  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(path, opts \\ []) do
    path = Path.expand(path)

    cond do
      not File.exists?(path) ->
        {:error, "File not found: #{path}"}

      not String.ends_with?(String.downcase(path), ".pdf") ->
        {:error, "Not a PDF file: #{path}"}

      true ->
        extract_pdf(path, opts)
    end
  end

  @doc """
  Read a PDF from a URL and convert to Markdown.

  Downloads the PDF to a temp file, extracts text, then cleans up.
  """
  @spec read_url(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_url(url, opts \\ []) do
    with {:ok, tmp_path} <- download_pdf(url),
         {:ok, result} <- extract_pdf(tmp_path, opts) do
      # Cleanup temp file
      File.rm(tmp_path)
      {:ok, Map.put(result, :source_url, url)}
    else
      {:error, reason} = error ->
        Logger.warning("[PDF] Failed to read URL #{url}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Get metadata from a PDF without extracting text.
  """
  @spec metadata(String.t()) :: {:ok, map()} | {:error, term()}
  def metadata(path) do
    path = Path.expand(path)

    if File.exists?(path) do
      extract_metadata(path)
    else
      {:error, "File not found: #{path}"}
    end
  end

  @doc """
  Check if PyMuPDF is available.
  """
  @spec available?() :: boolean()
  def available? do
    case System.cmd("python3", ["-c", "import fitz; print('ok')"], stderr_to_stdout: true) do
      {"ok\n", 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ─────────────────────────────────────────────────────────────────
  # Private Implementation
  # ─────────────────────────────────────────────────────────────────

  defp extract_pdf(path, opts) do
    pages_opt = Keyword.get(opts, :pages, :all)
    include_metadata = Keyword.get(opts, :include_metadata, true)
    format = Keyword.get(opts, :format, :markdown)

    script = build_extraction_script(path, pages_opt, include_metadata, format)

    case run_python(script) do
      {:ok, output} ->
        parse_extraction_output(output)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_extraction_script(path, pages_opt, include_metadata, format) do
    pages_filter =
      case pages_opt do
        :all -> "None"
        pages when is_list(pages) -> "[#{Enum.join(pages, ", ")}]"
        _ -> "None"
      end

    """
    import json
    import sys

    try:
        import fitz  # PyMuPDF
    except ImportError:
        print(json.dumps({"error": "PyMuPDF not installed. Run: pip install PyMuPDF"}))
        sys.exit(1)

    path = #{inspect(path)}
    pages_filter = #{pages_filter}
    include_metadata = #{if include_metadata, do: "True", else: "False"}
    format_type = #{inspect(to_string(format))}

    try:
        doc = fitz.open(path)
        result = {
            "pages_total": len(doc),
            "pages_extracted": 0,
            "content": [],
            "metadata": {}
        }

        # Extract metadata
        if include_metadata:
            meta = doc.metadata
            result["metadata"] = {
                "title": meta.get("title", ""),
                "author": meta.get("author", ""),
                "subject": meta.get("subject", ""),
                "creator": meta.get("creator", ""),
                "producer": meta.get("producer", ""),
                "creation_date": meta.get("creationDate", ""),
                "mod_date": meta.get("modDate", "")
            }

        # Determine which pages to extract
        if pages_filter is None:
            page_indices = range(len(doc))
        else:
            # Convert 1-indexed to 0-indexed
            page_indices = [p - 1 for p in pages_filter if 0 < p <= len(doc)]

        # Extract text from each page
        for i in page_indices:
            page = doc[i]
            text = page.get_text()

            if format_type == "markdown":
                # Add page header for markdown
                page_content = f"\\n## Page {i + 1}\\n\\n{text}"
            else:
                page_content = text

            result["content"].append({
                "page": i + 1,
                "text": page_content.strip()
            })
            result["pages_extracted"] += 1

        doc.close()
        print(json.dumps({"success": True, "data": result}))

    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
    """
  end

  defp parse_extraction_output(output) do
    case Jason.decode(output) do
      {:ok, %{"success" => true, "data" => data}} ->
        markdown =
          data["content"]
          |> Enum.map(& &1["text"])
          |> Enum.join("\n\n")

        {:ok,
         %{
           markdown: markdown,
           pages_total: data["pages_total"],
           pages_extracted: data["pages_extracted"],
           metadata: data["metadata"] || %{},
           content_by_page: data["content"]
         }}

      {:ok, %{"error" => reason}} ->
        {:error, reason}

      {:error, _} ->
        {:error, "Failed to parse Python output: #{String.slice(output, 0, 200)}"}
    end
  end

  defp extract_metadata(path) do
    script = """
    import json
    import sys

    try:
        import fitz
    except ImportError:
        print(json.dumps({"error": "PyMuPDF not installed"}))
        sys.exit(1)

    try:
        doc = fitz.open(#{inspect(path)})
        meta = doc.metadata
        result = {
            "title": meta.get("title", ""),
            "author": meta.get("author", ""),
            "subject": meta.get("subject", ""),
            "creator": meta.get("creator", ""),
            "producer": meta.get("producer", ""),
            "creation_date": meta.get("creationDate", ""),
            "mod_date": meta.get("modDate", ""),
            "page_count": len(doc)
        }
        doc.close()
        print(json.dumps({"success": True, "data": result}))
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
    """

    case run_python(script) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, %{"success" => true, "data" => data}} ->
            {:ok, data}

          {:ok, %{"error" => reason}} ->
            {:error, reason}

          _ ->
            {:error, "Failed to parse metadata"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp download_pdf(url) do
    tmp_dir = System.tmp_dir!()
    filename = "mimo_pdf_#{:erlang.phash2(url)}_#{System.system_time(:millisecond)}.pdf"
    tmp_path = Path.join(tmp_dir, filename)

    # Use Req to download
    case Req.get(url, receive_timeout: @timeout, into: File.stream!(tmp_path)) do
      {:ok, %{status: 200}} ->
        {:ok, tmp_path}

      {:ok, %{status: status}} ->
        File.rm(tmp_path)
        {:error, "HTTP #{status} when downloading PDF"}

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, "Download failed: #{inspect(reason)}"}
    end
  end

  defp run_python(script) do
    # Write script to temp file to avoid shell escaping issues
    tmp_dir = System.tmp_dir!()
    script_path = Path.join(tmp_dir, "mimo_pdf_#{System.system_time(:millisecond)}.py")

    File.write!(script_path, script)

    try do
      case System.cmd("python3", [script_path], stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, String.trim(output)}

        {output, _code} ->
          # Try to extract JSON error from output
          case Jason.decode(output) do
            {:ok, %{"error" => reason}} ->
              {:error, reason}

            _ ->
              {:error, "Python error: #{String.slice(output, 0, 500)}"}
          end
      end
    after
      File.rm(script_path)
    end
  rescue
    e ->
      {:error, "Failed to run Python: #{Exception.message(e)}"}
  end
end
