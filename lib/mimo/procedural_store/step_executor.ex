defmodule Mimo.ProceduralStore.StepExecutor do
  @moduledoc """
  Behaviour and implementations for procedure step execution.

  Step executors are deterministic modules that perform specific
  actions within a procedure. They receive context and return
  results without any LLM involvement.

  ## Implementing a Step Executor

      defmodule MyApp.Steps.ValidateInput do
        @behaviour Mimo.ProceduralStore.StepExecutor
        
        @impl true
        def execute(context, _args) do
          if valid?(context["input"]) do
            {:ok, %{validated: true}}
          else
            {:error, :invalid_input}
          end
        end
      end
  """

  @doc """
  Executes a step with the given context and arguments.

  ## Parameters

    - `context` - Current execution context (accumulated state)
    - `args` - Step-specific arguments from procedure definition

  ## Returns

    - `{:ok, result}` - Step completed successfully, result merged into context
    - `{:error, reason}` - Step failed
    - `{:transition, event}` - Explicit transition event (overrides default :success)
  """
  @callback execute(context :: map(), args :: list()) ::
              {:ok, map()} | {:ok, term()} | :ok | {:error, term()} | {:transition, atom()}
end

# ============================================================================
# Built-in Step Executors
# ============================================================================

defmodule Mimo.ProceduralStore.Steps.Log do
  @moduledoc """
  Simple logging step for debugging procedures.
  """
  @behaviour Mimo.ProceduralStore.StepExecutor

  require Logger

  @impl true
  def execute(context, args) do
    level = Keyword.get(args, :level, :info)
    message = Keyword.get(args, :message, "Step executed")
    fields = Keyword.get(args, :fields, [])

    field_values =
      fields
      |> Enum.map(fn field -> {field, Map.get(context, field)} end)
      |> Enum.into(%{})

    Logger.log(level, "#{message}: #{inspect(field_values)}")
    :ok
  end
end

defmodule Mimo.ProceduralStore.Steps.Validate do
  @moduledoc """
  Validates context fields against rules.
  """
  @behaviour Mimo.ProceduralStore.StepExecutor

  @impl true
  def execute(context, args) when is_map(args) do
    rules = Map.get(args, "rules", [])
    validate_with_rules(context, rules)
  end

  @impl true
  def execute(context, args) when is_list(args) do
    rules = Keyword.get(args, :rules, [])
    validate_with_rules(context, rules)
  end

  defp validate_with_rules(context, rules) do
    errors =
      rules
      |> Enum.reduce([], fn rule, acc ->
        case validate_rule(context, rule) do
          :ok -> acc
          {:error, msg} -> [msg | acc]
        end
      end)

    case errors do
      [] -> {:ok, %{validation_passed: true}}
      _ -> {:error, {:validation_failed, Enum.reverse(errors)}}
    end
  end

  defp validate_rule(context, {:required, field}) do
    if Map.has_key?(context, field) and context[field] != nil do
      :ok
    else
      {:error, "#{field} is required"}
    end
  end

  # Map-based rule (from JSON)
  defp validate_rule(context, %{"type" => "required", "field" => field}) do
    if Map.has_key?(context, field) and context[field] != nil do
      :ok
    else
      {:error, "#{field} is required"}
    end
  end

  defp validate_rule(context, {:type, field, type}) do
    value = Map.get(context, field)

    valid =
      case type do
        :string -> is_binary(value)
        :integer -> is_integer(value)
        :float -> is_float(value)
        :number -> is_number(value)
        :boolean -> is_boolean(value)
        :list -> is_list(value)
        :map -> is_map(value)
        _ -> true
      end

    if valid, do: :ok, else: {:error, "#{field} must be #{type}"}
  end

  defp validate_rule(context, {:min, field, min}) do
    value = Map.get(context, field)

    if is_number(value) and value >= min do
      :ok
    else
      {:error, "#{field} must be >= #{min}"}
    end
  end

  defp validate_rule(context, {:max, field, max}) do
    value = Map.get(context, field)

    if is_number(value) and value <= max do
      :ok
    else
      {:error, "#{field} must be <= #{max}"}
    end
  end

  defp validate_rule(context, {:regex, field, pattern}) do
    value = Map.get(context, field, "")

    if Regex.match?(pattern, value) do
      :ok
    else
      {:error, "#{field} does not match required pattern"}
    end
  end

  defp validate_rule(_context, _unknown) do
    :ok
  end
end

