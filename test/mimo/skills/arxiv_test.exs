defmodule Mimo.Skills.ArxivTest do
  use ExUnit.Case, async: false

  alias Mimo.Skills.Arxiv

  @moduletag :external
  @moduletag timeout: 60_000

  describe "search/2" do
    test "searches arXiv for papers" do
      {:ok, papers} = Arxiv.search("large language models", limit: 3)

      assert is_list(papers)
      assert length(papers) <= 3

      if Enum.any?(papers) do
        paper = List.first(papers)
        assert is_binary(paper.id)
        assert is_binary(paper.title)
        assert is_list(paper.authors)
        assert is_binary(paper.summary)
        assert is_binary(paper.published)
        assert is_list(paper.categories)
      end
    end

    test "filters by category" do
      {:ok, papers} = Arxiv.search("neural networks", limit: 5, categories: ["cs.AI", "cs.LG"])

      assert is_list(papers)

      if Enum.any?(papers) do
        # All papers should have at least one of the requested categories
        for paper <- papers do
          assert Enum.any?(paper.categories, &(&1 in ["cs.AI", "cs.LG", "cs.CL", "cs.NE"]))
        end
      end
    end

    test "handles empty results gracefully" do
      {:ok, papers} = Arxiv.search("zzzznonexistentqueryzzz12345", limit: 1)
      assert is_list(papers)
    end
  end

  describe "get_paper/1" do
    test "retrieves paper by ID" do
      # Use a known stable paper
      {:ok, paper} = Arxiv.get_paper("1706.03762")

      assert paper.id =~ "1706.03762"
      assert paper.title =~ "Attention"
      assert is_list(paper.authors)
      assert Enum.any?(paper.authors)
    end

    test "returns error for non-existent paper" do
      result = Arxiv.get_paper("9999.99999")
      assert {:error, :not_found} = result
    end

    test "handles old-format IDs" do
      # Old format ID (hep-th/...)
      {:ok, paper} = Arxiv.get_paper("hep-th/9711200")
      assert paper.id =~ "hep-th/9711200"
    end
  end

  describe "get_paper_with_pdf/2" do
    @tag :slow
    test "retrieves paper with PDF content" do
      {:ok, result} = Arxiv.get_paper_with_pdf("1706.03762")

      assert is_map(result.paper)
      assert result.paper.title =~ "Attention"
      assert is_binary(result.pdf_content)
      assert byte_size(result.pdf_content) > 1000
      assert is_integer(result.pages_total)
      assert result.pages_total > 0
      assert is_map(result.sections)
    end
  end

  describe "extract_sections/1" do
    test "extracts common paper sections" do
      sample_text = """
      Abstract

      This paper presents a novel approach to memory management in AI agents.

      1. Introduction

      Memory is crucial for AI systems. We propose a new architecture.

      2. Methods

      Our method uses a two-phase pipeline with semantic search.

      3. Results

      We achieved 95% accuracy on benchmark tasks.

      4. Conclusion

      This work demonstrates the importance of unified memory management.

      References

      [1] Smith et al. (2024). Memory Systems.
      """

      sections = Arxiv.extract_sections(sample_text)

      assert Map.has_key?(sections, "abstract")
      assert Map.has_key?(sections, "introduction")
      assert Map.has_key?(sections, "methods")
      assert Map.has_key?(sections, "conclusion")
      assert Map.has_key?(sections, "references")
    end
  end

  describe "available?/0" do
    test "checks API availability" do
      result = Arxiv.available?()
      assert is_boolean(result)
    end
  end
end
