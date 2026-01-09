defmodule Mimo.Learning.WebFallback do
  @moduledoc """
  SPEC-096: Synergy P5 - Web fallback when memory search finds nothing.

  When memory.search or memory.synthesize returns empty/low-quality results,
  this module can automatically search the web and optionally store findings.

  ## Usage

      # Check if fallback is needed and perform it
      case WebFallback.maybe_fallback(query, memory_results) do
        {:hit, results} -> # Memory had results, no fallback needed
        {:web_fallback, web_results} -> # Fell back to web search
        {:miss, :no_results} -> # Both memory and web found nothing
      end
  """

  require Logger

  alias Mimo.Brain.Memory
  alias Mimo.Tools.Dispatchers.Web

  @doc """
  Check if web fallback is needed and perform it.

  Returns:
  - `{:hit, results}` - Memory had sufficient results
  - `{:web_fallback, results}` - Fell back to web, found results
  - `{:miss, :no_results}` - Both memory and web found nothing
  """
  def maybe_fallback(query, memory_results, opts \\ []) do
    min_results = Keyword.get(opts, :min_results, 1)
    store_to_memory = Keyword.get(opts, :store_to_memory, true)

    cond do
      # Memory had sufficient results
      is_list(memory_results) and length(memory_results) >= min_results ->
        {:hit, memory_results}

      # No results or insufficient - try web fallback
      true ->
        Logger.info("[P5 Synergy] Memory miss for: #{String.slice(query, 0, 50)}... trying web")
        perform_web_fallback(query, store_to_memory, opts)
    end
  end

  @doc """
  Perform web search fallback and optionally store results.
  """
  def perform_web_fallback(query, store_to_memory, opts \\ []) do
    max_results = Keyword.get(opts, :max_web_results, 3)

    case Web.dispatch(%{"operation" => "search", "query" => query, "num_results" => max_results}) do
      {:ok, %{results: results}} when is_list(results) and results != [] ->
        Logger.info("[P5 Synergy] Web found #{length(results)} results")

        # Optionally store to memory for future queries
        if store_to_memory do
          store_web_results(query, results)
        end

        {:web_fallback, format_web_results(results)}

      {:ok, %{items: results}} when is_list(results) and results != [] ->
        Logger.info("[P5 Synergy] Web found #{length(results)} results")

        if store_to_memory do
          store_web_results(query, results)
        end

        {:web_fallback, format_web_results(results)}

      _ ->
        Logger.debug("[P5 Synergy] Web search also found nothing for: #{query}")
        {:miss, :no_results}
    end
  end

  defp format_web_results(results) do
    Enum.map(results, fn r ->
      %{
        title: r[:title] || r["title"] || "Untitled",
        snippet: r[:snippet] || r["snippet"] || r[:description] || r["description"] || "",
        url: r[:url] || r["url"] || "",
        source: :web_fallback
      }
    end)
  end

  defp store_web_results(query, results) do
    # Take top result and store as memory for future
    case List.first(results) do
      nil ->
        :ok

      result ->
        title = result[:title] || result["title"] || "Web result"
        snippet = result[:snippet] || result["snippet"] || result[:description] || ""
        url = result[:url] || result["url"] || ""

        content = """
        Web search result for: #{query}
        Title: #{title}
        Summary: #{String.slice(snippet, 0, 500)}
        Source: #{url}
        Cached via P5 Synergy on #{Date.to_string(Date.utc_today())}
        """

        Memory.store(%{
          content: content,
          type: "fact",
          metadata: %{
            "source" => "web_fallback",
            "query" => query,
            "url" => url
          }
        })

        Logger.debug("[P5 Synergy] Cached web result for: #{query}")
    end
  rescue
    _ -> :ok
  end
end
