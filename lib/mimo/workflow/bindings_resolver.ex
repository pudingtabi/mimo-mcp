defmodule Mimo.Workflow.BindingsResolver do
  @moduledoc """
  SPEC-053 Phase 2: Dynamic Parameter Binding Resolution

  Resolves dynamic bindings in workflow patterns by substituting
  placeholders with values from context or previous step outputs.

  ## Binding Sources

    * `:previous_output` - Output from the previous step
    * `:global_context` - Current execution context
    * `:literal` - Static literal value

  ## Path Syntax

  Uses JSONPath-like syntax for extracting values:
    * `$` - Root object
    * `$.field` - Field access
    * `$.array[0]` - Array index
    * `$.nested.field` - Nested access

  ## Usage

      bindings = BindingsResolver.resolve(pattern, context)
      # => %{"path" => "/app/src/main.ts", "query" => "authentication"}
  """
  require Logger

  alias Mimo.Workflow.Pattern

  @type binding :: %{
          source: :previous_output | :global_context | :literal,
          path: String.t(),
          target_param: String.t()
        }

  @type context :: map()

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Resolves all bindings for a pattern's steps given the current context.

  Returns a map of step indices to resolved parameter maps.
  """
  @spec resolve(Pattern.t(), context()) :: %{non_neg_integer() => map()}
  def resolve(%Pattern{steps: steps}, context) do
    steps
    |> Enum.with_index()
    |> Enum.reduce({%{}, nil}, fn {step, idx}, {resolved, prev_output} ->
      step_bindings = resolve_step_bindings(step, context, prev_output)
      {Map.put(resolved, idx, step_bindings), nil}
    end)
    |> elem(0)
  end

  @doc """
  Resolves bindings for a single step.
  """
  @spec resolve_step_bindings(map(), context(), map() | nil) :: map()
  def resolve_step_bindings(step, context, prev_output \\ nil) do
    static_params = step["params"] || step[:params] || %{}
    dynamic_bindings = step["dynamic_bindings"] || step[:dynamic_bindings] || []

    dynamic_params =
      dynamic_bindings
      |> Enum.map(fn binding ->
        binding = normalize_binding(binding)
        value = resolve_binding(binding, context, prev_output)
        {binding.target_param, value}
      end)
      |> Enum.filter(fn {_, v} -> v != nil end)
      |> Map.new()

    Map.merge(static_params, dynamic_params)
  end

  @doc """
  Resolves a single binding value.
  """
  @spec resolve_binding(binding() | map(), context(), map() | nil) :: any()
  def resolve_binding(binding, context, prev_output) do
    binding = normalize_binding(binding)

    source_data =
      case binding.source do
        :previous_output -> prev_output || %{}
        :global_context -> context
        :literal -> %{"value" => binding.path}
        _ -> %{}
      end

    extract_path(source_data, binding.path)
  end

  @doc """
  Updates a resolved bindings map with a step's output.

  Used during execution to chain outputs to subsequent bindings.
  """
  @spec with_step_output(map(), non_neg_integer(), any()) :: map()
  def with_step_output(resolved, step_idx, output) do
    # Update bindings for subsequent steps that reference previous_output
    Map.put(resolved, {:output, step_idx}, output)
  end

  @doc """
  Validates that all required bindings can be resolved.
  """
  @spec validate_bindings(Pattern.t(), context()) ::
          {:ok, [String.t()]} | {:error, [String.t()]}
  def validate_bindings(%Pattern{steps: steps}, context) do
    missing =
      steps
      |> Enum.flat_map(fn step ->
        bindings = step["dynamic_bindings"] || step[:dynamic_bindings] || []

        Enum.filter(bindings, fn binding ->
          binding = normalize_binding(binding)

          case binding.source do
            :global_context ->
              extract_path(context, binding.path) == nil

            :literal ->
              false

            :previous_output ->
              # Can't validate until execution
              false
          end
        end)
        |> Enum.map(fn binding ->
          binding = normalize_binding(binding)
          "#{binding.source}:#{binding.path} -> #{binding.target_param}"
        end)
      end)

    if Enum.empty?(missing) do
      {:ok, []}
    else
      {:error, missing}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp normalize_binding(binding) when is_map(binding) do
    %{
      source: normalize_source(binding["source"] || binding[:source]),
      path: binding["path"] || binding[:path] || "$",
      target_param: binding["target_param"] || binding[:target_param]
    }
  end

  defp normalize_source("previous_output"), do: :previous_output
  defp normalize_source("global_context"), do: :global_context
  defp normalize_source("literal"), do: :literal
  defp normalize_source(atom) when is_atom(atom), do: atom
  defp normalize_source(_), do: :global_context

  @doc """
  Extracts a value from a map using JSONPath-like syntax.
  """
  @spec extract_path(map() | nil, String.t()) :: any()
  def extract_path(nil, _path), do: nil
  def extract_path(data, "$"), do: data

  def extract_path(data, path) when is_binary(path) do
    # Remove leading $ if present
    path = String.trim_leading(path, "$")
    path = String.trim_leading(path, ".")

    if path == "" do
      data
    else
      segments = parse_path(path)
      navigate_path(data, segments)
    end
  end

  defp parse_path(path) do
    # Split on dots and brackets
    # e.g., "errors[0].message" -> ["errors", "[0]", "message"]
    path
    |> String.split(~r/\.(?=[^\[\]]*(?:\[|$))/)
    |> Enum.flat_map(fn segment ->
      case Regex.scan(~r/^([^\[]+)?(\[\d+\])?$/, segment) do
        [[_full, name, idx]] ->
          parts = if name != "", do: [name], else: []
          if idx != "", do: parts ++ [idx], else: parts

        _ ->
          [segment]
      end
    end)
    |> Enum.filter(&(&1 != ""))
  end

  defp navigate_path(data, []), do: data
  defp navigate_path(nil, _), do: nil

  defp navigate_path(data, [segment | rest]) when is_map(data) do
    result =
      try do
        cond do
          # Array index
          String.starts_with?(segment, "[") ->
            nil

          # String key
          Map.has_key?(data, segment) ->
            Map.get(data, segment)

          # Atom key
          atom_key = String.to_existing_atom(segment) ->
            Map.get(data, atom_key)

          true ->
            nil
        end
      rescue
        ArgumentError -> nil
      end
    
    navigate_path(result, rest)
  end

  defp navigate_path(data, [segment | rest]) when is_list(data) do
    case parse_array_index(segment) do
      {:ok, idx} when idx >= 0 and idx < length(data) ->
        navigate_path(Enum.at(data, idx), rest)

      _ ->
        nil
    end
  end

  defp navigate_path(_, _), do: nil

  defp parse_array_index(segment) do
    case Regex.run(~r/^\[(\d+)\]$/, segment) do
      [_, idx_str] -> {:ok, String.to_integer(idx_str)}
      _ -> :error
    end
  end
end
