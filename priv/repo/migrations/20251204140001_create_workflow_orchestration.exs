defmodule Mimo.Repo.Migrations.CreateWorkflowOrchestration do
  @moduledoc """
  SPEC-053: Intelligent Tool Orchestration & Auto-Chaining
  SPEC-054: Adaptive Workflow Engine for Model Optimization

  Creates tables for:
  - workflow_patterns: Learned workflow patterns from tool usage
  - workflow_tool_logs: Tool usage logging for pattern extraction
  - workflow_executions: Workflow execution history
  - agent_profiles: Agent behavior clustering
  - model_profiles: Model capability profiles
  - adaptive_workflow_templates: Model-specific workflow templates
  - model_workflow_performance: Performance tracking per model-workflow pair
  - capability_benchmarks: Model capability assessment results
  """
  use Ecto.Migration

  def change do
    # =========================================================================
    # SPEC-053: Intelligent Tool Orchestration Tables
    # =========================================================================

    # Workflow patterns - extracted from historical tool usage
    create table(:workflow_patterns, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :category, :string, default: "custom"
      add :preconditions, :map, default: "[]"
      add :steps, :map, null: false, default: "[]"
      add :bindings, :map, default: "[]"
      add :success_rate, :float, default: 0.0
      add :avg_token_savings, :integer, default: 0
      add :usage_count, :integer, default: 0
      add :last_used, :utc_datetime_usec
      add :confidence_threshold, :float, default: 0.7
      add :timeout_ms, :integer
      add :metadata, :map, default: "{}"
      add :tags, {:array, :string}, default: []
      add :created_from, {:array, :string}, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflow_patterns, [:name])
    create index(:workflow_patterns, [:category])
    create index(:workflow_patterns, [:success_rate])
    create index(:workflow_patterns, [:usage_count])
    create index(:workflow_patterns, [:tags])

    # Tool usage logs - for pattern extraction
    create table(:workflow_tool_logs) do
      add :session_id, :string, null: false
      add :tool, :string, null: false
      add :operation, :string, null: false
      add :params, :map
      add :success, :boolean
      add :duration_ms, :integer
      add :token_usage, :integer
      add :context_snapshot, :map
      add :timestamp, :utc_datetime_usec, null: false
    end

    create index(:workflow_tool_logs, [:session_id])
    create index(:workflow_tool_logs, [:tool])
    create index(:workflow_tool_logs, [:timestamp])
    create index(:workflow_tool_logs, [:session_id, :timestamp])

    # Workflow executions - execution history
    create table(:workflow_executions, primary_key: false) do
      add :id, :string, primary_key: true
      add :pattern_id, references(:workflow_patterns, type: :string, on_delete: :nilify_all)
      add :session_id, :string, null: false
      add :bindings, :map
      add :status, :string, null: false, default: "pending"
      add :result, :map
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :metrics, :map, default: "{}"
      add :error, :text
    end

    create index(:workflow_executions, [:pattern_id])
    create index(:workflow_executions, [:session_id])
    create index(:workflow_executions, [:status])
    create index(:workflow_executions, [:started_at])

    # Agent behavior profiles - for personalization
    create table(:agent_profiles, primary_key: false) do
      add :agent_id, :string, primary_key: true
      add :preferred_workflows, :map, default: "{}"
      add :success_rates, :map, default: "{}"
      add :behavior_cluster, :string
      add :tool_preferences, :map, default: "{}"

      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:agent_profiles, [:behavior_cluster])

    # =========================================================================
    # SPEC-054: Adaptive Workflow Engine Tables
    # =========================================================================

    # Model profiles - capability assessment
    create table(:model_profiles, primary_key: false) do
      add :id, :string, primary_key: true
      add :model_family, :string, null: false
      add :model_variant, :string
      add :capabilities, :map, null: false, default: "{}"
      add :optimization_settings, :map, null: false, default: "{}"
      add :performance_benchmarks, :map, null: false, default: "{}"
      add :learned_patterns, :map, null: false, default: "{}"
      add :usage_count, :integer, default: 0
      add :last_benchmarked, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:model_profiles, [:model_family, :model_variant])
    create index(:model_profiles, [:model_family])

    # Adaptive workflow templates - model-specific workflows
    create table(:adaptive_workflow_templates, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :target_models, :map, null: false, default: "[]"
      add :complexity, :string, null: false
      add :steps, :map, null: false, default: "[]"
      add :preconditions, :map, default: "[]"
      add :success_criteria, :map, default: "{}"
      add :adaptation_rules, :map, default: "[]"
      add :base_success_rate, :float, default: 0.0
      add :usage_count, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:adaptive_workflow_templates, [:name])
    create index(:adaptive_workflow_templates, [:complexity])

    # Model-workflow performance tracking
    create table(:model_workflow_performance, primary_key: false) do
      add :model_profile_id, references(:model_profiles, type: :string, on_delete: :delete_all),
        primary_key: true

      add :workflow_template_id,
          references(:adaptive_workflow_templates, type: :string, on_delete: :delete_all),
          primary_key: true

      add :success_count, :integer, default: 0
      add :failure_count, :integer, default: 0
      add :avg_duration_ms, :integer
      add :avg_token_usage, :integer
      add :last_used, :utc_datetime_usec
    end

    create index(:model_workflow_performance, [:model_profile_id])
    create index(:model_workflow_performance, [:workflow_template_id])

    # Capability benchmarks - assessment results
    create table(:capability_benchmarks, primary_key: false) do
      add :model_profile_id, references(:model_profiles, type: :string, on_delete: :delete_all),
        primary_key: true

      add :capability_type, :string, null: false, primary_key: true
      add :score, :float, null: false
      add :confidence, :float, null: false
      add :measured_at, :utc_datetime_usec, null: false
      add :metadata, :map, default: "{}"
    end

    create index(:capability_benchmarks, [:model_profile_id])
    create index(:capability_benchmarks, [:capability_type])
  end
end
