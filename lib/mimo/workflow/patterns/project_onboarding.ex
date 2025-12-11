defmodule Mimo.Workflow.Patterns.ProjectOnboarding do
  @moduledoc """
  SPEC-053: Pre-defined workflow pattern for project onboarding.

  This pattern captures the common workflow:
  1. Index code symbols
  2. Discover dependencies
  3. Build knowledge graph
  4. Store project context in memory

  Suitable for: New projects, session starts, project structure changes
  """

  alias Mimo.Workflow.Pattern

  @pattern_id "project_onboarding_v1"
  @pattern_name "project_onboarding"

  @doc """
  Returns the project onboarding workflow pattern.
  """
  @spec pattern() :: Pattern.t()
  def pattern do
    %Pattern{
      id: @pattern_id,
      name: @pattern_name,
      category: :project_setup,
      description: """
      Initialize project context for optimal tool performance.
      Indexes symbols, discovers dependencies, and builds knowledge graph.
      """,
      preconditions: [
        %{
          type: :file_exists,
          params: %{check: "project_root"},
          description: "Project root must exist"
        }
      ],
      steps: [
        %{
          "tool" => "code",
          "operation" => "index",
          "params" => %{},
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.project_path",
              "target_param" => "path"
            }
          ],
          "timeout_ms" => 120_000
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
          ],
          "timeout_ms" => 60_000
        },
        %{
          "tool" => "knowledge",
          "operation" => "link",
          "params" => %{},
          "dynamic_bindings" => [
            %{
              "source" => "global_context",
              "path" => "$.project_path",
              "target_param" => "path"
            }
          ],
          "timeout_ms" => 60_000
        },
        %{
          "tool" => "memory",
          "operation" => "store",
          "params" => %{
            "category" => "fact",
            "importance" => 0.9,
            "content" => "Project onboarded successfully"
          },
          "dynamic_bindings" => []
        }
      ],
      success_rate: 0.92,
      avg_token_savings: 3000,
      usage_count: 0,
      confidence_threshold: 0.85,
      tags: ["onboarding", "initialization", "project-setup"],
      created_from: ["seed"],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
end
