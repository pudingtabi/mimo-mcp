defmodule Mimo.Tools.Dispatchers.Reflector do
  @moduledoc """
  SPEC-043: Reflector tool dispatcher.

  Exposes the Reflective Intelligence System via MCP tool interface.

  Operations:
  - reflect: Evaluate and optionally refine an output
  - evaluate: Evaluate output quality without refinement
  - confidence: Estimate confidence for a response
  - errors: Detect potential errors in output
  - format: Format output with confidence indicators
  - config: Get/set reflector configuration
  """

  require Logger

  alias Mimo.Brain.Reflector

  alias Mimo.Brain.Reflector.{
    ConfidenceEstimator,
    ConfidenceOutput,
    Config,
    ErrorDetector,
    Evaluator
  }

  @doc """
  Dispatch reflector operation based on args.
  """
  def dispatch(args) do
    op = args["operation"] || "reflect"

    case op do
      "reflect" ->
        dispatch_reflect(args)

      "evaluate" ->
        dispatch_evaluate(args)

      "confidence" ->
        dispatch_confidence(args)

      "errors" ->
        dispatch_errors(args)

      "format" ->
        dispatch_format(args)

      "config" ->
        dispatch_config(args)

      _ ->
        {:error,
         "Unknown reflector operation: #{op}. Available: reflect, evaluate, confidence, errors, format, config"}
    end
  end

  defp dispatch_reflect(args) do
    output = args["output"] || args["content"] || ""

    if output == "" do
      {:error, "Output/content is required for reflect operation"}
    else
      context = build_context(args)
      opts = build_opts(args)

      case Reflector.reflect_and_refine(output, context, opts) do
        {:ok, result} ->
          {:ok,
           %{
             operation: :reflect,
             original: output,
             refined: Map.get(result, :refined_output) || Map.get(result, :output) || output,
             iterations: Map.get(result, :iterations, 0),
             final_score: get_aggregate_score(result),
             passed_threshold: Map.get(result, :passed_threshold, false),
             improvements: Map.get(result, :improvements, [])
           }}

        {:error, reason} ->
          {:error, "Reflection failed: #{inspect(reason)}"}
      end
    end
  end

  # Helper to safely extract aggregate score from result
  defp get_aggregate_score(result) do
    cond do
      Map.has_key?(result, :final_score) -> result.final_score
      Map.has_key?(result, :evaluation) -> Map.get(result.evaluation, :aggregate_score, 0.0)
      Map.has_key?(result, :confidence) -> Map.get(result.confidence, :score, 0.0)
      true -> 0.0
    end
  end

  defp dispatch_evaluate(args) do
    output = args["output"] || args["content"] || ""

    if output == "" do
      {:error, "Output/content is required for evaluate operation"}
    else
      context = build_context(args)

      evaluation = Evaluator.evaluate(output, context)

      {:ok,
       %{
         operation: :evaluate,
         aggregate_score: evaluation.aggregate_score,
         scores: evaluation.scores,
         passed_threshold: evaluation.aggregate_score >= Config.get().default_threshold,
         issues: Map.get(evaluation, :issues, []),
         suggestions: Map.get(evaluation, :suggestions, [])
       }}
    end
  end

  defp dispatch_confidence(args) do
    output = args["output"] || args["content"] || ""

    if output == "" do
      {:error, "Output/content is required for confidence operation"}
    else
      context = build_context(args)

      confidence = ConfidenceEstimator.estimate(output, context)

      {:ok,
       %{
         operation: :confidence,
         score: confidence.score,
         level: confidence.level,
         signals: confidence.signals,
         explanation: confidence.explanation
       }}
    end
  end

  defp dispatch_errors(args) do
    output = args["output"] || args["content"] || ""

    if output == "" do
      {:error, "Output/content is required for errors operation"}
    else
      context = build_context(args)

      errors = ErrorDetector.detect(output, context)

      {:ok,
       %{
         operation: :errors,
         count: length(errors),
         errors: Enum.map(errors, &format_error/1),
         severity: calculate_severity(errors)
       }}
    end
  end

  defp dispatch_format(args) do
    output = args["output"] || args["content"] || ""

    if output == "" do
      {:error, "Output/content is required for format operation"}
    else
      context = build_context(args)
      format_type = parse_format_type(args["format_type"])

      # ConfidenceOutput.format expects (output, confidence, opts)
      # First estimate confidence, then format
      confidence = ConfidenceEstimator.estimate(output, context)
      formatted = ConfidenceOutput.format(output, confidence, format: format_type)

      {:ok,
       %{
         operation: :format,
         formatted: formatted,
         format_type: format_type
       }}
    end
  end

  defp dispatch_config(args) do
    action = args["action"] || "get"

    case action do
      "get" ->
        config = Config.get()
        {:ok, %{operation: :config, action: :get, config: config}}

      "set" ->
        key = args["key"]
        value = args["value"]

        if key == nil do
          {:error, "Key is required for config set action"}
        else
          Config.put(String.to_atom(key), value)
          {:ok, %{operation: :config, action: :set, key: key, value: value}}
        end

      _ ->
        {:error, "Unknown config action: #{action}. Available: get, set"}
    end
  end

  defp build_context(args) do
    %{
      query: args["query"],
      task: args["task"],
      domain: args["domain"],
      expected_format: args["expected_format"],
      constraints: args["constraints"] || []
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_opts(args) do
    opts = []

    opts =
      if args["max_iterations"],
        do: Keyword.put(opts, :max_iterations, args["max_iterations"]),
        else: opts

    opts = if args["threshold"], do: Keyword.put(opts, :threshold, args["threshold"]), else: opts

    opts =
      if args["auto_refine"] != nil,
        do: Keyword.put(opts, :auto_refine, args["auto_refine"]),
        else: opts

    opts
  end

  defp format_error(error) do
    %{
      type: error.type,
      severity: error.severity,
      message: error.message,
      location: error.location,
      suggestion: error.suggestion
    }
  end

  defp calculate_severity(errors) when errors == [], do: :none

  defp calculate_severity(errors) do
    severities = Enum.map(errors, & &1.severity)

    cond do
      :critical in severities -> :critical
      :high in severities -> :high
      :medium in severities -> :medium
      true -> :low
    end
  end

  defp parse_format_type("structured"), do: :structured
  defp parse_format_type("natural"), do: :natural
  defp parse_format_type("hidden"), do: :hidden
  defp parse_format_type(_), do: :structured
end
