defmodule Mimo.Skills.Network.StructuredDataTest do
  use ExUnit.Case, async: true

  alias Mimo.Skills.Network

  describe "extract_structured_data/1" do
    test "extracts JSON-LD data from script tags" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@type": "Article",
          "headline": "Test Article",
          "author": {"@type": "Person", "name": "John Doe"}
        }
        </script>
      </head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      assert length(result.json_ld) == 1
      [article] = result.json_ld
      assert article["@type"] == "Article"
      assert article["headline"] == "Test Article"
    end

    test "handles @graph arrays in JSON-LD" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@graph": [
            {"@type": "WebPage", "name": "Test Page"},
            {"@type": "Article", "headline": "Test Article"}
          ]
        }
        </script>
      </head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      # @graph should be flattened
      assert length(result.json_ld) == 2
      types = Enum.map(result.json_ld, & &1["@type"])
      assert "WebPage" in types
      assert "Article" in types
    end

    test "extracts multiple JSON-LD blocks" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <script type="application/ld+json">
        {"@type": "Organization", "name": "Acme Inc"}
        </script>
        <script type="application/ld+json">
        {"@type": "WebSite", "name": "Acme Blog"}
        </script>
      </head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      assert length(result.json_ld) == 2
    end

    test "extracts OpenGraph metadata" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <meta property="og:title" content="Test Title">
        <meta property="og:description" content="Test Description">
        <meta property="og:image" content="https://example.com/image.jpg">
        <meta property="og:type" content="article">
        <meta property="og:url" content="https://example.com/page">
      </head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      assert result.opengraph["title"] == "Test Title"
      assert result.opengraph["description"] == "Test Description"
      assert result.opengraph["image"] == "https://example.com/image.jpg"
      assert result.opengraph["type"] == "article"
      assert result.opengraph["url"] == "https://example.com/page"
    end

    test "extracts Twitter Card metadata" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <meta name="twitter:card" content="summary_large_image">
        <meta name="twitter:site" content="@testsite">
        <meta name="twitter:title" content="Twitter Title">
        <meta name="twitter:description" content="Twitter Description">
      </head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      assert result.twitter["card"] == "summary_large_image"
      assert result.twitter["site"] == "@testsite"
      assert result.twitter["title"] == "Twitter Title"
    end

    test "extracts canonical URL" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <link rel="canonical" href="https://example.com/canonical-url">
      </head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      assert result.meta.canonical == "https://example.com/canonical-url"
    end

    test "extracts language from html tag" do
      html = """
      <!DOCTYPE html>
      <html lang="en-US">
      <head></head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      assert result.meta.language == "en-US"
    end

    test "extracts charset" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
      </head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      assert result.meta.charset == "UTF-8"
    end

    test "extracts article metadata" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <meta property="article:published_time" content="2024-01-15T10:00:00Z">
        <meta property="article:modified_time" content="2024-01-16T12:00:00Z">
        <meta property="article:section" content="Technology">
        <meta property="article:tag" content="AI">
        <meta property="article:tag" content="Machine Learning">
      </head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      assert result.meta.published_time == "2024-01-15T10:00:00Z"
      assert result.meta.modified_time == "2024-01-16T12:00:00Z"
      assert result.meta.section == "Technology"
      assert result.meta.tags == ["AI", "Machine Learning"]
    end

    test "extracts basic meta tags" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <meta name="author" content="Jane Doe">
        <meta name="description" content="Page description">
        <meta name="keywords" content="keyword1, keyword2">
        <meta name="robots" content="index, follow">
      </head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      assert result.meta.author == "Jane Doe"
      assert result.meta.description == "Page description"
      assert result.meta.keywords == "keyword1, keyword2"
      assert result.meta.robots == "index, follow"
    end

    test "handles invalid JSON-LD gracefully" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <script type="application/ld+json">
        {invalid json here}
        </script>
        <script type="application/ld+json">
        {"@type": "Valid", "name": "Test"}
        </script>
      </head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      # Invalid JSON should be skipped, valid one kept
      assert length(result.json_ld) == 1
      assert hd(result.json_ld)["@type"] == "Valid"
    end

    test "handles empty HTML" do
      html = ""
      # Empty HTML is still parseable - returns empty structure
      {:ok, result} = Network.extract_structured_data(html)
      assert result.json_ld == []
      assert result.opengraph == %{}
      assert result.twitter == %{}
    end

    test "handles minimal HTML without structured data" do
      html = """
      <!DOCTYPE html>
      <html>
      <head><title>Simple Page</title></head>
      <body><p>Content</p></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      assert result.json_ld == []
      assert result.opengraph == %{}
      assert result.twitter == %{}
    end

    test "extracts charset from Content-Type meta" do
      html = """
      <!DOCTYPE html>
      <html>
      <head>
        <meta http-equiv="Content-Type" content="text/html; charset=ISO-8859-1">
      </head>
      <body></body>
      </html>
      """

      {:ok, result} = Network.extract_structured_data(html)

      assert result.meta.charset == "ISO-8859-1"
    end
  end
end
