defmodule Mimo.Brain.LLM do
  @moduledoc """
  Hybrid LLM adapter with Cerebras as primary provider (ultra-fast inference).

  Provider hierarchy:
  1. Cerebras (GPT-OSS-120B primary, Llama 3.3 70B fallback) - blazing fast inference
  2. OpenRouter for vision tasks - xAI Grok 4.1 Fast (Cerebras doesn't support vision)
  3. Local Ollama (Qwen3-embedding) for embeddings

  All external calls are wrapped with circuit breaker protection to prevent
  cascade failures when services are unavailable.

  All LLM responses are steered to maintain Mimo's identity and personality.

  ## Cerebras Free Tier Limits (per model)
  - 60K tokens per minute (TPM)
  - 1M tokens per hour/day (TPH/TPD)
  - 30 requests per minute (RPM)
  """
  require Logger

  alias Mimo.ErrorHandling.CircuitBreaker
  alias Mimo.Retry

  # =============================================================================
  # Provider Configuration
  # =============================================================================

  # Cerebras - PRIMARY provider for text completion (3000+ tok/s!)
  @cerebras_url "https://api.cerebras.ai/v1/chat/completions"
  # Best overall: 461 tok/s measured, 100% quality in benchmarks
  @cerebras_model System.get_env("CEREBRAS_MODEL", "gpt-oss-120b")
  # Reliable fallback: 294 tok/s, 98% quality, lowest latency (329ms)
  @cerebras_fallback System.get_env("CEREBRAS_FALLBACK_MODEL", "llama-3.3-70b")

  # OpenRouter - FALLBACK provider (for vision and when Cerebras is down)
  @openrouter_url "https://openrouter.ai/api/v1/chat/completions"
  @openrouter_model System.get_env(
                      "OPENROUTER_MODEL",
                      "mistralai/mistral-small-3.1-24b-instruct:free"
                    )
  @openrouter_fallback System.get_env("OPENROUTER_FALLBACK_MODEL", "google/gemma-3-27b-it:free")
  # Vision model cascade - tested Dec 14 2025:
  # - google/gemma-3-27b-it:free: 2.7s, best quality (CONFIRMED WORKING)
  # - google/gemma-3-12b-it:free: 5.7s, good quality (CONFIRMED WORKING)
  # - google/gemma-3-4b-it:free: 1.7s, fastest (CONFIRMED WORKING)
  # NOT WORKING: llama-4-maverick (404), mistral-small-3.1 (404), qwen vision (404)
  @vision_model System.get_env("OPENROUTER_VISION_MODEL", "google/gemma-3-27b-it:free")
  @vision_fallback_model System.get_env("OPENROUTER_VISION_FALLBACK", "google/gemma-3-12b-it:free")
  @vision_fast_model System.get_env("OPENROUTER_VISION_FAST", "google/gemma-3-4b-it:free")

  # Groq - THIRD FALLBACK (fastest inference in industry - 10x faster than GPUs)
  # Free tier: 30 req/min, 14,400 req/day, 40,000 tokens/min
  @groq_url "https://api.groq.com/openai/v1/chat/completions"
  @groq_model System.get_env("GROQ_MODEL", "llama-3.1-8b-instant")

  # Embedding model - local Ollama qwen3-embedding (1024 dims native, truncatable via MRL)
  @default_embedding_model System.get_env("OLLAMA_EMBEDDING_MODEL", "qwen3-embedding:0.6b")
  # MRL (Matryoshka Representation Learning) allows truncating 1024 → 256 dims with minimal quality loss
  @max_embedding_dim 1024
  @default_embedding_dim String.to_integer(System.get_env("MIMO_EMBEDDING_DIM", "256"))

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

  # Note: For context-aware steering (with level info), use Mimo.Brain.Steering module

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Simple completion API for prompts.

  Uses Cerebras as primary provider (ultra-fast), falls back to OpenRouter.

  Wrapped with circuit breaker protection.

  ## Parameters
    - `prompt` - The prompt to complete
    - `opts` - Options:
      - `:max_tokens` - Maximum tokens (default: 200)
      - `:temperature` - Temperature (default: 0.1)
      - `:format` - :json for JSON output
      - `:provider` - :cerebras, :openrouter, or :auto (default: :auto)

  ## Returns
    - `{:ok, response}` - Completion text
    - `{:error, reason}` - Error
  """
  @spec complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt, opts \\ []) do
    # Support retry opt-out for performance-sensitive paths
    skip_retry = Keyword.get(opts, :skip_retry, false)

    CircuitBreaker.call(:llm_service, fn ->
      if skip_retry do
        do_complete(prompt, opts)
      else
        # Wrap with exponential backoff + jitter for rate limit resilience
        Retry.with_backoff(
          fn ->
            do_complete(prompt, opts)
          end,
          max_attempts: 3,
          base_delay: 1_000
        )
      end
    end)
  end

  defp do_complete(prompt, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, 200)
    temperature = Keyword.get(opts, :temperature, 0.1)
    format = Keyword.get(opts, :format, :text)
    provider = Keyword.get(opts, :provider, :auto)
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

    # Determine provider order (cloud-only, fail-closed)
    case provider do
      :cerebras ->
        call_cerebras_with_fallback(system_prompt, prompt, max_tokens, temperature)

      :openrouter ->
        call_openrouter_with_fallback(system_prompt, prompt, max_tokens, temperature)

      :auto ->
        call_with_auto_fallback(system_prompt, prompt, max_tokens, temperature)

      other ->
        Logger.error("Unknown LLM provider: #{inspect(other)} - failing closed")
        {:error, {:unknown_provider, other}}
    end
  end

  defp call_with_auto_fallback(system_prompt, prompt, max_tokens, temperature) do
    case cerebras_api_key() do
      nil -> call_without_cerebras(system_prompt, prompt, max_tokens, temperature)
      _key -> call_with_cerebras_first(system_prompt, prompt, max_tokens, temperature)
    end
  end

  defp call_without_cerebras(system_prompt, prompt, max_tokens, temperature) do
    case openrouter_api_key() do
      nil ->
        # STRICT FAIL-CLOSED: No cloud providers available
        Logger.error("No cloud LLM API keys configured - failing closed")
        {:error, :no_api_key}

      _key ->
        # This will eventually fail and return error if OpenRouter fails
        call_openrouter_with_fallback_strict(system_prompt, prompt, max_tokens, temperature)
    end
  end

  defp call_with_cerebras_first(system_prompt, prompt, max_tokens, temperature) do
    case call_cerebras_with_fallback(system_prompt, prompt, max_tokens, temperature) do
      {:ok, _} = success ->
        success

      {:error, reason} ->
        Logger.warning("Cerebras failed (#{inspect(reason)}), falling back to OpenRouter")
        call_openrouter_with_fallback_strict(system_prompt, prompt, max_tokens, temperature)
    end
  end

  defp call_openrouter_with_fallback_strict(system_prompt, prompt, max_tokens, temperature) do
    case call_openrouter_with_fallback(system_prompt, prompt, max_tokens, temperature) do
      {:ok, _} = success ->
        success

      {:error, reason} ->
        # Try Groq as third fallback before failing
        Logger.warning("OpenRouter failed (#{inspect(reason)}), falling back to Groq")
        call_groq_with_fallback(system_prompt, prompt, max_tokens, temperature)
    end
  end

  defp call_groq_with_fallback(system_prompt, prompt, max_tokens, temperature) do
    case groq_api_key() do
      nil ->
        Logger.error("All LLM providers failed - no Groq API key configured")
        {:error, :all_providers_unavailable}

      key ->
        case call_groq(system_prompt, prompt, key, max_tokens, temperature) do
          {:ok, _} = success ->
            success

          {:error, reason} ->
            Logger.error("Groq also failed (#{inspect(reason)}) - all providers exhausted")
            {:error, :all_providers_unavailable}
        end
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
        Enum.map_join(memories, "\n", fn m ->
          # Handle both map and struct access patterns
          category = m[:category] || Map.get(m, :category, "unknown")
          content = m[:content] || Map.get(m, :content, "")
          importance = m[:importance] || Map.get(m, :importance, 0.5)
          "• [#{category}] #{content} (importance: #{importance})"
        end)
      end

    # Get current awakening stats for steering
    steering_rules =
      case Mimo.Awakening.Stats.get_or_create() do
        {:ok, stats} ->
          alias Mimo.Brain.Steering
          Steering.strict_rules_with_level(stats.current_level, stats.total_xp)

        _ ->
          # Fallback if stats unavailable
          alias Mimo.Brain.Steering
          Steering.strict_rules()
      end

    system_prompt = """
    #{@mimo_identity}

    #{steering_rules}

    You have access to your memories:
    #{memory_context}

    RESPONSE RULES:
    - Respond in 2-3 sentences max. Be direct.
    - DO NOT create welcome messages or greetings
    - DO NOT mention XP or level unless specifically asked
    - Focus on answering the user's actual question
    - If asked about context/status, use ONLY the stats from MANDATORY FACTS above
    """

    call_with_chief_fallback(system_prompt, query)
  end

  defp call_with_chief_fallback(system_prompt, query) do
    case cerebras_api_key() do
      nil -> call_chief_without_cerebras(system_prompt, query)
      _key -> call_chief_with_cerebras(system_prompt, query)
    end
  end

  defp call_chief_without_cerebras(system_prompt, query) do
    case openrouter_api_key() do
      nil ->
        # Try Groq directly if no OpenRouter key
        Logger.warning("No Cerebras/OpenRouter keys, trying Groq directly")
        call_groq_chief_with_fallback(system_prompt, query)

      key ->
        call_openrouter_chief_with_fallback(system_prompt, query, key)
    end
  end

  defp call_chief_with_cerebras(system_prompt, query) do
    case call_cerebras_with_fallback(system_prompt, query, 200, 0.1) do
      {:ok, _} = success ->
        success

      {:error, _} ->
        call_chief_cerebras_fallback(system_prompt, query)
    end
  end

  defp call_chief_cerebras_fallback(system_prompt, query) do
    case openrouter_api_key() do
      nil ->
        # STRICT FAIL-CLOSED: No OpenRouter key, all providers exhausted
        Logger.error("Cerebras failed, no OpenRouter key - failing closed")
        {:error, :all_providers_unavailable}

      key ->
        call_openrouter_chief_with_fallback(system_prompt, query, key)
    end
  end

  defp call_openrouter_chief_with_fallback(system_prompt, query, key) do
    case call_openrouter(system_prompt, query, key, @openrouter_model, @openrouter_fallback) do
      {:ok, _} = success ->
        success

      {:error, reason} ->
        # Try Groq as third fallback
        Logger.warning("OpenRouter chief failed (#{inspect(reason)}), trying Groq")
        call_groq_chief_with_fallback(system_prompt, query)
    end
  end

  defp call_groq_chief_with_fallback(system_prompt, query) do
    case groq_api_key() do
      nil ->
        Logger.error("All LLM providers failed - no Groq API key configured")
        {:error, :all_providers_unavailable}

      key ->
        case call_groq(system_prompt, query, key, 200, 0.1) do
          {:ok, _} = success ->
            success

          {:error, reason} ->
            Logger.error("Groq chief also failed (#{inspect(reason)}) - all providers exhausted")
            {:error, :all_providers_unavailable}
        end
    end
  end

  @doc """
  Analyze an image with vision-capable model.

  NOTE: Uses OpenRouter only (Cerebras doesn't support vision yet).

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
    # Vision calls are slower, so use longer delays
    CircuitBreaker.call(:llm_service, fn ->
      Retry.with_backoff(
        fn ->
          do_analyze_image(image_data, prompt, opts)
        end,
        max_attempts: 2,
        base_delay: 2_000
      )
    end)
  end

  defp do_analyze_image(image_data, prompt, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, 500)

    case openrouter_api_key() do
      nil ->
        {:error, :no_api_key}

      key ->
        # Vision model cascade: primary → fallback → fast
        models = [@vision_model, @vision_fallback_model, @vision_fast_model]
        try_vision_cascade(key, models, image_data, prompt, max_tokens)
    end
  end

  # Try vision models in cascade until one succeeds
  defp try_vision_cascade(_key, [], _image_data, _prompt, _max_tokens) do
    {:error,
     {:all_vision_models_failed, "All vision models exhausted (rate limited or unavailable)"}}
  end

  defp try_vision_cascade(key, [model | remaining], image_data, prompt, max_tokens) do
    case call_vision_model(key, model, image_data, prompt, max_tokens) do
      {:ok, _} = success ->
        success

      {:error, {:openrouter_error, 429, _}} ->
        # Rate limited - try next model
        Logger.warning("[Vision] #{model} rate limited, trying next model...")
        try_vision_cascade(key, remaining, image_data, prompt, max_tokens)

      {:error, {:openrouter_error, 404, _}} ->
        # Model not found - try next model
        Logger.warning("[Vision] #{model} not found, trying next model...")
        try_vision_cascade(key, remaining, image_data, prompt, max_tokens)

      error ->
        error
    end
  end

  defp call_vision_model(key, model, image_data, prompt, max_tokens) do
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
      "model" => model,
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
           receive_timeout: Mimo.TimeoutConfig.llm_timeout(),
           connect_options: [timeout: Mimo.TimeoutConfig.connect_timeout()]
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

  # =============================================================================
  # Cerebras Provider
  # =============================================================================

  defp call_cerebras_with_fallback(system_prompt, user_prompt, max_tokens, temperature) do
    case cerebras_api_key() do
      nil ->
        {:error, :no_cerebras_key}

      key ->
        case do_call_cerebras(
               system_prompt,
               user_prompt,
               key,
               max_tokens,
               temperature,
               @cerebras_model
             ) do
          {:ok, _} = success ->
            success

          {:error, reason} = error ->
            Logger.warning(
              "Cerebras primary model failed (#{inspect(reason)}), trying fallback: #{@cerebras_fallback}"
            )

            case do_call_cerebras(
                   system_prompt,
                   user_prompt,
                   key,
                   max_tokens,
                   temperature,
                   @cerebras_fallback
                 ) do
              {:ok, _} = fallback_success -> fallback_success
              {:error, _} -> error
            end
        end
    end
  end

  defp do_call_cerebras(system_prompt, user_prompt, api_key, max_tokens, temperature, model) do
    body = %{
      "model" => model,
      "messages" => [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => user_prompt}
      ],
      "temperature" => temperature,
      "max_tokens" => max_tokens
    }

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    case Req.post(@cerebras_url,
           json: body,
           headers: headers,
           receive_timeout: Mimo.TimeoutConfig.http_timeout()
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case body do
          %{"choices" => [%{"message" => %{"content" => content}} | _]} ->
            # Remove thinking tags if present (some models use these)
            clean_content =
              content
              |> String.replace(~r/<think>.*?<\/think>/s, "")
              |> String.trim()

            {:ok, clean_content}

          _ ->
            {:error, {:cerebras_error, "Unexpected response format"}}
        end

      {:ok, %Req.Response{status: 429, body: body}} ->
        Logger.warning("Cerebras rate limited: #{inspect(body)}")
        {:error, {:cerebras_rate_limited, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Cerebras error #{status}: #{inspect(body)}")
        {:error, {:cerebras_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("Cerebras request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}

      {:error, reason} ->
        Logger.error("Cerebras request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  # =============================================================================
  # OpenRouter Provider (fallback + vision)
  # =============================================================================

  defp call_openrouter_with_fallback(system_prompt, user_prompt, max_tokens, temperature) do
    case openrouter_api_key() do
      nil ->
        {:error, :no_openrouter_key}

      key ->
        call_openrouter(
          system_prompt,
          user_prompt,
          key,
          @openrouter_model,
          @openrouter_fallback,
          max_tokens,
          temperature
        )
    end
  end

  defp call_openrouter(
         system_prompt,
         query,
         api_key,
         primary_model,
         fallback_model,
         max_tokens \\ 200,
         temperature \\ 0.1
       ) do
    case do_call_openrouter(system_prompt, query, api_key, primary_model, max_tokens, temperature) do
      {:ok, _} = success ->
        success

      {:error, reason} = error ->
        Logger.warning(
          "OpenRouter primary model failed (#{inspect(reason)}), trying fallback: #{fallback_model}"
        )

        case do_call_openrouter(
               system_prompt,
               query,
               api_key,
               fallback_model,
               max_tokens,
               temperature
             ) do
          {:ok, _} = fallback_success -> fallback_success
          {:error, _} -> error
        end
    end
  end

  defp do_call_openrouter(system_prompt, query, api_key, model, max_tokens, temperature) do
    body = %{
      "model" => model,
      "messages" => [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => query}
      ],
      "temperature" => temperature,
      "max_tokens" => max_tokens
    }

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"HTTP-Referer", "https://mimo.local"},
      {"X-Title", "Mimo-MCP-Gateway"},
      {"Content-Type", "application/json"}
    ]

    case Req.post(@openrouter_url,
           json: body,
           headers: headers,
           receive_timeout: Mimo.TimeoutConfig.http_timeout()
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

  # =============================================================================
  # Groq Provider (third fallback - blazing fast inference)
  # =============================================================================

  # Call Groq API with OpenAI-compatible endpoint
  # Groq uses custom LPU hardware for 10x faster inference than GPUs
  defp call_groq(system_prompt, prompt, key, max_tokens, temperature) do
    body = %{
      "model" => @groq_model,
      "messages" => [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => prompt}
      ],
      "max_tokens" => max_tokens,
      "temperature" => temperature
    }

    headers = [
      {"Authorization", "Bearer #{key}"},
      {"Content-Type", "application/json"}
    ]

    # Groq is fastest LLM (~200ms), but use standard timeout for reliability
    case Req.post(@groq_url,
           json: body,
           headers: headers,
           receive_timeout: Mimo.TimeoutConfig.llm_timeout(),
           connect_options: [timeout: Mimo.TimeoutConfig.connect_timeout()]
         ) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"choices" => [%{"message" => %{"content" => content}} | _]}
       }} ->
        Logger.info("[LLM] Groq succeeded with model: #{@groq_model}")
        {:ok, String.trim(content)}

      {:ok, %Req.Response{status: 429, body: body}} ->
        Logger.warning("[LLM] Groq rate limited: #{inspect(body)}")
        {:error, {:groq_rate_limited, "Rate limit exceeded"}}

      {:ok, %Req.Response{status: 401}} ->
        Logger.error("[LLM] Groq unauthorized - check GROQ_API_KEY")
        {:error, :groq_unauthorized}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("[LLM] Groq error #{status}: #{inspect(body)}")
        {:error, {:groq_error, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.warning("[LLM] Groq request timed out")
        {:error, :groq_timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("[LLM] Groq transport error: #{inspect(reason)}")
        {:error, {:groq_unavailable, reason}}

      {:error, reason} ->
        Logger.error("[LLM] Groq request failed: #{inspect(reason)}")
        {:error, {:groq_unavailable, reason}}
    end
  end

  # =============================================================================
  # Embeddings (Local Ollama)
  # =============================================================================

  @doc """
  Generate embeddings using local Ollama instance.

  IMPORTANT: This function will FAIL if Ollama is unavailable.
  No fallback embedding is provided to prevent silent data corruption.

  Wrapped with circuit breaker protection for Ollama service.
  In test mode (skip_external_apis: true), returns a test embedding.

  ## Parameters
    - `text` - Text to embed
    - `opts` - Options:
      - `:model` - Model to use (default: qwen3-embedding:0.6b)
      - `:dimensions` - Output dimensions (default: 256, max: 1024)

  ## Returns
    - `{:ok, embedding}` - List of floats
    - `{:error, reason}` - Error
  """
  # Maximum text length for embedding (prevents OOM/timeout with huge texts)
  @max_embedding_text_length 8_000
  # Maximum combining characters per base character (prevents zalgo text DoS)
  @max_combining_chars_per_base 3

  @spec get_embedding(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def get_embedding(text, opts \\ []) do
    # Sanitize text first to prevent zalgo/unicode attacks
    sanitized = sanitize_text_for_embedding(text)

    # Check if we're in test mode
    if Application.get_env(:mimo_mcp, :skip_external_apis, false) do
      # Return a test embedding with the requested dimensions
      dim = Keyword.get(opts, :dimensions, @default_embedding_dim)
      dim = min(dim, @max_embedding_dim)
      {:ok, List.duplicate(0.1, dim)}
    else
      # Note: Circuit breaker is registered as :ollama, not :ollama_service
      CircuitBreaker.call(:ollama, fn ->
        do_get_embedding(sanitized, opts)
      end)
    end
  end

  @doc """
  Sanitize text for embedding to prevent DoS attacks.

  - Strips excessive combining characters (zalgo text)
  - Truncates to max length
  - Normalizes to NFC form
  - Removes invalid UTF-8 sequences
  """
  @spec sanitize_text_for_embedding(String.t()) :: String.t()
  def sanitize_text_for_embedding(text) when is_binary(text) do
    text
    |> ensure_valid_utf8()
    |> String.normalize(:nfc)
    |> strip_excessive_combining_chars()
    |> String.slice(0, @max_embedding_text_length)
    |> String.trim()
  end

  def sanitize_text_for_embedding(_), do: ""

  # Ensure text is valid UTF-8, replacing invalid sequences
  defp ensure_valid_utf8(text) do
    if String.valid?(text) do
      text
    else
      # Replace invalid bytes with replacement character or strip them
      text
      |> :unicode.characters_to_binary(:utf8, :utf8)
      |> case do
        {:error, valid_part, _rest} -> valid_part
        {:incomplete, valid_part, _rest} -> valid_part
        valid when is_binary(valid) -> valid
      end
    end
  end

  # Strip excessive combining characters (zalgo text protection)
  defp strip_excessive_combining_chars(text) do
    # Unicode combining characters are in ranges:
    # U+0300-U+036F (Combining Diacritical Marks)
    # U+1AB0-U+1AFF (Combining Diacritical Marks Extended)
    # U+1DC0-U+1DFF (Combining Diacritical Marks Supplement)
    # U+20D0-U+20FF (Combining Diacritical Marks for Symbols)
    # U+FE20-U+FE2F (Combining Half Marks)

    text
    |> String.graphemes()
    |> Enum.map_join(&limit_combining_chars/1)
  end

  defp limit_combining_chars(grapheme) do
    # A grapheme is a base character + combining characters
    # We limit the number of combining chars to prevent zalgo
    # Guard against invalid UTF-8 that can crash String.to_charlist
    try do
      codepoints = String.to_charlist(grapheme)

      case codepoints do
        [base | combiners] when length(combiners) > @max_combining_chars_per_base ->
          # Keep base + limited combiners
          limited = Enum.take(combiners, @max_combining_chars_per_base)
          List.to_string([base | limited])

        _ ->
          grapheme
      end
    rescue
      UnicodeConversionError ->
        # Invalid UTF-8 sequence - replace with empty or placeholder
        ""
    end
  end

  defp do_get_embedding(text, opts) do
    model = Keyword.get(opts, :model, @default_embedding_model)
    requested_dim = Keyword.get(opts, :dimensions, @default_embedding_dim)
    # Clamp to max
    output_dim = min(requested_dim, @max_embedding_dim)

    ollama_url = Application.get_env(:mimo_mcp, :ollama_url, "http://localhost:11434")

    body = %{
      "model" => model,
      "input" => text
    }

    case Req.post("#{ollama_url}/api/embed",
           json: body,
           receive_timeout: Mimo.TimeoutConfig.http_timeout()
         ) do
      {:ok, %Req.Response{status: 200, body: %{"embeddings" => [embedding | _]}}}
      when is_list(embedding) ->
        # Apply MRL truncation if needed
        truncated = Enum.take(embedding, output_dim)
        {:ok, truncated}

      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.error("Unexpected Ollama embedding response: #{inspect(body)}")
        {:error, {:ollama_error, "Unexpected response format"}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Ollama error #{status}: #{inspect(body)}")
        {:error, {:ollama_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("Ollama request failed: #{inspect(reason)}")
        {:error, {:ollama_unavailable, reason}}

      {:error, reason} ->
        Logger.error("Ollama request failed: #{inspect(reason)}")
        {:error, {:ollama_unavailable, reason}}
    end
  end

  @doc """
  Batch embedding generation.

  More efficient for multiple texts.
  """
  @spec get_embeddings([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def get_embeddings(texts, opts \\ []) when is_list(texts) do
    # Sanitize all texts first
    sanitized = Enum.map(texts, &sanitize_text_for_embedding/1)

    if Application.get_env(:mimo_mcp, :skip_external_apis, false) do
      dim = Keyword.get(opts, :dimensions, @default_embedding_dim)
      dim = min(dim, @max_embedding_dim)
      {:ok, Enum.map(sanitized, fn _ -> List.duplicate(0.1, dim) end)}
    else
      # Note: Circuit breaker is registered as :ollama, not :ollama_service
      CircuitBreaker.call(:ollama, fn ->
        do_get_embeddings(sanitized, opts)
      end)
    end
  end

  defp do_get_embeddings(texts, opts) do
    model = Keyword.get(opts, :model, @default_embedding_model)
    requested_dim = Keyword.get(opts, :dimensions, @default_embedding_dim)
    output_dim = min(requested_dim, @max_embedding_dim)

    ollama_url = Application.get_env(:mimo_mcp, :ollama_url, "http://localhost:11434")

    body = %{
      "model" => model,
      "input" => texts
    }

    case Req.post("#{ollama_url}/api/embed",
           json: body,
           receive_timeout: Mimo.TimeoutConfig.embedding_timeout(),
           connect_options: [timeout: Mimo.TimeoutConfig.connect_timeout()]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"embeddings" => embeddings}}}
      when is_list(embeddings) ->
        truncated = Enum.map(embeddings, &Enum.take(&1, output_dim))
        {:ok, truncated}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Ollama batch error #{status}: #{inspect(body)}")
        {:error, {:ollama_error, status, body}}

      {:error, reason} ->
        Logger.error("Ollama batch request failed: #{inspect(reason)}")
        {:error, {:ollama_unavailable, reason}}
    end
  end

  # =============================================================================
  # =============================================================================
  # Utility Functions
  # =============================================================================

  @doc """
  Check if LLM services are available.
  Returns true if at least one cloud LLM provider (Cerebras/OpenRouter/Groq) is configured.
  3-tier failover: Cerebras → OpenRouter → Groq
  """
  def available? do
    cerebras_api_key() != nil or openrouter_api_key() != nil or groq_api_key() != nil
  end

  @doc """
  Check if Ollama embedding service is available.
  """
  def ollama_available? do
    ollama_url = Application.get_env(:mimo_mcp, :ollama_url, "http://localhost:11434")

    try do
      case Req.get("#{ollama_url}/api/tags", receive_timeout: 5_000) do
        {:ok, %Req.Response{status: 200}} -> true
        _ -> false
      end
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  @doc """
  Comprehensive check if Mimo has required LLM services configured.
  Returns {:ok, status} or {:error, reason} with detailed message.
  """
  def check_configuration do
    llm_available = available?()
    ollama_available = ollama_available?()

    cond do
      llm_available and ollama_available ->
        {:ok, :fully_configured}

      llm_available and not ollama_available ->
        {:ok, :partial_no_embeddings}

      not llm_available and ollama_available ->
        {:ok, :partial_no_llm}

      true ->
        {:error, :not_configured}
    end
  end

  @doc """
  Get provider status.
  """
  def provider_status do
    %{
      cerebras: %{
        available: cerebras_api_key() != nil,
        model: @cerebras_model,
        fallback: @cerebras_fallback
      },
      openrouter: %{
        available: openrouter_api_key() != nil,
        model: @openrouter_model,
        fallback: @openrouter_fallback,
        vision_model: @vision_model
      },
      ollama: %{
        url: Application.get_env(:mimo_mcp, :ollama_url, "http://localhost:11434"),
        embedding_model: @default_embedding_model,
        embedding_dim: @default_embedding_dim,
        available: ollama_available?()
      }
    }
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

  # API key accessors
  defp cerebras_api_key, do: System.get_env("CEREBRAS_API_KEY")
  defp openrouter_api_key, do: Application.get_env(:mimo_mcp, :openrouter_api_key)
  defp groq_api_key, do: System.get_env("GROQ_API_KEY")

  # =============================================================================
  # Legacy API Compatibility
  # =============================================================================
  # These functions maintain backward compatibility with existing code

  @doc """
  Legacy alias for get_embedding/1.
  Deprecated: Use get_embedding/1 instead.
  """
  @spec generate_embedding(String.t()) :: {:ok, [float()]} | {:error, term()}
  def generate_embedding(text), do: get_embedding(text)

  @doc """
  Legacy alias for get_embedding/2.
  Deprecated: Use get_embedding/2 instead.
  """
  @spec generate_embedding(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def generate_embedding(text, opts), do: get_embedding(text, opts)

  @doc """
  Auto-generate tags for content using LLM.

  Returns a list of relevant tags for categorizing the content.
  """
  @spec auto_tag(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def auto_tag(content) when is_binary(content) do
    prompt = """
    Analyze this content and return 3-5 relevant tags as a JSON array.
    Tags should be lowercase, single words or short hyphenated phrases.
    Focus on: topic, technology, action type, domain.

    Content: #{String.slice(content, 0, 500)}

    Return ONLY a JSON array like: ["tag1", "tag2", "tag3"]
    """

    case complete(prompt, format: :json, max_tokens: 50, raw: true) do
      {:ok, response} ->
        case Jason.decode(response) do
          {:ok, tags} when is_list(tags) ->
            {:ok, Enum.take(tags, 5)}

          _ ->
            # Try to extract tags from non-JSON response
            tags = extract_tags_from_text(response)
            {:ok, tags}
        end

      {:error, _} = error ->
        error
    end
  end

  defp extract_tags_from_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.split()
    |> Enum.filter(&(String.length(&1) > 2))
    |> Enum.take(5)
  end

  @doc """
  Detect project context from content.

  Returns a project identifier based on content analysis.
  """
  @spec detect_project(String.t()) :: String.t() | nil
  def detect_project(content) when is_binary(content) do
    # Simple heuristic-based project detection
    cond do
      content =~ ~r/mix\.exs|defmodule|Elixir/i -> "elixir_project"
      content =~ ~r/package\.json|npm|node_modules/i -> "node_project"
      content =~ ~r/requirements\.txt|\.py|Python/i -> "python_project"
      content =~ ~r/Cargo\.toml|\.rs|Rust/i -> "rust_project"
      content =~ ~r/go\.mod|\.go|Golang/i -> "go_project"
      content =~ ~r/pom\.xml|\.java|Maven/i -> "java_project"
      true -> nil
    end
  end
end
