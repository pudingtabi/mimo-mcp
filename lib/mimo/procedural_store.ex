defmodule Mimo.ProceduralStore do
  @moduledoc """
  Facade module for the Procedural Store - deterministic state machine execution.

  Provides a unified API for:
  - Procedure registration and management
  - Step-by-step execution with rollback
  - Procedure search and retrieval

  ## Architecture

  The ProceduralStore is composed of several sub-modules:
  - `Procedure` - Procedure and step schemas
  - `Loader` - YAML/JSON procedure loading
  - `Registry` - In-memory procedure registry
  - `ExecutionFSM` - Finite state machine for execution
  - `StepExecutor` - Individual step handlers
  - `Validator` - Procedure validation
  """

  alias ExecutionFSM
  alias Mimo.ProceduralStore.{Loader, Procedure}

  @doc """
  Search for procedures by query text.

  ## Options

    * `:limit` - Maximum results (default: 10)
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    try do
      procedures = Loader.list(active_only: true)

      results =
        procedures
        |> Enum.filter(fn proc ->
          name = proc.name || ""
          description = proc.description || ""
          query_lower = String.downcase(query)

          String.contains?(String.downcase(name), query_lower) or
            String.contains?(String.downcase(description), query_lower)
        end)
        |> Enum.take(limit)
        |> Enum.map(fn proc ->
          %{
            id: proc.id || proc.name,
            name: proc.name,
            content: proc.description || "",
            category: "procedure",
            importance: 0.7,
            metadata: %{"type" => "procedure", "version" => proc.version}
          }
        end)

      {:ok, results}
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Get a procedure by name.
  """
  @spec get(String.t()) :: {:ok, Procedure.t()} | {:error, :not_found}
  def get(name) do
    Loader.load(name, "latest")
  end

  @doc """
  List all registered procedures.
  """
  @spec list() :: [Procedure.t()]
  def list do
    Loader.list(active_only: true)
  end

  @doc """
  Execute a procedure by name.
  """
  @spec execute(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(name, context \\ %{}) do
    case get(name) do
      {:ok, proc} ->
        # Start the procedure FSM
        try do
          Mimo.ProceduralStore.ExecutionFSM.start_procedure(
            proc.name,
            proc.version || "latest",
            context,
            caller: self()
          )
        rescue
          _ -> {:error, :execution_not_available}
        end

      error ->
        error
    end
  end
end
