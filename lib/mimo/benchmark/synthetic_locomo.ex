defmodule Mimo.Benchmark.SyntheticLOCOMO do
  @moduledoc """
  Synthetic LOCOMO-style dataset generator used when the official dataset is
  unavailable. Generates conversations with factual, temporal, and multi-hop
  questions for quick benchmarking and CI sanity checks.
  """

  @topics ~w(project_setup debugging deployment authentication database caching search)

  @spec generate(pos_integer(), pos_integer(), pos_integer()) :: [map()]
  def generate(num_conversations \\ 50, turns_per_conv \\ 20, questions_per_conv \\ 10) do
    1..num_conversations
    |> Enum.map(fn i ->
      topic = Enum.random(@topics)
      turns = generate_turns(topic, turns_per_conv)
      questions = generate_questions(turns, questions_per_conv)

      %{
        "conversation_id" => "synth_#{i}",
        "turns" => turns,
        "questions" => questions
      }
    end)
  end

  defp generate_turns(topic, count) do
    templates = conversation_templates(topic)

    1..count
    |> Enum.map(fn i ->
      speaker = if rem(i, 2) == 1, do: "user", else: "assistant"
      template = Enum.at(templates, rem(i - 1, length(templates)))

      %{
        "speaker" => speaker,
        "text" => String.replace(template, "{{turn}}", Integer.to_string(i)),
        "turn" => i
      }
    end)
  end

  defp generate_questions(_turns, count) when count <= 0, do: []

  defp generate_questions(turns, count) when length(turns) < 2 do
    # Not enough turns for temporal/multi-hop, just generate factual
    generate_factual_questions(turns, min(count, length(turns)))
  end

  defp generate_questions(turns, count) do
    factual = generate_factual_questions(turns, div(count, 3))
    temporal = generate_temporal_questions(turns, div(count, 3))
    multi_hop = generate_multi_hop_questions(turns, count - 2 * div(count, 3))

    factual ++ temporal ++ multi_hop
  end

  defp generate_factual_questions(_turns, count) when count <= 0, do: []

  defp generate_factual_questions(turns, count) do
    turns
    |> Enum.take_random(count)
    |> Enum.with_index(1)
    |> Enum.map(fn {turn, i} ->
      %{
        "id" => "q_fact_#{i}",
        "type" => "factual",
        "turn_reference" => turn["turn"],
        "text" => "What was discussed in turn #{turn["turn"]}?",
        "answer" => turn["text"]
      }
    end)
  end

  defp generate_temporal_questions(_turns, count) when count <= 0, do: []

  defp generate_temporal_questions(turns, _count) when length(turns) < 2, do: []

  defp generate_temporal_questions(turns, count) do
    1..count
    |> Enum.map(fn i ->
      t1 = Enum.random(1..max(1, length(turns) - 1))
      answer_turn = Enum.min([t1 + 1, length(turns)])

      %{
        "id" => "q_temp_#{i}",
        "type" => "temporal",
        "turn_reference" => t1,
        "text" => "What happened after turn #{t1}?",
        "answer" => turns |> Enum.at(answer_turn - 1) |> Map.get("text")
      }
    end)
  end

  defp generate_multi_hop_questions(_turns, count) when count <= 0, do: []

  defp generate_multi_hop_questions(turns, _count) when length(turns) < 2, do: []

  defp generate_multi_hop_questions(turns, count) do
    1..count
    |> Enum.map(fn i ->
      [t1, t2] = Enum.take_random(turns, 2)

      %{
        "id" => "q_multi_#{i}",
        "type" => "multi_hop",
        "turn_reference" => [t1["turn"], t2["turn"]],
        "text" => "Combine information from turns #{t1["turn"]} and #{t2["turn"]}.",
        "answer" => "#{t1["text"]} #{t2["text"]}"
      }
    end)
  end

  defp conversation_templates("project_setup") do
    [
      "I need help setting up a new Elixir project",
      "Sure, run `mix new project_name` to create it",
      "What about dependencies?",
      "Add them to mix.exs under deps",
      "How do I start the server?",
      "Use `mix phx.server` after installing Phoenix"
    ]
  end

  defp conversation_templates("debugging") do
    [
      "I'm seeing a crash at turn {{turn}}",
      "Check the stacktrace and ensure configs are loaded",
      "Could it be missing ENV vars?",
      "Yes, verify DATABASE_URL and SECRET_KEY_BASE",
      "Logs mention timeout",
      "Increase the timeout or add retries around the HTTP call"
    ]
  end

  defp conversation_templates("deployment") do
    [
      "How do I deploy to Fly.io?",
      "Create a fly.toml and run fly launch",
      "What about secrets?",
      "Set them with fly secrets set",
      "How to scale?",
      "Use fly scale count and fly scale memory"
    ]
  end

  defp conversation_templates("authentication") do
    [
      "Need login for the app",
      "Use bcrypt for hashing and sessions for web",
      "What about APIs?",
      "Use JWT with short expiry and refresh tokens",
      "Should I allow social login?",
      "Optional; start with email/password and MFA"
    ]
  end

  defp conversation_templates("database") do
    [
      "Choosing between Postgres and SQLite",
      "Postgres for prod, SQLite fine for local",
      "How to run migrations?",
      "mix ecto.create && mix ecto.migrate",
      "What about pooling?",
      "Set pool_size env var based on worker counts"
    ]
  end

  defp conversation_templates("caching") do
    [
      "Cache layer needed",
      "Use Redis with TTL 300s",
      "How to invalidate?",
      "Use versioned keys and background sweeps",
      "Should I cache DB results?",
      "Yes, for read-heavy endpoints"
    ]
  end

  defp conversation_templates("search") do
    [
      "Need search over documents",
      "Use embedding search with HNSW",
      "How to handle typos?",
      "Add trigram index or fuzzy search",
      "What about filters?",
      "Store metadata and filter before vector ranking"
    ]
  end

  defp conversation_templates(_), do: conversation_templates("project_setup")
end
