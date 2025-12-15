defmodule Mix.Tasks.Mimo.Backup do
  @moduledoc """
  Backup Mimo database before migrations or on-demand.

  ## Usage

      # Backup database manually
      mix mimo.backup

      # Backup with custom name
      mix mimo.backup --name "before-migration"

      # List all backups
      mix mimo.backup --list

      # Restore from backup
      mix mimo.backup --restore backup_20251207_123456.db

  ## Automatic Backup Before Migrations

  This task automatically backs up the database before running migrations
  by hooking into `mix ecto.migrate`.

  Backups are stored in `priv/backups/` with timestamps.
  """

  use Mix.Task
  require Logger

  @shortdoc "Backup Mimo database"

  @backup_dir "priv/backups"

  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [name: :string, list: :boolean, restore: :string],
        aliases: [n: :name, l: :list, r: :restore]
      )

    cond do
      opts[:list] ->
        list_backups()

      opts[:restore] ->
        restore_backup(opts[:restore])

      true ->
        create_backup(opts[:name])
    end
  end

  defp create_backup(custom_name) do
    db_path = get_db_path()

    unless File.exists?(db_path) do
      Mix.shell().error("Database not found: #{db_path}")
      exit({:shutdown, 1})
    end

    File.mkdir_p!(@backup_dir)

    backup_name =
      if custom_name do
        "#{custom_name}_#{timestamp()}.db"
      else
        "backup_#{timestamp()}.db"
      end

    backup_path = Path.join(@backup_dir, backup_name)

    Mix.shell().info("Creating backup: #{backup_path}")
    File.cp!(db_path, backup_path)

    # Also backup WAL files if they exist
    for ext <- ["-wal", "-shm"] do
      wal_path = db_path <> ext

      if File.exists?(wal_path) do
        File.cp!(wal_path, backup_path <> ext)
      end
    end

    # Calculate stats
    {:ok, stats} = File.stat(backup_path)
    size_mb = Float.round(stats.size / 1024 / 1024, 2)

    Mix.shell().info("✓ Backup created: #{backup_name} (#{size_mb} MB)")
    Mix.shell().info("  Location: #{backup_path}")

    # Store metadata
    metadata = %{
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      original_db: db_path,
      size_bytes: stats.size,
      custom_name: custom_name
    }

    metadata_path = backup_path <> ".meta.json"
    File.write!(metadata_path, Jason.encode!(metadata, pretty: true))

    backup_path
  end

  defp list_backups do
    if File.exists?(@backup_dir) do
      backups =
        @backup_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".db"))
        |> Enum.sort(:desc)

      if Enum.empty?(backups) do
        Mix.shell().info("No backups found in #{@backup_dir}")
      else
        Mix.shell().info("Available backups in #{@backup_dir}:\n")

        for backup <- backups do
          backup_path = Path.join(@backup_dir, backup)
          {:ok, stats} = File.stat(backup_path)
          size_mb = Float.round(stats.size / 1024 / 1024, 2)
          mtime = stats.mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_string()

          Mix.shell().info("  • #{backup}")
          Mix.shell().info("    Size: #{size_mb} MB")
          Mix.shell().info("    Modified: #{mtime}")

          # Show metadata if exists
          meta_path = backup_path <> ".meta.json"

          if File.exists?(meta_path) do
            case Jason.decode(File.read!(meta_path)) do
              {:ok, meta} ->
                if meta["custom_name"], do: Mix.shell().info("    Name: #{meta["custom_name"]}")
                Mix.shell().info("    Created: #{meta["created_at"]}")

              _ ->
                :ok
            end
          end

          Mix.shell().info("")
        end
      end
    else
      Mix.shell().info("No backups found (#{@backup_dir} does not exist)")
    end
  end

  defp restore_backup(backup_name) do
    backup_path = Path.join(@backup_dir, backup_name)

    unless File.exists?(backup_path) do
      Mix.shell().error("Backup not found: #{backup_path}")
      exit({:shutdown, 1})
    end

    db_path = get_db_path()

    # Create backup of current database first
    if File.exists?(db_path) do
      Mix.shell().info("Creating safety backup of current database...")
      current_backup = create_backup("pre-restore")
      Mix.shell().info("✓ Current database backed up to: #{current_backup}")
    end

    # Confirm restore
    Mix.shell().info("\nThis will REPLACE your current database with:")
    Mix.shell().info("  #{backup_path}")
    Mix.shell().info("\nCurrent database: #{db_path}")

    if Mix.shell().yes?("\nAre you sure you want to restore this backup?") do
      Mix.shell().info("Restoring backup...")
      File.cp!(backup_path, db_path)

      # Restore WAL files if they exist
      for ext <- ["-wal", "-shm"] do
        wal_backup = backup_path <> ext

        if File.exists?(wal_backup) do
          File.cp!(wal_backup, db_path <> ext)
        end
      end

      Mix.shell().info("✓ Database restored successfully!")
      Mix.shell().info("  From: #{backup_path}")
      Mix.shell().info("  To: #{db_path}")
    else
      Mix.shell().info("Restore cancelled.")
    end
  end

  defp get_db_path do
    # Read from config
    config = Application.get_env(:mimo_mcp, Mimo.Repo, [])
    config[:database] || System.get_env("MIMO_DB_PATH") || "priv/mimo_mcp.db"
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
    |> String.replace(~r/[:\-\.]/, "")
    |> String.slice(0..14)
  end
end
