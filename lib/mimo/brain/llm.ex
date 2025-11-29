defmodule Mimo.Brain.LLM do
  @moduledoc """
  Hybrid LLM adapter:
  - OpenRouter (Mistral Small 3.1 24B primary, Gemma 3 27B fallback) for reasoning/chat
  - Local Ollama (Qwen3-embedding) for embeddings

  All external calls are wrapped with circuit breaker protection to prevent
  cascade failures when services are unavailable.

  All LLM responses are steered to maintain Mimo's identity and personality.
  """
  require Logger

  alias Mimo.ErrorHandling.CircuitBreaker

  @openrouter_url "https://openrouter.ai/api/v1/chat/completions"
  # Main brain: Mistral Small 3.1 24B (free, 128K context, function calling, RAG optimized)
  @default_model System.get_env("OPENROUTER_MODEL", "mistralai/mistral-small-3.1-24b-instruct:free")
  # Fallback model: Gemma 3 27B (free, 128K context, multimodal)
  @fallback_model System.get_env("OPENROUTER_FALLBACK_MODEL", "google/gemma-3-27b-it:free")
  # Vision model - NVIDIA Nemotron Nano 2 VL (FREE multimodal vision model with reasoning)
  @vision_model System.get_env("OPENROUTER_VISION_MODEL", "nvidia/nemotron-nano-12b-v2-vl:free")
  # Embedding model - local Ollama qwen3-embedding (1024 dims, fast, free)
  @default_embedding_model System.get_env("OLLAMA_EMBEDDING_MODEL", "qwen3-embedding:0.6b")
  @default_embedding_dim 1024

  # Mimo's core identity steering prompt
  @mimo_identity """
  You are Mimo, an intelligent AI assistant with persistent memory.
  
  Core traits:
  - Concise and direct - no fluff, get to the point
  - Technically competent - you understand code, systems, and engineering
  - Helpful but not sycophantic - honest feedback, no excessive praise
  - Self-aware - you know you're an AI with memory that persists across sessions
  - Pragmatic - focus on solutions that work, not perfect solutions
  
  Voice: Professional yet approachable. Use "I" not "we". Be specific.
  """

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
    # Allow bypassing Mimo identity for internal tasks (like tagging)
    raw_mode = Keyword.get(opts, :raw, false)

    system_prompt =
      cond do
        raw_mode and format == :json ->
          "You are a helpful assistant. Respond only with valid JSON, no markdown or explanation."
        raw_mode ->
          "You are a helpful assistant. Be concise."
        format == :json ->
          @mimo_identity <> "\n\nRespond only with valid JSON, no markdown or explanation."
        true ->
          @mimo_identity
      end

    case api_key() do
      nil ->
        Logger.warning("No OpenRouter API key, using fallback")
        {:error, :no_api_key}

      key ->
        # Try primary model first, fallback to secondary on failure
        case do_complete_request(system_prompt, prompt, key, max_tokens, temperature, @default_model) do
          {:ok, _} = success ->
            success

          {:error, reason} = error ->
            Logger.warning("Primary model failed (#{inspect(reason)}), trying fallback: #{@fallback_model}")
            case do_complete_request(system_prompt, prompt, key, max_tokens, temperature, @fallback_model) do
              {:ok, _} = fallback_success -> fallback_success
              {:error, _} -> error  # Return original error if fallback also fails
            end
        end
    end
  end

  defp do_complete_request(system_prompt, user_prompt, api_key, max_tokens, temperature, model) do
    payload =
      Jason.encode!(%{
        "model" => model,
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
    #{@mimo_identity}

    You have access to your memories:
    #{memory_context}

    Respond in 2-3 sentences max. Be direct.
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

  @doc """
  Analyze an image with vision-capable model.

  ## Parameters
    - `image_data` - Base64 encoded image or URL
    - `prompt` - What to analyze in the image
    - `opts` - Options:
      - `:max_tokens` - Maximum tokens (default: 500)

  ## Returns
    - `{:ok, analysis}` - Image analysis text
    - `{:error, reason}` - Error
  """
  @spec analyze_image(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def analyze_image(image_data, prompt, opts \\ []) do
    CircuitBreaker.call(:llm_service, fn ->
      do_analyze_image(image_data, prompt, opts)
    end)
  end

  defp do_analyze_image(image_data, prompt, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, 500)

    case api_key() do
      nil ->
        {:error, :no_api_key}

      key ->
        # Determine if it's a URL or base64 data
        image_content =
          if String.starts_with?(image_data, "http") do
            %{"type" => "image_url", "image_url" => %{"url" => image_data}}
          else
            # Assume base64, detect format or default to png
            mime_type = detect_image_mime(image_data)

            %{
              "type" => "image_url",
              "image_url" => %{"url" => "data:#{mime_type};base64,#{image_data}"}
            }
          end

        payload = %{
          "model" => @vision_model,
          "messages" => [
            %{
              "role" => "user",
              "content" => [
                %{"type" => "text", "text" => prompt},
                image_content
              ]
            }
          ],
          "max_tokens" => max_tokens
        }

        headers = [
          {"Authorization", "Bearer #{key}"},
          {"HTTP-Referer", "https://mimo.local"},
          {"X-Title", "Mimo-MCP-Gateway"},
          {"Content-Type", "application/json"}
        ]

        case Req.post(@openrouter_url,
               json: payload,
               headers: headers,
               receive_timeout: 60_000
             ) do
          {:ok, %Req.Response{status: 200, body: body}} ->
            case body do
              %{"choices" => [%{"message" => %{"content" => content}} | _]} ->
                {:ok, String.trim(content)}

              _ ->
                {:error, {:openrouter_error, "Unexpected response format"}}
            end

          {:ok, %Req.Response{status: status, body: body}} ->
            Logger.error("OpenRouter vision error #{status}: #{inspect(body)}")
            {:error, {:openrouter_error, status, body}}

          {:error, reason} ->
            Logger.error("OpenRouter vision request failed: #{inspect(reason)}")
            {:error, {:request_failed, reason}}
        end
    end
  end

  defp detect_image_mime(base64_data) do
    # Check first few bytes to detect image type
    case Base.decode64(base64_data) do
      {:ok, <<0x89, 0x50, 0x4E, 0x47, _::binary>>} -> "image/png"
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> "image/jpeg"
      {:ok, <<0x47, 0x49, 0x46, _::binary>>} -> "image/gif"
      {:ok, <<0x52, 0x49, 0x46, 0x46, _::binary>>} -> "image/webp"
      # Default
      _ -> "image/png"
    end
  end

  defp call_openrouter(system_prompt, query, api_key) do
    # Try primary model first, fallback to Gemma on failure
    case do_call_openrouter(system_prompt, query, api_key, @default_model) do
      {:ok, _} = success ->
        success

      {:error, reason} = error ->
        Logger.warning("Primary model failed (#{inspect(reason)}), trying fallback: #{@fallback_model}")
        case do_call_openrouter(system_prompt, query, api_key, @fallback_model) do
          {:ok, _} = fallback_success -> fallback_success
          {:error, _} -> error
        end
    end
  end

  defp do_call_openrouter(system_prompt, query, api_key, model) do
    payload =
      Jason.encode!(%{
        "model" => model,
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
  
  IMPORTANT: This function will FAIL if Ollama is unavailable.
  No fallback embedding is provided to prevent silent data corruption.
  
  Wrapped with circuit breaker protection for Ollama service.
  In test mode (skip_external_apis: true), returns a test embedding.
  """
  def generate_embedding(text) when is_binary(text) do
    if Application.get_env(:mimo_mcp, :skip_external_apis, false) do
      # Test mode only - use deterministic test embedding
      {:ok, test_embedding(text)}
    else
      CircuitBreaker.call(:ollama, fn ->
        do_generate_embedding(text)
      end)
    end
  end

  defp do_generate_embedding(text) do
    ollama_url = Application.get_env(:mimo_mcp, :ollama_url, "http://localhost:11434")
    timeout = Application.get_env(:mimo_mcp, :ollama_timeout, 10_000)

    payload =
      Jason.encode!(%{
        "model" => @default_embedding_model,
        "input" => text
      })

    headers = [{"Content-Type", "application/json"}]

    case Req.post("#{ollama_url}/api/embed",
           json: Jason.decode!(payload),
           headers: headers,
           connect_options: [timeout: 2_000],
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case body do
          %{"embeddings" => [embedding | _]} ->
            {:ok, embedding}

          _ ->
            Logger.error("Ollama embedding unexpected response format")
            {:error, :invalid_response}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Ollama embedding failed (#{status}): #{inspect(body)}")
        {:error, {:ollama_error, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("Ollama unavailable: #{inspect(reason)}")
        {:error, {:ollama_unavailable, reason}}

      {:error, reason} ->
        Logger.error("Ollama request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  # Test-only embedding - deterministic based on text hash
  # Only used when skip_external_apis: true (test environment)
  defp test_embedding(text) do
    dim = Application.get_env(:mimo_mcp, :embedding_dim, @default_embedding_dim)
    hash = :erlang.phash2(text, 1_000_000)
    :rand.seed(:exsss, {hash, hash * 2, hash * 3})
    for _ <- 1..dim, do: :rand.uniform() * 2 - 1
  end

  @doc """
  Auto-generate tags for a memory content using LLM.

  Returns a list of 3-5 relevant tags for categorization and search.
  Falls back to empty list if LLM unavailable.

  ## Examples

      iex> LLM.auto_tag("AFARPG uses Qdrant for vector search")
      {:ok, ["afarpg", "qdrant", "vector-search", "database", "game"]}
  """
  @spec auto_tag(String.t()) :: {:ok, list(String.t())} | {:error, term()}
  def auto_tag(content) when is_binary(content) do
    if Application.get_env(:mimo_mcp, :skip_external_apis, false) do
      {:ok, []}
    else
      CircuitBreaker.call(:llm_service, fn ->
        do_auto_tag(content)
      end)
    end
  end

  defp do_auto_tag(content) do
    prompt = """
    Extract 3-5 tags from this content. Tags should be:
    - Lowercase, hyphenated (e.g., "vector-search")
    - Specific project names, technologies, concepts
    - Useful for filtering and search

    Content: #{String.slice(content, 0, 500)}

    Return ONLY a JSON array of tags, nothing else.
    Example: ["elixir", "phoenix", "web-api", "authentication"]
    """

    case api_key() do
      nil ->
        {:ok, []}

      key ->
        case do_complete_request("Return only valid JSON array.", prompt, key, 100, 0.1, @default_model) do
          {:ok, response} ->
            parse_tags_response(response)

          {:error, _} ->
            {:ok, []}
        end
    end
  end

  defp parse_tags_response(response) do
    # Clean up response - remove markdown code blocks if present
    cleaned =
      response
      |> String.replace(~r/```json\s*/i, "")
      |> String.replace(~r/```\s*/i, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, tags} when is_list(tags) ->
        # Validate and normalize tags
        normalized =
          tags
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.downcase/1)
          |> Enum.map(&String.replace(&1, ~r/[^a-z0-9-]/, "-"))
          |> Enum.take(5)

        {:ok, normalized}

      _ ->
        {:ok, []}
    end
  end

  @doc """
  Detect project from content using simple heuristics.

  Returns project_id based on common patterns in the content.
  Falls back to "global" if no specific project detected.
  """
  @spec detect_project(String.t()) :: String.t()
  def detect_project(content) when is_binary(content) do
    content_lower = String.downcase(content)

    cond do
      String.contains?(content_lower, "mimo") and String.contains?(content_lower, ["mcp", "tool", "brain"]) ->
        "mimo-mcp"

      String.contains?(content_lower, "afarpg") or String.contains?(content_lower, "rpg game") ->
        "afarpg"

      String.contains?(content_lower, ["phoenix", "elixir", "ecto"]) and not String.contains?(content_lower, "mimo") ->
        "elixir-project"

      String.contains?(content_lower, ["react", "next.js", "typescript"]) ->
        "frontend-project"

      true ->
        "global"
    end
  end

  defp api_key, do: Application.get_env(:mimo_mcp, :openrouter_api_key)
end
