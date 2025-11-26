defmodule Mix.Tasks.Mimo.GenerateManifest do
  @shortdoc "Generate skills manifest for lazy-loading"
  @moduledoc """
  Generate skills manifest by discovering tools from each skill.
  Run once to cache tool definitions for instant loading.

  Usage: mix mimo.generate_manifest
  """
  use Mix.Task
  require Logger

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    skills_path = Application.get_env(:mimo_mcp, :skills_path, "priv/skills.json")
    manifest_path = String.replace(skills_path, ".json", "_manifest.json")

    case File.read(skills_path) do
      {:ok, content} ->
        {:ok, skills} = Jason.decode(content)
        manifest = discover_all_tools(skills)

        File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
        IO.puts("✅ Generated manifest: #{manifest_path}")
        IO.puts("   #{map_size(manifest)} skills, #{count_tools(manifest)} tools")

      {:error, reason} ->
        IO.puts("❌ Failed to read #{skills_path}: #{inspect(reason)}")
    end
  end

  defp discover_all_tools(skills) do
    skills
    |> Enum.map(fn {name, config} ->
      IO.puts("Discovering: #{name}...")

      case discover_skill_tools(config) do
        {:ok, tools} ->
          IO.puts("  ✓ #{length(tools)} tools")
          {name, %{"config" => config, "tools" => tools}}

        {:error, reason} ->
          IO.puts("  ✗ #{inspect(reason)}")
          {name, %{"config" => config, "tools" => [], "error" => inspect(reason)}}
      end
    end)
    |> Map.new()
  end

  defp discover_skill_tools(%{"command" => cmd, "args" => args} = config) do
    env = config |> Map.get("env", %{}) |> interpolate_env()

    case System.find_executable(cmd) do
      nil ->
        {:error, "Command not found: #{cmd}"}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :use_stdio,
            {:env, env},
            {:args, args}
          ])

        Process.sleep(2000)

        request =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "tools/list",
            "id" => 1
          })

        Port.command(port, request <> "\n")

        result =
          receive do
            {^port, {:data, data}} ->
              case Jason.decode(data) do
                {:ok, %{"result" => %{"tools" => tools}}} -> {:ok, tools}
                {:ok, %{"error" => error}} -> {:error, error}
                _ -> {:error, :invalid_response}
              end
          after
            15_000 -> {:error, :timeout}
          end

        Port.close(port)
        result
    end
  end

  defp interpolate_env(env_map) do
    Enum.map(env_map, fn {k, v} ->
      value =
        Regex.replace(~r/\$\{([^}]+)\}/, v, fn _, var ->
          System.get_env(var) || ""
        end)

      {String.to_charlist(k), String.to_charlist(value)}
    end)
  end

  defp count_tools(manifest) do
    manifest
    |> Enum.map(fn {_, data} -> length(Map.get(data, "tools", [])) end)
    |> Enum.sum()
  end
end
