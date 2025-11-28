defmodule MimoWeb.CortexChannel do
  @moduledoc """
  Phoenix Channel for real-time cognitive signaling.

  The Cortex Channel enables bidirectional communication between
  Mimo and connected agents, supporting:

  - Query submission and streaming responses
  - Real-time thought/progress updates
  - Execution interruption
  - Presence tracking

  ## Client Protocol

  ### Joining

      socket.channel("cortex:<agent_id>", {api_key: "..."})

  ### Sending Queries

      channel.push("query", {q: "...", ref: "unique-id"})

  ### Receiving Thoughts

      channel.on("thought", ({thought, ref}) => {...})

  ### Interrupting

      channel.push("interrupt", {ref: "query-ref", reason: "..."})
  """

  use Phoenix.Channel

  alias Mimo.Synapse.{ConnectionManager, InterruptManager}
  alias Phoenix.PubSub

  require Logger

  # Intercept outgoing events for transformation
  intercept(["thought:issued", "execution:interrupt", "result"])

  @doc """
  Handles channel join requests.

  Validates API key and tracks the connection.
  """
  def join("cortex:" <> agent_id, %{"api_key" => key}, socket) do
    with {:ok, :authorized} <- authenticate(key),
         {:ok, _pid} <- ConnectionManager.track(agent_id, self()) do
      send(self(), :after_join)

      socket =
        socket
        |> assign(:agent_id, agent_id)
        |> assign(:joined_at, System.monotonic_time(:millisecond))

      Logger.info("Agent #{agent_id} joined cortex channel")
      {:ok, %{agent_id: agent_id}, socket}
    else
      {:error, reason} ->
        Logger.warning("Channel join rejected for agent #{agent_id}: #{inspect(reason)}")
        {:error, %{reason: "unauthorized"}}
    end
  end

  def join("cortex:" <> agent_id, _params, _socket) do
    Logger.warning("Channel join rejected for agent #{agent_id}: missing api_key")
    {:error, %{reason: "api_key required"}}
  end

  @doc """
  Handles query submission from client.
  """
  def handle_in("query", %{"q" => query, "ref" => ref} = params, socket) do
    agent_id = socket.assigns.agent_id
    priority = Map.get(params, "priority", 5)
    timeout = Map.get(params, "timeout", 30_000)

    Logger.debug("Query from #{agent_id}: #{String.slice(query, 0, 50)}...")

    # Spawn async cognition process
    Task.Supervisor.async_nolink(Mimo.TaskSupervisor, fn ->
      process_query(query, agent_id, ref, priority, timeout)
    end)

    {:reply, {:ok, %{ref: ref, status: "processing"}}, socket}
  end

  def handle_in("query", _params, socket) do
    {:reply, {:error, %{reason: "missing required fields: q, ref"}}, socket}
  end

  # Handles interrupt requests from client.
  def handle_in("interrupt", %{"ref" => ref, "reason" => reason}, socket) do
    agent_id = socket.assigns.agent_id
    Logger.info("Interrupt request from #{agent_id} for ref #{ref}: #{reason}")

    InterruptManager.signal(ref, :interrupt, %{reason: reason, agent_id: agent_id})

    {:reply, :ok, socket}
  end

  def handle_in("interrupt", %{"ref" => ref}, socket) do
    handle_in("interrupt", %{"ref" => ref, "reason" => "user requested"}, socket)
  end

  # Handles ping for connection health check.
  def handle_in("ping", _params, socket) do
    {:reply, {:ok, %{pong: System.monotonic_time(:millisecond)}}, socket}
  end

  # Handles subscription to specific event types.
  def handle_in("subscribe", %{"events" => events}, socket) when is_list(events) do
    socket = assign(socket, :subscribed_events, events)
    {:reply, :ok, socket}
  end

  # ============================================================================
  # Outgoing Event Handlers
  # ============================================================================

  @doc """
  Intercepts thought events for transformation before sending.
  """
  def handle_out("thought:issued", %{thought: thought, ref: ref}, socket) do
    # Check if client is subscribed to this event type
    subscribed = Map.get(socket.assigns, :subscribed_events, ["thought", "result"])

    if "thought" in subscribed do
      push(socket, "thought", %{
        thought: thought,
        ref: ref,
        timestamp: System.system_time(:millisecond)
      })
    end

    {:noreply, socket}
  end

  def handle_out("result", payload, socket) do
    push(socket, "result", payload)
    {:noreply, socket}
  end

  def handle_out("execution:interrupt", %{ref: ref, reason: reason}, socket) do
    push(socket, "interrupted", %{ref: ref, reason: reason})
    {:noreply, socket}
  end

  # ============================================================================
  # Internal Message Handlers
  # ============================================================================

  def handle_info(:after_join, socket) do
    agent_id = socket.assigns.agent_id

    # Subscribe to agent-specific PubSub topic
    PubSub.subscribe(Mimo.PubSub, "agent:#{agent_id}")

    # Track presence
    {:ok, _} =
      MimoWeb.Presence.track(socket, agent_id, %{
        online_at: System.system_time(:second),
        status: "active"
      })

    {:noreply, socket}
  end

  # Handle PubSub broadcasts
  def handle_info(%{event: event, payload: payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Termination
  # ============================================================================

  def terminate(reason, socket) do
    agent_id = socket.assigns.agent_id
    Logger.info("Agent #{agent_id} disconnected: #{inspect(reason)}")
    ConnectionManager.untrack(agent_id)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp authenticate(api_key) do
    configured_key = Application.get_env(:mimo_mcp, :api_key)

    cond do
      # No key configured = dev mode, allow all
      is_nil(configured_key) ->
        {:ok, :authorized}

      # Key matches
      api_key == configured_key ->
        {:ok, :authorized}

      true ->
        {:error, :invalid_api_key}
    end
  end

  defp process_query(query, agent_id, ref, _priority, timeout) do
    start_time = System.monotonic_time(:millisecond)

    # Register with interrupt manager
    InterruptManager.register(ref, self())

    try do
      # Emit initial thought
      broadcast_thought(agent_id, ref, %{
        type: "processing",
        content: "Analyzing query..."
      })

      # Route through meta-cognitive router
      decision = Mimo.MetaCognitiveRouter.classify(query)

      broadcast_thought(agent_id, ref, %{
        type: "routing",
        content: "Routing to #{decision.primary_store} store",
        confidence: decision.confidence
      })

      # Execute based on routing decision
      result =
        case decision.primary_store do
          :semantic ->
            execute_semantic_query(query, agent_id, ref, timeout)

          :procedural ->
            execute_procedural_query(query, agent_id, ref, timeout)

          :episodic ->
            execute_episodic_query(query, agent_id, ref, timeout)
        end

      # Calculate latency
      latency = System.monotonic_time(:millisecond) - start_time

      # Broadcast result
      broadcast_result(agent_id, ref, :success, result, latency)
    catch
      :interrupt ->
        broadcast_result(agent_id, ref, :interrupted, nil, 0)

      kind, reason ->
        Logger.error("Query processing failed: #{kind} - #{inspect(reason)}")
        latency = System.monotonic_time(:millisecond) - start_time
        broadcast_result(agent_id, ref, :error, inspect(reason), latency)
    after
      InterruptManager.unregister(ref)
    end
  end

  defp execute_semantic_query(query, agent_id, ref, _timeout) do
    broadcast_thought(agent_id, ref, %{
      type: "memory_recall",
      content: "Searching semantic memory..."
    })

    alias Mimo.SemanticStore.Query

    try do
      # Try pattern matching for structured queries
      triples = Query.pattern_match([{:any, "relates_to", :any}])

      if triples == [] do
        # Fallback to episodic search if no semantic results
        broadcast_thought(agent_id, ref, %{
          type: "fallback",
          content: "No semantic matches, searching episodic memory..."
        })

        episodic_results = Mimo.Brain.Memory.search_memories(query, limit: 5)

        %{
          store: "semantic_with_episodic_fallback",
          query: query,
          results: episodic_results
        }
      else
        %{
          store: "semantic",
          query: query,
          results: triples
        }
      end
    rescue
      e ->
        Logger.warning("Semantic query failed: #{Exception.message(e)}")
        %{store: "semantic", query: query, results: [], error: Exception.message(e)}
    end
  end

  defp execute_procedural_query(query, agent_id, ref, _timeout) do
    broadcast_thought(agent_id, ref, %{
      type: "tool_invocation",
      content: "Checking procedural skills..."
    })

    alias Mimo.ProceduralStore.Loader

    # Try to find a procedure matching the query
    # Query is used as procedure name lookup
    procedure_name = extract_procedure_name(query)

    case Loader.load(procedure_name, "latest") do
      {:ok, procedure} ->
        %{
          store: "procedural",
          query: query,
          results: [
            %{
              name: procedure.name,
              version: procedure.version,
              description: procedure.description,
              steps: procedure.steps
            }
          ]
        }

      {:error, :not_found} ->
        # List available procedures as context
        available = Loader.list(active_only: true) |> Enum.take(5)

        %{
          store: "procedural",
          query: query,
          results: [],
          available_procedures: Enum.map(available, & &1.name)
        }

      {:error, reason} ->
        Logger.warning("Procedural query failed: #{inspect(reason)}")
        %{store: "procedural", query: query, results: [], error: inspect(reason)}
    end
  end

  defp extract_procedure_name(query) do
    # Simple extraction: use the query as-is for now
    # Could be enhanced with NLP entity extraction
    query
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "_")
    |> String.slice(0, 64)
  end

  defp execute_episodic_query(query, agent_id, ref, _timeout) do
    broadcast_thought(agent_id, ref, %{
      type: "memory_recall",
      content: "Searching episodic memory..."
    })

    # Use existing memory search
    results = Mimo.Brain.Memory.search_memories(query, limit: 10)

    %{
      store: "episodic",
      query: query,
      results: results
    }
  end

  defp broadcast_thought(agent_id, ref, thought) do
    PubSub.broadcast(Mimo.PubSub, "agent:#{agent_id}", %{
      event: "thought:issued",
      payload: %{thought: thought, ref: ref}
    })
  end

  defp broadcast_result(agent_id, ref, status, data, latency_ms) do
    PubSub.broadcast(Mimo.PubSub, "agent:#{agent_id}", %{
      event: "result",
      payload: %{
        ref: ref,
        status: status,
        data: data,
        latency_ms: latency_ms
      }
    })
  end
end
