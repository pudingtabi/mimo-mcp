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

  @doc """
  Extract sections from PDF text.

  Detects section headers and splits content into logical sections with metadata.
  Supports numbered sections (1., 1.1, 1.1.1) and title case headers.

  ## Options
  - `:patterns` - Custom section patterns (list of regex or tuples)
  - `:min_section_length` - Minimum characters for a section (default: 50)
  - `:detect_hierarchy` - Detect section hierarchy from numbering (default: true)

  ## Returns
  - `{:ok, %{sections: [%{title: "", content: "", level: 1, page: 1}], ...}}`
  - `{:error, reason}`

  ## Example

      {:ok, result} = Pdf.read("/path/to/paper.pdf")
      {:ok, %{sections: sections}} = Pdf.extract_sections(result.markdown)
      # Returns: [%{title: "Abstract", content: "...", level: 1}, ...]
  """
  @spec extract_sections(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def extract_sections(text, opts \\ []) when is_binary(text) do
    min_length = Keyword.get(opts, :min_section_length, 50)
    detect_hierarchy = Keyword.get(opts, :detect_hierarchy, true)
    custom_patterns = Keyword.get(opts, :patterns, nil)

    patterns = custom_patterns || default_section_patterns()

    sections =
      text
      |> find_section_markers(patterns)
      |> extract_sections_from_markers(text, min_length)
      |> maybe_add_hierarchy(detect_hierarchy)

    {:ok, %{sections: sections, total_sections: length(sections)}}
  end

  @doc """
  Chunk PDF by sections instead of pages.

  Reads the PDF and returns section-based chunks with metadata.
  Each chunk represents a logical section of the document.

  ## Options
  - All options from `read/2`
  - `:min_section_length` - Minimum characters for a section (default: 50)
  - `:patterns` - Custom section patterns

  ## Returns
  - `{:ok, %{chunks: [%{title: "", content: "", level: 1, ...}], metadata: map}}`
  """
  @spec chunk_by_sections(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def chunk_by_sections(path, opts \\ []) do
    with {:ok, result} <- read(path, opts),
         {:ok, sections} <- extract_sections(result.markdown, opts) do
      {:ok,
       %{
         chunks: sections.sections,
         total_chunks: sections.total_sections,
         pages_total: result.pages_total,
         metadata: result.metadata
       }}
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Section Detection Patterns
  # ─────────────────────────────────────────────────────────────────

  @doc false
  def default_section_patterns do
    [
      # Numbered sections: "1. Introduction", "1.1 Background"
      {:numbered, ~r/(?:^|\n)\s*(\d+(?:\.\d+)*)\s*\.?\s+([A-Z][^.\n]{2,50})\s*(?:\n|$)/},
      # All caps headers: "INTRODUCTION", "METHODS"
      {:caps, ~r/(?:^|\n)\s*([A-Z]{2}[A-Z\s]{2,30})\s*(?:\n|$)/},
      # Title case with colon: "Introduction:", "Methods:"
      {:title_colon, ~r/(?:^|\n)\s*([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\s*:\s*(?:\n|$)/},
      # Common academic sections
      {:academic,
       ~r/(?:^|\n)\s*(?:\d+\.?\s*)?(Abstract|Introduction|Background|Related\s+Work|Methods?|Methodology|Approach|Experiments?|Results?|Discussion|Conclusion|References|Acknowledgements?|Appendix)\s*(?:\n|:)/i}
    ]
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
          |> Enum.map_join("\n\n", & &1["text"])

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

  # ─────────────────────────────────────────────────────────────────
  # Section Detection Helpers
  # ─────────────────────────────────────────────────────────────────

  defp find_section_markers(text, patterns) do
    patterns
    |> Enum.flat_map(fn {type, pattern} ->
      Regex.scan(pattern, text, return: :index)
      |> Enum.map(fn match ->
        [{start_pos, match_len} | captures] = match
        full_match = String.slice(text, start_pos, match_len)

        title = extract_title_from_captures(type, full_match, captures, text)
        level = detect_level(type, full_match)

        %{
          position: start_pos,
          title: title |> String.trim() |> clean_title(),
          level: level,
          type: type,
          match_length: match_len
        }
      end)
    end)
    |> Enum.uniq_by(& &1.position)
    |> Enum.sort_by(& &1.position)
  end

  defp extract_title_from_captures(:numbered, full_match, captures, text) do
    case captures do
      # Two captures: number and title
      [{_num_pos, _num_len}, {title_pos, title_len}] ->
        String.slice(text, title_pos, title_len)

      _ ->
        # Fall back to removing number prefix
        full_match
        |> String.replace(~r/^\s*\d+(?:\.\d+)*\s*\.?\s*/, "")
        |> String.trim()
    end
  end

  defp extract_title_from_captures(:caps, full_match, _captures, _text) do
    full_match |> String.trim()
  end

  defp extract_title_from_captures(:title_colon, full_match, captures, text) do
    case captures do
      [{title_pos, title_len} | _] ->
        String.slice(text, title_pos, title_len)

      _ ->
        full_match |> String.replace(":", "") |> String.trim()
    end
  end

  defp extract_title_from_captures(:academic, full_match, captures, text) do
    case captures do
      [{title_pos, title_len} | _] ->
        String.slice(text, title_pos, title_len) |> String.trim()

      _ ->
        full_match
        |> String.replace(~r/^\s*\d+\.?\s*/, "")
        |> String.replace(":", "")
        |> String.trim()
    end
  end

  defp extract_title_from_captures(_, full_match, _, _), do: String.trim(full_match)

  defp detect_level(:numbered, match) do
    case Regex.run(~r/^[\s\n]*(\d+(?:\.\d+)*)/, match) do
      [_, number] ->
        # Count dots + 1: "1" = level 1, "1.1" = level 2, "1.1.1" = level 3
        String.split(number, ".") |> length()

      _ ->
        1
    end
  end

  defp detect_level(:caps, _match), do: 1
  defp detect_level(:academic, _match), do: 1
  defp detect_level(:title_colon, _match), do: 2
  defp detect_level(_, _), do: 1

  defp clean_title(title) do
    title
    |> String.replace(~r/^\d+(?:\.\d+)*\s*\.?\s*/, "")
    |> String.replace(~r/[:]+$/, "")
    |> String.trim()
  end

  defp extract_sections_from_markers([], text, min_length) do
    # No sections found - return entire text as one section
    if String.length(text) >= min_length do
      [%{title: "Document", content: String.trim(text), level: 1}]
    else
      []
    end
  end

  defp extract_sections_from_markers(markers, text, min_length) do
    text_length = String.length(text)

    markers
    |> Enum.with_index()
    |> Enum.map(fn {marker, idx} ->
      content_start = marker.position + marker.match_length

      content_end =
        case Enum.at(markers, idx + 1) do
          nil -> text_length
          next_marker -> next_marker.position
        end

      content =
        text
        |> String.slice(content_start, content_end - content_start)
        |> String.trim()

      %{
        title: marker.title,
        content: content,
        level: marker.level,
        position: marker.position,
        type: marker.type
      }
    end)
    |> Enum.filter(&(String.length(&1.content) >= min_length))
  end

  defp maybe_add_hierarchy(sections, false), do: sections

  defp maybe_add_hierarchy(sections, true) do
    sections
    |> Enum.with_index()
    |> Enum.map(fn {section, idx} ->
      parent = find_parent_section(sections, section.level, idx)
      Map.put(section, :parent_index, parent)
    end)
  end

  defp find_parent_section(_sections, 1, _current_idx), do: nil

  defp find_parent_section(sections, current_level, current_idx) do
    sections
    |> Enum.take(current_idx)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {section, idx} ->
      if section.level < current_level, do: idx
    end)
  end
end
