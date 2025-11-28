defmodule Mimo.ProceduralStore.LoaderTest do
  @moduledoc """
  Unit tests for Procedural Store Loader.

  SPEC-007: Validates procedure registration, versioning, and caching.
  """
  use ExUnit.Case, async: false
  alias Mimo.ProceduralStore.Loader
  alias Mimo.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Initialize loader cache
    try do
      Loader.init()
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  describe "register/1" do
    test "registers valid procedure" do
      procedure = valid_procedure("loader_test_1")

      assert {:ok, registered} = Loader.register(procedure)
      assert registered.name == "loader_test_1"
      assert registered.version == "1.0"
      assert registered.hash != nil
    end

    test "validates procedure schema - rejects missing definition" do
      invalid = %{name: "bad_proc", version: "1.0"}

      assert {:error, changeset} = Loader.register(invalid)
      assert changeset.valid? == false
    end

    test "validates procedure schema - rejects missing initial_state" do
      invalid = %{
        name: "no_initial",
        version: "1.0",
        definition: %{
          "states" => %{"start" => %{}}
        }
      }

      assert {:error, changeset} = Loader.register(invalid)
      # Should fail validation
      assert changeset.valid? == false
    end

    test "validates version format" do
      procedure = %{
        name: "bad_version",
        version: "invalid-version",
        definition: %{
          "initial_state" => "start",
          "states" => %{"start" => %{}}
        }
      }

      assert {:error, changeset} = Loader.register(procedure)
      errors = errors_on(changeset)
      assert errors[:version] != nil
    end

    test "allows version updates" do
      proc_v1 = valid_procedure("versioned_proc")
      proc_v2 = %{proc_v1 | version: "2.0"}

      {:ok, _} = Loader.register(proc_v1)
      {:ok, v2} = Loader.register(proc_v2)

      assert v2.version == "2.0"
    end

    test "generates hash from definition" do
      procedure = valid_procedure("hash_test")

      {:ok, registered} = Loader.register(procedure)

      assert registered.hash != nil
      # SHA256 hex
      assert String.length(registered.hash) == 64
    end

    test "same definition produces same hash" do
      proc1 = valid_procedure("hash_consistency_1")
      proc2 = %{proc1 | name: "hash_consistency_2"}

      {:ok, reg1} = Loader.register(proc1)
      {:ok, reg2} = Loader.register(proc2)

      assert reg1.hash == reg2.hash
    end
  end

  describe "load/2" do
    test "loads registered procedure by name and version" do
      procedure = valid_procedure("load_test")
      {:ok, _} = Loader.register(procedure)

      assert {:ok, loaded} = Loader.load("load_test", "1.0")
      assert loaded.name == "load_test"
    end

    test "returns error for non-existent procedure" do
      result = Loader.load("nonexistent", "1.0")
      assert {:error, :not_found} = result
    end

    test "loads latest version" do
      base = valid_procedure("latest_test")
      {:ok, _} = Loader.register(base)
      {:ok, _} = Loader.register(%{base | version: "2.0"})

      {:ok, loaded} = Loader.load("latest_test", "latest")
      assert loaded.version == "2.0"
    end

    test "caches loaded procedures" do
      procedure = valid_procedure("cache_test")
      {:ok, _} = Loader.register(procedure)

      # First load - from DB
      {:ok, _} = Loader.load("cache_test", "1.0")

      # Second load - should be cached
      {:ok, loaded} = Loader.load("cache_test", "1.0")
      assert loaded.name == "cache_test"
    end
  end

  describe "list/1" do
    test "lists all registered procedures" do
      {:ok, _} = Loader.register(valid_procedure("list_test_1"))
      {:ok, _} = Loader.register(valid_procedure("list_test_2"))

      procedures = Loader.list()
      names = Enum.map(procedures, & &1.name)

      assert "list_test_1" in names
      assert "list_test_2" in names
    end

    test "filters by active status" do
      {:ok, _} = Loader.register(valid_procedure("active_test"))

      procedures = Loader.list(active_only: true)
      assert Enum.all?(procedures, &(&1.active == true))
    end

    test "filters by name" do
      {:ok, _} = Loader.register(valid_procedure("filter_name_1"))
      {:ok, _} = Loader.register(valid_procedure("filter_name_2"))

      procedures = Loader.list(name: "filter_name_1")
      assert length(procedures) == 1
      assert hd(procedures).name == "filter_name_1"
    end
  end

  describe "deactivate/2" do
    test "deactivates a procedure version" do
      {:ok, _} = Loader.register(valid_procedure("deactivate_test"))

      {:ok, deactivated} = Loader.deactivate("deactivate_test", "1.0")
      assert deactivated.active == false
    end

    test "returns error for non-existent procedure" do
      result = Loader.deactivate("nonexistent", "1.0")
      assert {:error, :not_found} = result
    end
  end

  describe "cache management" do
    test "invalidate_cache removes specific version" do
      procedure = valid_procedure("cache_invalidate_test")
      {:ok, _} = Loader.register(procedure)

      # Load to cache
      {:ok, _} = Loader.load("cache_invalidate_test", "1.0")

      # Invalidate
      :ok = Loader.invalidate_cache("cache_invalidate_test", "1.0")

      # Should still load from DB
      {:ok, loaded} = Loader.load("cache_invalidate_test", "1.0")
      assert loaded.name == "cache_invalidate_test"
    end

    test "clear_cache removes all cached entries" do
      {:ok, _} = Loader.register(valid_procedure("clear_cache_test"))
      {:ok, _} = Loader.load("clear_cache_test", "1.0")

      :ok = Loader.clear_cache()

      # Should still work (loads from DB)
      {:ok, _} = Loader.load("clear_cache_test", "1.0")
    end
  end

  # Helper function to create a valid procedure
  defp valid_procedure(name) do
    %{
      name: name,
      version: "1.0",
      definition: %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.SetContext",
              "function" => "execute",
              "args" => [%{"values" => %{"started" => true}}]
            },
            "transitions" => [
              %{"event" => "success", "target" => "done"}
            ]
          },
          "done" => %{}
        }
      }
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
