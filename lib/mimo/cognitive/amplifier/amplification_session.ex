defmodule Mimo.Cognitive.Amplifier.AmplificationSession do
  @moduledoc """
  Extended session state for cognitive amplification.

  Builds on top of ReasoningSession to track amplification-specific state:
  - Decomposition results
  - Challenges generated and addressed
  - Perspectives considered
  - Coherence issues detected
  - Synthesis threads

  ## Session Lifecycle

  1. `create/3` - Create amplification session from problem
  2. `record_decomposition/2` - Store forced decomposition
  3. `add_challenge/2` - Record a challenge
  4. `mark_challenge_addressed/2` - Mark challenge as handled
  5. `add_perspective/2` - Record perspective consideration
  6. `record_coherence_check/2` - Store coherence validation result
  7. `prepare_synthesis/1` - Gather all threads for synthesis

  ## Storage

  Uses ETS via the base ReasoningSession for persistence.
  Amplification state is stored in session metadata.
  """

  alias Mimo.Cognitive.Amplifier.AmplificationLevel
  alias Mimo.Cognitive.ReasoningSession

  @type challenge :: %{
          id: String.t(),
          type: atom(),
          content: String.t(),
          severity: :must_address | :should_consider | :optional,
          addressed: boolean(),
          response: String.t() | nil
        }

  @type perspective :: %{
          name: atom(),
          prompt: String.t(),
          considered: boolean(),
          insights: [String.t()]
        }

  @type coherence_issue :: %{
          type: atom(),
          description: String.t(),
          steps_involved: [non_neg_integer()],
          resolved: boolean()
        }

  @type amplification_state :: %{
          level: AmplificationLevel.t(),
          stage: atom(),
          decomposition: [String.t()],
          decomposition_answered: [boolean()],
          challenges: [challenge()],
          perspectives: [perspective()],
          coherence_issues: [coherence_issue()],
          synthesis_ready: boolean(),
          blocking_reason: String.t() | nil
        }

  @doc """
  Create an amplification session.

  Wraps a ReasoningSession with additional amplification state.
  """
  @spec create(String.t(), AmplificationLevel.t(), keyword()) :: map()
  def create(problem, level, opts \\ []) do
    # Create base reasoning session
    strategy = Keyword.get(opts, :strategy, :cot)
    base_session = ReasoningSession.create(problem, strategy, opts)

    # SPEC-092: Detect document references that should be verified
    required_sources = detect_source_references(problem)

    # Initialize amplification state
    amp_state = %{
      level: level,
      stage: :init,
      decomposition: [],
      decomposition_answered: [],
      challenges: [],
      perspectives: [],
      coherence_issues: [],
      synthesis_ready: false,
      blocking_reason: nil,
      # SPEC-092: Source verification to prevent hallucination
      required_sources: required_sources,
      verified_sources: []
    }

    # Store in session metadata
    {:ok, updated} =
      ReasoningSession.update(base_session.id, %{
        amplification: amp_state
      })

    updated
  end

  @doc """
  Get amplification state from a session.
  """
  @spec get_state(String.t()) :: {:ok, amplification_state()} | {:error, term()}
  def get_state(session_id) do
    case ReasoningSession.get(session_id) do
      {:ok, session} ->
        {:ok, Map.get(session, :amplification, default_state())}

      error ->
        error
    end
  end

  @doc """
  Update amplification state.
  """
  @spec update_state(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_state(session_id, updates) do
    with {:ok, session} <- ReasoningSession.get(session_id) do
      current_amp = Map.get(session, :amplification, default_state())
      new_amp = Map.merge(current_amp, updates)
      ReasoningSession.update(session_id, %{amplification: new_amp})
    end
  end

  @doc """
  Record forced decomposition sub-problems.
  """
  @spec record_decomposition(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def record_decomposition(session_id, sub_problems) when is_list(sub_problems) do
    update_state(session_id, %{
      decomposition: sub_problems,
      decomposition_answered: List.duplicate(false, length(sub_problems)),
      stage: :decomposed
    })
  end

  @doc """
  Mark a decomposition sub-problem as answered.
  """
  @spec mark_decomposition_answered(String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def mark_decomposition_answered(session_id, index) do
    with {:ok, state} <- get_state(session_id) do
      answered = List.replace_at(state.decomposition_answered, index, true)
      update_state(session_id, %{decomposition_answered: answered})
    end
  end

  @doc """
  Check if all decomposition sub-problems are answered.
  """
  @spec decomposition_complete?(String.t()) :: boolean()
  def decomposition_complete?(session_id) do
    case get_state(session_id) do
      {:ok, state} ->
        state.decomposition == [] or Enum.all?(state.decomposition_answered)

      _ ->
        true
    end
  end

  @doc """
  Add a challenge to the session.
  """
  @spec add_challenge(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def add_challenge(session_id, challenge) do
    with {:ok, state} <- get_state(session_id) do
      challenge_with_id =
        Map.merge(challenge, %{
          id: generate_id("chal"),
          addressed: false,
          response: nil
        })

      update_state(session_id, %{
        challenges: state.challenges ++ [challenge_with_id]
      })
    end
  end

  @doc """
  Mark a challenge as addressed with a response.
  """
  @spec address_challenge(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def address_challenge(session_id, challenge_id, response) do
    with {:ok, state} <- get_state(session_id) do
      updated_challenges =
        Enum.map(state.challenges, fn c ->
          if c.id == challenge_id do
            %{c | addressed: true, response: response}
          else
            c
          end
        end)

      update_state(session_id, %{challenges: updated_challenges})
    end
  end

  @doc """
  Get unaddressed must-address challenges.
  """
  @spec pending_must_address(String.t()) :: [challenge()]
  def pending_must_address(session_id) do
    case get_state(session_id) do
      {:ok, state} ->
        Enum.filter(state.challenges, fn c ->
          c.severity == :must_address and not c.addressed
        end)

      _ ->
        []
    end
  end

  @doc """
  Add a perspective to consider.
  """
  @spec add_perspective(String.t(), atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def add_perspective(session_id, name, prompt) do
    with {:ok, state} <- get_state(session_id) do
      perspective = %{
        name: name,
        prompt: prompt,
        considered: false,
        insights: []
      }

      update_state(session_id, %{
        perspectives: state.perspectives ++ [perspective]
      })
    end
  end

  @doc """
  Record insights from a perspective.
  """
  @spec record_perspective_insights(String.t(), atom(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def record_perspective_insights(session_id, perspective_name, insights) do
    with {:ok, state} <- get_state(session_id) do
      # Check if perspective already exists
      existing = Enum.find(state.perspectives, fn p -> p.name == perspective_name end)

      updated =
        if existing do
          # Update existing perspective
          Enum.map(state.perspectives, fn p ->
            if p.name == perspective_name do
              %{p | considered: true, insights: insights}
            else
              p
            end
          end)
        else
          # Add new perspective as already considered
          new_perspective = %{
            name: perspective_name,
            prompt: "Perspective: #{perspective_name}",
            considered: true,
            insights: insights
          }

          state.perspectives ++ [new_perspective]
        end

      update_state(session_id, %{perspectives: updated})
    end
  end

  @doc """
  Get count of considered perspectives.
  """
  @spec perspectives_considered_count(String.t()) :: non_neg_integer()
  def perspectives_considered_count(session_id) do
    case get_state(session_id) do
      {:ok, state} ->
        Enum.count(state.perspectives, & &1.considered)

      _ ->
        0
    end
  end

  @doc """
  Record a coherence issue.
  """
  @spec record_coherence_issue(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record_coherence_issue(session_id, issue) do
    with {:ok, state} <- get_state(session_id) do
      issue_with_id =
        Map.merge(issue, %{
          id: generate_id("coh"),
          resolved: false
        })

      update_state(session_id, %{
        coherence_issues: state.coherence_issues ++ [issue_with_id]
      })
    end
  end

  @doc """
  Mark a coherence issue as resolved.
  """
  @spec resolve_coherence_issue(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_coherence_issue(session_id, issue_id) do
    with {:ok, state} <- get_state(session_id) do
      updated_issues =
        Enum.map(state.coherence_issues, fn issue ->
          if issue.id == issue_id do
            %{issue | resolved: true}
          else
            issue
          end
        end)

      # Check if all blocking issues are now resolved
      still_blocking =
        Enum.any?(updated_issues, fn i ->
          i.type in [:contradiction, :circular] and not i.resolved
        end)

      new_state = %{coherence_issues: updated_issues}

      new_state =
        if not still_blocking and state.blocking_reason == "coherence_issue" do
          Map.put(new_state, :blocking_reason, nil)
        else
          new_state
        end

      update_state(session_id, new_state)
    end
  end

  @doc """
  Mark all coherence issues as resolved.
  """
  @spec resolve_all_coherence_issues(String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_all_coherence_issues(session_id) do
    with {:ok, state} <- get_state(session_id) do
      updated_issues =
        Enum.map(state.coherence_issues, fn issue ->
          %{issue | resolved: true}
        end)

      new_state = %{coherence_issues: updated_issues}

      new_state =
        if state.blocking_reason == "coherence_issue" do
          Map.put(new_state, :blocking_reason, nil)
        else
          new_state
        end

      update_state(session_id, new_state)
    end
  end

  @doc """
  Check if there are unresolved major coherence issues.
  """
  @spec has_blocking_coherence_issues?(String.t()) :: boolean()
  def has_blocking_coherence_issues?(session_id) do
    case get_state(session_id) do
      {:ok, state} ->
        Enum.any?(state.coherence_issues, fn i ->
          i.type in [:contradiction, :circular] and not i.resolved
        end)

      _ ->
        false
    end
  end

  @doc """
  Prepare synthesis by gathering all threads.
  """
  @spec prepare_synthesis(String.t()) :: {:ok, map()} | {:error, term()}
  def prepare_synthesis(session_id) do
    with {:ok, session} <- ReasoningSession.get(session_id),
         {:ok, state} <- get_state(session_id) do
      threads = %{
        problem: session.problem,
        decomposition: Enum.zip(state.decomposition, state.decomposition_answered),
        challenges:
          Enum.map(state.challenges, fn c ->
            %{type: c.type, content: c.content, response: c.response}
          end),
        perspectives:
          Enum.flat_map(state.perspectives, fn p ->
            if p.considered, do: p.insights, else: []
          end),
        thoughts: Enum.map(session.thoughts, & &1.content),
        coherence_issues: state.coherence_issues
      }

      completeness = calculate_completeness(threads, state.level)

      update_state(session_id, %{
        synthesis_ready: completeness >= 0.8,
        stage: :synthesis
      })

      {:ok,
       %{
         threads: threads,
         completeness: completeness,
         ready: completeness >= 0.8
       }}
    end
  end

  @doc """
  Set a blocking reason that prevents progression.
  """
  @spec set_blocking(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_blocking(session_id, reason) do
    update_state(session_id, %{blocking_reason: reason})
  end

  @doc """
  Clear blocking state.
  """
  @spec clear_blocking(String.t()) :: {:ok, map()} | {:error, term()}
  def clear_blocking(session_id) do
    update_state(session_id, %{blocking_reason: nil})
  end

  @doc """
  Check if session is blocked.
  """
  @spec blocked?(String.t()) :: {boolean(), String.t() | nil}
  def blocked?(session_id) do
    case get_state(session_id) do
      {:ok, %{blocking_reason: nil}} -> {false, nil}
      {:ok, %{blocking_reason: reason}} -> {true, reason}
      _ -> {false, nil}
    end
  end

  defp default_state do
    %{
      level: AmplificationLevel.get(:standard),
      stage: :init,
      decomposition: [],
      decomposition_answered: [],
      challenges: [],
      perspectives: [],
      coherence_issues: [],
      synthesis_ready: false,
      blocking_reason: nil,
      # SPEC-092: Source verification
      required_sources: [],
      verified_sources: []
    }
  end

  defp generate_id(prefix) do
    random = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "#{prefix}_#{random}"
  end

  defp calculate_completeness(threads, level) do
    scores = []

    # Decomposition completeness
    scores =
      if level.decomposition and threads.decomposition != [] do
        answered = Enum.count(threads.decomposition, fn {_, answered} -> answered end)
        total = length(threads.decomposition)
        [{answered / max(total, 1), 0.3} | scores]
      else
        scores
      end

    # Challenge completeness
    scores =
      if level.challenges > 0 do
        addressed = Enum.count(threads.challenges, &(&1.response != nil))

        required =
          if level.challenges == :all, do: length(threads.challenges), else: level.challenges

        [{addressed / max(required, 1), 0.25} | scores]
      else
        scores
      end

    # Perspective completeness
    scores =
      if level.perspectives > 0 do
        count = length(threads.perspectives)
        required = if level.perspectives == :all, do: 5, else: level.perspectives
        [{count / max(required, 1), 0.25} | scores]
      else
        scores
      end

    # Coherence (no unresolved issues)
    scores =
      if level.coherence != :none do
        unresolved = Enum.count(threads.coherence_issues, &(not &1.resolved))
        score = if unresolved == 0, do: 1.0, else: 0.5
        [{score, 0.2} | scores]
      else
        scores
      end

    if scores == [] do
      1.0
    else
      total_weight = Enum.reduce(scores, 0, fn {_, w}, acc -> acc + w end)

      Enum.reduce(scores, 0, fn {score, weight}, acc ->
        acc + score * (weight / total_weight)
      end)
    end
  end

  # ============================================================================
  # SPEC-092: Source Verification Functions
  # ============================================================================

  @doc """
  Mark a source as verified during reasoning.

  Call this when a file referenced in the problem has been read.
  """
  @spec mark_source_verified(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def mark_source_verified(session_id, source_path) do
    with {:ok, state} <- get_state(session_id) do
      verified = state.verified_sources || []

      if source_path in verified do
        {:ok, state}
      else
        update_state(session_id, %{verified_sources: [source_path | verified]})
      end
    end
  end

  @doc """
  Check if all required sources have been verified.

  Returns a report of verification status.
  """
  @spec check_source_verification(String.t()) :: {:ok, map()} | {:error, term()}
  def check_source_verification(session_id) do
    with {:ok, state} <- get_state(session_id) do
      required = state.required_sources || []
      verified = state.verified_sources || []

      unverified = required -- verified

      {:ok,
       %{
         required: required,
         verified: verified,
         unverified: unverified,
         all_verified: unverified == [],
         verification_rate: if(required == [], do: 1.0, else: length(verified) / length(required))
       }}
    end
  end

  @doc """
  Detect document references in a problem statement.

  Looks for patterns like:
  - SPEC-XXX
  - docs/path/to/file.md
  - lib/path/to/module.ex
  - Explicit file paths
  """
  @spec detect_source_references(String.t()) :: [String.t()]
  def detect_source_references(text) do
    # Pattern for SPEC references
    spec_refs =
      Regex.scan(~r/SPEC-\d+/i, text)
      |> Enum.map(fn [match] -> "docs/#{String.upcase(match)}-*.md" end)

    # Pattern for explicit file paths
    file_refs =
      Regex.scan(~r/(?:docs|lib|test)\/[\w\/\-\.]+\.\w+/, text)
      |> Enum.map(fn [match] -> match end)

    # Pattern for quoted file references
    quoted_refs =
      Regex.scan(~r/["'`]((?:docs|lib|test)\/[^"'`]+)["'`]/, text)
      |> Enum.map(fn [_, match] -> match end)

    (spec_refs ++ file_refs ++ quoted_refs)
    |> Enum.uniq()
  end
end
