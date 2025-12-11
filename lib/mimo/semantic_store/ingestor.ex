defmodule Mimo.SemanticStore.Ingestor do
  @moduledoc """
  Text-to-Triple ingestion pipeline with entity resolution.

  Converts natural language text into canonical triples by:
  1. Extracting relationships via LLM
  2. Resolving entity mentions to canonical IDs
  3. Storing triples with provenance
  4. Triggering async inference
  """

  require Logger
  alias Mimo.SemanticStore.{Resolver, Repository, Dreamer}
  alias Mimo.Brain.LLM

  @extraction_prompt """
  Extract all factual relationships from the following text.
  Return a JSON array of objects with: subject, predicate, object.

  Use simple predicates like: depends_on, contains, reports_to, owns, uses, is_a, located_in.

  Text: 
  """

  # Regex patterns for LLM-free relationship extraction
  @doc false
  def relationship_patterns do
    [
      # "X depends on Y", "X depends_on Y"
      {~r/(\w+[\w\s]*?)\s+depends[\s_]on\s+(\w+[\w\s]*)/i, "depends_on"},
      # "X uses Y"
      {~r/(\w+[\w\s]*?)\s+uses\s+(\w+[\w\s]*)/i, "uses"},
      # "X is a Y", "X is an Y"
      {~r/(\w+[\w\s]*?)\s+is\s+an?\s+(\w+[\w\s]*)/i, "is_a"},
      # "X contains Y"
      {~r/(\w+[\w\s]*?)\s+contains\s+(\w+[\w\s]*)/i, "contains"},
      # "X reports to Y"
      {~r/(\w+[\w\s]*?)\s+reports[\s_]to\s+(\w+[\w\s]*)/i, "reports_to"},
      # "X implements Y"
      {~r/(\w+[\w\s]*?)\s+implements\s+(\w+[\w\s]*)/i, "implements"},
      # "X replaces Y"
      {~r/(\w+[\w\s]*?)\s+replaces\s+(\w+[\w\s]*)/i, "replaces"},
      # "X introduces Y"
      {~r/(\w+[\w\s]*?)\s+introduces\s+(\w+[\w\s]*)/i, "introduces"},
      # "X requires Y"
      {~r/(\w+[\w\s]*?)\s+requires\s+(\w+[\w\s]*)/i, "requires"},
      # "X extends Y"
      {~r/(\w+[\w\s]*?)\s+extends\s+(\w+[\w\s]*)/i, "extends"},
      # "X calls Y"
      {~r/(\w+[\w\s]*?)\s+calls\s+(\w+[\w\s]*)/i, "calls"},
      # "X imports Y"
      {~r/(\w+[\w\s]*?)\s+imports\s+(\w+[\w\s]*)/i, "imports"}
    ]
  end

  @doc """
  Ingests natural language text and creates semantic triples.

  ## Parameters
    - `text` - Natural language text describing relationships
    - `source` - Source identifier for provenance
    - `opts` - Options:
      - `:graph_id` - Graph namespace (default: "global")

  ## Returns
    - `{:ok, count}` - Number of triples created
    - `{:error, reason}` - Ingestion failed
  """
  @spec ingest_text(String.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def ingest_text(text, source, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    graph_id = Keyword.get(opts, :graph_id, "global")

    result =
      with {:ok, extracted} <- extract_relationships(text),
           {:ok, triples} <- resolve_and_structure(extracted, source, graph_id),
           {:ok, count} <- store_triples(triples) do
        # Trigger async operations
        schedule_async_tasks(triples, graph_id)

        duration_ms = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:mimo, :semantic_store, :ingest],
          %{duration_ms: duration_ms},
          %{triple_count: count, source: source, graph_id: graph_id, method: "text"}
        )

        {:ok, count}
      end

    result
  end

  @doc """
  Ingests a structured triple directly (no LLM extraction).

  ## Parameters
    - `triple` - Map with :subject, :predicate, :object keys
    - `source` - Source identifier
    - `opts` - Options
  """
  @spec ingest_triple(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ingest_triple(triple, source, opts \\ []) do
    graph_id = Keyword.get(opts, :graph_id, "global")

    with {:ok, subject_id} <-
           Resolver.resolve_entity(triple.subject, :auto, graph_id: graph_id, create_anchor: true),
         {:ok, object_id} <-
           Resolver.resolve_entity(triple.object, :auto, graph_id: graph_id, create_anchor: true) do
      # Extract types from canonical IDs (format: "type:name")
      {subject_type, _} = extract_type_from_id(subject_id)
      {object_type, _} = extract_type_from_id(object_id)

      structured = %{
        subject_id: subject_id,
        subject_type: subject_type,
        predicate: normalize_predicate(triple.predicate),
        object_id: object_id,
        object_type: object_type,
        graph_id: graph_id,
        context: %{
          "source" => source,
          "method" => "direct_ingestion",
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }

      # Use upsert to handle duplicate triples gracefully
      # This prevents Ecto.ConstraintError from crashing the MCP server
      case Repository.upsert(structured) do
        {:ok, record} ->
          Dreamer.schedule_inference(graph_id)
          {:ok, record.id}

        {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
          # Extract error message from changeset
          errors =
            Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
              Enum.reduce(opts, msg, fn {key, value}, acc ->
                String.replace(acc, "%{#{key}}", to_string(value))
              end)
            end)

          {:error, "Validation failed: #{inspect(errors)}"}

        error ->
          error
      end
    else
      {:error, :ambiguous, candidates} ->
        {:error,
         "Ambiguous entity: multiple matches found (#{Enum.join(candidates, ", ")}). Use specific entity format like 'entity:name' or 'concept:name'."}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, "Failed to resolve entities: #{inspect(other)}"}
    end
  end

  @doc """
  Batch ingests multiple triples.
  """
  @spec ingest_batch([map()], String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def ingest_batch(triples, source, opts \\ []) do
    results =
      Enum.map(triples, fn triple ->
        ingest_triple(triple, source, opts)
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, success_count}
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp extract_relationships(text) do
    # First, try regex-based extraction (fast, no API needed)
    case extract_with_regex(text) do
      {:ok, [_ | _] = triples} ->
        Logger.debug("Extracted #{length(triples)} relationships using regex patterns")
        {:ok, triples}

      _ ->
        # Fallback to LLM extraction
        extract_with_llm(text)
    end
  end

  @doc """
  Extract relationships from text using regex patterns.
  Public API for use by KnowledgeSyncer and tests.
  """
  def extract_with_regex(text) do
    triples =
      relationship_patterns()
      |> Enum.flat_map(fn {pattern, predicate} ->
        Regex.scan(pattern, text)
        |> Enum.map(fn
          [_, subject, object] ->
            %{
              "subject" => String.trim(subject),
              "predicate" => predicate,
              "object" => String.trim(object)
            }

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.uniq_by(fn t -> {t["subject"], t["predicate"], t["object"]} end)

    {:ok, triples}
  end

  defp extract_with_llm(text) do
    prompt = @extraction_prompt <> text

    case LLM.complete(prompt, format: :json) do
      {:ok, response} ->
        parse_extraction_response(response)

      {:error, :no_api_key} ->
        Logger.warning("No LLM API key configured - using regex-only extraction")
        # Return empty list to allow graceful degradation
        {:ok, []}

      {:error, reason} ->
        Logger.warning("LLM extraction failed: #{inspect(reason)}")

        {:error,
         "LLM extraction failed: #{inspect(reason)}. Try using subject+predicate+object format."}
    end
  end

  defp parse_extraction_response(response) do
    # Try to extract JSON from the response (LLM might include markdown or extra text)
    json_str = extract_json_from_response(response)

    case Jason.decode(json_str) do
      {:ok, list} when is_list(list) ->
        valid =
          Enum.filter(list, fn item ->
            is_map(item) and
              Map.has_key?(item, "subject") and
              Map.has_key?(item, "predicate") and
              Map.has_key?(item, "object")
          end)

        {:ok, valid}

      {:ok, %{"relationships" => list}} when is_list(list) ->
        # Handle wrapped format
        valid =
          Enum.filter(list, fn item ->
            is_map(item) and
              Map.has_key?(item, "subject") and
              Map.has_key?(item, "predicate") and
              Map.has_key?(item, "object")
          end)

        {:ok, valid}

      {:ok, _} ->
        {:error,
         "LLM returned invalid format. Expected JSON array of {subject, predicate, object}."}

      {:error, _} ->
        {:error, "Failed to parse LLM response as JSON. Use subject+predicate+object instead."}
    end
  end

  # Extract JSON from LLM response (handles markdown code blocks)
  defp extract_json_from_response(response) when is_binary(response) do
    cond do
      # Check for ```json code block
      String.contains?(response, "```json") ->
        response
        |> String.split("```json")
        |> Enum.at(1, "")
        |> String.split("```")
        |> List.first()
        |> String.trim()

      # Check for ``` code block
      String.contains?(response, "```") ->
        response
        |> String.split("```")
        |> Enum.at(1, response)
        |> String.trim()

      # Try to find JSON array directly
      String.contains?(response, "[") ->
        # Find first [ and last ]
        start_idx = :binary.match(response, "[")
        end_idx = String.reverse(response) |> :binary.match("]")

        case {start_idx, end_idx} do
          {{s, _}, {e, _}} ->
            len = byte_size(response) - s - e
            :binary.part(response, s, len)

          _ ->
            response
        end

      true ->
        response
    end
  end

  defp extract_json_from_response(response), do: inspect(response)

  defp resolve_and_structure(extracted, source, graph_id) do
    triples =
      Enum.reduce_while(extracted, {:ok, []}, fn item, {:ok, acc} ->
        case resolve_single(item, source, graph_id) do
          {:ok, triple} -> {:cont, {:ok, [triple | acc]}}
          # Skip ambiguous
          {:error, :ambiguous, _} -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case triples do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp resolve_single(item, source, graph_id) do
    subject_original =
      Map.get(item, "subject") || Map.get(item, :subject) || Map.get(item, "subject_id") ||
        Map.get(item, :subject_id)

    object_original =
      Map.get(item, "object") || Map.get(item, :object) || Map.get(item, "object_id") ||
        Map.get(item, :object_id)

    with {:ok, subject_id} <-
           Resolver.resolve_entity(subject_original, :auto, graph_id: graph_id, create_anchor: true),
         {:ok, object_id} <-
           Resolver.resolve_entity(object_original, :auto, graph_id: graph_id, create_anchor: true) do
      # Extract types from canonical IDs
      {subject_type, _} = extract_type_from_id(subject_id)
      {object_type, _} = extract_type_from_id(object_id)

      {:ok,
       %{
         subject_id: subject_id,
         subject_type: subject_type,
         predicate:
           normalize_predicate(
             Map.get(item, "predicate") || Map.get(item, :predicate) || Map.get(item, "pred") ||
               Map.get(item, :pred)
           ),
         object_id: object_id,
         object_type: object_type,
         graph_id: graph_id,
         context: %{
           "source" => source,
           "method" => "llm_extraction",
           "original_subject" => subject_original,
           "original_object" => object_original,
           "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }
       }}
    end
  end

  defp store_triples(triples) do
    case Repository.batch_create(triples) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_async_tasks(triples, graph_id) do
    # Ensure all entity anchors exist (async)
    Mimo.Sandbox.run_async(Mimo.Repo, fn ->
      Enum.each(triples, fn t ->
        Resolver.ensure_entity_anchor(
          t.subject_id,
          t.context["original_subject"] || t.subject_id,
          graph_id
        )

        Resolver.ensure_entity_anchor(
          t.object_id,
          t.context["original_object"] || t.object_id,
          graph_id
        )
      end)
    end)

    # Trigger inference
    Dreamer.schedule_inference(graph_id)
  end

  defp normalize_predicate(predicate) do
    predicate
    |> String.downcase()
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/[^a-z0-9_]/, "")
  end

  defp extract_type_from_id(entity_id) do
    case String.split(entity_id, ":", parts: 2) do
      [type, name] -> {type, name}
      _ -> {"entity", entity_id}
    end
  end
end
