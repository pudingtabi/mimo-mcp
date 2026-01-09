defmodule Mimo.Brain.DbMaintenanceTest do
  use Mimo.DataCase, async: false

  alias Mimo.Brain.DbMaintenance

  describe "SPEC-101: Database Maintenance" do
    @tag :db_maintenance
    test "run_analyze executes successfully" do
      # ANALYZE should always succeed on a valid SQLite database
      assert :ok = DbMaintenance.run_analyze()
    end

    @tag :db_maintenance
    test "run_pragma_optimize executes successfully" do
      assert :ok = DbMaintenance.run_pragma_optimize()
    end

    @tag :db_maintenance
    @tag :integration
    # VACUUM cannot run inside a transaction (Ecto Sandbox)
    @tag :skip
    test "run_vacuum executes successfully" do
      # Note: VACUUM can be slow on large databases, but should succeed
      assert :ok = DbMaintenance.run_vacuum()
    end

    @tag :db_maintenance
    test "db_stats returns correct structure" do
      stats = DbMaintenance.db_stats()

      assert is_map(stats)
      assert is_integer(stats.db_size_bytes)
      assert is_float(stats.db_size_mb)
      assert is_integer(stats.free_pages)
      assert is_integer(stats.free_bytes)
      assert is_float(stats.fragmentation_pct)
      assert is_integer(stats.page_size)
      assert is_integer(stats.total_pages)
      assert is_boolean(stats.vacuum_recommended)

      # SQLite page size is typically 4096 (default) or 1024, 2048, 8192, etc.
      assert stats.page_size in [1024, 2048, 4096, 8192, 16384, 32768, 65536]
    end

    @tag :db_maintenance
    test "status returns scheduling information" do
      status = DbMaintenance.status()

      assert is_map(status)
      # last_*_at can be nil if never run, or DateTime if run
      assert is_nil(status.last_vacuum_at) or match?(%DateTime{}, status.last_vacuum_at)
      assert is_nil(status.last_analyze_at) or match?(%DateTime{}, status.last_analyze_at)
      assert is_boolean(status.vacuum_due)
      assert is_boolean(status.analyze_due)
      assert is_number(status.next_vacuum_in_hours)
      assert is_number(status.next_analyze_in_hours)
    end

    @tag :db_maintenance
    test "optimize with force runs analyze and pragma_optimize" do
      # Force runs even if not scheduled
      # Note: VACUUM will fail in Ecto Sandbox (transaction) - that's expected
      assert {:ok, results} = DbMaintenance.optimize(force: true, analyze_only: true)

      assert is_map(results)
      assert results.analyze == :completed
      assert results.pragma_optimize == :completed
      # vacuum is skipped when using analyze_only
      assert results.vacuum == :skipped
      assert is_integer(results.duration_ms)
    end

    @tag :db_maintenance
    @tag :integration
    # VACUUM cannot run inside a transaction (Ecto Sandbox)
    @tag :skip
    test "optimize respects vacuum_only option" do
      {:ok, results} = DbMaintenance.optimize(force: true, vacuum_only: true)

      assert results.vacuum == :completed
      assert results.analyze == :skipped
      assert results.pragma_optimize == :skipped
    end

    @tag :db_maintenance
    test "optimize respects analyze_only option" do
      {:ok, results} = DbMaintenance.optimize(force: true, analyze_only: true)

      assert results.analyze == :completed
      assert results.pragma_optimize == :completed
      assert results.vacuum == :skipped
    end

    @tag :db_maintenance
    test "optimize without force respects schedule" do
      # Run once to set last run times (analyze only to avoid VACUUM transaction issue)
      {:ok, _} = DbMaintenance.optimize(force: true, analyze_only: true)

      # Immediately run again without force - should skip
      {:ok, results} = DbMaintenance.optimize(force: false, analyze_only: true)

      # Since we just ran, analyze should be skipped
      assert results.analyze == :skipped
    end
  end

  describe "SPEC-101: Database maintenance integration with BackgroundCognition" do
    @tag :db_maintenance
    @tag :integration
    test "BackgroundCognition includes db_maintenance stats" do
      alias Mimo.Brain.BackgroundCognition

      # Get stats - db_maintenance_runs should be present
      stats = BackgroundCognition.stats()

      assert Map.has_key?(stats, :db_maintenance_runs)
    end
  end
end
