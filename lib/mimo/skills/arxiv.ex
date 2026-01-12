defmodule Mimo.Skills.Arxiv do
  @moduledoc """
  arXiv API integration for searching and retrieving research papers.

  Part of Track 6: PDF/Document Integration - Phase 6.3.

  ## Features

  - Search arXiv papers by query
  - Retrieve paper metadata by arXiv ID
  - Download and extract PDF content
  - Extract structured sections (abstract, methods, etc.)

  ## Usage

      # Search for papers
      {:ok, papers} = Arxiv.search("transformer attention mechanism", limit: 5)

      # Get specific paper metadata
      {:ok, paper} = Arxiv.get_paper("2601.01885")

      # Get paper with full PDF content
      {:ok, paper} = Arxiv.get_paper_with_pdf("2601.01885")
  """

  require Logger

  alias Mimo.Skills.Pdf

  @api_base "https://export.arxiv.org/api/query"
  @pdf_base "https://arxiv.org/pdf"
  @timeout 30_000

  # ─────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Search arXiv for papers matching the query.

  ## Options
  - `:limit` - Maximum number of results (default: 10, max: 100)
  - `:start` - Starting index for pagination (default: 0)
  - `:sort_by` - Sort field: "relevance", "lastUpdatedDate", "submittedDate" (default: "relevance")
  - `:sort_order` - "ascending" or "descending" (default: "descending")
  - `:categories` - List of arXiv categories to filter, e.g. ["cs.AI", "cs.LG"]

  ## Returns
  - `{:ok, [paper_map]}`
  - `{:error, reason}`

  ## Example

      {:ok, papers} = Arxiv.search("large language models memory", limit: 5)
      # => [{id: "2601.01885", title: "...", authors: [...], summary: "..."}, ...]
  """
  @spec search(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10) |> min(100)
    start = Keyword.get(opts, :start, 0)
    sort_by = Keyword.get(opts, :sort_by, "relevance")
    sort_order = Keyword.get(opts, :sort_order, "descending")
    categories = Keyword.get(opts, :categories, [])

    # Build search query with optional category filter
    search_query = build_search_query(query, categories)

    url =
      "#{@api_base}?search_query=#{URI.encode(search_query)}" <>
        "&start=#{start}&max_results=#{limit}" <>
        "&sortBy=#{sort_by}&sortOrder=#{sort_order}"

    Logger.debug("arXiv API query: #{url}")

    case fetch_and_parse(url) do
      {:ok, papers} -> {:ok, papers}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get a specific paper by arXiv ID.

  The ID can be in various formats:
  - "2601.01885" (modern format)
  - "2601.01885v1" (with version)
  - "hep-th/9901001" (old format)

  ## Returns
  - `{:ok, paper_map}`
  - `{:error, :not_found}`
  - `{:error, reason}`
  """
  @spec get_paper(String.t()) :: {:ok, map()} | {:error, term()}
  def get_paper(arxiv_id) do
    # Normalize the ID (remove version suffix for lookup)
    normalized_id = normalize_id(arxiv_id)

    url = "#{@api_base}?id_list=#{normalized_id}"

    case fetch_and_parse(url) do
      {:ok, [paper]} -> {:ok, paper}
      {:ok, []} -> {:error, :not_found}
      {:ok, papers} -> {:ok, List.first(papers)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get a paper with its full PDF content extracted.

  ## Options
  - `:pages` - Specific pages to extract (default: all)
  - `:extract_sections` - Try to extract sections (default: true)

  ## Returns
  - `{:ok, %{paper: paper_map, pdf_content: content, sections: sections_map}}`
  - `{:error, reason}`
  """
  @spec get_paper_with_pdf(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_paper_with_pdf(arxiv_id, opts \\ []) do
    with {:ok, paper} <- get_paper(arxiv_id),
         {:ok, pdf_result} <- fetch_pdf(arxiv_id, opts) do
      sections =
        if Keyword.get(opts, :extract_sections, true) do
          extract_sections(pdf_result.markdown)
        else
          %{}
        end

      {:ok,
       %{
         paper: paper,
         pdf_content: pdf_result.markdown,
         pages_total: pdf_result.pages_total,
         sections: sections
       }}
    end
  end

  @doc """
  Get only the PDF content for an arXiv paper.

  ## Options
  - `:pages` - List of page numbers to extract (1-indexed)
  """
  @spec get_pdf(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_pdf(arxiv_id, opts \\ []) do
    fetch_pdf(arxiv_id, opts)
  end

  @doc """
  Check if arXiv API is accessible.
  """
  @spec available?() :: boolean()
  def available? do
    case Req.get("#{@api_base}?search_query=test&max_results=1",
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Private Functions
  # ─────────────────────────────────────────────────────────────────

  defp build_search_query(query, []) do
    # Search all fields
    "all:#{query}"
  end

  defp build_search_query(query, categories) when is_list(categories) do
    # Build category filter
    cat_filter =
      categories
      |> Enum.map_join("+OR+", &"cat:#{&1}")

    "all:#{query}+AND+(#{cat_filter})"
  end

  defp fetch_and_parse(url) do
    case Req.get(url, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: body}} ->
        parse_atom_response(body)

      {:ok, %{status: status}} ->
        {:error, "arXiv API returned status #{status}"}

      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  defp parse_atom_response(xml) when is_binary(xml) do
    # Parse Atom XML using Floki
    case Floki.parse_document(xml) do
      {:ok, doc} ->
        papers = extract_entries(doc)
        {:ok, papers}

      {:error, reason} ->
        {:error, "XML parse error: #{inspect(reason)}"}
    end
  end

  defp extract_entries(doc) do
    doc
    |> Floki.find("entry")
    |> Enum.map(&parse_entry/1)
  end

  defp parse_entry(entry) do
    %{
      id: extract_arxiv_id(entry),
      title: entry |> Floki.find("title") |> Floki.text() |> clean_text(),
      authors: extract_authors(entry),
      summary: entry |> Floki.find("summary") |> Floki.text() |> clean_text(),
      published: entry |> Floki.find("published") |> Floki.text(),
      updated: entry |> Floki.find("updated") |> Floki.text(),
      categories: extract_categories(entry),
      primary_category: extract_primary_category(entry),
      pdf_url: extract_pdf_url(entry),
      abs_url: extract_abs_url(entry),
      comment: entry |> Floki.find("arxiv|comment") |> Floki.text() |> clean_text(),
      journal_ref: entry |> Floki.find("arxiv|journal_ref") |> Floki.text() |> clean_text(),
      doi: entry |> Floki.find("arxiv|doi") |> Floki.text() |> clean_text()
    }
  end

  defp extract_arxiv_id(entry) do
    entry
    |> Floki.find("id")
    |> Floki.text()
    |> String.trim()
    |> String.replace(~r{^https?://arxiv\.org/abs/}, "")
  end

  defp extract_authors(entry) do
    entry
    |> Floki.find("author")
    |> Enum.map(fn author ->
      name = author |> Floki.find("name") |> Floki.text() |> clean_text()
      affiliation = author |> Floki.find("arxiv|affiliation") |> Floki.text() |> clean_text()

      if affiliation != "" do
        %{name: name, affiliation: affiliation}
      else
        %{name: name}
      end
    end)
  end

  defp extract_categories(entry) do
    entry
    |> Floki.find("category")
    |> Enum.map(fn cat ->
      Floki.attribute(cat, "term") |> List.first() || ""
    end)
    |> Enum.filter(&(&1 != ""))
  end

  defp extract_primary_category(entry) do
    entry
    |> Floki.find("arxiv|primary_category")
    |> Floki.attribute("term")
    |> List.first()
  end

  defp extract_pdf_url(entry) do
    entry
    |> Floki.find("link[title=pdf]")
    |> Floki.attribute("href")
    |> List.first()
  end

  defp extract_abs_url(entry) do
    entry
    |> Floki.find("link[rel=alternate]")
    |> Floki.attribute("href")
    |> List.first()
  end

  defp clean_text(nil), do: ""
  defp clean_text([]), do: ""

  defp clean_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp normalize_id(id) do
    # Remove version suffix (e.g., "v1", "v2") for API lookup
    String.replace(id, ~r/v\d+$/, "")
  end

  defp fetch_pdf(arxiv_id, opts) do
    # Build PDF URL
    normalized_id = normalize_id(arxiv_id)
    pdf_url = "#{@pdf_base}/#{normalized_id}.pdf"

    Logger.debug("Fetching arXiv PDF: #{pdf_url}")

    # Use existing PDF skill
    Pdf.read_url(pdf_url, opts)
  end

  @doc """
  Extract sections from paper text content.

  Attempts to identify common academic paper sections:
  - Abstract
  - Introduction
  - Related Work
  - Methods/Methodology
  - Results/Experiments
  - Discussion
  - Conclusion
  - References

  ## Returns
  Map with section names as keys and content as values.
  """
  @spec extract_sections(String.t()) :: map()
  def extract_sections(text) when is_binary(text) do
    sections = %{}

    # Define section patterns (case insensitive)
    section_patterns = [
      {"abstract", ~r/(?:^|\n)\s*(?:abstract|summary)\s*[\n:]/i},
      {"introduction", ~r/(?:^|\n)\s*(?:\d+\.?\s*)?introduction\s*[\n:]/i},
      {"related_work",
       ~r/(?:^|\n)\s*(?:\d+\.?\s*)?(?:related\s+work|background|literature\s+review)\s*[\n:]/i},
      {"methods", ~r/(?:^|\n)\s*(?:\d+\.?\s*)?(?:methods?|methodology|approach)\s*[\n:]/i},
      {"experiments", ~r/(?:^|\n)\s*(?:\d+\.?\s*)?(?:experiments?|results?|evaluation)\s*[\n:]/i},
      {"discussion", ~r/(?:^|\n)\s*(?:\d+\.?\s*)?discussion\s*[\n:]/i},
      {"conclusion", ~r/(?:^|\n)\s*(?:\d+\.?\s*)?(?:conclusions?|summary|future\s+work)\s*[\n:]/i},
      {"references", ~r/(?:^|\n)\s*(?:references|bibliography)\s*[\n:]/i}
    ]

    # Find all section positions
    positions =
      section_patterns
      |> Enum.flat_map(fn {name, pattern} ->
        case Regex.run(pattern, text, return: :index) do
          [{start, _len}] -> [{name, start}]
          _ -> []
        end
      end)
      |> Enum.sort_by(fn {_name, pos} -> pos end)

    # Extract content between sections
    extract_between_positions(text, positions, sections)
  end

  defp extract_between_positions(_text, [], sections), do: sections

  defp extract_between_positions(text, [{name, start} | rest], sections) do
    # Find end position (next section start or end of text)
    end_pos =
      case rest do
        [{_next_name, next_start} | _] -> next_start
        [] -> String.length(text)
      end

    content =
      text
      |> String.slice(start, end_pos - start)
      |> clean_section_content()

    sections = Map.put(sections, name, content)
    extract_between_positions(text, rest, sections)
  end

  defp clean_section_content(content) do
    content
    |> String.trim()
    |> String.replace(~r/^\s*(?:\d+\.?\s*)?[A-Z][a-z]+(?:\s+[A-Z]?[a-z]+)*\s*\n/, "")
    |> String.trim()
  end
end
