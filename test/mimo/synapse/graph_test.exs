defmodule Mimo.Synapse.GraphTest do
  @moduledoc """
  Tests for the Synapse Web Graph core module.
  """
  use Mimo.DataCase, async: false
  alias Mimo.Synapse.{Graph, GraphEdge, GraphNode}

  setup do
    # Clean up test data before each test
    Repo.delete_all(GraphEdge)
    Repo.delete_all(GraphNode)
    :ok
  end

  describe "create_node/1" do
    test "creates a node with required fields" do
      attrs = %{
        node_type: :function,
        name: "Mimo.Test.hello/1"
      }

      assert {:ok, node} = Graph.create_node(attrs)
      assert node.node_type == :function
      assert node.name == "Mimo.Test.hello/1"
      assert node.access_count == 0
    end

    test "creates a node with properties" do
      attrs = %{
        node_type: :file,
        name: "lib/test.ex",
        properties: %{language: "elixir", lines: 100}
      }

      assert {:ok, node} = Graph.create_node(attrs)
      assert node.properties["language"] == "elixir"
      assert node.properties["lines"] == 100
    end

    test "fails with invalid node type" do
      attrs = %{
        node_type: :invalid_type,
        name: "test"
      }

      assert {:error, changeset} = Graph.create_node(attrs)
      assert changeset.errors[:node_type]
    end

    test "enforces uniqueness of type+name" do
      attrs = %{node_type: :concept, name: "Authentication"}

      assert {:ok, _} = Graph.create_node(attrs)
      assert {:error, changeset} = Graph.create_node(attrs)
      assert changeset.errors[:node_type]
    end
  end

  describe "find_or_create_node/3" do
    test "creates new node if not exists" do
      assert {:ok, node} = Graph.find_or_create_node(:concept, "Testing", %{desc: "test"})
      assert node.node_type == :concept
      assert node.name == "Testing"
    end

    test "returns existing node if exists" do
      {:ok, original} = Graph.create_node(%{node_type: :module, name: "MyModule"})
      {:ok, found} = Graph.find_or_create_node(:module, "MyModule", %{})

      assert found.id == original.id
    end
  end

  describe "get_node/2" do
    test "returns node by type and name" do
      {:ok, created} = Graph.create_node(%{node_type: :function, name: "test/0"})

      found = Graph.get_node(:function, "test/0")
      assert found.id == created.id
    end

    test "returns nil when not found" do
      assert Graph.get_node(:function, "nonexistent") == nil
    end
  end

  describe "search_nodes/2" do
    test "finds nodes by name pattern" do
      {:ok, _} = Graph.create_node(%{node_type: :function, name: "Mimo.Tools.dispatch/2"})
      {:ok, _} = Graph.create_node(%{node_type: :function, name: "Mimo.Tools.list_tools/0"})
      {:ok, _} = Graph.create_node(%{node_type: :function, name: "Other.function/1"})

      results = Graph.search_nodes("Mimo.Tools")
      assert length(results) == 2
    end

    test "filters by node types" do
      {:ok, _} = Graph.create_node(%{node_type: :function, name: "test_fn"})
      {:ok, _} = Graph.create_node(%{node_type: :module, name: "test_module"})

      results = Graph.search_nodes("test", types: [:function])
      assert length(results) == 1
      assert hd(results).node_type == :function
    end

    test "respects limit" do
      for i <- 1..10 do
        Graph.create_node(%{node_type: :function, name: "func_#{i}"})
      end

      results = Graph.search_nodes("func", limit: 3)
      assert length(results) == 3
    end
  end

  describe "create_edge/1" do
    test "creates an edge between nodes" do
      {:ok, source} = Graph.create_node(%{node_type: :function, name: "caller/0"})
      {:ok, target} = Graph.create_node(%{node_type: :function, name: "callee/0"})

      attrs = %{
        source_node_id: source.id,
        target_node_id: target.id,
        edge_type: :calls
      }

      assert {:ok, edge} = Graph.create_edge(attrs)
      assert edge.edge_type == :calls
      assert edge.weight == 1.0
    end

    test "creates edge with custom weight" do
      {:ok, source} = Graph.create_node(%{node_type: :memory, name: "mem_1"})
      {:ok, target} = Graph.create_node(%{node_type: :concept, name: "auth"})

      attrs = %{
        source_node_id: source.id,
        target_node_id: target.id,
        edge_type: :mentions,
        weight: 0.7
      }

      assert {:ok, edge} = Graph.create_edge(attrs)
      assert edge.weight == 0.7
    end

    test "enforces uniqueness of source+target+type" do
      {:ok, s} = Graph.create_node(%{node_type: :function, name: "s"})
      {:ok, t} = Graph.create_node(%{node_type: :function, name: "t"})

      attrs = %{source_node_id: s.id, target_node_id: t.id, edge_type: :calls}

      assert {:ok, _} = Graph.create_edge(attrs)
      assert {:error, _} = Graph.create_edge(attrs)
    end
  end

  describe "ensure_edge/4" do
    test "creates edge if not exists" do
      {:ok, s} = Graph.create_node(%{node_type: :file, name: "a.ex"})
      {:ok, t} = Graph.create_node(%{node_type: :function, name: "fn"})

      assert {:ok, edge} = Graph.ensure_edge(s.id, t.id, :defines, %{})
      assert edge.edge_type == :defines
    end

    test "returns existing edge if exists" do
      {:ok, s} = Graph.create_node(%{node_type: :file, name: "b.ex"})
      {:ok, t} = Graph.create_node(%{node_type: :function, name: "fn2"})

      {:ok, original} =
        Graph.create_edge(%{
          source_node_id: s.id,
          target_node_id: t.id,
          edge_type: :defines
        })

      {:ok, found} = Graph.ensure_edge(s.id, t.id, :defines, %{})
      assert found.id == original.id
    end
  end

  describe "outgoing_edges/2 and incoming_edges/2" do
    test "returns outgoing edges from a node" do
      {:ok, s} = Graph.create_node(%{node_type: :function, name: "source"})
      {:ok, t1} = Graph.create_node(%{node_type: :function, name: "target1"})
      {:ok, t2} = Graph.create_node(%{node_type: :function, name: "target2"})

      Graph.create_edge(%{source_node_id: s.id, target_node_id: t1.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: s.id, target_node_id: t2.id, edge_type: :calls})

      edges = Graph.outgoing_edges(s.id)
      assert length(edges) == 2
    end

    test "returns incoming edges to a node" do
      {:ok, s1} = Graph.create_node(%{node_type: :function, name: "src1"})
      {:ok, s2} = Graph.create_node(%{node_type: :function, name: "src2"})
      {:ok, t} = Graph.create_node(%{node_type: :function, name: "tgt"})

      Graph.create_edge(%{source_node_id: s1.id, target_node_id: t.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: s2.id, target_node_id: t.id, edge_type: :calls})

      edges = Graph.incoming_edges(t.id)
      assert length(edges) == 2
    end

    test "filters edges by type" do
      {:ok, s} = Graph.create_node(%{node_type: :function, name: "fn_filter"})
      {:ok, t1} = Graph.create_node(%{node_type: :function, name: "target_call"})
      {:ok, t2} = Graph.create_node(%{node_type: :module, name: "target_import"})

      Graph.create_edge(%{source_node_id: s.id, target_node_id: t1.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: s.id, target_node_id: t2.id, edge_type: :imports})

      call_edges = Graph.outgoing_edges(s.id, types: [:calls])
      assert length(call_edges) == 1
      assert hd(call_edges).edge_type == :calls
    end
  end

  describe "neighbors/2" do
    test "returns all neighboring nodes" do
      {:ok, center} = Graph.create_node(%{node_type: :function, name: "center"})
      {:ok, out1} = Graph.create_node(%{node_type: :function, name: "out1"})
      {:ok, in1} = Graph.create_node(%{node_type: :function, name: "in1"})

      Graph.create_edge(%{source_node_id: center.id, target_node_id: out1.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: in1.id, target_node_id: center.id, edge_type: :calls})

      neighbors = Graph.neighbors(center.id)
      neighbor_ids = Enum.map(neighbors, & &1.id)

      assert out1.id in neighbor_ids
      assert in1.id in neighbor_ids
    end
  end

  describe "track_access/1" do
    test "increments access count" do
      {:ok, node} = Graph.create_node(%{node_type: :concept, name: "tracked"})
      assert node.access_count == 0

      {:ok, updated} = Graph.track_access(node.id)
      assert updated.access_count == 1

      {:ok, updated2} = Graph.track_access(node.id)
      assert updated2.access_count == 2
    end
  end

  describe "stats/0" do
    test "returns graph statistics" do
      {:ok, n1} = Graph.create_node(%{node_type: :function, name: "fn1"})
      {:ok, n2} = Graph.create_node(%{node_type: :concept, name: "c1"})
      Graph.create_edge(%{source_node_id: n1.id, target_node_id: n2.id, edge_type: :implements})

      stats = Graph.stats()

      assert stats.total_nodes == 2
      assert stats.total_edges == 1
      assert stats.nodes_by_type[:function] == 1
      assert stats.nodes_by_type[:concept] == 1
    end
  end
end
