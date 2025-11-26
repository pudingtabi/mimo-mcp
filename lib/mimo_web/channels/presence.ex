defmodule MimoWeb.Presence do
  @moduledoc """
  Presence tracking for connected agents.
  
  Tracks agent connection status, cognitive load, and activity
  across the distributed Mimo cluster.
  """
  use Phoenix.Presence,
    otp_app: :mimo_mcp,
    pubsub_server: Mimo.PubSub

  @doc """
  Tracks an agent's cognitive load.
  """
  def track_load(socket, agent_id, load_pct) when is_number(load_pct) do
    update(socket, agent_id, fn meta ->
      Map.merge(meta, %{
        load: load_pct,
        last_activity: System.system_time(:millisecond)
      })
    end)
  end

  @doc """
  Updates an agent's status.
  """
  def update_status(socket, agent_id, status) when is_binary(status) do
    update(socket, agent_id, fn meta ->
      Map.put(meta, :status, status)
    end)
  end

  @doc """
  Gets all online agents with their metadata.
  """
  def list_agents do
    list("cortex:presence")
    |> Enum.map(fn {agent_id, %{metas: [meta | _]}} ->
      {agent_id, meta}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Gets a specific agent's presence info.
  """
  def get_agent(agent_id) do
    case list("cortex:presence") |> Map.get(agent_id) do
      nil -> nil
      %{metas: [meta | _]} -> meta
    end
  end

  @doc """
  Returns count of online agents.
  """
  def agent_count do
    list("cortex:presence") |> map_size()
  end
end

defmodule MimoWeb.CortexSocket do
  @moduledoc """
  WebSocket handler for the Cortex channel.
  """
  use Phoenix.Socket

  channel "cortex:*", MimoWeb.CortexChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    # Validate token if provided
    case validate_token(token) do
      {:ok, agent_info} ->
        {:ok, assign(socket, :agent_info, agent_info)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, socket, _connect_info) do
    # Allow connection without token - authentication happens on channel join
    {:ok, socket}
  end

  @impl true
  def id(socket) do
    case socket.assigns[:agent_info] do
      %{agent_id: agent_id} -> "cortex:#{agent_id}"
      _ -> nil
    end
  end

  defp validate_token(token) do
    # Simple token validation - expand as needed
    case Phoenix.Token.verify(MimoWeb.Endpoint, "agent_socket", token, max_age: 86400) do
      {:ok, agent_id} -> {:ok, %{agent_id: agent_id}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :invalid_token}
  end
end
