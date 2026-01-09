defmodule Mimo.Context.Compactor do
  @moduledoc """
  SPEC-2026-002: Context Compaction with Intent-Based Prioritization

  Compacts conversation context by prioritizing content relevant to detected intent.
  Uses hybrid approach: heuristic detection first, LLM fallback for uncertain cases.

  ## Strategy

  1. **Heuristic Detection** (fast, ~0ms)
     - Extract file mentions from messages
     - Extract keywords suggesting intent
     - Calculate confidence based on patterns

  2. **LLM Fallback** (if heuristic confidence < 0.6)
     - Use Cerebras gpt-oss-120b (~66ms for 200 tokens)
     - Get precise intent from LLM

  3. **Compaction**
     - Keep full content if relevant to intent
     - Truncate/summarize irrelevant content
  """

  require Logger

  alias Mimo.Brain.LLM

  # Intent detection thresholds
  @heuristic_confidence_threshold 0.6
  @max_llm_prompt_tokens 500
  @llm_intent_max_tokens 150

  # Common programming-related keywords by category
  @intent_keywords %{
    auth: ~w(auth login logout session token password jwt oauth credentials),
    api: ~w(api endpoint route controller request response rest graphql),
    database: ~w(database db schema migration model query ecto repo postgres),
    testing: ~w(test spec assert expect mock stub integration unit),
    ui: ~w(ui ux component view template layout style css html),
    performance: ~w(performance optimize cache speed memory latency),
    security: ~w(security vulnerability xss csrf injection sanitize),
    deploy: ~w(deploy production release docker kubernetes ci cd pipeline),
    debug: ~w(debug error exception crash fix bug issue problem)
  }

  @doc """
  Detect user intent from conversation messages.

  Returns intent map with:
  - `:primary_files` - Most relevant files
  - `:keywords` - Detected intent keywords
  - `:intent_type` - Categorized intent (e.g., :auth, :testing)
  - `:confidence` - Detection confidence (0.0 - 1.0)
  - `:source` - :heuristic or :llm
  """
  def detect_intent(messages) when is_list(messages) do
    # Step 1: Heuristic detection (fast path)
    heuristic = heuristic_detect(messages)

    # Step 2: If low confidence, escalate to LLM
    if heuristic.confidence < @heuristic_confidence_threshold do
      case llm_detect(messages) do
        {:ok, llm_result} ->
          Logger.debug("[Compactor] LLM detection used, intent: #{inspect(llm_result.intent_type)}")
          Map.put(llm_result, :source, :llm)

        {:error, _reason} ->
          # Fallback to heuristic result
          Logger.debug("[Compactor] LLM failed, using heuristic")
          Map.put(heuristic, :source, :heuristic_fallback)
      end
    else
      Logger.debug("[Compactor] Heuristic detection sufficient: #{heuristic.confidence}")
      Map.put(heuristic, :source, :heuristic)
    end
  end

  def detect_intent(_),
    do: %{primary_files: [], keywords: [], intent_type: :unknown, confidence: 0.0, source: :none}

  @doc """
  Compact messages based on detected intent.

  Keeps full content for relevant messages, truncates/summarizes others.
  """
  def compact(messages, intent) when is_list(messages) do
    Enum.map(messages, fn msg ->
      if relevant_to_intent?(msg, intent) do
        # Keep full
        msg
      else
        compact_message(msg)
      end
    end)
  end

  def compact(messages, _intent), do: messages

  @doc """
  One-shot: detect intent and compact in single call.
  """
  def compact_with_intent(messages) do
    intent = detect_intent(messages)
    compacted = compact(messages, intent)
    {compacted, intent}
  end

  # --- Heuristic Detection ---

  defp heuristic_detect(messages) do
    text = messages_to_text(messages)

    files = extract_file_mentions(text)
    keywords = extract_keywords(text)
    intent_type = categorize_intent(keywords)
    confidence = calculate_confidence(files, keywords, intent_type)

    %{
      primary_files: Enum.take(files, 5),
      keywords: Enum.take(keywords, 10),
      intent_type: intent_type,
      confidence: confidence
    }
  end

  defp messages_to_text(messages) when is_list(messages) do
    messages
    |> Enum.map(fn
      %{content: content} when is_binary(content) -> content
      msg when is_binary(msg) -> msg
      _ -> ""
    end)
    |> Enum.join(" ")
  end

  defp extract_file_mentions(text) do
    # Match file paths like /path/to/file.ex, lib/foo.ex, ./file.ts
    ~r{(?:^|[\s"'\(])([./\w-]+\.(?:ex|exs|ts|tsx|js|jsx|py|rs|go|rb|java|c|cpp|h|hpp|md|json|yaml|yml|toml))}
    |> Regex.scan(text)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_path, count} -> -count end)
    |> Enum.map(fn {path, _} -> path end)
    |> Enum.uniq()
  end

  defp extract_keywords(text) do
    text_lower = String.downcase(text)

    all_keywords =
      @intent_keywords
      |> Map.values()
      |> List.flatten()

    all_keywords
    |> Enum.filter(&String.contains?(text_lower, &1))
    |> Enum.frequencies_by(& &1)
    |> Enum.sort_by(fn {_kw, count} -> -count end)
    |> Enum.map(fn {kw, _} -> kw end)
  end

  defp categorize_intent(keywords) when keywords == [], do: :general

  defp categorize_intent(keywords) do
    # Score each intent category
    scores =
      @intent_keywords
      |> Enum.map(fn {category, category_keywords} ->
        matches = Enum.count(keywords, &(&1 in category_keywords))
        {category, matches}
      end)
      |> Enum.filter(fn {_, score} -> score > 0 end)
      |> Enum.sort_by(fn {_, score} -> -score end)

    case scores do
      [{category, _} | _] -> category
      [] -> :general
    end
  end

  defp calculate_confidence(files, keywords, intent_type) do
    file_score = min(length(files) * 0.15, 0.45)
    keyword_score = min(length(keywords) * 0.1, 0.35)
    intent_score = if intent_type != :general, do: 0.2, else: 0.0

    min(file_score + keyword_score + intent_score, 1.0)
  end

  # --- LLM Detection ---

  defp llm_detect(messages) do
    user_text = build_intent_prompt(messages)

    # Embed system instruction in the prompt itself (raw mode + json format)
    prompt = """
    Task: Classify the user's intent from this conversation.

    Respond with ONLY a JSON object, no explanation:
    {"intent_type": "auth|api|database|testing|ui|performance|security|deploy|debug|general", "keywords": ["key1", "key2"], "files": ["file1.ex"]}

    Conversation:
    #{user_text}
    """

    case LLM.complete(prompt,
           max_tokens: @llm_intent_max_tokens,
           temperature: 0.1,
           raw: true,
           format: :json
         ) do
      {:ok, response} ->
        parse_llm_intent(response)

      {:error, reason} ->
        Logger.warning("[Compactor] LLM intent detection failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_intent_prompt(messages) do
    text = messages_to_text(messages)

    # Truncate if too long
    if String.length(text) > @max_llm_prompt_tokens * 4 do
      String.slice(text, 0, @max_llm_prompt_tokens * 4) <> "..."
    else
      text
    end
  end

  defp parse_llm_intent(response) do
    # Try to extract JSON from response
    case Regex.run(~r/\{[^}]+\}/, response) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, %{"intent_type" => intent, "keywords" => kw, "files" => files}} ->
            {:ok,
             %{
               intent_type: String.to_atom(intent),
               keywords: kw || [],
               primary_files: files || [],
               # LLM detection is more confident
               confidence: 0.85
             }}

          {:ok, %{"intent_type" => intent}} ->
            {:ok,
             %{
               intent_type: String.to_atom(intent),
               keywords: [],
               primary_files: [],
               confidence: 0.75
             }}

          _ ->
            {:error, :parse_failed}
        end

      _ ->
        {:error, :no_json_found}
    end
  end

  # --- Message Compaction ---

  defp relevant_to_intent?(msg, intent) do
    text = message_to_text(msg)
    text_lower = String.downcase(text)

    # Check if message mentions relevant files
    file_relevant =
      intent.primary_files
      |> Enum.any?(&String.contains?(text, &1))

    # Check if message contains relevant keywords
    keyword_relevant =
      intent.keywords
      |> Enum.any?(&String.contains?(text_lower, &1))

    file_relevant or keyword_relevant
  end

  defp message_to_text(%{content: content}) when is_binary(content), do: content
  defp message_to_text(msg) when is_binary(msg), do: msg
  defp message_to_text(_), do: ""

  defp compact_message(msg) when is_binary(msg) do
    if String.length(msg) > 500 do
      String.slice(msg, 0, 200) <> "\n... [compacted: #{String.length(msg)} chars] ..."
    else
      msg
    end
  end

  defp compact_message(%{content: content} = msg) when is_binary(content) do
    if String.length(content) > 500 do
      compacted =
        String.slice(content, 0, 200) <> "\n... [compacted: #{String.length(content)} chars] ..."

      Map.put(msg, :content, compacted)
    else
      msg
    end
  end

  defp compact_message(msg), do: msg
end
