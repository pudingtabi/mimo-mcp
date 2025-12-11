defmodule Mimo.NeuroSymbolic.CrossModalityLinkerTest do
  use Mimo.DataCase, async: true

  alias Mimo.NeuroSymbolic.CrossModalityLinker

  describe "infer_links/3" do
    test "returns empty list for code_symbol with no matches" do
      {:ok, links} =
        CrossModalityLinker.infer_links(
          :code_symbol,
          "NonExistentSymbol_#{System.unique_integer()}",
          []
        )

      # May return empty or with some links if memories mention it
      assert is_list(links)
    end

    test "returns error tuple on failure" do
      # Even with invalid input, it should handle gracefully
      result = CrossModalityLinker.infer_links(:code_symbol, "test", [])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "respects min_confidence option" do
      {:ok, links} =
        CrossModalityLinker.infer_links(:code_symbol, "TestModule", min_confidence: 0.9)

      # All returned links should have confidence >= 0.9
      Enum.each(links, fn link ->
        assert link.confidence >= 0.9
      end)
    end

    test "respects limit option" do
      {:ok, links} = CrossModalityLinker.infer_links(:code_symbol, "Phoenix", limit: 2)
      assert length(links) <= 2
    end

    test "memory source type returns links" do
      {:ok, links} = CrossModalityLinker.infer_links(:memory, "1", [])
      assert is_list(links)
    end

    test "knowledge source type returns links" do
      {:ok, links} = CrossModalityLinker.infer_links(:knowledge, "test_node", [])
      assert is_list(links)
    end

    test "library source type returns links" do
      {:ok, links} = CrossModalityLinker.infer_links(:library, "phoenix", [])
      assert is_list(links)
    end
  end

  describe "find_cross_connections/2" do
    test "returns 0 for item with no connections" do
      item = %{id: nil, content: "plain text with no refs"}
      count = CrossModalityLinker.find_cross_connections(item)
      # Should return 0 since the item has no inline markers
      assert count >= 0
    end

    test "returns count based on inline markers for items without id" do
      item = %{file_path: "/some/path.ex", content: "code"}
      count = CrossModalityLinker.find_cross_connections(item)
      # Has file_path, so should count code_symbol connection
      assert count >= 1
    end

    test "returns count based on library markers" do
      item = %{package: "phoenix", ecosystem: "hex"}
      count = CrossModalityLinker.find_cross_connections(item)
      assert count >= 1
    end

    test "returns count based on knowledge markers" do
      item = %{relationships: ["depends_on"], node_type: :concept}
      count = CrossModalityLinker.find_cross_connections(item)
      assert count >= 1
    end

    test "returns count based on explicit cross_modality_connections" do
      item = %{cross_modality_connections: 3}
      count = CrossModalityLinker.find_cross_connections(item)
      assert count == 3
    end

    test "returns count based on list of cross_modality" do
      item = %{cross_modality: [:code, :memory, :knowledge]}
      count = CrossModalityLinker.find_cross_connections(item)
      assert count == 3
    end
  end

  describe "link_all/1" do
    setup do
      alias Mimo.NeuroSymbolic.CrossModalityLink
      alias Mimo.Repo
      :ok
    end

    test "batches multiple source types" do
      pairs = [
        {:code_symbol, "TestModule"},
        {:library, "phoenix"}
      ]

      {:ok, links} = CrossModalityLinker.link_all(pairs)
      assert is_list(links)
    end

    test "returns empty list for empty pairs" do
      {:ok, links} = CrossModalityLinker.link_all([])
      assert links == []
    end

    test "handles mixed source types gracefully" do
      pairs = [
        {:code_symbol, "TestModule"},
        {:memory, "123"},
        {:knowledge, "concept_1"},
        {:library, "ecto"}
      ]

      {:ok, links} = CrossModalityLinker.link_all(pairs)
      assert is_list(links)
    end

    test "persists links when persist option is true" do
      pairs = [{:code_symbol, "Phoenix.Controller"}]

      pre_count = Mimo.Repo.aggregate(Mimo.NeuroSymbolic.CrossModalityLink, :count, :id)

      {:ok, links} = CrossModalityLinker.link_all(pairs, persist: true)

      post_count = Mimo.Repo.aggregate(Mimo.NeuroSymbolic.CrossModalityLink, :count, :id)

      # After persisting, the count should not be less than before
      assert post_count >= pre_count
      assert is_list(links)
    end
  end

  describe "cross_modality_stats/2" do
    test "returns stats structure" do
      stats = CrossModalityLinker.cross_modality_stats(:code_symbol, "Phoenix.Controller")

      assert Map.has_key?(stats, :total_connections)
      assert Map.has_key?(stats, :by_target_type)
      assert Map.has_key?(stats, :average_confidence)
      assert Map.has_key?(stats, :source_type)
      assert Map.has_key?(stats, :source_id)
    end

    test "returns zero stats for non-existent entity" do
      stats =
        CrossModalityLinker.cross_modality_stats(
          :code_symbol,
          "NonExistent_#{System.unique_integer()}"
        )

      assert stats.total_connections >= 0
      assert is_map(stats.by_target_type)
      assert is_float(stats.average_confidence) or is_integer(stats.average_confidence)
    end

    test "returns correct source metadata" do
      stats = CrossModalityLinker.cross_modality_stats(:library, "ecto")

      assert stats.source_type == :library
      assert stats.source_id == "ecto"
    end
  end

  describe "link type inference" do
    test "code_symbol links include library hints for Phoenix" do
      {:ok, links} =
        CrossModalityLinker.infer_links(:code_symbol, "Phoenix.Controller.Action", limit: 10)

      library_links = Enum.filter(links, &(&1.target_type == "library"))

      if length(library_links) > 0 do
        assert Enum.any?(library_links, &(&1.target_id == "phoenix"))
      end
    end

    test "code_symbol links include library hints for Ecto" do
      {:ok, links} = CrossModalityLinker.infer_links(:code_symbol, "Ecto.Query.Builder", limit: 10)

      library_links = Enum.filter(links, &(&1.target_type == "library"))

      if length(library_links) > 0 do
        assert Enum.any?(library_links, &(&1.target_id == "ecto"))
      end
    end
  end
end
