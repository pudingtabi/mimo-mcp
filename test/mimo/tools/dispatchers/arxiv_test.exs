defmodule Mimo.Tools.Dispatchers.ArxivTest do
  use ExUnit.Case, async: false

  alias Mimo.Tools.Dispatchers.Web

  @moduletag :external
  @moduletag timeout: 60_000

  describe "dispatch_arxiv_search/1" do
    test "searches arXiv via dispatcher" do
      {:ok, result} = Web.dispatch_arxiv_search(%{"query" => "attention mechanism", "limit" => 2})

      assert result.operation == :arxiv_search
      assert result.query == "attention mechanism"
      assert is_integer(result.results_count)
      assert is_list(result.papers)
      assert is_binary(result.interpretation)
    end

    test "returns error for missing query" do
      {:error, msg} = Web.dispatch_arxiv_search(%{})
      assert msg =~ "Query is required"
    end
  end

  describe "dispatch_arxiv_paper/1" do
    test "retrieves paper by ID via dispatcher" do
      {:ok, result} = Web.dispatch_arxiv_paper(%{"id" => "1706.03762"})

      assert result.operation == :arxiv_paper
      assert result.paper.id =~ "1706.03762"
      assert result.paper.title =~ "Attention"
      assert is_binary(result.interpretation)
    end

    test "returns error for missing ID" do
      {:error, msg} = Web.dispatch_arxiv_paper(%{})
      assert msg =~ "Paper ID is required"
    end

    test "returns error for non-existent paper" do
      {:error, msg} = Web.dispatch_arxiv_paper(%{"id" => "9999.99999"})
      assert msg =~ "not found"
    end
  end

  describe "dispatch/1 routing" do
    test "routes arxiv_search operation" do
      {:ok, result} =
        Web.dispatch(%{"operation" => "arxiv_search", "query" => "neural networks", "limit" => 1})

      assert result.operation == :arxiv_search
    end

    test "routes arxiv_paper operation" do
      {:ok, result} = Web.dispatch(%{"operation" => "arxiv_paper", "id" => "1706.03762"})
      assert result.operation == :arxiv_paper
    end
  end
end
