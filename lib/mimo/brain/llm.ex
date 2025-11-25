defmodule Mimo.Brain.LLM do
  @moduledoc """
  Hybrid LLM adapter. OpenRouter for reasoning, local Ollama for embeddings.
  """
  require Logger

  @openrouter_url "https://openrouter.ai/api/v1/chat/completions"
  # Use env var for model, default to fast kat-coder-pro (~2s response)
  @default_model System.get_env("OPENROUTER_MODEL", "kwaipilot/kat-coder-pro:free")

  def consult_chief_of_staff(query, memories) when is_list(memories) do
    memory_context = 
      if Enum.empty?(memories) do
        "No relevant memories found."
      else
        memories
        |> Enum.map(fn m -> 
          # Handle both map and struct access patterns
          category = m[:category] || Map.get(m, :category, "unknown")
          content = m[:content] || Map.get(m, :content, "")
          importance = m[:importance] || Map.get(m, :importance, 0.5)
          "• [#{category}] #{content} (importance: #{importance})" 
        end)
        |> Enum.join("\n")
      end

    system_prompt = """
    You are Mimo, a concise AI assistant. Be brief and direct.
    
    Context: #{memory_context}
    
    Respond in 2-3 sentences max.
    """

    case api_key() do
      nil ->
        # Fallback to local response if no API key
        {:ok, "No OpenRouter API key configured. Query: #{query}\n\nMemories consulted: #{length(memories)}"}
      
      key ->
        call_openrouter(system_prompt, query, key)
    end
  end

  defp call_openrouter(system_prompt, query, api_key) do
    payload = %{
      "model" => @default_model,
      "messages" => [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => query}
      ],
      "temperature" => 0.1,
      "max_tokens" => 200
    }

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"HTTP-Referer", "https://mimo.local"},
      {"X-Title", "Mimo-MCP-Gateway"},
      {"Content-Type", "application/json"}
    ]

    case Req.post(@openrouter_url, json: payload, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
        # Remove thinking tags if present
        clean_content = content 
          |> String.replace(~r/<think>.*?<\/think>/s, "") 
          |> String.trim()
        {:ok, clean_content}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenRouter error #{status}: #{inspect(body)}")
        {:error, {:openrouter_error, status, body}}

      {:error, reason} ->
        Logger.error("OpenRouter request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Generate embeddings using local Ollama instance.
  Falls back to simple hash-based vectors if Ollama unavailable.
  """
  def generate_embedding(text) when is_binary(text) do
    ollama_url = Application.get_env(:mimo_mcp, :ollama_url, "http://localhost:11434")
    
    payload = %{
      "model" => "nomic-embed-text",
      "prompt" => text
    }

    case Req.post("#{ollama_url}/api/embeddings", json: payload, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"embedding" => embedding}}} -> 
        {:ok, embedding}
      
      {:ok, %{status: status, body: body}} ->
        Logger.warning("Ollama embedding failed (#{status}): #{inspect(body)}")
        {:ok, fallback_embedding(text)}
      
      {:error, reason} -> 
        Logger.warning("Ollama unavailable: #{inspect(reason)}, using fallback")
        {:ok, fallback_embedding(text)}
    end
  end

  # Simple fallback embedding using hash - not ideal but works without Ollama
  defp fallback_embedding(text) do
    dim = Application.get_env(:mimo_mcp, :embedding_dim, 768)
    hash = :erlang.phash2(text, 1_000_000)
    :rand.seed(:exsss, {hash, hash * 2, hash * 3})
    for _ <- 1..dim, do: :rand.uniform() * 2 - 1
  end

  defp api_key, do: Application.get_env(:mimo_mcp, :openrouter_api_key)
end
