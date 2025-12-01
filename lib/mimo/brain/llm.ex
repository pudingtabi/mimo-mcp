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
  # Vision model - xAI Grok 4.1 Fast (FREE vision model with 2M context, no rate limits)
  # Benchmarked at 5.8s latency with detailed, high-quality descriptions
  # Previous models tested: nvidia/nemotron-nano (provider error), novai/bert-nebulon-alpha (removed from OpenRouter)
  @vision_model System.get_env("OPENROUTER_VISION_MODEL", "x-ai/grok-4.1-fast:free")

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
    CircuitBreaker.call(:llm_service, fn ->
      do_complete(prompt, opts)
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

    # Determine provider order
    case provider do
      :cerebras ->
        call_cerebras_with_fallback(system_prompt, prompt, max_tokens, temperature)

      :openrouter ->
        call_openrouter_with_fallback(system_prompt, prompt, max_tokens, temperature)

      :auto ->
        # Try Cerebras first (faster), fall back to OpenRouter
        case cerebras_api_key() do
          nil ->
            Logger.debug("No Cerebras key, using OpenRouter")
            call_openrouter_with_fallback(system_prompt, prompt, max_tokens, temperature)

          _key ->
            case call_cerebras_with_fallback(system_prompt, prompt, max_tokens, temperature) do
              {:ok, _} = success ->
                success

              {:error, reason} ->
                Logger.warning("Cerebras failed (#{inspect(reason)}), falling back to OpenRouter")
                call_openrouter_with_fallback(system_prompt, prompt, max_tokens, temperature)
            end
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

    system_prompt = """
    #{@mimo_identity}

    You have access to your memories:
    #{memory_context}

    Respond in 2-3 sentences max. Be direct.
    """

    # Use Cerebras for speed, fall back to OpenRouter
    case cerebras_api_key() do
      nil ->
        case openrouter_api_key() do
          nil ->
            Logger.error("No API keys configured - LLM synthesis unavailable")
            {:error, :no_api_key}

          key ->
            call_openrouter(system_prompt, query, key, @openrouter_model, @openrouter_fallback)
        end

      _key ->
        case call_cerebras_with_fallback(system_prompt, query, 200, 0.1) do
          {:ok, _} = success ->
            success

          {:error, _} ->
            case openrouter_api_key() do
              nil ->
                {:error, :no_api_key}

              key ->
                call_openrouter(system_prompt, query, key, @openrouter_model, @openrouter_fallback)
            end
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
    CircuitBreaker.call(:llm_service, fn ->
      do_analyze_image(image_data, prompt, opts)
    end)
  end

  defp do_analyze_image(image_data, prompt, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, 500)

    case openrouter_api_key() do
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
           receive_timeout: 30_000
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
  @spec get_embedding(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def get_embedding(text, opts \\ []) do
    # Check if we're in test mode
    if Application.get_env(:mimo_mcp, :skip_external_apis, false) do
      # Return a test embedding with the requested dimensions
      dim = Keyword.get(opts, :dimensions, @default_embedding_dim)
      dim = min(dim, @max_embedding_dim)
      {:ok, List.duplicate(0.1, dim)}
    else
      CircuitBreaker.call(:ollama_service, fn ->
        do_get_embedding(text, opts)
      end)
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
           receive_timeout: 30_000
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
    if Application.get_env(:mimo_mcp, :skip_external_apis, false) do
      dim = Keyword.get(opts, :dimensions, @default_embedding_dim)
      dim = min(dim, @max_embedding_dim)
      {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, dim) end)}
    else
      CircuitBreaker.call(:ollama_service, fn ->
        do_get_embeddings(texts, opts)
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
           receive_timeout: 60_000
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
  # Utility Functions
  # =============================================================================

  @doc """
  Check if LLM services are available.
  """
  def available? do
    cerebras_api_key() != nil or openrouter_api_key() != nil
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
        embedding_dim: @default_embedding_dim
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
