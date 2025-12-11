defmodule Mimo do
  @moduledoc """
  Main module for bootstrapping and lifecycle management.
  """
  require Logger

  @doc """
  Bootstrap all skills from priv/skills.json.
  Called after supervision tree is stable to prevent race conditions.
  """
  def bootstrap_skills do
    path = Application.fetch_env!(:mimo_mcp, :skills_path)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, skills} when is_map(skills) ->
            Logger.info("Bootstrapping #{map_size(skills)} skills...")

            Enum.each(skills, fn {name, config} ->
              _ =
                Mimo.TaskHelper.safe_start_child(fn ->
                  case start_skill(name, config) do
                    {:ok, _pid} ->
                      Logger.info("✓ Skill '#{name}' started")

                    {:error, error} ->
                      Logger.warning("✗ Skill '#{name}' failed: #{inspect(error)}")
                  end
                end)
            end)

          {:ok, _} ->
            Logger.error("Invalid skills.json: must be a JSON object")

          {:error, reason} ->
            Logger.error("Failed to parse skills.json: #{inspect(reason)}")
        end

      {:error, :enoent} ->
        Logger.warning("No skills.json found at #{path}, starting with internal tools only")

      {:error, reason} ->
        Logger.error("Failed to read skills.json: #{inspect(reason)}")
    end
  end

  defp start_skill(name, config) do
    child_spec = %{
      id: {Mimo.Skills.Client, name},
      start: {Mimo.Skills.Client, :start_link, [name, config]},
      restart: :transient,
      shutdown: 30_000
    }

    DynamicSupervisor.start_child(Mimo.Skills.Supervisor, child_spec)
  end

  @doc """
  Hot reload all skills without restarting the gateway.
  """
  def reload_skills do
    Logger.warning("🔄 Hot reload initiated...")
    Mimo.ToolRegistry.reload_skills()
  end
end
