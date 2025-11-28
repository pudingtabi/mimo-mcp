defmodule Mimo.Brain.LLM do
  @moduledoc """
  Hybrid LLM adapter. OpenRouter for reasoning, local Ollama for embeddings.

  All external calls are wrapped with circuit breaker protection to prevent
  cascade failures when services are unavailable.
  """
  require Logger

  alias Mimo.ErrorHandling.CircuitBreaker

  @openrouter_url "https://openrouter.ai/api/v1/chat/completions"
  # Use env var for model, default to fast kat-coder-pro (~2s response)
  @default_model System.get_env("OPENROUTER_MODEL", "kwaipilot/kat-coder-pro:free")

  @doc """
  Simple completion API for prompts.

  Wrapped with circuit breaker protection.

  ## Parameters
    - `prompt` - The prompt to complete
    - `opts` - Options:
      - `:max_tokens` - Maximum tokens (default: 200)
      - `:temperature` - Temperature (default: 0.1)
      - `:format` - :json for JSON output

  ## Returns
    - `{:ok, response}` - Completion text
    - `{:error, reason}` - Error
  """
  @spec complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt, opts \\ []) do
    CircuitBreaker.call(:llm_service, fn ->
      do_complete(prompt, opts)
    end)
  end

  defp do_complete(prompt, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, 200)
    temperature = Keyword.get(opts, :temperature, 0.1)
    format = Keyword.get(opts, :format, :text)

    system_prompt =
      if format == :json do
        "You are a helpful assistant. Respond only with valid JSON, no markdown or explanation."
      else
        "You are a helpful assistant. Be concise."
      end

    case api_key() do
      nil ->
        Logger.warning("No OpenRouter API key, using fallback")
        {:error, :no_api_key}

      key ->
        do_complete_request(system_prompt, prompt, key, max_tokens, temperature)
    end
  end

  defp do_complete_request(system_prompt, user_prompt, api_key, max_tokens, temperature) do
    payload =
      Jason.encode!(%{
        "model" => @default_model,
        "messages" => [
          %{"role" => "system", "content" => system_prompt},
          %{"role" => "user", "content" => user_prompt}
        ],
        "temperature" => temperature,
        "max_tokens" => max_tokens
      })

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"HTTP-Referer", "https://mimo.local"},
      {"X-Title", "Mimo-MCP-Gateway"},
      {"Content-Type", "application/json"}
    ]

    case Req.post(@openrouter_url,
           json: Jason.decode!(payload),
           headers: headers,
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case body do
          %{"choices" => [%{"message" => %{"content" => content}} | _]} ->
            clean_content =
              content
              |> String.replace(~r/<think>.*?<\/think>/s, "")
              |> String.trim()

            {:ok, clean_content}

          _ ->
            {:error, {:openrouter_error, "Unexpected response format"}}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("OpenRouter error #{status}: #{inspect(body)}")
        {:error, {:openrouter_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("OpenRouter request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}

      {:error, reason} ->
        Logger.error("OpenRouter request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Consult chief of staff with memory context.

  Wrapped with circuit breaker protection.
  """
  def consult_chief_of_staff(query, memories) when is_list(memories) do
    CircuitBreaker.call(:llm_service, fn ->
      do_consult_chief_of_staff(query, memories)
    end)
  end

  defp do_consult_chief_of_staff(query, memories) do
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
        {:ok,
         "No OpenRouter API key configured. Query: #{query}\n\nMemories consulted: #{length(memories)}"}

      key ->
        call_openrouter(system_prompt, query, key)
    end
  end

  defp call_openrouter(system_prompt, query, api_key) do
    payload =
      Jason.encode!(%{
        "model" => @default_model,
        "messages" => [
          %{"role" => "system", "content" => system_prompt},
          %{"role" => "user", "content" => query}
        ],
        "temperature" => 0.1,
        "max_tokens" => 200
      })

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"HTTP-Referer", "https://mimo.local"},
      {"X-Title", "Mimo-MCP-Gateway"},
      {"Content-Type", "application/json"}
    ]

    case Req.post(@openrouter_url,
           json: Jason.decode!(payload),
           headers: headers,
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case body do
          %{"choices" => [%{"message" => %{"content" => content}} | _]} ->
            # Remove thinking tags if present
            clean_content =
              content
              |> String.replace(~r/<think>.*?<\/think>/s, "")
              |> String.trim()

            {:ok, clean_content}

          _ ->
            {:error, {:openrouter_error, "Unexpected response format"}}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("OpenRouter error #{status}: #{inspect(body)}")
        {:error, {:openrouter_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("OpenRouter request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}

      {:error, reason} ->
        Logger.error("OpenRouter request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Generate embeddings using local Ollama instance.
  Falls back to simple hash-based vectors if Ollama unavailable.

  Wrapped with circuit breaker protection for Ollama service.
  In test mode (skip_external_apis: true), returns fallback immediately.
  """
  def generate_embedding(text) when is_binary(text) do
    if Application.get_env(:mimo_mcp, :skip_external_apis, false) do
      # Test mode - skip external API calls entirely
      {:ok, fallback_embedding(text)}
    else
      CircuitBreaker.call(:ollama, fn ->
        do_generate_embedding(text)
      end)
    end
  end

  defp do_generate_embedding(text) do
    ollama_url = Application.get_env(:mimo_mcp, :ollama_url, "http://localhost:11434")
    # Use shorter timeout in dev/test, longer in production
    timeout = Application.get_env(:mimo_mcp, :ollama_timeout, 10_000)

    payload =
      Jason.encode!(%{
        "model" => "nomic-embed-text",
        "prompt" => text
      })

    headers = [{"Content-Type", "application/json"}]

    case Req.post("#{ollama_url}/api/embeddings",
           json: Jason.decode!(payload),
           headers: headers,
           connect_timeout: 2_000,
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case body do
          %{"embedding" => embedding} ->
            {:ok, embedding}

          _ ->
            Logger.warning("Ollama embedding unexpected response")
            {:ok, fallback_embedding(text)}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Ollama embedding failed (#{status}): #{inspect(body)}")
        {:ok, fallback_embedding(text)}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.warning("Ollama unavailable: #{inspect(reason)}, using fallback")
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
