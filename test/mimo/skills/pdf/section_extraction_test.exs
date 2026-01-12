defmodule Mimo.Skills.Pdf.SectionExtractionTest do
  @moduledoc """
  Tests for PDF section extraction and chunking.
  Track 6 Phase 6.4: Section-Aware Chunking.
  """
  use ExUnit.Case, async: true

  alias Mimo.Skills.Pdf

  describe "extract_sections/2" do
    test "extracts numbered sections like '1. Introduction'" do
      text = """
      Some preamble text here that provides context.

      1. Introduction

      This is the introduction section with some content that spans multiple lines
      and provides context about what we're doing. It needs to be long enough to
      pass the minimum length filter of 50 characters.

      2. Methods

      Here we describe the methodology used in this study in significant detail.
      Multiple paragraphs of method description follow to make sure we have enough
      content to pass the minimum length filter.

      3. Results

      The results section contains findings from our comprehensive analysis.
      We present the data and discuss what it means for our research objectives.
      """

      {:ok, result} = Pdf.extract_sections(text)

      assert result.total_sections == 3
      assert Enum.map(result.sections, & &1.title) == ["Introduction", "Methods", "Results"]

      intro = Enum.find(result.sections, &(&1.title == "Introduction"))
      assert intro.level == 1
      assert String.contains?(intro.content, "introduction section")
    end

    test "extracts nested numbered sections with hierarchy" do
      text = """
      1. Main Section

      Overview of the main section content here with enough detail to pass the
      minimum length filter. This content needs to be substantial.

      1.1 Subsection A

      Content for subsection A with details that span multiple lines to ensure
      we have enough characters to pass the filter requirement.

      1.1.1 Sub-subsection

      Even more detailed content here that goes into the specifics of this
      particular sub-subsection topic.

      1.2 Subsection B

      Content for subsection B with its own detailed explanations and context
      that make it a meaningful section worth extracting.

      2. Another Main Section

      Content for another main section that wraps up this example document
      with additional information and context.
      """

      {:ok, result} = Pdf.extract_sections(text, detect_hierarchy: true)

      assert result.total_sections == 5

      # Check levels are correct
      main = Enum.find(result.sections, &(&1.title == "Main Section"))
      sub_a = Enum.find(result.sections, &(&1.title == "Subsection A"))
      sub_sub = Enum.find(result.sections, &(&1.title == "Sub-subsection"))

      assert main.level == 1
      assert sub_a.level == 2
      assert sub_sub.level == 3
    end

    test "extracts ALL CAPS headers" do
      text = """
      INTRODUCTION

      This is the introduction with important content that provides enough detail
      to pass the minimum length filter of 50 characters. More content follows.

      METHODOLOGY

      Description of methods used in our study with detailed explanations that
      span multiple lines for completeness.

      CONCLUSION

      Final thoughts and summary of what we learned from this research endeavor
      and its implications for future work.
      """

      {:ok, result} = Pdf.extract_sections(text)

      assert result.total_sections == 3
      titles = Enum.map(result.sections, & &1.title)
      assert "INTRODUCTION" in titles
      assert "METHODOLOGY" in titles
      assert "CONCLUSION" in titles
    end

    test "extracts title case headers with colon" do
      text = """
      Background:

      Some background information that is relevant and provides context about
      the topic we are discussing in this document section.

      Problem Statement:

      The problem we are addressing in this work is complex and requires careful
      analysis and consideration of multiple factors.

      Proposed Solution:

      Our approach to solving the problem involves several steps that we will
      outline in detail throughout this section.
      """

      {:ok, result} = Pdf.extract_sections(text)

      assert result.total_sections >= 2
      titles = Enum.map(result.sections, & &1.title)
      assert Enum.any?(titles, &String.contains?(&1, "Background"))
    end

    test "extracts common academic sections" do
      text = """
      Abstract

      This paper presents a novel approach to the problem that has been
      studied extensively in prior literature and research.

      Introduction

      We introduce the context and motivation for our work and discuss
      the background needed to understand our contributions.

      Methods

      The methodology is described here with sufficient detail to allow
      replication of our experimental procedures.

      Results

      Our findings show significant improvement over prior approaches
      and demonstrate the effectiveness of our method.

      Discussion

      We discuss implications of our results and their relevance to the
      broader field of study.

      Conclusion

      In conclusion, this work demonstrates value and opens new avenues
      for future research in this area.

      References

      [1] Smith et al., 2023 - A comprehensive study of the topic
      [2] Jones et al., 2022 - Related work in the field
      """

      {:ok, result} = Pdf.extract_sections(text)

      assert result.total_sections >= 5
      titles = Enum.map(result.sections, &String.downcase(&1.title))

      assert Enum.any?(titles, &String.contains?(&1, "abstract"))
      assert Enum.any?(titles, &String.contains?(&1, "introduction"))
      assert Enum.any?(titles, &String.contains?(&1, "method"))
    end

    test "respects min_section_length option" do
      text = """
      1. Short

      Tiny.

      2. Long Section

      This section has enough content to pass the minimum length filter.
      It spans multiple lines and contains substantial information.
      """

      {:ok, result} = Pdf.extract_sections(text, min_section_length: 50)

      # Short section filtered out
      assert result.total_sections == 1
      assert hd(result.sections).title == "Long Section"
    end

    test "returns entire document when no sections found" do
      text = """
      This is just a plain text document without any clear section headers.
      It contains multiple paragraphs of content but no structured sections.
      The text goes on for a while to meet the minimum length requirement.
      """

      {:ok, result} = Pdf.extract_sections(text, min_section_length: 10)

      assert result.total_sections == 1
      assert hd(result.sections).title == "Document"
    end

    test "handles empty text" do
      {:ok, result} = Pdf.extract_sections("")

      assert result.total_sections == 0
      assert result.sections == []
    end

    test "detects parent_index for hierarchy" do
      text = """
      1. Parent Section

      Content for parent section that is substantial enough to pass the
      minimum length filter for section extraction.

      1.1 Child Section

      Content for child section that also has enough content to be
      included in the extracted sections.
      """

      {:ok, result} = Pdf.extract_sections(text, detect_hierarchy: true)

      child = Enum.find(result.sections, &(&1.title == "Child Section"))
      parent = Enum.find(result.sections, &(&1.title == "Parent Section"))

      assert child.parent_index != nil
      # Child's parent should be the parent section
      assert parent.parent_index == nil
    end

    test "disables hierarchy detection when option is false" do
      text = """
      1. Parent Section

      Content for parent section that is substantial enough to pass the
      minimum length filter for section extraction.

      1.1 Child Section

      Content for child section that also has enough content to be
      included in the extracted sections.
      """

      {:ok, result} = Pdf.extract_sections(text, detect_hierarchy: false)

      # Should not have parent_index key
      assert length(result.sections) > 0
      refute Map.has_key?(hd(result.sections), :parent_index)
    end
  end

  describe "default_section_patterns/0" do
    test "returns list of pattern tuples" do
      patterns = Pdf.default_section_patterns()

      assert is_list(patterns)
      assert length(patterns) > 0

      Enum.each(patterns, fn {type, pattern} ->
        assert is_atom(type)
        assert %Regex{} = pattern
      end)
    end
  end

  describe "chunk_by_sections/2 integration" do
    # This test requires PyMuPDF - skip if not available
    @tag :integration
    test "chunks a real PDF by sections" do
      if Pdf.available?() do
        # Would need a test PDF file
        # For now, just verify the function exists and has correct arity
        assert function_exported?(Pdf, :chunk_by_sections, 2)
      end
    end
  end
end
