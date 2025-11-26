defmodule Mimo.Synapse.MessageRouter do
  @moduledoc """
  Routes messages between components via PubSub.

  Provides a unified interface for broadcasting thoughts,
  results, and system events to connected agents.
  """

  alias Phoenix.PubSub
  require Logger

  @pubsub Mimo.PubSub

  @doc """
  Broadcasts a thought to an agent.

  ## Parameters

    - `agent_id` - Target agent ID
    - `ref` - Query reference
    - `thought` - Thought payload
  """
  @spec broadcast_thought(String.t(), String.t(), map()) :: :ok
  def broadcast_thought(agent_id, ref, thought) do
    PubSub.broadcast(@pubsub, "agent:#{agent_id}", %{
      event: "thought:issued",
      payload: %{
        ref: ref,
        thought: thought,
        timestamp: System.system_time(:millisecond)
      }
    })
  end

  @doc """
  Broadcasts a query result to an agent.
  """
  @spec broadcast_result(String.t(), String.t(), atom(), term(), non_neg_integer()) :: :ok
  def broadcast_result(agent_id, ref, status, data, latency_ms) do
    PubSub.broadcast(@pubsub, "agent:#{agent_id}", %{
      event: "result",
      payload: %{
        ref: ref,
        status: to_string(status),
        data: data,
        latency_ms: latency_ms
      }
    })
  end

  @doc """
  Broadcasts an error to an agent.
  """
  @spec broadcast_error(String.t(), String.t(), term()) :: :ok
  def broadcast_error(agent_id, ref, error) do
    PubSub.broadcast(@pubsub, "agent:#{agent_id}", %{
      event: "error",
      payload: %{
        ref: ref,
        error: format_error(error),
        timestamp: System.system_time(:millisecond)
      }
    })
  end

  @doc """
  Broadcasts a system event to all agents.
  """
  @spec broadcast_system(String.t(), map()) :: :ok
  def broadcast_system(event, payload) do
    # Get all connected agents and broadcast
    Mimo.Synapse.ConnectionManager.list_active()
    |> Enum.each(fn {agent_id, _pid, _meta} ->
      PubSub.broadcast(@pubsub, "agent:#{agent_id}", %{
        event: "system:#{event}",
        payload: payload
      })
    end)
  end

  @doc """
  Broadcasts a procedure execution update.
  """
  @spec broadcast_procedure_update(String.t(), String.t(), String.t(), map()) :: :ok
  def broadcast_procedure_update(agent_id, ref, state, context) do
    PubSub.broadcast(@pubsub, "agent:#{agent_id}", %{
      event: "procedure:update",
      payload: %{
        ref: ref,
        state: state,
        context: context,
        timestamp: System.system_time(:millisecond)
      }
    })
  end

  @doc """
  Subscribes the current process to an agent's topic.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(agent_id) do
    PubSub.subscribe(@pubsub, "agent:#{agent_id}")
  end

  @doc """
  Unsubscribes the current process from an agent's topic.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(agent_id) do
    PubSub.unsubscribe(@pubsub, "agent:#{agent_id}")
  end

  # Private

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: to_string(error)
  defp format_error(error), do: inspect(error)
end
