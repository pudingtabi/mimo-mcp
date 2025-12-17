defmodule Mimo.NeuroSymbolic.GnnPredictor do
  @moduledoc """
  Graph Neural Network predictor stub.

  This module provides placeholder functions that return empty results.
  Not implemented - exists to satisfy API contracts.
  """
  require Logger

  @spec train(map(), integer()) :: {:ok, map()} | {:error, term()}
  def train(_graph, _epochs \\ 100) do
    Logger.info("GNN training is a stub in Phase 1")
    {:ok, %{version: 1, path: "/tmp/gnn_model"}}
  end

  @spec predict_links(map(), [String.t()]) :: [map()]
  def predict_links(_model, _node_ids) do
    # No predictions in Phase 1
    []
  end

  @spec cluster_similar(map(), atom()) :: [map()]
  def cluster_similar(_model, _node_type) do
    []
  end
end
