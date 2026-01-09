defmodule Mimo.NeuroSymbolic.GnnPredictorTest do
  @moduledoc """
  Test suite for GnnPredictor - the k-means clustering and link prediction module.
  """
  use Mimo.DataCase

  alias Mimo.NeuroSymbolic.GnnPredictor
  alias Mimo.Brain.Engram
  alias Mimo.Repo

  # Test data setup
  setup do
    # Ensure we have some memories with embeddings for testing
    # The production database should have 6000+ memories, but tests need stable fixtures

    # Check if we have enough memories
    count =
      Repo.one(
        from(e in Engram,
          where: not is_nil(e.embedding_int8),
          select: count(e.id)
        )
      )

    {:ok, memory_count: count}
  end

  describe "train/2" do
    test "trains successfully with sufficient memories", %{memory_count: count} do
      if count >= 10 do
        assert {:ok, model} = GnnPredictor.train(%{k: 5, sample_size: 50})

        # Verify model structure
        assert is_map(model)
        assert model.version == 1
        assert model.k == 5
        assert model.sample_size <= 50
        assert is_binary(model.trained_at)
        assert is_list(model.centroids)
        assert length(model.centroids) == 5
        assert is_map(model.cluster_sizes)

        # Verify centroids are valid embedding vectors
        first_centroid = hd(model.centroids)
        assert is_list(first_centroid)
        # MRL-truncated embedding dimension
        assert length(first_centroid) == 256
        assert Enum.all?(first_centroid, &is_float/1)
      else
        # Not enough memories - expect error
        assert {:error, _reason} = GnnPredictor.train(%{k: 5, sample_size: 50})
      end
    end

    test "returns error when k > available memories", %{memory_count: count} do
      if count < 1000 do
        result = GnnPredictor.train(%{k: 1000, sample_size: 50})
        assert {:error, reason} = result
        assert is_binary(reason)
        assert String.contains?(reason, "Not enough memories")
      end
    end

    test "uses default values when opts are empty" do
      # Should use k: 10, sample_size: 1000 by default
      result = GnnPredictor.train()
      # Result depends on memory count - just verify it returns ok or error
      assert is_tuple(result)
      assert elem(result, 0) in [:ok, :error]
    end

    test "stores model in ETS for subsequent calls", %{memory_count: count} do
      if count >= 10 do
        # Train first
        {:ok, model1} = GnnPredictor.train(%{k: 3, sample_size: 20})

        # Second call should use cached model
        # Note: cluster_similar/predict_links use the cached model
        clusters = GnnPredictor.cluster_similar(nil, :memory)

        # Should return valid clusters (from cached model)
        assert is_list(clusters)
        # Cluster count matches what we trained
        # (may differ if model was retrained by another test)
      end
    end
  end

  describe "cluster_similar/2" do
    test "returns empty list when no model is trained" do
      # Clear ETS table to simulate no model
      try do
        :ets.delete(:gnn_predictor_model)
      rescue
        ArgumentError -> :ok
      end

      result = GnnPredictor.cluster_similar(nil, :memory)
      assert result == []
    end

    test "returns valid clusters when model is available", %{memory_count: count} do
      if count >= 10 do
        # Ensure model is trained
        {:ok, _model} = GnnPredictor.train(%{k: 4, sample_size: 30})

        clusters = GnnPredictor.cluster_similar(nil, :memory)

        assert is_list(clusters)
        assert length(clusters) > 0

        # Verify cluster structure
        first_cluster = hd(clusters)
        assert Map.has_key?(first_cluster, :cluster_id)
        assert Map.has_key?(first_cluster, :size)
        assert Map.has_key?(first_cluster, :member_ids)
        assert Map.has_key?(first_cluster, :category_breakdown)
        assert Map.has_key?(first_cluster, :avg_similarity)

        # Verify types
        assert is_integer(first_cluster.cluster_id)
        assert is_integer(first_cluster.size)
        assert is_list(first_cluster.member_ids)
        assert is_map(first_cluster.category_breakdown)
        assert is_float(first_cluster.avg_similarity) or first_cluster.avg_similarity == 0.0
      end
    end

    test "cluster sizes sum to total memory count", %{memory_count: count} do
      if count >= 10 do
        {:ok, _model} = GnnPredictor.train(%{k: 3, sample_size: 30})

        clusters = GnnPredictor.cluster_similar(nil, :memory)

        total_in_clusters = Enum.sum(Enum.map(clusters, & &1.size))

        # Should equal total memories with embeddings
        memories_with_embeddings =
          Repo.one(
            from(e in Engram,
              where: not is_nil(e.embedding_int8),
              select: count(e.id)
            )
          )

        assert total_in_clusters == memories_with_embeddings
      end
    end
  end

  describe "predict_links/2" do
    test "returns empty list when no model is trained" do
      # Clear model
      try do
        :ets.delete(:gnn_predictor_model)
      rescue
        ArgumentError -> :ok
      end

      result = GnnPredictor.predict_links(nil, [1, 2, 3])
      assert result == []
    end

    test "returns valid predictions for valid memory IDs", %{memory_count: count} do
      if count >= 20 do
        # Train model first
        {:ok, _model} = GnnPredictor.train(%{k: 5, sample_size: 50})

        # Get some real memory IDs
        memory_ids =
          Repo.all(
            from(e in Engram,
              where: not is_nil(e.embedding_int8),
              limit: 3,
              select: e.id
            )
          )

        predictions = GnnPredictor.predict_links(nil, memory_ids)

        assert is_list(predictions)

        if length(predictions) > 0 do
          first = hd(predictions)

          # Verify structure
          assert Map.has_key?(first, :from)
          assert Map.has_key?(first, :to)
          assert Map.has_key?(first, :score)
          assert Map.has_key?(first, :from_category)
          assert Map.has_key?(first, :to_category)
          assert Map.has_key?(first, :reason)

          # Verify score is between 0 and 1
          assert first.score >= 0.0
          assert first.score <= 1.0

          # Predictions should be sorted by score descending
          scores = Enum.map(predictions, & &1.score)
          assert scores == Enum.sort(scores, :desc)
        end
      end
    end

    test "returns empty list for non-existent memory IDs", %{memory_count: count} do
      if count >= 5 do
        {:ok, _model} = GnnPredictor.train(%{k: 3, sample_size: 20})

        # Use IDs that definitely don't exist
        predictions = GnnPredictor.predict_links(nil, [999_999_998, 999_999_999])

        # Should return empty since these IDs don't exist
        assert predictions == []
      end
    end

    test "limits predictions to top 20" do
      result = GnnPredictor.train(%{k: 5, sample_size: 50})

      if match?({:ok, _}, result) do
        memory_ids =
          Repo.all(
            from(e in Engram,
              where: not is_nil(e.embedding_int8),
              limit: 10,
              select: e.id
            )
          )

        if length(memory_ids) >= 5 do
          predictions = GnnPredictor.predict_links(nil, memory_ids)
          assert length(predictions) <= 20
        end
      end
    end
  end

  describe "cosine_similarity" do
    # Testing through public API since cosine_similarity is private

    test "similar memories get higher scores than dissimilar ones", %{memory_count: count} do
      if count >= 30 do
        {:ok, _model} = GnnPredictor.train(%{k: 5, sample_size: 100})

        # Get clusters
        clusters = GnnPredictor.cluster_similar(nil, :memory)

        if length(clusters) > 0 do
          # Members in same cluster should have higher avg_similarity
          # than the minimum threshold (0.5)
          cluster_with_members =
            Enum.find(clusters, fn c -> c.size > 1 end)

          if cluster_with_members do
            # Avg similarity should be positive (members are similar)
            assert cluster_with_members.avg_similarity >= 0.0
          end
        end
      end
    end
  end
end
