defmodule Mimo.SystemHealthTest do
  use ExUnit.Case, async: false

  alias Mimo.SystemHealth

  describe "check/0" do
    test "returns a map with required keys" do
      result = SystemHealth.check()

      assert is_map(result)
      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checks)
      assert Map.has_key?(result, :timestamp)
    end

    test "status is one of :healthy, :degraded, or :critical" do
      result = SystemHealth.check()

      assert result.status in [:healthy, :degraded, :critical]
    end

    test "checks contains all subsystems" do
      result = SystemHealth.check()

      assert Map.has_key?(result.checks, :hnsw)
      assert Map.has_key?(result.checks, :backup)
      assert Map.has_key?(result.checks, :database)
      assert Map.has_key?(result.checks, :instance_lock)
      assert Map.has_key?(result.checks, :system)
    end

    test "timestamp is a DateTime" do
      result = SystemHealth.check()

      assert %DateTime{} = result.timestamp
    end

    test "each check has a status field" do
      result = SystemHealth.check()

      for {_name, check_result} <- result.checks do
        assert Map.has_key?(check_result, :status)
      end
    end
  end

  describe "status/0" do
    test "returns an atom" do
      result = SystemHealth.status()

      assert is_atom(result)
      assert result in [:healthy, :degraded, :critical]
    end
  end

  describe "summary/0" do
    test "returns a string" do
      result = SystemHealth.summary()

      assert is_binary(result)
    end

    test "includes status indicator" do
      result = SystemHealth.summary()

      assert String.contains?(result, "✓") or
               String.contains?(result, "⚠") or
               String.contains?(result, "✗")
    end

    test "includes subsystem names" do
      result = SystemHealth.summary()

      assert String.contains?(result, "hnsw=")
      assert String.contains?(result, "backup=")
      assert String.contains?(result, "database=")
    end
  end

  describe "get_metrics/0" do
    test "returns same structure as check/0" do
      check_result = SystemHealth.check()
      metrics_result = SystemHealth.get_metrics()

      assert Map.keys(check_result) == Map.keys(metrics_result)
    end
  end

  describe "individual checks" do
    test "hnsw check returns status" do
      result = SystemHealth.check()
      hnsw = result.checks.hnsw

      assert Map.has_key?(hnsw, :status)
      assert is_atom(hnsw.status)
    end

    test "database check returns connection status" do
      result = SystemHealth.check()
      db = result.checks.database

      assert Map.has_key?(db, :status)
      assert Map.has_key?(db, :connection)
    end

    test "system check returns memory and uptime" do
      result = SystemHealth.check()
      sys = result.checks.system

      assert Map.has_key?(sys, :status)
      assert Map.has_key?(sys, :uptime)
      assert Map.has_key?(sys, :memory_total_mb)
    end
  end
end
