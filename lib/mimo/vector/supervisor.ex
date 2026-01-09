defmodule Mimo.Vector.Supervisor do
  # alias Mimo.Vector.Math (already using full path)
  @moduledoc """
  Supervisor for vector computation infrastructure.

  Manages:
  - NIF preloading
  - Worker pool for batch operations
  """
  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # NIF preloader - ensures NIF is compiled and loaded
      {Mimo.Vector.NIFPreloader, []},

      # Worker pool for batch operations
      # Using a simple Task.Supervisor as poolboy adds complexity
      {Task.Supervisor, name: Mimo.Vector.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Mimo.Vector.NIFPreloader do
  @moduledoc """
  Preloads the Rust NIF on application startup.

  This GenServer ensures the NIF is compiled (in dev) and loaded
  before any vector operations are attempted.
  """
  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Trigger NIF loading by calling the module
    case Mimo.Vector.Math.cosine_similarity([1.0], [1.0]) do
      {:ok, _} ->
        Logger.info("✅ Vector Math NIF ready")

      {:error, reason} ->
        Logger.warning("⚠️ Vector Math NIF not available: #{inspect(reason)}, using fallback")
    end

    {:ok, %{}}
  end

  @doc """
  Returns status of NIF loading.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def handle_call(:status, _from, state) do
    nif_loaded = Mimo.Vector.Math.nif_loaded?()
    {:reply, %{nif_loaded: nif_loaded}, state}
  end
end
