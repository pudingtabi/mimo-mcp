defmodule Mimo.Tools.Helpers do
  @moduledoc """
  Shared helper functions and constants for tool dispatchers.

  Extracted from the monolithic tools.ex as part of SPEC-030 modularization.
  Contains:
  - Safe atom conversion (prevents atom table exhaustion)
  - Allowed value whitelists for user input validation
  - Common formatting functions for graph nodes, edges, etc.
  - Response enrichment helpers for memory context
  """

  require Logger

  # ==========================================================================
  # ALLOWED VALUE WHITELISTS - Prevents atom table exhaustion attacks
  # ==========================================================================

  @allowed_search_backends ~w(auto duckduckgo bing brave)a
  @allowed_browser_profiles ~w(chrome firefox safari random chrome_136 firefox_135 safari_18)a
  @allowed_directions ~w(outgoing incoming both)a
  @allowed_diagnostic_ops ~w(check lint typecheck all)a
  @allowed_languages ~w(auto elixir typescript python rust go javascript)a
  @allowed_severities ~w(error warning info all)a
  @allowed_action_keys ~w(type selector text value delay screenshot evaluate waitForNavigation click hover focus press scroll select wait)a
  @allowed_assertion_keys ~w(type contains equals matches url text selector visible hidden)a

  # Expose constants for use by dispatchers
  def allowed_search_backends, do: @allowed_search_backends
  def allowed_browser_profiles, do: @allowed_browser_profiles
  def allowed_directions, do: @allowed_directions
  def allowed_diagnostic_ops, do: @allowed_diagnostic_ops
  def allowed_languages, do: @allowed_languages
  def allowed_severities, do: @allowed_severities
  def allowed_action_keys, do: @allowed_action_keys
  def allowed_assertion_keys, do: @allowed_assertion_keys

  # ==========================================================================
  # SAFE ATOM CONVERSION - Prevents atom table exhaustion attacks
  # ==========================================================================

  @doc """
  Safe atom conversion - only allows pre-defined values.
  Returns nil if value is not in the allowed list.
  """
  def safe_to_atom(value, allowed) when is_binary(value) do
    atom_value = String.to_existing_atom(value)
    if atom_value in allowed, do: atom_value, else: nil
  rescue
    ArgumentError -> nil
  end

  def safe_to_atom(value, allowed) when is_atom(value) do
    if value in allowed, do: value, else: nil
  end

  def safe_to_atom(_, _), do: nil

  @doc """
  Safe conversion for map keys from JSON - uses whitelist.
  SECURITY FIX: Unknown keys are kept as strings instead of creating atoms.
  This prevents atom table exhaustion from attacker-controlled JSON keys.
  """
  def safe_key_to_atom(key, allowed) when is_binary(key) do
    case safe_to_atom(key, allowed) do
      # Keep as string - don't create atoms for unknown keys
      nil -> key
      atom -> atom
    end
  end

  def safe_key_to_atom(key, _allowed) when is_atom(key), do: key
  # Keep unknown as string
  def safe_key_to_atom(key, _allowed) when is_binary(key), do: key
  # String, not atom
  def safe_key_to_atom(_, _), do: "_unknown"

  # ==========================================================================
  # NODE TYPE PARSING
  # ==========================================================================

  @doc """
  Parse node type string to atom.
  """
  def parse_node_type(nil), do: :function
  def parse_node_type("concept"), do: :concept
  def parse_node_type("file"), do: :file
  def parse_node_type("function"), do: :function
  def parse_node_type("module"), do: :module
  def parse_node_type("external_lib"), do: :external_lib
  def parse_node_type("memory"), do: :memory
  def parse_node_type(type) when is_atom(type), do: type
  def parse_node_type(_), do: :function

  # ==========================================================================
  # HEADER NORMALIZATION
  # ==========================================================================

  @doc """
  Normalize headers from various formats to tuple list.
  """
  def normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      %{"name" => n, "value" => v} -> {n, v}
      {n, v} -> {n, v}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  def normalize_headers(_), do: []

  # ==========================================================================
  # IMAGE URL DETECTION
  # ==========================================================================

  @doc """
  Check if a URL looks like an image.
  """
  def image_url?(url) when is_binary(url) do
    lower_url = String.downcase(url)

    String.ends_with?(lower_url, [".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg"]) or
      String.contains?(lower_url, ["/image/", "/img/", "/photo/", "/picture/"]) or
      String.contains?(lower_url, ["imgur.com", "i.redd.it", "pbs.twimg.com"])
  end

  def image_url?(_), do: false

  # ==========================================================================
  # GRAPH NODE/EDGE FORMATTING
  # ==========================================================================

  @doc """
  Format a single graph node for output.
  """
  def format_graph_node(nil), do: nil

  def format_graph_node(node) do
    %{
      id: node.id,
      type: node.node_type,
      name: node.name,
      properties: node.properties || %{},
      access_count: node.access_count || 0
    }
  end

  @doc """
  Format multiple graph nodes for output.
  """
  def format_graph_nodes(nodes) do
    Enum.map(nodes, &format_graph_node/1)
  end

  @doc """
  Format edges for output.
  """
  def format_edges(edges) do
    Enum.map(edges, fn edge ->
      %{
        id: edge.id,
        from_node_id: edge.from_node_id,
        to_node_id: edge.to_node_id,
        edge_type: edge.edge_type,
        weight: edge.weight || 1.0,
        properties: edge.properties || %{}
      }
    end)
  end

  # ==========================================================================
  # SYMBOL/REFERENCE FORMATTING (for code_symbols dispatcher)
  # ==========================================================================

  @doc """
  Format a symbol for output.
  """
  def format_symbol(symbol) do
    %{
      name: symbol.name,
      qualified_name: symbol.qualified_name,
      kind: symbol.kind,
      file_path: symbol.file_path,
      start_line: symbol.start_line,
      end_line: symbol.end_line
    }
  end

  @doc """
  Format a reference for output.
  """
  def format_reference(ref) do
    %{
      name: ref.name,
      kind: ref.kind,
      file_path: ref.file_path,
      line: ref.line,
      col: ref.col
    }
  end

  # ==========================================================================
  # MEMORY CONTEXT ENRICHMENT (Layer 2 - Accuracy over Speed)
  # Automatically brings relevant knowledge to the agent without behavior change
  # ==========================================================================

  @doc """
  Enrich file operation response with memory context.
  """
  def enrich_file_response({:ok, data}, path, false = _skip) when is_map(data) do
    task =
      Mimo.TaskHelper.async_with_callers(fn ->
        Mimo.Skills.MemoryContext.get_file_context(path)
      end)

    case Task.yield(task, 2000) || Task.shutdown(task) do
      {:ok, {:ok, context}} when not is_nil(context) ->
        {:ok, Mimo.Skills.MemoryContext.enrich_response(data, context)}

      _ ->
        {:ok, data}
    end
  end

  def enrich_file_response({:ok, data}, _path, true = _skip), do: {:ok, data}
  def enrich_file_response({:error, _} = error, _path, _skip), do: error
  def enrich_file_response(other, _path, _skip), do: other

  @doc """
  Enrich terminal operation response with memory context.
  """
  def enrich_terminal_response({:ok, data}, command, false = _skip) when is_map(data) do
    task =
      Mimo.TaskHelper.async_with_callers(fn ->
        Mimo.Skills.MemoryContext.get_command_context(command)
      end)

    case Task.yield(task, 2000) || Task.shutdown(task) do
      {:ok, {:ok, context}} when not is_nil(context) ->
        {:ok, Mimo.Skills.MemoryContext.enrich_response(data, context)}

      _ ->
        {:ok, data}
    end
  end

  def enrich_terminal_response({:ok, data}, _command, true = _skip), do: {:ok, data}
  def enrich_terminal_response(other, _command, _skip), do: other

  # ==========================================================================
  # ECOSYSTEM PARSING (for library dispatcher)
  # ==========================================================================

  @doc """
  Parse ecosystem string to atom.
  """
  def parse_ecosystem(ecosystem) when is_binary(ecosystem) do
    case String.downcase(ecosystem) do
      "hex" -> :hex
      "pypi" -> :pypi
      "npm" -> :npm
      "crates" -> :crates
      _ -> :hex
    end
  end

  def parse_ecosystem(ecosystem) when is_atom(ecosystem), do: ecosystem
  def parse_ecosystem(_), do: :hex

  # ==========================================================================
  # PACKAGE FORMATTING (for library dispatcher)
  # ==========================================================================

  @doc """
  Format package info for output.
  """
  def format_package(package) do
    modules = package[:modules] || package["modules"] || []
    types = package[:types] || package["types"]
    modules_count = count_modules(modules, types)

    %{
      name: package[:name] || package["name"],
      version: package[:version] || package["version"],
      description: package[:description] || package["description"],
      found: true,
      docs_url: package[:docs_url] || package["docs_url"],
      modules_count: modules_count,
      dependencies: package[:dependencies] || package["dependencies"] || []
    }
  end

  # Multi-head module counting
  defp count_modules(modules, _types) when length(modules) > 0, do: length(modules)

  defp count_modules(_modules, types) when is_map(types) do
    type_modules = types[:modules] || types["modules"] || []

    Enum.reduce(type_modules, 0, fn mod, acc ->
      exports = mod[:exports] || mod["exports"] || []
      acc + length(exports)
    end)
  end

  defp count_modules(_modules, _types), do: 0

  # ==========================================================================
  # UNCERTAINTY FORMATTING (for cognitive dispatcher)
  # ==========================================================================

  @doc """
  Format uncertainty struct for output.
  """
  def format_uncertainty(uncertainty) do
    %{
      topic: uncertainty.topic,
      confidence: uncertainty.confidence,
      score: Float.round(uncertainty.score, 3),
      evidence_count: uncertainty.evidence_count,
      source_types: uncertainty.sources |> Enum.map(& &1.type) |> Enum.uniq(),
      staleness: Float.round(uncertainty.staleness, 3),
      has_gap: Mimo.Cognitive.Uncertainty.has_gap?(uncertainty),
      gap_indicators: uncertainty.gap_indicators
    }
  end
end
