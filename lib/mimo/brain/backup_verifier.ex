defmodule Mimo.Brain.BackupVerifier do
  @moduledoc """
  Verifies backup integrity to ensure backups are trustworthy.

  This module performs multiple checks on SQLite backup files:
  1. File existence and readability
  2. SQLite PRAGMA integrity_check
  3. Basic schema validation (engrams table exists)
  4. Engram count sanity check

  ## Usage

      # Verify a specific backup
      {:ok, stats} = BackupVerifier.verify("priv/backups/backup_20260103.db")

      # Verify the most recent backup
      {:ok, stats} = BackupVerifier.verify_latest()

      # Get status of all backups
      statuses = BackupVerifier.verification_status()

  ## Integration

  Called automatically after backup creation to mark backups as verified.
  Also used before restore to warn about unverified backups.
  """

  require Logger

  @backup_dir "priv/backups"

  @type verification_result ::
          {:ok,
           %{
             path: String.t(),
             verified: boolean(),
             integrity: :ok | {:error, String.t()},
             engram_count: non_neg_integer(),
             size_bytes: non_neg_integer(),
             verified_at: DateTime.t()
           }}
          | {:error, atom() | String.t()}

  @doc """
  Verifies a backup file's integrity.

  ## Parameters

    - `backup_path` - Path to the backup .db file

  ## Returns

    - `{:ok, stats}` - Backup is verified with statistics
    - `{:error, reason}` - Verification failed
  """
  @spec verify(String.t()) :: verification_result()
  def verify(backup_path) do
    with :ok <- check_file_exists(backup_path),
         :ok <- check_file_readable(backup_path),
         {:ok, size} <- get_file_size(backup_path),
         {:ok, integrity} <- run_integrity_check(backup_path),
         {:ok, engram_count} <- count_engrams(backup_path) do
      stats = %{
        path: backup_path,
        verified: true,
        status: "verified",
        integrity: to_string(integrity),
        engram_count: engram_count,
        size_bytes: size,
        verified_at: DateTime.utc_now()
      }

      # Update metadata file with verification status
      update_metadata(backup_path, stats)

      Logger.info(
        "[BackupVerifier] Verified: #{Path.basename(backup_path)} " <>
          "(#{engram_count} engrams, #{Float.round(size / 1024 / 1024, 2)} MB)"
      )

      {:ok, stats}
    else
      {:error, reason} = error ->
        Logger.warning(
          "[BackupVerifier] Verification failed for #{backup_path}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Verifies the most recent backup in the backup directory.
  """
  @spec verify_latest() :: verification_result() | {:error, :no_backups}
  def verify_latest do
    case find_latest_backup() do
      {:ok, path} -> verify(path)
      {:error, _} = error -> error
    end
  end

  @doc """
  Returns verification status for all backups in the backup directory.
  """
  @spec verification_status() :: [map()]
  def verification_status do
    if File.exists?(@backup_dir) do
      @backup_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".db"))
      |> Enum.map(fn backup ->
        path = Path.join(@backup_dir, backup)
        meta = read_metadata(path)

        %{
          name: backup,
          path: path,
          verified: Map.get(meta, "verified", false),
          verified_at: Map.get(meta, "verified_at"),
          engram_count: Map.get(meta, "engram_count"),
          size_bytes: Map.get(meta, "size_bytes")
        }
      end)
      |> Enum.sort_by(& &1.name, :desc)
    else
      []
    end
  end

  @doc """
  Returns the status of the latest backup.
  """
  @spec latest_status() :: map() | nil
  def latest_status do
    case verification_status() do
      [latest | _] -> latest
      [] -> nil
    end
  end

  # Private functions

  defp check_file_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, :file_not_found}
  end

  defp check_file_readable(path) do
    case File.open(path, [:read]) do
      {:ok, file} ->
        File.close(file)
        :ok

      {:error, reason} ->
        {:error, {:not_readable, reason}}
    end
  end

  defp get_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, {:stat_failed, reason}}
    end
  end

  defp run_integrity_check(backup_path) do
    # Use sqlite3 CLI to run PRAGMA integrity_check
    case System.cmd("sqlite3", [backup_path, "PRAGMA integrity_check;"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.trim(output) == "ok" do
          {:ok, :ok}
        else
          {:error, {:integrity_failed, String.trim(output)}}
        end

      {error, _} ->
        {:error, {:sqlite_error, String.trim(error)}}
    end
  end

  defp count_engrams(backup_path) do
    case System.cmd("sqlite3", [backup_path, "SELECT COUNT(*) FROM engrams;"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {count, _} -> {:ok, count}
          :error -> {:error, :count_parse_failed}
        end

      {error, _} ->
        {:error, {:count_failed, String.trim(error)}}
    end
  end

  defp find_latest_backup do
    if File.exists?(@backup_dir) do
      backups =
        @backup_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".db"))
        |> Enum.sort(:desc)

      case backups do
        [latest | _] -> {:ok, Path.join(@backup_dir, latest)}
        [] -> {:error, :no_backups}
      end
    else
      {:error, :backup_dir_not_found}
    end
  end

  defp read_metadata(backup_path) do
    meta_path = backup_path <> ".meta.json"

    if File.exists?(meta_path) do
      case Jason.decode(File.read!(meta_path)) do
        {:ok, meta} -> meta
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp update_metadata(backup_path, stats) do
    meta_path = backup_path <> ".meta.json"

    existing_meta =
      if File.exists?(meta_path) do
        case Jason.decode(File.read!(meta_path)) do
          {:ok, meta} -> meta
          _ -> %{}
        end
      else
        %{}
      end

    updated_meta =
      Map.merge(existing_meta, %{
        "verified" => stats.verified,
        "verified_at" => DateTime.to_iso8601(stats.verified_at),
        "engram_count" => stats.engram_count,
        "integrity" => to_string(stats.integrity)
      })

    File.write!(meta_path, Jason.encode!(updated_meta, pretty: true))
  rescue
    e ->
      Logger.warning("[BackupVerifier] Failed to update metadata: #{Exception.message(e)}")
  end
end
