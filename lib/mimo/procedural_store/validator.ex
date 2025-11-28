defmodule Mimo.ProceduralStore.Validator do
  @moduledoc """
  JSON Schema validator for procedure definitions.

  Validates that procedure definitions conform to the expected
  state machine format before registration.
  """

  @doc """
  Validates a procedure definition.

  ## Required Structure

      %{
        "name" => "procedure_name",
        "version" => "1.0",
        "initial_state" => "state_name",
        "states" => %{
          "state_name" => %{
            "action" => %{...},
            "transitions" => [%{...}]
          }
        }
      }

  ## Returns

    - `:ok` - Valid definition
    - `{:error, errors}` - List of validation errors
  """
  @spec validate(map()) :: :ok | {:error, [String.t()]}
  def validate(definition) when is_map(definition) do
    errors =
      []
      |> validate_required_fields(definition)
      |> validate_initial_state(definition)
      |> validate_states(definition)
      |> validate_transitions(definition)
      |> validate_no_orphan_states(definition)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(_), do: {:error, ["definition must be a map"]}

  defp validate_required_fields(errors, definition) do
    required = ["initial_state", "states"]

    missing =
      required
      |> Enum.reject(&Map.has_key?(definition, &1))

    case missing do
      [] -> errors
      fields -> ["missing required fields: #{Enum.join(fields, ", ")}" | errors]
    end
  end

  defp validate_initial_state(errors, definition) do
    initial = Map.get(definition, "initial_state")
    states = Map.get(definition, "states", %{})

    cond do
      is_nil(initial) ->
        errors

      not is_binary(initial) ->
        ["initial_state must be a string" | errors]

      not is_map(states) ->
        # Skip this check if states is not a map (will be caught by validate_states)
        errors

      not Map.has_key?(states, initial) ->
        ["initial_state '#{initial}' not found in states" | errors]

      true ->
        errors
    end
  end

  defp validate_states(errors, definition) do
    states = Map.get(definition, "states", %{})

    if not is_map(states) do
      ["states must be a map" | errors]
    else
      states
      |> Enum.reduce(errors, fn {name, state}, acc ->
        validate_state(acc, name, state)
      end)
    end
  end

  defp validate_state(errors, name, state) when is_map(state) do
    errors
    |> validate_state_action(name, state)
    |> validate_state_transitions(name, state)
  end

  defp validate_state(errors, name, _state) do
    ["state '#{name}' must be a map" | errors]
  end

  defp validate_state_action(errors, name, state) do
    case Map.get(state, "action") do
      nil ->
        # Action is optional for terminal states
        errors

      action when is_map(action) ->
        validate_action(errors, name, action)

      _ ->
        ["state '#{name}' action must be a map" | errors]
    end
  end

  defp validate_action(errors, state_name, action) do
    case {Map.get(action, "module"), Map.get(action, "function")} do
      {nil, _} ->
        ["state '#{state_name}' action missing 'module'" | errors]

      {_, nil} ->
        ["state '#{state_name}' action missing 'function'" | errors]

      {mod, fun} when is_binary(mod) and is_binary(fun) ->
        errors

      _ ->
        ["state '#{state_name}' action module/function must be strings" | errors]
    end
  end

  defp validate_state_transitions(errors, name, state) do
    case Map.get(state, "transitions") do
      nil ->
        # No transitions = terminal state
        errors

      transitions when is_list(transitions) ->
        transitions
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {t, idx}, acc ->
          validate_transition(acc, name, idx, t)
        end)

      _ ->
        ["state '#{name}' transitions must be a list" | errors]
    end
  end

  defp validate_transition(errors, state_name, idx, transition) when is_map(transition) do
    case {Map.get(transition, "event"), Map.get(transition, "target")} do
      {nil, _} ->
        ["state '#{state_name}' transition #{idx} missing 'event'" | errors]

      {_, nil} ->
        ["state '#{state_name}' transition #{idx} missing 'target'" | errors]

      {event, target} when is_binary(event) and is_binary(target) ->
        errors

      _ ->
        ["state '#{state_name}' transition #{idx} event/target must be strings" | errors]
    end
  end

  defp validate_transition(errors, state_name, idx, _) do
    ["state '#{state_name}' transition #{idx} must be a map" | errors]
  end

  defp validate_transitions(errors, definition) do
    states = Map.get(definition, "states", %{})

    # Skip if states is not a map
    if not is_map(states) do
      errors
    else
      state_names = Map.keys(states) |> MapSet.new()

      # Check all transition targets exist
      states
      |> Enum.reduce(errors, fn {name, state}, acc ->
        # Skip if state is not a map
        if not is_map(state) do
          acc
        else
          transitions = Map.get(state, "transitions", [])

          # Skip if transitions is not a list
          if not is_list(transitions) do
            acc
          else
            invalid_targets =
              transitions
              |> Enum.filter(&is_map/1)
              |> Enum.map(&Map.get(&1, "target"))
              |> Enum.reject(&is_nil/1)
              |> Enum.reject(&MapSet.member?(state_names, &1))

            case invalid_targets do
              [] ->
                acc

              targets ->
                [
                  "state '#{name}' has transitions to non-existent states: #{Enum.join(targets, ", ")}"
                  | acc
                ]
            end
          end
        end
      end)
    end
  end

  defp validate_no_orphan_states(errors, definition) do
    states = Map.get(definition, "states", %{})

    # Skip if states is not a map
    if not is_map(states) do
      errors
    else
      initial = Map.get(definition, "initial_state")

      # Find all reachable states from initial
      reachable = find_reachable_states(states, initial, MapSet.new([initial]))

      # Find orphans (states not reachable from initial)
      all_states = Map.keys(states) |> MapSet.new()
      orphans = MapSet.difference(all_states, reachable)

      case MapSet.to_list(orphans) do
        [] ->
          errors

        orphan_list ->
          ["unreachable states from initial: #{Enum.join(orphan_list, ", ")}" | errors]
      end
    end
  end

  defp find_reachable_states(states, current, visited) do
    state = Map.get(states, current, %{})

    # If state is not a map, return visited as-is
    if not is_map(state) do
      visited
    else
      transitions = Map.get(state, "transitions", [])

      # If transitions is not a list, return visited as-is
      if not is_list(transitions) do
        visited
      else
        targets =
          transitions
          |> Enum.filter(&is_map/1)
          |> Enum.map(&Map.get(&1, "target"))
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&MapSet.member?(visited, &1))

        new_visited = Enum.reduce(targets, visited, &MapSet.put(&2, &1))

        Enum.reduce(targets, new_visited, fn target, acc ->
          find_reachable_states(states, target, acc)
        end)
      end
    end
  end
end
