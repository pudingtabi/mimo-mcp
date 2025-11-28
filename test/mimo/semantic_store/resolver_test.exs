defmodule Mimo.SemanticStore.ResolverTest do
  use Mimo.DataCase, async: false

  alias Mimo.SemanticStore.Resolver

  describe "resolve_entity/3" do
    test "creates new entity when no match found" do
      assert {:ok, entity_id} = Resolver.resolve_entity("PostgreSQL database", :service)
      assert String.starts_with?(entity_id, "service:")
      assert String.contains?(entity_id, "postgresql")
    end

    test "generates canonical ID with proper format" do
      assert {:ok, entity_id} = Resolver.resolve_entity("The Auth Service", :service)
      assert entity_id =~ ~r/^service:[a-z0-9_]+$/
    end

    test "handles empty text gracefully" do
      assert {:ok, entity_id} = Resolver.resolve_entity("", :auto)
      assert is_binary(entity_id)
    end

    test "normalizes whitespace in text" do
      {:ok, id1} = Resolver.resolve_entity("auth  service", :service)
      {:ok, id2} = Resolver.resolve_entity("auth service", :service)
      assert id1 == id2
    end

    test "respects graph_id option" do
      {:ok, id1} = Resolver.resolve_entity("test", :service, graph_id: "project:a")
      {:ok, id2} = Resolver.resolve_entity("test", :service, graph_id: "project:b")
      # Both should create entities (different graphs)
      assert is_binary(id1)
      assert is_binary(id2)
    end
  end

  describe "ensure_entity_anchor/3" do
    test "is idempotent" do
      entity_id = "service:test_#{System.unique_integer()}"

      assert :ok = Resolver.ensure_entity_anchor(entity_id, "Test Service")
      assert :ok = Resolver.ensure_entity_anchor(entity_id, "Test Service")
    end
  end

  describe "create_new_entity/3" do
    test "creates entity with canonical ID" do
      assert {:ok, entity_id} = Resolver.create_new_entity("My Test Entity", :entity, "global")
      assert entity_id =~ ~r/^entity:[a-z0-9_]+$/
    end

    test "handles special characters in text" do
      assert {:ok, entity_id} = Resolver.create_new_entity("Test@Entity#123!", :service, "global")
      assert entity_id =~ ~r/^service:[a-z0-9_]+$/
      refute String.contains?(entity_id, "@")
      refute String.contains?(entity_id, "#")
    end
  end
end
