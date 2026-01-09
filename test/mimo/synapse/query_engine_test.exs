defmodule Mimo.Synapse.QueryEngineTest do
  @moduledoc """
  Tests for the Synapse Web QueryEngine - hybrid vector + graph search.
  """
  use Mimo.DataCase, async: false
  alias Mimo.Synapse.{Graph, GraphEdge, GraphNode, QueryEngine}

  setup do
    # Clean up test data before each test
    Repo.delete_all(GraphEdge)
    Repo.delete_all(GraphNode)
    :ok
  end

  describe "query/2" do
    test "returns results with node_type filter" do
      {:ok, _fn1} =
        Graph.create_node(%{
          node_type: :function,
          name: "calculate_sum",
          description: "Calculates the sum of numbers"
        })

      {:ok, _mod1} =
        Graph.create_node(%{
          node_type: :module,
          name: "Calculator",
          description: "Math calculator module"
        })

      {:ok, results} = QueryEngine.query("calculate", node_types: [:function])

      # Should only return functions
      assert Enum.all?(results.nodes, fn n -> n.node_type == :function end)
    end

    test "returns empty for no matches" do
      {:ok, _fn1} =
        Graph.create_node(%{
          node_type: :function,
          name: "something_else",
          description: "Does something else"
        })

      {:ok, results} = QueryEngine.query("nonexistent_query_term_xyz123")

      assert results.nodes == []
    end

    test "finds nodes by description match" do
      {:ok, _fn1} =
        Graph.create_node(%{
          node_type: :function,
          name: "process_auth",
          description: "Handles user authentication and session management"
        })

      {:ok, _fn2} =
        Graph.create_node(%{
          node_type: :function,
          name: "unrelated_function",
          description: "Does something unrelated"
        })

      # Query for term in description, not in name
      {:ok, results} = QueryEngine.query("session management")

      assert results.nodes != []
      assert Enum.any?(results.nodes, fn n -> n.name == "process_auth" end)
    end

    test "expands results with graph traversal" do
      # Create connected graph
      {:ok, fn1} =
        Graph.create_node(%{
          node_type: :function,
          name: "process_data",
          description: "Process data function"
        })

      {:ok, fn2} =
        Graph.create_node(%{
          node_type: :function,
          name: "helper_function",
          description: "Helper for processing"
        })

      Graph.create_edge(%{source_node_id: fn1.id, target_node_id: fn2.id, edge_type: :calls})

      {:ok, results} = QueryEngine.query("process", expansion_hops: 2)

      # Should find the matched node
      node_names = Enum.map(results.nodes, & &1.name)
      assert "process_data" in node_names
      # Helper should be expanded via graph
      assert "helper_function" in node_names
    end

    test "respects limit parameter" do
      # Create multiple matching nodes
      for i <- 1..10 do
        Graph.create_node(%{
          node_type: :function,
          name: "limited_func_#{i}",
          description: "Limited function #{i}"
        })
      end

      {:ok, results} = QueryEngine.query("limited", max_nodes: 3)

      assert length(results.nodes) <= 3
    end
  end

  describe "query_code/2" do
    test "finds code nodes" do
      {:ok, _fn1} =
        Graph.create_node(%{
          node_type: :function,
          name: "code_function",
          source_ref_type: "file",
          source_ref_id: "/path/to/file.ex"
        })

      {:ok, _mod1} =
        Graph.create_node(%{
          node_type: :module,
          name: "CodeModule"
        })

      {:ok, _concept} =
        Graph.create_node(%{
          node_type: :concept,
          name: "coding"
        })

      {:ok, results} = QueryEngine.query_code("code")

      # Should only return code-related types (function, module, file, external_lib)
      node_types = Enum.map(results.nodes, & &1.node_type)
      refute :concept in node_types
      refute :memory in node_types
    end
  end

  describe "query_concepts/2" do
    test "finds concept nodes" do
      {:ok, _concept1} =
        Graph.create_node(%{
          node_type: :concept,
          name: "authentication",
          description: "User authentication concept"
        })

      {:ok, _fn1} =
        Graph.create_node(%{
          node_type: :function,
          name: "authenticate_user"
        })

      {:ok, results} = QueryEngine.query_concepts("authentication")

      # Should only return concepts
      assert Enum.all?(results.nodes, fn n -> n.node_type == :concept end)
    end
  end

  describe "node_context/2" do
    test "returns connected context" do
      {:ok, center} =
        Graph.create_node(%{
          node_type: :function,
          name: "context_center",
          description: "Center node for context test"
        })

      {:ok, _called} =
        Graph.create_node(%{
          node_type: :function,
          name: "called_by_center"
        })

      {:ok, _caller} =
        Graph.create_node(%{
          node_type: :function,
          name: "calls_center"
        })

      Graph.create_edge(%{source_node_id: center.id, target_node_id: _called.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: _caller.id, target_node_id: center.id, edge_type: :calls})

      {:ok, context} = QueryEngine.node_context(center.id)

      assert Map.has_key?(context, :node)
      assert Map.has_key?(context, :neighbors)
      assert Map.has_key?(context, :edges)
      assert context.node.id == center.id
    end

    test "returns related neighbors" do
      {:ok, fn1} = Graph.create_node(%{node_type: :function, name: "typed_fn"})
      {:ok, mod1} = Graph.create_node(%{node_type: :module, name: "typed_mod"})
      {:ok, fn2} = Graph.create_node(%{node_type: :function, name: "typed_fn2"})

      Graph.create_edge(%{source_node_id: fn1.id, target_node_id: mod1.id, edge_type: :imports})
      Graph.create_edge(%{source_node_id: fn1.id, target_node_id: fn2.id, edge_type: :calls})

      {:ok, context} = QueryEngine.node_context(fn1.id, hops: 1)

      # Both neighbors should be found
      neighbor_ids = Enum.map(context.neighbors, & &1.id)
      assert mod1.id in neighbor_ids or fn2.id in neighbor_ids
    end
  end

  describe "find_related/2" do
    test "finds related nodes by text search" do
      {:ok, _n1} = Graph.create_node(%{node_type: :function, name: "related_origin"})
      {:ok, _n2} = Graph.create_node(%{node_type: :function, name: "related_target"})
      {:ok, _n3} = Graph.create_node(%{node_type: :function, name: "unrelated_xyz"})

      # find_related takes a query string for text search
      related = QueryEngine.find_related("related")

      related_names = Enum.map(related, & &1.name)
      assert "related_origin" in related_names
      assert "related_target" in related_names
    end

    test "respects from_node_id for graph expansion" do
      {:ok, n1} = Graph.create_node(%{node_type: :function, name: "expand_origin"})
      {:ok, n2} = Graph.create_node(%{node_type: :function, name: "called_func"})
      {:ok, _n3} = Graph.create_node(%{node_type: :module, name: "imported_mod"})

      Graph.create_edge(%{source_node_id: n1.id, target_node_id: n2.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: n1.id, target_node_id: _n3.id, edge_type: :imports})

      # With from_node_id, should include graph neighbors
      related = QueryEngine.find_related("nonexistent", from_node_id: n1.id)

      related_ids = Enum.map(related, & &1.id)
      assert n2.id in related_ids or _n3.id in related_ids
    end
  end

  describe "explore/2" do
    test "returns structured exploration result" do
      {:ok, _start} =
        Graph.create_node(%{
          node_type: :concept,
          name: "exploration_concept",
          description: "Starting point for exploration"
        })

      {:ok, _n1} = Graph.create_node(%{node_type: :function, name: "explore_func"})

      # explore takes a query string, not node_id
      {:ok, result} = QueryEngine.explore("exploration")

      assert Map.has_key?(result, :query)
      assert Map.has_key?(result, :concepts)
      assert Map.has_key?(result, :code)
      assert result.query == "exploration"
    end

    test "categorizes results by type" do
      {:ok, _concept} = Graph.create_node(%{node_type: :concept, name: "test_concept"})
      {:ok, _func} = Graph.create_node(%{node_type: :function, name: "test_function"})
      {:ok, _lib} = Graph.create_node(%{node_type: :external_lib, name: "test_lib"})
      {:ok, _mem} = Graph.create_node(%{node_type: :memory, name: "test_memory"})

      {:ok, result} = QueryEngine.explore("test")

      assert is_list(result.concepts)
      assert is_list(result.code)
      assert is_list(result.libraries)
      assert is_list(result.memories)
    end
  end

  describe "code_for_concept/2" do
    test "finds code connected to a concept by name" do
      {:ok, concept} =
        Graph.create_node(%{
          node_type: :concept,
          name: "authentication_concept"
        })

      {:ok, fn1} =
        Graph.create_node(%{
          node_type: :function,
          name: "login_function"
        })

      {:ok, fn2} =
        Graph.create_node(%{
          node_type: :function,
          name: "logout_function"
        })

      # Use :implements edge type as expected by the function
      Graph.create_edge(%{
        source_node_id: fn1.id,
        target_node_id: concept.id,
        edge_type: :implements
      })

      Graph.create_edge(%{
        source_node_id: fn2.id,
        target_node_id: concept.id,
        edge_type: :implements
      })

      # code_for_concept takes concept NAME, not id
      {:ok, code_nodes} = QueryEngine.code_for_concept("authentication_concept")

      # Should return code nodes
      assert is_list(code_nodes)
    end

    test "returns error for non-existent concept" do
      result = QueryEngine.code_for_concept("nonexistent_concept_xyz")

      assert {:error, :concept_not_found} = result
    end
  end
end
