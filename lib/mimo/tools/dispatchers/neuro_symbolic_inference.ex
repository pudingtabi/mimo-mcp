defmodule Mimo.Tools.Dispatchers.NeuroSymbolicInference do
  @moduledoc """
  Dispatcher for neuro-symbolic inference tool.

  Operations:
  - discover_rules
  - link_modalities
  - train_gnn (placeholder)
  """
  require Logger
  alias Mimo.NeuroSymbolic.{RuleGenerator, CrossModalityLinker, GnnPredictor}

  @operations ["discover_rules", "link_modalities", "train_gnn"]

  def dispatch(args) do
    op = args["operation"] || "discover_rules"

    case op do
      "discover_rules" ->
        dispatch_discover_rules(args)

      "link_modalities" ->
        dispatch_link_modalities(args)

      "train_gnn" ->
        dispatch_train_gnn(args)

      unknown ->
        {:error, "Unknown neuro_symbolic_inference operation: #{unknown}. Valid: #{inspect(@operations)}"}
    end
  end

  defp dispatch_discover_rules(args) do
    prompt = args["prompt"] || args[:prompt] || ""
    max_rules = args["max_rules"] || args[:max_rules] || 5

    if prompt == "" do
      {:error, "prompt is required for discover_rules"}
    else
      persist_validated = args["persist_validated"] || args[:persist_validated] || false
      RuleGenerator.generate_and_persist_rules(prompt, max_rules: max_rules, persist_validated: persist_validated)
    end
  end

  defp dispatch_link_modalities(%{"entities" => entities} = args) when is_list(entities) do
    # Entities expected to be list of maps: {"type" => "code_symbol", "id" => "..."}
    pairs =
      entities
      |> Enum.map(fn
        %{"type" => type, "id" => id} -> {String.to_atom(type), id}
        %{type: type, id: id} when is_atom(type) -> {type, id}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    persist = args["persist"] || args[:persist] || false
    CrossModalityLinker.link_all(pairs, persist: persist)
  end

  defp dispatch_link_modalities(_), do: {:error, "entities: required for link_modalities"}

  defp dispatch_train_gnn(%{"graph" => graph, "epochs" => epochs}) do
    GnnPredictor.train(graph, epochs)
  end

  defp dispatch_train_gnn(_), do: {:error, "graph and epochs required for train_gnn"}
end
