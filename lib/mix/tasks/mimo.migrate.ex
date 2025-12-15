defmodule Mix.Tasks.Mimo.Migrate do
  @moduledoc """
  MIMO wrapper for Ecto migrations with automatic backup.

  Use `mix mimo.migrate` instead of `mix ecto.migrate` to ensure
  automatic backup before migrations.

  This ensures we NEVER lose data during migrations.
  """

  use Mix.Task
  require Logger

  @shortdoc "Runs Ecto migrations with automatic backup"

  def run(args) do
    # Parse args to check if --skip-backup is provided
    {opts, remaining_args} = OptionParser.parse!(args, strict: [skip_backup: :boolean])

    if opts[:skip_backup] do
      Mix.shell().info("⚠️  Skipping automatic backup (--skip-backup flag)")
    else
      Mix.shell().info("🔒 Creating automatic backup before migration...")

      try do
        Mix.Task.run("mimo.backup", ["--name", "pre-migration"])
        Mix.shell().info("✓ Backup complete\n")
      rescue
        e ->
          Mix.shell().error("Failed to create backup: #{inspect(e)}")

          if Mix.shell().yes?("Continue without backup? (NOT RECOMMENDED)") do
            Mix.shell().info("Proceeding without backup...")
          else
            Mix.shell().info("Migration cancelled. Fix backup issues first.")
            exit({:shutdown, 1})
          end
      end
    end

    # Run the actual Ecto migration
    Mix.shell().info("Running Ecto migrations...")
    Mix.Task.run("ecto.migrate", remaining_args ++ ["--repo", "Mimo.Repo"])
  end
end
