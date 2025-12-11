defmodule Mimo.Workflow.Patterns.DebugError do
  @moduledoc """
  SPEC-053: Pre-defined workflow pattern for debugging errors.

  This pattern captures the common workflow:
  1. Get diagnostics
  2. Search memory for past solutions
  3. Read the relevant file
  4. Apply reasoning to fix

  Suitable for: Compilation errors, runtime errors, type errors
  """

  alias Mimo.Workflow.Pattern

  @pattern_id "debug_error_v1"
  @pattern_name "debug_error"

  @doc """
  Returns the debug error workflow pattern.
  """
  @spec pattern() :: Pattern.t()
  def pattern do
    %Pattern{
      id: @pattern_id,
      name: @pattern_name,
      category: :debugging,
      description: """
      Debug and fix code errors using diagnostics, memory search, and guided reasoning.
      Automatically gathers context from past solutions and applies step-by-step debugging.
      """,
      preconditions: [
        %{
          type: :custom,
          params: %{check: "error_message_present"},
          description: "An error message or diagnostic must be available"
        }
      ],
      steps: [
        %{
          "tool" => "code",
          "operation" => "diagnose",
          "params" => %{},
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.current_file",
              "target_param" => "path"
            }
          ],
          "timeout_ms" => 30_000
        },
        %{
          "tool" => "memory",
          "operation" => "search",
          "params" => %{
            "limit" => 5
          },
          "dynamic_bindings" => [
            %{
              "source" => "previous_output",
              "path" => "$.errors[0].message",
              "target_param" => "query"
            }
          ]
        },
        %{
          "tool" => "file",
          "operation" => "read",
          "params" => %{},
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.error_location.file",
              "target_param" => "path"
            }
          ]
        },
        %{
          "tool" => "reason",
          "operation" => "guided",
          "params" => %{
            "strategy" => "reflexion"
          },
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.error_message",
              "target_param" => "problem"
            }
          ]
        }
      ],
      success_rate: 0.85,
      avg_token_savings: 1500,
      usage_count: 0,
      confidence_threshold: 0.75,
      tags: ["debugging", "error-handling", "code-fix"],
      created_from: ["seed"],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
end
