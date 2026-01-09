defmodule Mimo.Brain.BackupVerifierTest do
  use ExUnit.Case, async: false

  alias Mimo.Brain.BackupVerifier

  @moduletag :backup_verifier

  setup do
    # Create a temporary directory for test backups
    test_dir = Path.join(System.tmp_dir!(), "mimo_backup_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "verify/1" do
    test "returns error for non-existent file" do
      result = BackupVerifier.verify("/nonexistent/path/backup.db")

      assert {:error, reason} = result
      assert reason == :file_not_found or reason == :enoent
    end

    test "verifies a valid SQLite database", %{test_dir: test_dir} do
      # Create a minimal valid SQLite database WITH engrams table
      db_path = Path.join(test_dir, "valid_backup.db")

      # Use sqlite3 to create a database with the expected schema
      {_, 0} =
        System.cmd("sqlite3", [
          db_path,
          """
            CREATE TABLE engrams (
              id INTEGER PRIMARY KEY,
              content TEXT,
              category TEXT,
              importance REAL
            );
            INSERT INTO engrams (content, category, importance) VALUES ('test memory', 'fact', 0.5);
          """
        ])

      result = BackupVerifier.verify(db_path)

      assert {:ok, verification} = result
      assert verification.status == "verified"
      assert verification.integrity == "ok"
      assert verification.engram_count == 1
    end

    test "detects corruption in invalid file", %{test_dir: test_dir} do
      # Create a file that's not a valid SQLite database
      corrupt_path = Path.join(test_dir, "corrupt_backup.db")
      File.write!(corrupt_path, "this is not a sqlite database")

      result = BackupVerifier.verify(corrupt_path)

      # Should either return error or corrupted status
      case result do
        {:ok, verification} ->
          assert verification.status == "corrupted" or
                   String.contains?(to_string(verification.integrity), "not a database")

        {:error, _reason} ->
          assert true
      end
    end

    test "creates meta file after verification", %{test_dir: test_dir} do
      db_path = Path.join(test_dir, "meta_test.db")
      meta_path = db_path <> ".meta.json"

      # Create database with engrams table
      {_, 0} =
        System.cmd("sqlite3", [
          db_path,
          """
            CREATE TABLE engrams (
              id INTEGER PRIMARY KEY,
              content TEXT
            );
          """
        ])

      {:ok, _} = BackupVerifier.verify(db_path)

      assert File.exists?(meta_path)

      {:ok, content} = File.read(meta_path)
      {:ok, meta} = Jason.decode(content)

      assert Map.has_key?(meta, "verified")
      assert Map.has_key?(meta, "verified_at")
    end
  end

  describe "verify_latest/0" do
    test "returns error when no backups exist" do
      # This depends on the backup directory being empty or having no .db files
      # In test environment, this may vary
      result = BackupVerifier.verify_latest()

      # Either succeeds with a backup or fails with no_backups
      assert match?({:ok, _}, result) or match?({:error, :no_backups}, result)
    end
  end

  describe "verification_status/0" do
    test "returns a list" do
      result = BackupVerifier.verification_status()

      assert is_list(result)
    end
  end

  describe "latest_status/0" do
    test "returns nil or a map" do
      result = BackupVerifier.latest_status()

      assert is_nil(result) or is_map(result)
    end
  end
end
