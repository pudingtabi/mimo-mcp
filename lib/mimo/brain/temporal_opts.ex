defmodule Mimo.Brain.TemporalOpts do
  @moduledoc """
  SPEC-060 Enhancement: Structured temporal validity options.
  
  Replaces keyword list threading with a typed struct for compile-time safety.
  
  ## Benefits
  
  - Compile-time field checking via struct pattern matching
  - Clear documentation of available options
  - Default values in one place
  - Type specs for Dialyzer
  - Easier to extend with new temporal options
  
  ## Usage
  
      # Create with explicit values
      opts = TemporalOpts.new(
        valid_from: ~U[2025-01-01 00:00:00Z],
        valid_until: ~U[2025-12-31 23:59:59Z],
        validity_source: "explicit"
      )
      
      # Create empty (all nil = no temporal bounds)
      opts = TemporalOpts.new()
      
      # Convert to keyword list for backward compatibility
      kw = TemporalOpts.to_keyword_list(opts)
      
      # Parse from string values (for tool interface)
      {:ok, opts} = TemporalOpts.from_params(%{
        "valid_from" => "2025-01-01T00:00:00Z",
        "valid_until" => "2025-12-31",
        "validity_source" => "explicit"
      })
  """

  @type validity_source :: String.t() | nil
  @valid_sources ["explicit", "inferred", "superseded", "corrected", "expired"]

  @type t :: %__MODULE__{
    valid_from: DateTime.t() | nil,
    valid_until: DateTime.t() | nil,
    validity_source: validity_source()
  }

  defstruct [
    :valid_from,
    :valid_until,
    :validity_source
  ]

  @doc """
  Create a new TemporalOpts struct.
  
  All fields default to nil, meaning no temporal bounds.
  
  ## Options
  
    * `:valid_from` - DateTime when the memory becomes valid
    * `:valid_until` - DateTime when the memory expires
    * `:validity_source` - Source of validity info ("explicit", "inferred", "superseded", "corrected")
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      valid_from: Keyword.get(opts, :valid_from),
      valid_until: Keyword.get(opts, :valid_until),
      validity_source: Keyword.get(opts, :validity_source)
    }
  end

  @doc """
  Convert to keyword list for backward compatibility with existing code.
  
  Only includes non-nil values to avoid polluting changesets.
  """
  @spec to_keyword_list(t()) :: keyword()
  def to_keyword_list(%__MODULE__{} = opts) do
    [
      valid_from: opts.valid_from,
      valid_until: opts.valid_until,
      validity_source: opts.validity_source
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  Parse temporal options from string parameters (tool interface input).
  
  Handles ISO8601 datetime strings and date-only strings.
  
  ## Examples
  
      {:ok, opts} = from_params(%{"valid_from" => "2025-01-01T00:00:00Z"})
      {:ok, opts} = from_params(%{"valid_until" => "2025-12-31"})
      {:error, {:invalid_datetime, "not-a-date"}} = from_params(%{"valid_from" => "not-a-date"})
  """
  @spec from_params(map()) :: {:ok, t()} | {:error, term()}
  def from_params(params) when is_map(params) do
    with {:ok, valid_from} <- parse_datetime_param(params, "valid_from"),
         {:ok, valid_until} <- parse_datetime_param(params, "valid_until"),
         {:ok, validity_source} <- parse_validity_source(params) do
      {:ok, %__MODULE__{
        valid_from: valid_from,
        valid_until: valid_until,
        validity_source: validity_source
      }}
    end
  end

  @doc """
  Check if the opts specify any temporal bounds.
  """
  @spec has_temporal_bounds?(t()) :: boolean()
  def has_temporal_bounds?(%__MODULE__{valid_from: nil, valid_until: nil}), do: false
  def has_temporal_bounds?(%__MODULE__{}), do: true

  @doc """
  Check if the validity_source is valid.
  """
  @spec valid_source?(String.t() | nil) :: boolean()
  def valid_source?(nil), do: true
  def valid_source?(source) when source in @valid_sources, do: true
  def valid_source?(_), do: false

  @doc """
  List valid validity sources.
  """
  @spec valid_sources() :: [String.t()]
  def valid_sources, do: @valid_sources

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp parse_datetime_param(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> parse_datetime(value)
      %DateTime{} = dt -> {:ok, dt}
      other -> {:error, {:invalid_datetime, other}}
    end
  end

  defp parse_datetime(str) when is_binary(str) do
    # Try ISO8601 with timezone first
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> 
        {:ok, dt}
      {:error, _} ->
        # Try date-only format (defaults to start of day UTC)
        case Date.from_iso8601(str) do
          {:ok, date} ->
            {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
          {:error, _} ->
            {:error, {:invalid_datetime, str}}
        end
    end
  end

  defp parse_validity_source(params) do
    case Map.get(params, "validity_source") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      source when source in @valid_sources -> {:ok, source}
      other -> {:error, {:invalid_validity_source, other, @valid_sources}}
    end
  end
end
