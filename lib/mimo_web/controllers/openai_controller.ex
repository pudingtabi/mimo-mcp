defmodule MimoWeb.OpenAIController do
  @moduledoc """
  OpenAI-compatible endpoint for the Universal Aperture.
  
  Exposes a drop-in replacement for OpenAI's /v1/chat/completions endpoint.
  Clients believe they are talking to a generative model; in reality, they
  invoke Mimo's Meta-Cognitive Router and Memory Stores as functions.
  
  Strategy: Mimo does NOT generate text. It returns a `tool_calls` array,
  forcing the client to invoke Mimo's memory functions. The client (e.g., LangChain)
  then re-calls Mimo with the function result for synthesis.
  """
  use MimoWeb, :controller
  require Logger

  @model_name "mimo-polymorphic-1"
  @model_description "Mimo Memory OS - Polymorphic Intelligence via Triad Stores"

  # Mimo tools exposed as OpenAI functions
  @mimo_functions [
    %{
      "type" => "function",
      "function" => %{
        "name" => "mimo_search_memory",
        "description" => "Search Mimo's memory stores for relevant context",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "The search query"},
            "store" => %{
              "type" => "string",
              "enum" => ["episodic", "semantic", "procedural", "auto"],
              "description" => "Which memory store to search (auto lets the router decide)"
            }
          },
          "required" => ["query"]
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "mimo_store_fact",
        "description" => "Store a new fact or memory in Mimo's brain",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string", "description" => "The content to store"},
            "category" => %{
              "type" => "string",
              "enum" => ["fact", "observation", "action", "plan"]
            },
            "importance" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
          },
          "required" => ["content", "category"]
        }
      }
    }
  ]

  @doc """
  GET /v1/models
  
  Returns available models (OpenAI-compatible format).
  """
  def models(conn, _params) do
    json(conn, %{
      "object" => "list",
      "data" => [
        %{
          "id" => @model_name,
          "object" => "model",
          "created" => 1700000000,
          "owned_by" => "mimo",
          "description" => @model_description
        }
      ]
    })
  end

  @doc """
  POST /v1/chat/completions
  
  OpenAI-compatible chat completions endpoint.
  
  Request body (OpenAI format):
    - model: Model name (ignored, always uses mimo-polymorphic-1)
    - messages: Array of chat messages
    - tools: Optional array of function definitions
    - tool_choice: "auto", "none", or specific function
  
  Response (OpenAI format):
    - Returns tool_calls to force memory function invocation
    - Or returns synthesized content if tools array is empty
  """
  def create(conn, params) do
    messages = Map.get(params, "messages", [])
    tools = Map.get(params, "tools", [])
    tool_choice = Map.get(params, "tool_choice", "auto")

    user_query = extract_last_user_message(messages)

    if is_nil(user_query) or user_query == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: %{message: "No user message found in messages array"}})
    else
      # Check if this is a tool result callback
      case extract_tool_results(messages) do
        {:ok, tool_results} when tool_results != [] ->
          # Client is returning tool results, synthesize response
          handle_tool_results(conn, user_query, tool_results)

        _ ->
          # Initial request, return tool_calls
          handle_initial_request(conn, user_query, tools, tool_choice)
      end
    end
  end

  defp handle_initial_request(conn, user_query, tools, tool_choice) do
    # Use Meta-Cognitive Router to decide which function to call
    router_decision = Mimo.MetaCognitiveRouter.classify(user_query)

    store = case router_decision.primary_store do
      :episodic -> "episodic"
      :semantic -> "semantic"
      :procedural -> "procedural"
      _ -> "auto"
    end

    # If tools is empty and tool_choice is "none", return synthesized text directly
    if Enum.empty?(tools) and tool_choice == "none" do
      handle_direct_response(conn, user_query, router_decision)
    else
      # Return tool_calls to force client to invoke memory functions
      tool_call = %{
        "id" => "call_#{UUID.uuid4()}",
        "type" => "function",
        "function" => %{
          "name" => "mimo_search_memory",
          "arguments" => Jason.encode!(%{
            "query" => user_query,
            "store" => store
          })
        }
      }

      response = %{
        "id" => "chatcmpl-#{UUID.uuid4()}",
        "object" => "chat.completion",
        "created" => System.os_time(:second),
        "model" => @model_name,
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [tool_call]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{
          "prompt_tokens" => String.length(user_query),
          "completion_tokens" => 0,
          "total_tokens" => String.length(user_query)
        }
      }

      json(conn, response)
    end
  end

  defp handle_tool_results(conn, original_query, tool_results) do
    # Synthesize response from tool results
    memories = Enum.flat_map(tool_results, fn result ->
      case Jason.decode(result) do
        {:ok, %{"data" => data}} when is_list(data) -> data
        {:ok, data} when is_list(data) -> data
        _ -> []
      end
    end)

    # Use LLM to synthesize if configured
    synthesis = case Mimo.Brain.LLM.consult_chief_of_staff(original_query, memories) do
      {:ok, response} -> response
      {:error, _} -> format_memories_as_text(memories)
    end

    response = %{
      "id" => "chatcmpl-#{UUID.uuid4()}",
      "object" => "chat.completion",
      "created" => System.os_time(:second),
      "model" => @model_name,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => synthesis
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => String.length(original_query),
        "completion_tokens" => String.length(synthesis),
        "total_tokens" => String.length(original_query) + String.length(synthesis)
      }
    }

    json(conn, response)
  end

  defp handle_direct_response(conn, query, router_decision) do
    # Direct response without tool calling (compatibility mode)
    memories = Mimo.Brain.Memory.search_memories(query, limit: 5)

    synthesis = case Mimo.Brain.LLM.consult_chief_of_staff(query, memories) do
      {:ok, response} -> response
      {:error, _} -> 
        "Based on #{router_decision.primary_store} store analysis: #{format_memories_as_text(memories)}"
    end

    response = %{
      "id" => "chatcmpl-#{UUID.uuid4()}",
      "object" => "chat.completion",
      "created" => System.os_time(:second),
      "model" => @model_name,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => synthesis
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => String.length(query),
        "completion_tokens" => String.length(synthesis),
        "total_tokens" => String.length(query) + String.length(synthesis)
      }
    }

    json(conn, response)
  end

  defp extract_last_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      _ -> nil
    end)
  end

  defp extract_tool_results(messages) do
    results = messages
    |> Enum.filter(fn
      %{"role" => "tool", "content" => _} -> true
      _ -> false
    end)
    |> Enum.map(fn %{"content" => content} -> content end)

    {:ok, results}
  end

  defp format_memories_as_text(memories) when is_list(memories) do
    if Enum.empty?(memories) do
      "No relevant memories found."
    else
      memories
      |> Enum.take(5)
      |> Enum.map(fn m ->
        content = m[:content] || Map.get(m, "content", "")
        category = m[:category] || Map.get(m, "category", "memory")
        "• [#{category}] #{content}"
      end)
      |> Enum.join("\n")
    end
  end
end