defmodule Mimo.ProceduralStore.Steps.HttpRequest do
  @moduledoc """
  Makes HTTP requests as a procedure step.
  """
  @behaviour Mimo.ProceduralStore.StepExecutor

  require Logger

  @impl true
  def execute(context, args) do
    method = Keyword.get(args, :method, :get)
    url_template = Keyword.get(args, :url)
    headers = Keyword.get(args, :headers, [])
    body_template = Keyword.get(args, :body)
    result_key = Keyword.get(args, :result_key, "http_response")

    # Interpolate templates with context
    url = interpolate(url_template, context)
    body = if body_template, do: interpolate(body_template, context) |> Jason.encode!()

    req_opts = [url: url, method: method, headers: headers]
    req_opts = if body, do: Keyword.put(req_opts, :body, body), else: req_opts

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: code, body: resp_body}} when code in 200..299 ->
        parsed =
          case resp_body do
            body when is_map(body) ->
              body

            body when is_binary(body) ->
              case Jason.decode(body) do
                {:ok, json} -> json
                _ -> body
              end

            body ->
              body
          end

        {:ok, %{result_key => parsed, "http_status" => code}}

      {:ok, %Req.Response{status: code, body: resp_body}} ->
        Logger.error("HTTP request failed: #{code} - #{inspect(resp_body)}")
        {:error, {:http_error, code, resp_body}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("HTTP request error: #{inspect(reason)}")
        {:error, {:http_error, reason}}

      {:error, reason} ->
        Logger.error("HTTP request error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  defp interpolate(template, context) when is_binary(template) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _, key ->
      Map.get(context, key, "") |> to_string()
    end)
  end

  defp interpolate(template, _context), do: template
end

defmodule Mimo.ProceduralStore.Steps.Delay do
  @moduledoc """
  Introduces a delay in procedure execution.
  """
  @behaviour Mimo.ProceduralStore.StepExecutor

  @impl true
  def execute(_context, args) do
    ms = Keyword.get(args, :ms, 1000)
    Process.sleep(ms)
    :ok
  end
end

defmodule Mimo.ProceduralStore.Steps.Conditional do
  @moduledoc """
  Conditional branching based on context values.
  """
  @behaviour Mimo.ProceduralStore.StepExecutor

  @impl true
  def execute(context, args) when is_map(args) do
    field = Map.get(args, "field")
    operator = Map.get(args, "operator", "eq")
    value = Map.get(args, "value")
    true_event = Map.get(args, "true_event", "true")
    false_event = Map.get(args, "false_event", "false")

    actual = Map.get(context, field)
    result = evaluate(actual, operator, value)

    if result do
      {:transition, true_event}
    else
      {:transition, false_event}
    end
  end

  @impl true
  def execute(context, args) when is_list(args) do
    field = Keyword.get(args, :field)
    operator = Keyword.get(args, :operator, :eq)
    value = Keyword.get(args, :value)
    true_event = Keyword.get(args, :true_event, :condition_true)
    false_event = Keyword.get(args, :false_event, :condition_false)

    actual = Map.get(context, field)
    result = evaluate(actual, operator, value)

    if result do
      {:transition, true_event}
    else
      {:transition, false_event}
    end
  end

  defp evaluate(actual, op, value) when op in ["eq", :eq], do: actual == value
  defp evaluate(actual, op, value) when op in ["ne", :ne], do: actual != value
  defp evaluate(actual, op, value) when op in ["gt", :gt], do: actual > value
  defp evaluate(actual, op, value) when op in ["gte", :gte], do: actual >= value
  defp evaluate(actual, op, value) when op in ["lt", :lt], do: actual < value
  defp evaluate(actual, op, value) when op in ["lte", :lte], do: actual <= value

  defp evaluate(actual, op, value) when op in ["contains", :contains],
    do: is_binary(actual) and String.contains?(actual, value)

  defp evaluate(actual, op, value) when op in ["in", :in], do: actual in value
  defp evaluate(_, _, _), do: false
end

defmodule Mimo.ProceduralStore.Steps.SetContext do
  @moduledoc """
  Sets values in the execution context.
  """
  @behaviour Mimo.ProceduralStore.StepExecutor

  @impl true
  def execute(_context, args) when is_map(args) do
    values = Map.get(args, "values", %{})
    {:ok, values}
  end

  @impl true
  def execute(context, args) when is_list(args) do
    values = Keyword.get(args, :values, %{})

    # Support both static values and context references
    resolved =
      values
      |> Enum.map(fn {key, value} ->
        resolved_value =
          case value do
            {:ref, ref_key} -> Map.get(context, ref_key)
            {:env, env_key} -> System.get_env(env_key)
            _ -> value
          end

        {key, resolved_value}
      end)
      |> Enum.into(%{})

    {:ok, resolved}
  end
end
