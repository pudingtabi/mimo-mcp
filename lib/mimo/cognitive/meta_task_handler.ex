defmodule Mimo.Cognitive.MetaTaskHandler do
  @moduledoc """
  SPEC-063: Unified Meta-Task Handler
  
  Combines SELF-DISCOVER, Rephrase-and-Respond, and Self-Ask techniques
  for maximum accuracy on meta-tasks.
  """
  
  require Logger
  
  alias Mimo.Cognitive.{
    MetaTaskDetector,
    SelfDiscover,
    RephraseRespond,
    SelfAsk,
    ReasoningTelemetry
  }
  alias Mimo.Cognitive.Reasoner
  
  @type strategy :: :auto | :self_discover | :rephrase | :self_ask | :combined

  @spec handle(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle(task, opts \\ []) when is_binary(task) do
    start_time = System.monotonic_time(:millisecond)
    strategy = Keyword.get(opts, :strategy, :auto)
    fallback_to_reasoner = Keyword.get(opts, :fallback_to_reasoner, true)
    
    {is_meta_task, meta_task_info} = case MetaTaskDetector.detect(task) do
      {:meta_task, guidance} -> {true, guidance}
      {:standard, _} -> {false, nil}
    end
    
    result = if is_meta_task do
      handle_meta_task(task, meta_task_info, strategy, opts)
    else
      handle_standard_task(task, strategy, opts)
    end
    
    result = case result do
      {:ok, _} = success -> success
      {:error, _} when fallback_to_reasoner ->
        Logger.info("[MetaTaskHandler] Falling back to standard Reasoner")
        fallback_to_reasoner(task, is_from_handler: true)
      error -> error
    end
    
    duration = System.monotonic_time(:millisecond) - start_time
    success = match?({:ok, _}, result)
    technique = case result do
      {:ok, %{technique_used: t}} -> t
      _ -> :fallback
    end
    ReasoningTelemetry.emit_meta_task_handled(is_meta_task, technique, success, duration)
    
    case result do
      {:ok, inner_result} ->
        {:ok, %{
          task: task,
          is_meta_task: is_meta_task,
          technique_used: Map.get(inner_result, :technique_used, :unknown),
          result: inner_result,
          meta_task_info: meta_task_info,
          duration_ms: duration
        }}
      error -> error
    end
  end
  
  @spec apply_technique(String.t(), strategy(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_technique(task, technique, opts \\ [])
  
  def apply_technique(task, :self_discover, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, 1000)
    
    case SelfDiscover.discover(task) do
      {:ok, discovery} ->
        case SelfDiscover.solve(task, discovery.reasoning_structure, max_tokens: max_tokens) do
          {:ok, answer} ->
            {:ok, %{
              technique_used: :self_discover,
              answer: answer,
              reasoning_structure: discovery.reasoning_structure,
              selected_modules: discovery.selected_modules
            }}
          error -> error
        end
      error -> error
    end
  end
  
  def apply_technique(task, :rephrase, opts) do
    RephraseRespond.rephrase_and_respond(task, opts)
    |> case do
      {:ok, result} -> {:ok, Map.put(result, :technique_used, :rephrase)}
      error -> error
    end
  end
  
  def apply_technique(task, :self_ask, opts) do
    SelfAsk.decompose_and_answer(task, opts)
    |> case do
      {:ok, result} -> {:ok, Map.put(result, :technique_used, :self_ask)}
      error -> error
    end
  end
  
  def apply_technique(task, :combined, opts) do
    apply_combined_strategy(task, nil, opts)
  end
  
  def apply_technique(task, :auto, opts) do
    cond do
      RephraseRespond.needs_rephrasing?(task) ->
        apply_technique(task, :rephrase, opts)
      SelfAsk.benefits_from_decomposition?(task) ->
        apply_technique(task, :self_ask, opts)
      true ->
        apply_technique(task, :self_discover, opts)
    end
  end
  
  defp handle_meta_task(task, guidance, strategy, opts) do
    case strategy do
      :auto -> try_techniques_in_order(task, guidance, opts)
      :combined -> apply_combined_strategy(task, guidance, opts)
      specific when specific in [:self_discover, :rephrase, :self_ask] ->
        apply_technique(task, specific, opts)
      _ -> {:error, "Unknown strategy: #{strategy}"}
    end
  end
  
  defp handle_standard_task(task, strategy, opts) do
    case strategy do
      :auto ->
        cond do
          SelfAsk.benefits_from_decomposition?(task) -> apply_technique(task, :self_ask, opts)
          RephraseRespond.needs_rephrasing?(task) -> apply_technique(task, :rephrase, opts)
          true -> fallback_to_reasoner(task)
        end
      specific when specific in [:self_discover, :rephrase, :self_ask, :combined] ->
        apply_technique(task, specific, opts)
      _ -> fallback_to_reasoner(task)
    end
  end
  
  defp try_techniques_in_order(task, guidance, opts) do
    techniques = case guidance.type do
      :generate_questions -> [:rephrase, :self_discover, :self_ask]
      :self_prediction -> [:self_discover, :rephrase, :self_ask]
      :iterative_task -> [:self_discover, :self_ask, :rephrase]
      :verification_design -> [:self_discover, :self_ask, :rephrase]
      :test_generation -> [:self_ask, :self_discover, :rephrase]
      _ -> [:rephrase, :self_discover, :self_ask]
    end
    
    Enum.reduce_while(techniques, {:error, "All techniques failed"}, fn technique, _acc ->
      case apply_technique(task, technique, opts) do
        {:ok, result} = success ->
          if is_valid_meta_task_result?(result, guidance) do
            {:halt, success}
          else
            {:cont, {:error, "#{technique} produced invalid result"}}
          end
        {:error, _} -> {:cont, {:error, "#{technique} failed"}}
      end
    end)
  end
  
  defp apply_combined_strategy(task, guidance, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, 1000)
    
    rephrased_task = case RephraseRespond.rephrase(task) do
      {:ok, %{rephrased: r}} -> r
      _ -> task
    end
    
    enhanced_task = if guidance do
      """
      ORIGINAL: #{task}
      CLARIFIED: #{rephrased_task}
      
      ⚠️ META-TASK (#{guidance.type}): #{guidance.instruction}
      #{if guidance.example, do: "Example: #{guidance.example}", else: ""}
      """
    else
      rephrased_task
    end
    
    case SelfDiscover.discover(enhanced_task) do
      {:ok, discovery} ->
        case SelfDiscover.solve(enhanced_task, discovery.reasoning_structure, max_tokens: max_tokens) do
          {:ok, answer} ->
            {:ok, %{
              technique_used: :combined,
              answer: answer,
              rephrased: rephrased_task,
              reasoning_structure: discovery.reasoning_structure
            }}
          error -> error
        end
      error -> error
    end
  end
  
  defp fallback_to_reasoner(task, opts \\ []) do
    # Pass skip_meta_handler: true to prevent recursive loop back to MetaTaskHandler
    reasoner_opts = if Keyword.get(opts, :is_from_handler, false) do
      [technique: :none, skip_meta_handler: true]
    else
      []
    end
    
    case Reasoner.guided(task, reasoner_opts) do
      {:ok, result} ->
        {:ok, %{
          technique_used: :reasoner_fallback,
          session_id: result.session_id,
          guidance: result.guidance,
          strategy: result.strategy
        }}
      error -> error
    end
  end
  
  defp is_valid_meta_task_result?(result, %{type: :generate_questions}) do
    answer = get_answer_text(result)
    not_waiting = not String.contains?(String.downcase(answer), ["didn't provide", "haven't provided", "no questions", "waiting for", "please provide"])
    has_content = String.contains?(answer, ["1.", "Question 1", "Trivia 1", "First question"])
    not_waiting and has_content
  end
  
  defp is_valid_meta_task_result?(result, %{type: :self_prediction}) do
    answer = get_answer_text(result)
    String.contains?(String.downcase(answer), ["predict", "confidence", "expect", "likely", "probability"])
  end
  
  defp is_valid_meta_task_result?(result, %{type: :generate_content}) do
    answer = get_answer_text(result)
    not String.contains?(String.downcase(answer), ["please provide", "need more", "what would you like"])
  end
  
  defp is_valid_meta_task_result?(_result, _guidance), do: true
  
  defp get_answer_text(%{answer: answer}) when is_binary(answer), do: answer
  defp get_answer_text(%{synthesis: synthesis}) when is_binary(synthesis), do: synthesis
  defp get_answer_text(%{result: result}) when is_binary(result), do: result
  defp get_answer_text(_), do: ""
end
