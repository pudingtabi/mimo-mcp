defmodule Mimo.Skills.Catalog do
  @moduledoc """
  Static tool catalog for lazy-loading skills.
  Tools are advertised immediately from manifest, processes spawn on-demand.
  """
  use GenServer
  require Logger

  @catalog_table :mimo_skill_catalog

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@catalog_table, [:named_table, :set, :public, read_concurrency: true])
    load_catalog()
    {:ok, %{}}
  end

  @doc """
  Load tool definitions from skills manifest.
  """
  def load_catalog do
    path = Application.get_env(:mimo_mcp, :skills_path, "priv/skills.json")
    manifest_path = String.replace(path, ".json", "_manifest.json")

    case File.read(manifest_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} ->
            load_from_manifest(manifest)

          {:error, _} ->
            Logger.warning("Invalid skills manifest, falling back to discovery")
            :ok
        end

      {:error, :enoent} ->
        Logger.info("No skills manifest found, will discover on first call")
        :ok
    end
  end

  defp load_from_manifest(manifest) when is_map(manifest) do
    Enum.each(manifest, fn {skill_name, skill_data} ->
      tools = Map.get(skill_data, "tools", [])
      config = Map.get(skill_data, "config", %{})

      Enum.each(tools, fn tool ->
        prefixed_name = "#{skill_name}_#{tool["name"]}"
        :ets.insert(@catalog_table, {prefixed_name, skill_name, config, tool})
      end)

      Logger.info("📦 Cataloged #{length(tools)} tools from '#{skill_name}'")
    end)
  end

  @doc """
  List all cataloged tools (instant, no process spawn).
  """
  def list_tools do
    @catalog_table
    |> :ets.tab2list()
    |> Enum.map(fn {prefixed_name, _skill, _config, tool} ->
      Map.put(tool, "name", prefixed_name)
    end)
  end

  @doc """
  Get skill config for a tool.
  """
  def get_skill_for_tool(tool_name) do
    case :ets.lookup(@catalog_table, tool_name) do
      [{_, skill_name, config, _tool}] -> {:ok, skill_name, config}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Reload catalog from manifest.
  """
  def reload do
    :ets.delete_all_objects(@catalog_table)
    load_catalog()
  end

  @doc """
  Get skill config by skill name.
  """
  def get_skill_config(skill_name) do
    # Find first tool for this skill and extract config
    case :ets.match(@catalog_table, {:_, skill_name, :"$1", :_}) do
      [[config] | _] -> config
      [] -> %{}
    end
  end
end
