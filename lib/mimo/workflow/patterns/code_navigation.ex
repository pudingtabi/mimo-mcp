defmodule Mimo.Workflow.Patterns.CodeNavigation do
  @moduledoc """
  SPEC-053: Pre-defined workflow pattern for code navigation.

  This pattern captures the common workflow:
  1. Find symbol definition
  2. Get symbol references
  3. Analyze call graph
  4. Store findings in memory

  Suitable for: Understanding code, finding usages, dependency analysis
  """

  alias Mimo.Workflow.Pattern

  @pattern_id "code_navigation_v1"
  @pattern_name "code_navigation"

  @doc """
  Returns the code navigation workflow pattern.
  """
  @spec pattern() :: Pattern.t()
  def pattern do
    %Pattern{
      id: @pattern_id,
      name: @pattern_name,
      category: :code_navigation,
      description: """
      Navigate and understand code structure. Finds definitions,
      references, and call relationships for symbols.
      """,
      preconditions: [
        %{
          type: :code_symbol_defined,
          params: %{},
          description: "A symbol name must be provided"
        }
      ],
      steps: [
        %{
          "tool" => "code",
          "operation" => "definition",
          "params" => %{},
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.symbol_name",
              "target_param" => "name"
            }
          ]
        },
        %{
          "tool" => "code",
          "operation" => "references",
          "params" => %{
            "limit" => 20
          },
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.symbol_name",
              "target_param" => "name"
            }
          ]
        },
        %{
          "tool" => "code",
          "operation" => "call_graph",
          "params" => %{},
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.symbol_name",
              "target_param" => "name"
            }
          ]
        },
        %{
          "tool" => "memory",
          "operation" => "store",
          "params" => %{
            "category" => "fact",
            "importance" => 0.7
          },
          "dynamic_bindings" => [
            %{
              "source" => "previous_output",
              "path" => "$",
              "target_param" => "content"
            }
          ]
        }
      ],
      success_rate: 0.88,
      avg_token_savings: 1200,
      usage_count: 0,
      confidence_threshold: 0.75,
      tags: ["navigation", "code-analysis", "understanding"],
      created_from: ["seed"],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
end
