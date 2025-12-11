defmodule Mimo.NeuroSymbolic.Inference do
  @moduledoc """
  Inference orchestration and triggers for neuro-symbolic features.

  Phase 1 implementation: lightweight hooks for new triple events and
  cross-modality linking in the background.
  """
  require Logger

  alias Mimo.NeuroSymbolic.CrossModalityLinker
  alias Mimo.TaskHelper

  @doc """
  Trigger neuro-symbolic processing on newly stored triple.

  For now, we run cross-modality linking in background and log.
  """
  def trigger_on_new_triple(triple) do
    TaskHelper.async_with_callers(fn ->
      Logger.info("[NeuroSymbolic] Triggered on new triple: #{triple.id}")

      # Kick off cross-modality linking: code_symbol -> memory -> knowledge
      # Attempt to infer links for the subject and object
      subj = %{type: triple.subject_type, id: triple.subject_id}
      obj = %{type: triple.object_type, id: triple.object_id}

      pairs = [
        {String.to_atom(String.downcase(to_string(subj.type))), subj.id},
        {String.to_atom(String.downcase(to_string(obj.type))), obj.id}
      ]

      # Use CrossModalityLinker for subject and object in Phase 1
      _ = CrossModalityLinker.link_all(pairs)

      :ok
    end)

    :ok
  rescue
    e ->
      Logger.error("Failed to trigger neuro-symbolic inference: #{inspect(e)}")
      {:error, e}
  end
end
