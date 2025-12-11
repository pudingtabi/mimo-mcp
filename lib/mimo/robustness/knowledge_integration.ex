defmodule Mimo.Robustness.KnowledgeIntegration do
  @moduledoc """
  Knowledge Graph Integration (SPEC-070 Task C)
  
  Tracks fragile code locations and links to incidents for institutional learning.
  Uses Mimo's Synapse knowledge graph to store relationships between:
  
  - Files and the patterns they contain
  - Patterns and the incidents they caused
  - Incidents and their fixes
  - Similar patterns across the codebase
  
  ## Graph Schema
  
  ### Node Types
  - `file` - Source code files
  - `function` - Specific functions within files
  - `pattern` - Red flag patterns (e.g., blocking_genserver_init)
  - `incident` - Production incidents
  
  ### Edge Types
  - `contains_pattern` - File contains a red flag pattern
  - `caused_incident` - Pattern led to an incident
  - `fixed_by` - Incident was fixed by a code change
  - `similar_to` - Pattern is similar to another pattern
  
  ## Usage
  
      # Store audit findings in graph
      {:ok, _} = KnowledgeIntegration.store_audit_findings(audit_result)
      
      # Query risk for a file
      {:ok, risk} = KnowledgeIntegration.query_file_risk("lib/file.ex")
      
      # Find files with specific pattern
      {:ok, files} = KnowledgeIntegration.find_files_with_pattern(:blocking_genserver_init)
  """

  require Logger
  alias Mimo.Robustness.IncidentParser
  # Note: PatternDetector is used indirectly via IncidentParser

  @doc """
  Initialize the knowledge graph with Dec 6 2025 incident data.
  
  This seeds the graph with known incidents and their patterns
  to enable learning and risk assessment.
  """
  @spec seed_dec6_incidents() :: {:ok, map()} | {:error, term()}
  def seed_dec6_incidents do
    with {:ok, incidents} <- IncidentParser.parse_dec6_incidents() do
      results = Enum.map(incidents, fn incident ->
        # Teach incident
        teach_incident(incident)
        
        # Teach patterns
        pattern_results = Enum.map(incident.patterns, fn pattern ->
          teach_pattern(pattern.name, pattern.category, incident.title)
        end)
        
        # Teach file locations
        location_results = Enum.map(incident.locations, fn loc ->
          if loc.file do
            teach_file_pattern(loc.file, incident.patterns, incident.title)
          end
        end)
        
        %{
          incident: incident.title,
          patterns: pattern_results,
          locations: location_results
        }
      end)
      
      {:ok, %{seeded: length(incidents), details: results}}
    end
  end

  @doc """
  Store audit findings in the knowledge graph.
  
  Creates relationships between files and detected patterns.
  """
  @spec store_audit_findings(map()) :: {:ok, map()} | {:error, term()}
  def store_audit_findings(audit_result) do
    files = Map.get(audit_result, :files, [])
    
    stored = Enum.reduce(files, %{files: 0, patterns: 0}, fn file_result, acc ->
      # Store file node with score
      teach("File #{file_result.file} has robustness score #{file_result.score}")
      
      # Store each pattern found
      pattern_count = Enum.reduce(file_result.red_flags, 0, fn pattern, count ->
        teach("File #{file_result.file} contains pattern #{pattern.id} at line #{pattern.line}")
        count + 1
      end)
      
      %{acc | files: acc.files + 1, patterns: acc.patterns + pattern_count}
    end)
    
    {:ok, stored}
  end

  @doc """
  Query the risk level of a file based on knowledge graph.
  
  Returns incidents, patterns, and historical issues.
  """
  @spec query_file_risk(String.t()) :: {:ok, map()} | {:error, term()}
  def query_file_risk(file_path) do
    # Query for patterns in file
    patterns_query = "What patterns does #{file_path} contain?"
    patterns = query(patterns_query)
    
    # Query for incidents involving file
    incidents_query = "What incidents involved #{file_path}?"
    incidents = query(incidents_query)
    
    # Calculate risk score
    pattern_count = case patterns do
      {:ok, result} -> length(Map.get(result, :triples, []))
      _ -> 0
    end
    
    incident_count = case incidents do
      {:ok, result} -> length(Map.get(result, :triples, []))
      _ -> 0
    end
    
    risk_score = calculate_risk_score(pattern_count, incident_count)
    
    {:ok, %{
      file: file_path,
      risk_score: risk_score,
      risk_level: risk_level(risk_score),
      pattern_count: pattern_count,
      incident_count: incident_count,
      patterns: patterns,
      incidents: incidents
    }}
  end

  @doc """
  Find all files containing a specific pattern.
  """
  @spec find_files_with_pattern(atom()) :: {:ok, [String.t()]} | {:error, term()}
  def find_files_with_pattern(pattern_id) do
    query_text = "Which files contain pattern #{pattern_id}?"
    
    case query(query_text) do
      {:ok, result} ->
        files = result
          |> Map.get(:triples, [])
          |> Enum.map(& &1.subject)
          |> Enum.filter(&String.contains?(&1, "/"))
          |> Enum.uniq()
        
        {:ok, files}
      error -> error
    end
  end

  @doc """
  Traverse the knowledge graph from a starting point.
  
  Useful for understanding impact and relationships.
  """
  @spec traverse_from(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def traverse_from(node_name, opts \\ []) do
    direction = Keyword.get(opts, :direction, :both)
    _depth = Keyword.get(opts, :depth, 3)
    
    case Code.ensure_loaded(Mimo.Synapse.Graph) do
      {:module, _} ->
        # Find node first
        case find_node(node_name) do
          {:ok, node} ->
            # Use neighbors function instead of non-existent Traversal.traverse
            neighbors = case direction do
              :out -> Mimo.Synapse.Graph.outgoing_edges(node.id)
              :in -> Mimo.Synapse.Graph.incoming_edges(node.id)
              :both -> Mimo.Synapse.Graph.neighbors(node.id)
            end
            {:ok, %{node: node, neighbors: neighbors}}
          error -> error
        end
      _ ->
        {:error, :synapse_not_available}
    end
  end

  @doc """
  Link an incident to its patterns and files in the graph.
  """
  @spec link_incident(map()) :: {:ok, map()} | {:error, term()}
  def link_incident(incident) do
    # Create incident node
    teach("Incident #{incident.title} occurred on #{incident.date} with severity #{incident.severity}")
    
    # Link patterns
    Enum.each(incident.patterns, fn pattern ->
      teach("Pattern #{pattern.name} caused incident #{incident.title}")
    end)
    
    # Link files
    Enum.each(incident.locations, fn loc ->
      if loc.file do
        teach("Incident #{incident.title} involved file #{loc.file}")
      end
    end)
    
    # Store fix
    if incident.fix && incident.fix != "" do
      teach("Incident #{incident.title} was fixed by #{String.slice(incident.fix, 0, 100)}")
    end
    
    {:ok, %{incident: incident.title}}
  end

  @doc """
  Get statistics about robustness knowledge in the graph.
  """
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    case Code.ensure_loaded(Mimo.Synapse.Graph) do
      {:module, _} ->
        # Graph.stats returns a map directly, not {:ok, map}
        graph_stats = Mimo.Synapse.Graph.stats()
        {:ok, %{
          graph_stats: graph_stats,
          patterns_known: count_pattern_nodes(),
          incidents_tracked: count_incident_nodes(),
          files_analyzed: count_file_nodes()
        }}
      _ ->
        {:ok, %{
          status: :synapse_not_available,
          patterns_known: 0,
          incidents_tracked: 0,
          files_analyzed: 0
        }}
    end
  end

  # --- Private Functions ---

  # Store knowledge as memories instead of using non-existent SemanticStore.teach
  defp teach(text) do
    case Code.ensure_loaded(Mimo.Brain.Memory) do
      {:module, _} ->
        Mimo.Brain.Memory.store(%{
          content: text,
          category: :fact,
          importance: 0.7
        })
      _ ->
        Logger.debug("Mimo.Brain.Memory not available, skipping teach: #{text}")
        {:ok, :not_available}
    end
  end

  # Use Synapse.QueryEngine for queries instead of non-existent SemanticStore.query
  defp query(text) do
    case Code.ensure_loaded(Mimo.Synapse.QueryEngine) do
      {:module, _} ->
        Mimo.Synapse.QueryEngine.query(text)
      _ ->
        {:ok, %{results: [], status: :not_available}}
    end
  end

  defp teach_incident(incident) do
    teach("Incident #{incident.title} occurred on #{incident.date} with severity #{incident.severity}")
    teach("Root cause of #{incident.title}: #{String.slice(incident.root_cause, 0, 100)}")
  end

  defp teach_pattern(name, category, incident_title) do
    teach("Pattern #{name} is in category #{category}")
    teach("Pattern #{name} caused incident #{incident_title}")
  end

  defp teach_file_pattern(file, patterns, incident_title) do
    Enum.each(patterns, fn pattern ->
      teach("File #{file} contained pattern #{pattern.name}")
      teach("File #{file} was involved in incident #{incident_title}")
    end)
  end

  defp find_node(name) do
    case Code.ensure_loaded(Mimo.Synapse.Graph) do
      {:module, _} ->
        # Use search_nodes instead of non-existent find_node_by_name
        case Mimo.Synapse.Graph.search_nodes(name, limit: 1) do
          {:ok, [node | _]} -> {:ok, node}
          {:ok, []} -> {:error, :not_found}
          error -> error
        end
      _ ->
        {:error, :synapse_not_available}
    end
  end

  defp calculate_risk_score(pattern_count, incident_count) do
    # Base score starts at 0 (no risk)
    # Each pattern adds 15 points
    # Each incident adds 30 points
    # Capped at 100
    min(100, pattern_count * 15 + incident_count * 30)
  end

  defp risk_level(score) when score >= 70, do: :high
  defp risk_level(score) when score >= 40, do: :medium
  defp risk_level(_score), do: :low

  defp count_pattern_nodes do
    case query("patterns in robustness framework") do
      {:ok, result} -> length(Map.get(result, :triples, []))
      _ -> 0
    end
  end

  defp count_incident_nodes do
    case query("incidents tracked") do
      {:ok, result} -> length(Map.get(result, :triples, []))
      _ -> 0
    end
  end

  defp count_file_nodes do
    case query("files analyzed for robustness") do
      {:ok, result} -> length(Map.get(result, :triples, []))
      _ -> 0
    end
  end
end
