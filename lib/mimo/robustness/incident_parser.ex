defmodule Mimo.Robustness.IncidentParser do
  @moduledoc """
  Incident Report Parser (SPEC-070 Task F)

  Parses incident post-mortems and extracts patterns for continuous learning.

  ## Incident Report Format

  Expected markdown format:

      # Incident: [Title]
      **Date:** YYYY-MM-DD
      **Severity:** critical | high | medium | low
      
      ## Root Cause
      [Description of root cause]
      
      ## Code Location
      - File: path/to/file.ex
      - Lines: 45-67
      - Function: function_name
      
      ## Pattern Identified
      - Pattern Name: [e.g., blocking_init_call]
      - Category: [blocking | external_dep | no_fallback | complexity]
      
      ## Fix Applied
      [Description of fix]
      
      ## Prevention
      [How to prevent similar issues]

  ## Usage

      {:ok, incident} = IncidentParser.parse(markdown_content)
      
      # Returns:
      # %{
      #   title: "...",
      #   date: ~D[2025-12-06],
      #   severity: :high,
      #   root_cause: "...",
      #   locations: [%{file: "...", lines: "...", function: "..."}],
      #   patterns: [%{name: "...", category: :blocking}],
      #   fix: "...",
      #   prevention: "..."
      # }
  """
  alias Memory

  require Logger

  @type severity :: :critical | :high | :medium | :low
  @type pattern_category :: :blocking | :external_dep | :no_fallback | :complexity | :other

  @type parsed_incident :: %{
          title: String.t(),
          date: Date.t() | nil,
          severity: severity(),
          root_cause: String.t(),
          locations: [map()],
          patterns: [map()],
          fix: String.t(),
          prevention: String.t()
        }

  @doc """
  Parse an incident report from markdown content.
  """
  @spec parse(String.t()) :: {:ok, parsed_incident()} | {:error, term()}
  def parse(content) do
    incident = %{
      title: extract_title(content),
      date: extract_date(content),
      severity: extract_severity(content),
      root_cause: extract_section(content, "Root Cause"),
      locations: extract_locations(content),
      patterns: extract_patterns(content),
      fix: extract_section(content, "Fix Applied"),
      prevention: extract_section(content, "Prevention")
    }

    {:ok, incident}
  rescue
    e -> {:error, {:parse_failed, e}}
  end

  @doc """
  Generate a new pattern detection rule from an incident.

  Extracts the pattern and creates a regex-based detection rule.
  """
  @spec generate_pattern_rule(parsed_incident()) :: {:ok, map()} | {:error, term()}
  def generate_pattern_rule(incident) do
    patterns = incident.patterns

    if patterns == [] do
      {:error, :no_patterns_identified}
    else
      rules =
        Enum.map(patterns, fn pattern ->
          %{
            id: String.to_atom(pattern.name),
            severity: incident.severity,
            description: incident.root_cause,
            category: pattern.category,
            source_incident: incident.title,
            source_date: incident.date,
            # Placeholder - actual regex would need human review
            regex_hint: suggest_regex(pattern.name, pattern.category),
            fix_template: incident.prevention
          }
        end)

      {:ok, rules}
    end
  end

  @doc """
  Store incident in memory and knowledge graph for future reference.
  """
  @spec store_incident(parsed_incident()) :: {:ok, map()} | {:error, term()}
  def store_incident(incident) do
    # Store in memory
    memory_result = store_in_memory(incident)

    # Teach to knowledge graph
    knowledge_result = teach_to_knowledge_graph(incident)

    {:ok,
     %{
       memory: memory_result,
       knowledge: knowledge_result
     }}
  rescue
    e -> {:error, {:storage_failed, e}}
  end

  @doc """
  Parse the Dec 6 2025 incidents from IMPLEMENTATION_ROBUSTNESS.md format.
  """
  @spec parse_dec6_incidents() :: {:ok, [parsed_incident()]} | {:error, term()}
  def parse_dec6_incidents do
    # Known incidents from Dec 6 2025
    incidents = [
      %{
        title: "Health Check Blocking Startup",
        date: ~D[2025-12-06],
        severity: :high,
        root_cause:
          "Added synchronous health check in stdio.ex to ensure services ready. GenServer.call during init created circular dependency that blocked startup indefinitely.",
        locations: [
          %{file: "lib/mimo/mcp_server/stdio.ex", lines: "init function", function: "init/1"}
        ],
        patterns: [
          %{name: "blocking_genserver_init", category: :blocking}
        ],
        fix:
          "Removed blocking health check from init. Services now use defensive checks at point of use with Process.whereis guards and try/catch around GenServer.call.",
        prevention:
          "Never use GenServer.call in init/start_link functions. Use defensive checks at runtime with fallbacks."
      },
      %{
        title: "Node Wrapper Compilation Check Fragility",
        date: ~D[2025-12-06],
        severity: :high,
        root_cause:
          "Used bash/bc/printf to check BEAM file staleness. External command dependencies failed in some environments. No graceful fallback when commands failed.",
        locations: [
          %{
            file: "bin/mimo-node-wrapper.js",
            lines: "needsCompilation function",
            function: "needsCompilation"
          }
        ],
        patterns: [
          %{name: "exec_sync_bash", category: :external_dep},
          %{name: "no_fallback_on_error", category: :no_fallback}
        ],
        fix:
          "Rewrote as pure Node.js using fs.statSync for mtime comparison. Added graceful fallback - if check fails, assume up-to-date and start anyway.",
        prevention:
          "Use pure language features instead of external commands. Always add try/catch with graceful fallback for non-critical operations."
      }
    ]

    {:ok, incidents}
  end

  # --- Private Functions ---

  defp extract_title(content) do
    case Regex.run(~r/#\s*Incident:\s*(.+)$/m, content) do
      [_, title] ->
        String.trim(title)

      _ ->
        # Fallback: first h1
        case Regex.run(~r/^#\s+(.+)$/m, content) do
          [_, title] -> String.trim(title)
          _ -> "Unknown Incident"
        end
    end
  end

  defp extract_date(content) do
    case Regex.run(~r/\*\*Date:\*\*\s*(\d{4}-\d{2}-\d{2})/m, content) do
      [_, date_str] ->
        case Date.from_iso8601(date_str) do
          {:ok, date} -> date
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_severity(content) do
    case Regex.run(~r/\*\*Severity:\*\*\s*(critical|high|medium|low)/im, content) do
      [_, severity] -> String.downcase(severity) |> String.to_atom()
      _ -> :medium
    end
  end

  defp extract_section(content, section_name) do
    pattern = ~r/##\s*#{Regex.escape(section_name)}\s*\n([\s\S]*?)(?=\n##|\z)/m

    case Regex.run(pattern, content) do
      [_, section_content] -> String.trim(section_content)
      _ -> ""
    end
  end

  defp extract_locations(content) do
    section = extract_section(content, "Code Location")

    if section == "" do
      []
    else
      file =
        case Regex.run(~r/File:\s*(.+)$/m, section) do
          [_, f] -> String.trim(f)
          _ -> nil
        end

      lines =
        case Regex.run(~r/Lines?:\s*(.+)$/m, section) do
          [_, l] -> String.trim(l)
          _ -> nil
        end

      function =
        case Regex.run(~r/Function:\s*(.+)$/m, section) do
          [_, f] -> String.trim(f)
          _ -> nil
        end

      [%{file: file, lines: lines, function: function}]
    end
  end

  defp extract_patterns(content) do
    section = extract_section(content, "Pattern Identified")

    if section == "" do
      []
    else
      name =
        case Regex.run(~r/Pattern Name:\s*(.+)$/m, section) do
          [_, n] -> n |> String.trim() |> String.downcase() |> String.replace(" ", "_")
          _ -> "unknown_pattern"
        end

      category =
        case Regex.run(~r/Category:\s*(.+)$/m, section) do
          [_, c] ->
            c |> String.trim() |> String.downcase() |> String.to_atom()

          _ ->
            :other
        end

      [%{name: name, category: category}]
    end
  end

  defp suggest_regex(pattern_name, category) do
    # Suggest regex patterns based on category
    case category do
      :blocking ->
        "~r/def\\s+(?:init|start).*GenServer\\.call/"

      :external_dep ->
        "~r/execSync|System\\.cmd|Port\\.open/"

      :no_fallback ->
        "~r/(?<!try)\\s+external_call/"

      :complexity ->
        "~r/if.*if.*if|case.*case.*case/"

      _ ->
        "~r/#{pattern_name}/"
    end
  end

  defp store_in_memory(incident) do
    content = """
    Incident: #{incident.title} (#{incident.date})
    Severity: #{incident.severity}
    Root Cause: #{incident.root_cause}
    Fix: #{incident.fix}
    Patterns: #{inspect(Enum.map(incident.patterns, & &1.name))}
    """

    case Code.ensure_loaded(Memory) do
      {:module, _} ->
        # Memory.store/1 takes a map with :content, :category, :importance keys
        Mimo.Brain.Memory.store(%{
          content: content,
          category: :fact,
          importance: 0.85
        })

      _ ->
        {:ok, :memory_not_available}
    end
  end

  defp teach_to_knowledge_graph(incident) do
    teachings = []

    # Teach pattern -> caused -> incident
    teachings =
      teachings ++
        Enum.map(incident.patterns, fn pattern ->
          "Pattern #{pattern.name} caused incident #{incident.title}"
        end)

    # Teach file -> contains_pattern -> pattern
    teachings =
      teachings ++
        Enum.flat_map(incident.locations, fn loc ->
          Enum.map(incident.patterns, fn pattern ->
            "File #{loc.file} contained #{pattern.name} pattern"
          end)
        end)

    # Use SemanticStore.query_related or store facts as memories instead
    # SemanticStore doesn't have a teach/1 function - use Memory for knowledge
    case Code.ensure_loaded(Memory) do
      {:module, _} ->
        results =
          Enum.map(teachings, fn text ->
            Mimo.Brain.Memory.store(%{
              content: text,
              category: :fact,
              importance: 0.7
            })
          end)

        {:ok, results}

      _ ->
        {:ok, :knowledge_not_available}
    end
  end
end
