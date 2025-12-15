defmodule Mimo.Awakening do
  @moduledoc """
  SPEC-040: Mimo Awakening Protocol - Main Facade Module

  The Awakening Protocol transforms any AI agent connecting via MCP into an
  enhanced, memory-augmented agent. Like Dragon Ball's Super Saiyan transformation,
  the AI gains persistent memory, accumulated wisdom, and superpowers that grow
  stronger as Mimo's technology evolves.

  ## Architecture

      ┌──────────────────────────────────────────────────────────────┐
      │                     AI CLIENT (Claude, GPT, etc)              │
      └────────────────────────────┬─────────────────────────────────┘
                                   │ MCP Protocol
                                   ▼
      ┌──────────────────────────────────────────────────────────────┐
      │                    AWAKENING LAYER                           │
      │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐         │
      │  │ SessionTracker│ │PowerCalculator│ │ContextInjector│        │
      │  └──────────────┘ └──────────────┘ └──────────────┘         │
      │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐         │
      │  │ PromptResource│ │  Achievements │ │  Intelligence │        │
      │  └──────────────┘ └──────────────┘ └──────────────┘         │
      └──────────────────────────────────────────────────────────────┘

  ## Power Levels

  | Level | Name     | Icon | XP Required |
  |-------|----------|------|-------------|
  | 1     | Base     | 🌑   | 0           |
  | 2     | Enhanced | 🌓   | 100         |
  | 3     | Awakened | 🌕   | 500         |
  | 4     | Ascended | ⭐   | 2000        |
  | 5     | Ultra    | 🌌   | 10000       |

  ## Usage

      # Start a session (on MCP initialize)
      {:ok, session} = Mimo.Awakening.start_session(user_id: "user", project_id: "proj")

      # Check if awakening context should be injected
      case Mimo.Awakening.maybe_inject_awakening(session.session_id, %{}) do
        {:inject, content} -> # prepend to response
        :skip -> # already awakened
      end

      # Award XP for actions
      Mimo.Awakening.award_xp(:memory_stored)
      Mimo.Awakening.award_xp(:tool_call)

      # Get current status
      {:ok, status} = Mimo.Awakening.get_status()
  """
  require Logger

  alias Mimo.Awakening.{
    Stats,
    PowerCalculator,
    SessionTracker,
    ContextInjector,
    PromptResource,
    Achievements,
    Intelligence
  }

  # ==========================================================================
  # Session Management
  # ==========================================================================

  @doc """
  Start a new awakening session.
  Called on MCP initialize.

  ## Options (keyword list or map)

  - `:user_id` / `"user_id"` - Optional user identifier
  - `:project_id` / `"project_id"` - Optional project identifier
  - `:session_id` / `"session_id"` - Optional external session ID

  ## Returns

  `{:ok, session_state}` with the new session state.
  """
  @spec start_session(keyword() | map()) :: {:ok, SessionTracker.t()}
  def start_session(opts \\ [])

  def start_session(opts) when is_map(opts) do
    # Convert map to keyword list for SessionTracker
    keyword_opts = [
      user_id: opts[:user_id] || opts["user_id"],
      project_id: opts[:project_id] || opts["project_id"],
      session_id: opts[:session_id] || opts["session_id"]
    ]

    SessionTracker.start_session(keyword_opts)
  end

  def start_session(opts) when is_list(opts) do
    result = SessionTracker.start_session(opts)

    # Auto-discover library dependencies if cache is empty
    Mimo.Sandbox.run_async(Mimo.Repo, fn ->
      handle_library_cache_status(Mimo.Library.cache_stats())
    end)

    result
  end

  defp handle_library_cache_status(%{hot_cache_entries: 0}) do
    Logger.info("🚀 [Awakening] Library cache empty - triggering auto-discover")
    project_path = System.get_env("MIMO_ROOT", ".")

    case Mimo.Library.cache_project_deps(project_path) do
      {:ok, results} ->
        Logger.info(
          "✅ [Awakening] Library auto-discover complete: #{length(results.success)} packages cached"
        )

      _ ->
        Logger.warning("[Awakening] Library auto-discover returned unexpected result")
    end
  end

  defp handle_library_cache_status(stats) when is_map(stats) do
    Logger.debug(
      "📚 [Awakening] Library cache already populated: #{stats.hot_cache_entries} entries"
    )
  end

  defp handle_library_cache_status(_) do
    Logger.debug("[Awakening] Library cache stats unavailable")
  end

  @doc """
  End the current session.
  Called on MCP disconnect.
  """
  @spec end_session(String.t()) :: :ok
  def end_session(session_id) do
    SessionTracker.end_session(session_id)
  end

  @doc """
  Get the current session state.
  """
  @spec get_session(String.t()) :: {:ok, SessionTracker.t()} | {:error, :not_found}
  def get_session(session_id) do
    SessionTracker.get_session(session_id)
  end

  # ==========================================================================
  # Awakening Injection
  # ==========================================================================

  @doc """
  Maybe inject awakening context into a tool response.

  Only injects on the FIRST tool call of a session.
  Returns `:skip` if already awakened, or `{:inject, content}` if this
  is the first call.

  ## Parameters

  - `session_id` - The session ID from MCP initialize
  - `_opts` - Reserved for future options

  ## Returns

  - `{:inject, awakening_message}` - First tool call, include this message
  - `:skip` - Already awakened, no injection needed
  """
  @spec maybe_inject_awakening(String.t() | nil, map()) :: {:inject, String.t()} | :skip
  def maybe_inject_awakening(nil, _opts), do: :skip

  def maybe_inject_awakening(session_id, _opts) do
    case SessionTracker.trigger_awakening(session_id) do
      {:ok, _session_state, :already_awakened} ->
        :skip

      {:ok, session_state, :awakened} ->
        # First tool call - build and inject awakening context
        stats =
          case Stats.get_or_create(session_state.user_id, session_state.project_id) do
            {:ok, s} -> s
            {:error, _} -> Stats.create_stats()
          end

        # Fetch recent memories for personalization
        recent_memories = fetch_recent_memories(5)

        # Generate awakening message (with LLM personalization if available)
        {:ok, message} = Intelligence.generate_awakening_message(stats, recent_memories)

        # Build full context
        power_info = ContextInjector.build_power_level_info(stats)
        hints = ContextInjector.build_behavioral_hints(stats.current_level)

        awakening_content = """
        #{message}

        ## Your Capabilities
        #{format_capabilities(PowerCalculator.unlocked_capabilities(stats.current_level))}

        ## Behavioral Guidance
        #{format_hints(hints)}

        ---
        Power: #{power_info["icon"]} Level #{power_info["current"]} (#{power_info["name"]}) | XP: #{power_info["xp"]} | Progress: #{power_info["progress_percent"]}%
        """

        Logger.info(
          "🔥 Awakening injected for session #{session_id} (Power Level #{stats.current_level})"
        )

        {:inject, String.trim(awakening_content)}

      {:error, _reason} ->
        :skip
    end
  rescue
    e ->
      Logger.warning("Awakening injection failed: #{Exception.message(e)}")
      :skip
  end

  @doc """
  Build awakening context for a session (without injection).
  Useful for prompts/get requests.
  """
  @spec build_context(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def build_context(session_id \\ nil) do
    session =
      case session_id do
        nil ->
          %SessionTracker{}

        id ->
          case SessionTracker.get_session(id) do
            {:ok, s} -> s
            {:error, _} -> %SessionTracker{}
          end
      end

    case Stats.get_or_create() do
      {:ok, stats} ->
        context = ContextInjector.build_awakening_context(session, stats)
        {:ok, context}

      {:error, _} = error ->
        error
    end
  end

  # ==========================================================================
  # XP & Stats
  # ==========================================================================

  @doc """
  Award XP for an event.

  ## Event Types

  | Event              | XP  |
  |--------------------|-----|
  | memory_stored      | 5   |
  | memory_accessed    | 1   |
  | knowledge_taught   | 10  |
  | graph_query        | 2   |
  | procedure_created  | 50  |
  | procedure_executed | 5   |
  | session_completed  | 20  |
  | tool_call          | 1   |
  | error_solved       | 25  |
  """
  @spec award_xp(atom(), map()) :: {:ok, Stats.t()} | {:error, term()}
  def award_xp(event_type, opts \\ %{}) do
    result = Stats.award_xp(event_type, opts)

    # Check for achievement unlocks after XP award
    case result do
      {:ok, stats} ->
        Achievements.process_achievements(stats)
        result

      error ->
        error
    end
  end

  @doc """
  Get current awakening status.
  """
  @spec get_status(keyword()) :: {:ok, map()} | {:error, term()}
  def get_status(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    include_achievements = Keyword.get(opts, :include_achievements, false)

    case Stats.get_or_create(user_id, project_id) do
      {:ok, stats} ->
        status = %{
          power_level: ContextInjector.build_power_level_info(stats),
          stats: ContextInjector.build_wisdom_stats(stats),
          unlocked_capabilities: PowerCalculator.unlocked_capabilities(stats.current_level),
          behavioral_guidance: ContextInjector.build_behavioral_hints(stats.current_level)
        }

        status =
          if include_achievements do
            Map.put(status, :achievements, stats.achievements)
          else
            status
          end

        {:ok, status}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Get power level info only.
  """
  @spec get_power_level(keyword()) :: {:ok, map()} | {:error, term()}
  def get_power_level(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)

    case Stats.get_or_create(user_id, project_id) do
      {:ok, stats} ->
        {:ok, ContextInjector.build_power_level_info(stats)}

      {:error, _} = error ->
        error
    end
  end

  # ==========================================================================
  # MCP Prompts
  # ==========================================================================

  @doc """
  List available MCP prompts.
  """
  @spec list_prompts() :: [map()]
  def list_prompts do
    PromptResource.list_prompts()
  end

  @doc """
  Get a specific MCP prompt.
  """
  @spec get_prompt(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def get_prompt(name, args \\ %{}) do
    PromptResource.get_prompt(name, args)
  end

  # ==========================================================================
  # Tool Call Tracking (for Hooks integration)
  # ==========================================================================

  @doc """
  Record a tool call for the current session.
  Awards XP and updates session stats.

  ## Parameters

  - `tool_name` - The name of the tool called
  - `success?` - Whether the tool call succeeded (default: true)
  """
  @spec record_tool_call(String.t(), boolean()) :: :ok
  def record_tool_call(tool_name, success? \\ true) do
    # Get session_id from process dictionary
    session_id = Process.get(:mimo_session_id)

    # Record in SessionTracker for tool balance tracking (SPEC-040 v1.2)
    if session_id do
      SessionTracker.record_tool_call(session_id, tool_name)
    end

    # Award XP asynchronously with proper sandbox synchronization
    Mimo.Sandbox.run_async(Mimo.Repo, fn ->
      if success?, do: award_xp(:tool_call)

      # Track tool call count per type for pattern analysis
      Stats.increment_counter(:tool_call, %{tool: tool_name})
    end)

    :ok
  end

  @doc """
  Record a memory stored for XP.
  Awards XP based on memory category.

  ## Parameters

  - `category` - The memory category (:fact, :action, :observation, :plan)
  """
  @spec record_memory_stored(atom()) :: :ok
  def record_memory_stored(category) when is_atom(category) do
    # Skip XP tracking in test mode to avoid sandbox ownership issues
    unless Code.ensure_loaded?(ExUnit) do
      Mimo.Sandbox.run_async(Mimo.Repo, fn ->
        award_xp(:memory_stored, %{category: category})
        Stats.increment_counter(:memory_stored, %{category: category})
      end)
    end

    :ok
  end

  @doc """
  Record a relationship created in the knowledge graph.
  Awards XP for knowledge teaching.

  ## Parameters

  - `predicate` - The relationship type/predicate
  """
  @spec record_relationship_created(String.t()) :: :ok
  def record_relationship_created(predicate) when is_binary(predicate) do
    # Skip XP tracking in test mode to avoid sandbox ownership issues
    unless Code.ensure_loaded?(ExUnit) do
      Mimo.Sandbox.run_async(Mimo.Repo, fn ->
        award_xp(:knowledge_taught, %{predicate: predicate})
        Stats.increment_counter(:relationship_created, %{predicate: predicate})
      end)
    end

    :ok
  end

  @doc """
  Record an insight generation.
  Awards XP for cognitive activity.
  """
  @spec record_insight_generated(String.t()) :: :ok
  def record_insight_generated(insight_type) when is_binary(insight_type) do
    unless Code.ensure_loaded?(ExUnit) do
      Mimo.Sandbox.run_async(Mimo.Repo, fn ->
        award_xp(:insight_generated, %{type: insight_type})
      end)
    end

    :ok
  end

  @doc """
  Record a reasoning session completion.
  Awards XP based on reasoning depth.
  """
  @spec record_reasoning_session(non_neg_integer()) :: :ok
  def record_reasoning_session(step_count) when is_integer(step_count) do
    unless Code.ensure_loaded?(ExUnit) do
      Mimo.Sandbox.run_async(Mimo.Repo, fn ->
        # More reasoning steps = more XP (up to 50 for deep reasoning)
        xp_multiplier = min(step_count, 10)
        for _ <- 1..xp_multiplier, do: award_xp(:reasoning_step)
      end)
    end

    :ok
  end

  @doc """
  Record knowledge graph activity.
  Awards XP for graph operations.
  """
  @spec record_knowledge_activity(atom()) :: :ok
  def record_knowledge_activity(activity_type) when is_atom(activity_type) do
    unless Code.ensure_loaded?(ExUnit) do
      Mimo.Sandbox.run_async(Mimo.Repo, fn -> award_for_activity(activity_type) end)
    end

    :ok
  end

  defp award_for_activity(:query), do: award_xp(:graph_query)
  defp award_for_activity(:traverse), do: award_xp(:graph_query)
  defp award_for_activity(:teach), do: award_xp(:knowledge_taught)
  defp award_for_activity(:link), do: award_xp(:graph_link)
  defp award_for_activity(_), do: :ok

  @doc """
  Record a procedure created.
  """
  @spec record_procedure_created() :: :ok
  def record_procedure_created do
    unless Code.ensure_loaded?(ExUnit) do
      Mimo.Sandbox.run_async(Mimo.Repo, fn ->
        award_xp(:procedure_created)
      end)
    end

    :ok
  end

  @doc """
  Record a procedure executed.
  """
  @spec record_procedure_executed() :: :ok
  def record_procedure_executed do
    unless Code.ensure_loaded?(ExUnit) do
      Mimo.Sandbox.run_async(Mimo.Repo, fn ->
        award_xp(:procedure_executed)
      end)
    end

    :ok
  end

  # ==========================================================================
  # Session Statistics
  # ==========================================================================

  @doc """
  Get session statistics.
  """
  @spec session_stats() :: map()
  def session_stats do
    SessionTracker.session_stats()
  end

  @doc """
  List all active sessions.
  """
  @spec list_sessions() :: [SessionTracker.t()]
  def list_sessions do
    SessionTracker.list_sessions()
  end

  # ==========================================================================
  # Achievements
  # ==========================================================================

  @doc """
  Get all achievement definitions.
  """
  @spec all_achievements() :: [map()]
  def all_achievements do
    Achievements.all_achievements()
  end

  @doc """
  Get progress towards an achievement.
  """
  @spec achievement_progress(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def achievement_progress(achievement_id, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)

    case Stats.get_or_create(user_id, project_id) do
      {:ok, stats} ->
        achievement = Achievements.get_achievement(achievement_id)
        {current, target, percentage} = Achievements.get_progress(achievement_id, stats)

        {:ok,
         %{
           achievement: achievement,
           current: current,
           target: target,
           percentage: percentage,
           unlocked: achievement_id in stats.achievements
         }}

      {:error, _} = error ->
        error
    end
  end

  # ==========================================================================
  # Intelligence (LLM-powered features)
  # ==========================================================================

  @doc """
  Generate a personalized awakening message using LLM.
  Falls back to template if LLM fails.
  """
  @spec generate_awakening_message(Stats.t(), list()) :: {:ok, String.t()}
  def generate_awakening_message(stats, recent_memories \\ []) do
    Intelligence.generate_awakening_message(stats, recent_memories)
  end

  @doc """
  Generate behavioral guidance using LLM.
  Falls back to pattern-based hints if LLM fails.
  """
  @spec generate_behavioral_guidance(Stats.t(), map()) :: [String.t()]
  def generate_behavioral_guidance(stats, tool_usage_patterns \\ %{}) do
    Intelligence.generate_behavioral_guidance(stats, tool_usage_patterns)
  end

  # ==========================================================================
  # Private Helpers
  # ==========================================================================

  defp fetch_recent_memories(limit) do
    try do
      # Query Mimo's memory system for recent engrams
      case Mimo.Brain.Memory.recent_engrams(limit) do
        {:ok, engrams} ->
          Enum.map(engrams, fn e ->
            %{content: e.content, category: e.category, importance: e.importance}
          end)

        _ ->
          []
      end
    rescue
      _ -> []
    end
  end

  defp format_capabilities(capabilities) do
    Enum.map_join(capabilities, "\n", fn cap -> "• `#{cap}`" end)
  end

  defp format_hints(hints) do
    hints
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {hint, i} -> "#{i}. #{hint}" end)
  end
end
