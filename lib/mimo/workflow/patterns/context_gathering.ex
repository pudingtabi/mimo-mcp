defmodule Mimo.Workflow.Patterns.ContextGathering do
  @moduledoc """
  SPEC-053: Pre-defined workflow pattern for context gathering.

  This pattern captures the common workflow:
  1. Search memory for relevant context
  2. Query knowledge graph for relationships
  3. Discover library documentation
  4. Prepare aggregated context

  Suitable for: Complex tasks, unfamiliar codebases, architecture questions
  """

  alias Mimo.Workflow.Pattern

  @pattern_id "context_gathering_v1"
  @pattern_name "context_gathering"

  @doc """
  Returns the context gathering workflow pattern.
  """
  @spec pattern() :: Pattern.t()
  def pattern do
    %Pattern{
      id: @pattern_id,
      name: @pattern_name,
      category: :context_gathering,
      description: """
      Comprehensive context gathering for complex tasks.
      Aggregates memory, knowledge graph, and library documentation in parallel.
      """,
      preconditions: [
        %{
          type: :custom,
          params: %{check: "task_description_present"},
          description: "A task description or query must be provided"
        }
      ],
      steps: [
        %{
          "tool" => "memory",
          "operation" => "search",
          "params" => %{
            "limit" => 10
          },
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.task_description",
              "target_param" => "query"
            }
          ]
        },
        %{
          "tool" => "knowledge",
          "operation" => "query",
          "params" => %{
            "limit" => 10
          },
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.task_description",
              "target_param" => "query"
            }
          ]
        },
        %{
          "tool" => "code",
          "operation" => "library_discover",
          "params" => %{},
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.project_path",
              "target_param" => "path"
            }
          ]
        }
      ],
      success_rate: 0.95,
      avg_token_savings: 2000,
      usage_count: 0,
      confidence_threshold: 0.70,
      tags: ["context", "preparation", "complex-tasks"],
      created_from: ["seed"],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
end
