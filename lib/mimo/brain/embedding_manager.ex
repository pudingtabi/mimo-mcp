defmodule Mimo.Brain.EmbeddingManager do
  @moduledoc """
  Unified embedding manager with HONEST fallback provider chain.

  Provider hierarchy:
  1. Ollama (local, fast, free) - qwen3-embedding
  2. OpenRouter (remote, fallback) - Uses embedding models with real semantics

  If both providers fail, returns `{:error, :all_providers_failed}` instead of
  degrading to meaningless placeholder vectors. This is HONEST behavior.

  ## Usage

      iex> EmbeddingManager.generate("Hello world")
      {:ok, [0.1, 0.2, ...], :ollama}

      iex> EmbeddingManager.generate("Hello world", provider: :openrouter)
      {:ok, [0.1, 0.2, ...], :openrouter}

      # When all providers fail:
      {:error, :all_providers_failed}

  ## Configuration

      config :mimo_mcp,
        embedding_dimension: 256,
        embedding_fallback_enabled: true,
        openrouter_embedding_model: "thenlper/gte-base"
  """

  require Logger

  alias Mimo.ErrorHandling.CircuitBreaker

  # Provider configuration
  @ollama_url Application.compile_env(:mimo_mcp, :ollama_url, "http://localhost:11434")
  @openrouter_url "https://openrouter.ai/api/v1/embeddings"
  @openrouter_embedding_model Application.compile_env(
                                :mimo_mcp,
                                :openrouter_embedding_model,
                                "thenlper/gte-base"
                              )

  @default_dim Application.compile_env(:mimo_mcp, :embedding_dim, 256)
  @max_dim 1024

  @doc """
  Generate embedding with automatic fallback.

  Returns `{:ok, embedding, provider}` or `{:error, reason}`.

  ## Options
    - `:provider` - Force specific provider (:ollama, :openrouter)
    - `:dimensions` - Output dimensions (default: 256)
    - `:fallback` - Enable fallback chain (default: true)
  """
  @spec generate(String.t(), keyword()) ::
          {:ok, [float()], atom()} | {:error, term()}
  def generate(text, opts \\ []) do
    provider = Keyword.get(opts, :provider, :auto)
    fallback_enabled = Keyword.get(opts, :fallback, true)
    use_cache = Keyword.get(opts, :cache, true)
    dimensions = Keyword.get(opts, :dimensions, @default_dim) |> min(@max_dim)

    opts = Keyword.put(opts, :dimensions, dimensions)

    # Check cache first (SPEC-061 optimization)
    if use_cache do
      case Mimo.Cache.Embedding.get(text) do
        {:ok, cached_embedding} ->
          {:ok, cached_embedding, :cache}

        :miss ->
          result = do_generate(text, provider, fallback_enabled, opts)

          # Cache successful result
          case result do
            {:ok, embedding, _provider} ->
              Mimo.Cache.Embedding.put(text, embedding)
              result

            error ->
              error
          end
      end
    else
      do_generate(text, provider, fallback_enabled, opts)
    end
  end

  # Internal generation without cache
  defp do_generate(text, provider, fallback_enabled, opts) do
    case provider do
      :ollama ->
        try_ollama(text, opts)

      :openrouter ->
        try_openrouter(text, opts)

      :auto ->
        try_with_fallback(text, opts, fallback_enabled)

      other ->
        {:error, {:unknown_provider, other}}
    end
  end

  @doc """
  Generate embeddings for multiple texts (batch).

  More efficient than calling generate/2 multiple times.
  """
  @spec generate_batch([String.t()], keyword()) ::
          {:ok, [[float()]], atom()} | {:error, term()}
  def generate_batch(texts, opts \\ []) when is_list(texts) do
    dimensions = Keyword.get(opts, :dimensions, @default_dim) |> min(@max_dim)
    opts = Keyword.put(opts, :dimensions, dimensions)

    case try_ollama_batch(texts, opts) do
      {:ok, embeddings, provider} ->
        {:ok, embeddings, provider}

      {:error, _reason} ->
        # Fallback to individual generation
        results =
          Enum.map(texts, fn text ->
            case generate(text, opts) do
              {:ok, emb, _provider} -> {:ok, emb}
              error -> error
            end
          end)

        if Enum.all?(results, &match?({:ok, _}, &1)) do
          embeddings = Enum.map(results, fn {:ok, emb} -> emb end)
          {:ok, embeddings, :fallback_batch}
        else
          {:error, :batch_failed}
        end
    end
  end

  @doc """
  Get current provider status.
  """
  @spec provider_status() :: map()
  def provider_status do
    ollama_ok = ollama_available?()
    openrouter_ok = openrouter_api_key() != nil

    %{
      ollama: %{
        available: ollama_ok,
        url: get_ollama_url(),
        model: get_ollama_model()
      },
      openrouter: %{
        available: openrouter_ok,
        model: @openrouter_embedding_model
      },
      any_available: ollama_ok or openrouter_ok,
      default_dimensions: @default_dim
    }
  end

  defp try_with_fallback(text, opts, fallback_enabled) do
    # Try Ollama first
    case try_ollama(text, opts) do
      {:ok, embedding, provider} ->
        {:ok, embedding, provider}

      {:error, ollama_error} ->
        if fallback_enabled do
          Logger.warning(
            "[EmbeddingManager] Ollama failed (#{inspect(ollama_error)}), trying OpenRouter"
          )

          # Try OpenRouter - our only fallback with real semantics
          case try_openrouter(text, opts) do
            {:ok, embedding, provider} ->
              {:ok, embedding, provider}

            {:error, openrouter_error} ->
              # HONEST FAILURE: No silent degradation to meaningless vectors
              Logger.error(
                "[EmbeddingManager] All providers failed. Ollama: #{inspect(ollama_error)}, OpenRouter: #{inspect(openrouter_error)}"
              )

              {:error, :all_providers_failed}
          end
        else
          {:error, ollama_error}
        end
    end
  end

  defp try_ollama(text, opts) do
    # Check if in test mode
    if Application.get_env(:mimo_mcp, :skip_external_apis, false) do
      dimensions = Keyword.get(opts, :dimensions, @default_dim)
      {:ok, List.duplicate(0.1, dimensions), :test}
    else
      # Note: Circuit breaker is registered as :ollama, not :ollama_service
      CircuitBreaker.call(:ollama, fn ->
        do_ollama_embedding(text, opts)
      end)
      |> case do
        {:ok, embedding} -> {:ok, embedding, :ollama}
        error -> error
      end
    end
  end

  defp try_ollama_batch(texts, opts) do
    if Application.get_env(:mimo_mcp, :skip_external_apis, false) do
      dimensions = Keyword.get(opts, :dimensions, @default_dim)
      embeddings = Enum.map(texts, fn _ -> List.duplicate(0.1, dimensions) end)
      {:ok, embeddings, :test}
    else
      # Note: Circuit breaker is registered as :ollama, not :ollama_service
      CircuitBreaker.call(:ollama, fn ->
        do_ollama_batch_embedding(texts, opts)
      end)
      |> case do
        {:ok, embeddings} -> {:ok, embeddings, :ollama}
        error -> error
      end
    end
  end

  defp try_openrouter(text, opts) do
    case openrouter_api_key() do
      nil ->
        {:error, :no_openrouter_key}

      api_key ->
        CircuitBreaker.call(:llm_service, fn ->
          do_openrouter_embedding(text, api_key, opts)
        end)
        |> case do
          {:ok, embedding} -> {:ok, embedding, :openrouter}
          error -> error
        end
    end
  end

  defp do_ollama_embedding(text, opts) do
    model = get_ollama_model()
    dimensions = Keyword.get(opts, :dimensions, @default_dim)
    url = get_ollama_url()

    body = %{
      "model" => model,
      "input" => sanitize_text(text)
    }

    case Req.post("#{url}/api/embed",
           json: body,
           receive_timeout: Mimo.TimeoutConfig.embedding_timeout()
         ) do
      {:ok, %Req.Response{status: 200, body: %{"embeddings" => [embedding | _]}}}
      when is_list(embedding) ->
        {:ok, Enum.take(embedding, dimensions)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:ollama_error, status, body}}

      {:error, reason} ->
        {:error, {:ollama_unavailable, reason}}
    end
  end

  defp do_ollama_batch_embedding(texts, opts) do
    model = get_ollama_model()
    dimensions = Keyword.get(opts, :dimensions, @default_dim)
    url = get_ollama_url()

    sanitized = Enum.map(texts, &sanitize_text/1)

    body = %{
      "model" => model,
      "input" => sanitized
    }

    case Req.post("#{url}/api/embed",
           json: body,
           receive_timeout: Mimo.TimeoutConfig.embedding_timeout()
         ) do
      {:ok, %Req.Response{status: 200, body: %{"embeddings" => embeddings}}}
      when is_list(embeddings) ->
        truncated = Enum.map(embeddings, &Enum.take(&1, dimensions))
        {:ok, truncated}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:ollama_error, status, body}}

      {:error, reason} ->
        {:error, {:ollama_unavailable, reason}}
    end
  end

  defp do_openrouter_embedding(text, api_key, opts) do
    dimensions = Keyword.get(opts, :dimensions, @default_dim)

    body = %{
      "model" => @openrouter_embedding_model,
      "input" => sanitize_text(text)
    }

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"HTTP-Referer", "https://mimo.local"},
      {"X-Title", "Mimo-Embedding"},
      {"Content-Type", "application/json"}
    ]

    case Req.post(@openrouter_url,
           json: body,
           headers: headers,
           receive_timeout: Mimo.TimeoutConfig.http_timeout()
         ) do
      {:ok, %Req.Response{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]}}}
      when is_list(embedding) ->
        # Pad or truncate to desired dimensions
        adjusted = adjust_dimensions(embedding, dimensions)
        {:ok, adjusted}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:openrouter_error, status, body}}

      {:error, reason} ->
        {:error, {:openrouter_unavailable, reason}}
    end
  end

  # The system now fails clearly with {:error, :all_providers_failed} instead
  # of silently degrading to meaningless placeholder vectors.

  defp sanitize_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.slice(0, 8000)
  end

  defp sanitize_text(_), do: ""

  defp adjust_dimensions(embedding, target) when length(embedding) >= target do
    Enum.take(embedding, target)
  end

  defp adjust_dimensions(embedding, target) do
    # Pad with zeros if embedding is smaller than target
    padding = List.duplicate(0.0, target - length(embedding))
    embedding ++ padding
  end

  defp get_ollama_url do
    Application.get_env(:mimo_mcp, :ollama_url, @ollama_url)
  end

  defp get_ollama_model do
    Application.get_env(:mimo_mcp, :ollama_embedding_model, "qwen3-embedding:0.6b")
  end

  defp openrouter_api_key do
    Application.get_env(:mimo_mcp, :openrouter_api_key) ||
      System.get_env("OPENROUTER_API_KEY")
  end

  defp ollama_available? do
    url = get_ollama_url()

    try do
      case Req.get("#{url}/api/tags", receive_timeout: 5_000) do
        {:ok, %Req.Response{status: 200}} -> true
        _ -> false
      end
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end
end
