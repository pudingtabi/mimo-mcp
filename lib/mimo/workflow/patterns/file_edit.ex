defmodule Mimo.Workflow.Patterns.FileEdit do
  @moduledoc """
  SPEC-053: Pre-defined workflow pattern for file editing.

  This pattern captures the common workflow:
  1. Search memory for related context
  2. Read the target file
  3. Get code symbols for understanding
  4. Apply the edit

  Suitable for: Code modifications, refactoring, feature additions
  """

  alias Mimo.Workflow.Pattern

  @pattern_id "file_edit_v1"
  @pattern_name "file_edit"

  @doc """
  Returns the file edit workflow pattern.
  """
  @spec pattern() :: Pattern.t()
  def pattern do
    %Pattern{
      id: @pattern_id,
      name: @pattern_name,
      category: :file_operations,
      description: """
      Edit files with full context awareness. Gathers memory context,
      reads the file, analyzes symbols, and applies surgical edits.
      """,
      preconditions: [
        %{
          type: :file_exists,
          params: %{},
          description: "Target file must exist"
        }
      ],
      steps: [
        %{
          "tool" => "memory",
          "operation" => "search",
          "params" => %{
            "limit" => 3
          },
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.target_file",
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
              "path" => "$.target_file",
              "target_param" => "path"
            }
          ]
        },
        %{
          "tool" => "code",
          "operation" => "symbols",
          "params" => %{},
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.target_file",
              "target_param" => "path"
            }
          ]
        },
        %{
          "tool" => "file",
          "operation" => "edit",
          "params" => %{},
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.target_file",
              "target_param" => "path"
            },
            %{
              "source" => "global_context",
              "path" => "$.old_content",
              "target_param" => "old_str"
            },
            %{
              "source" => "global_context",
              "path" => "$.new_content",
              "target_param" => "new_str"
            }
          ]
        }
      ],
      success_rate: 0.90,
      avg_token_savings: 800,
      usage_count: 0,
      confidence_threshold: 0.80,
      tags: ["editing", "file-operations", "code-modification"],
      created_from: ["seed"],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
end
