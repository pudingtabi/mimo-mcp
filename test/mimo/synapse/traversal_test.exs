defmodule Mimo.Synapse.TraversalTest do
  @moduledoc """
  Tests for the Synapse Web Traversal algorithms.
  """
  use Mimo.DataCase, async: false
  alias Mimo.Synapse.{Graph, GraphEdge, GraphNode, Traversal}

  setup do
    # Clean up test data before each test
    Repo.delete_all(GraphEdge)
    Repo.delete_all(GraphNode)
    :ok
  end

  describe "bfs/2" do
    test "traverses outgoing edges" do
      # Create a simple chain: A -> B -> C
      {:ok, a} = Graph.create_node(%{node_type: :function, name: "A"})
      {:ok, b} = Graph.create_node(%{node_type: :function, name: "B"})
      {:ok, c} = Graph.create_node(%{node_type: :function, name: "C"})

      Graph.create_edge(%{source_node_id: a.id, target_node_id: b.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: b.id, target_node_id: c.id, edge_type: :calls})

      results = Traversal.bfs(a.id, max_depth: 3)

      assert length(results) == 2
      depths = Enum.map(results, & &1.depth)
      assert 1 in depths
      assert 2 in depths
    end

    test "traverses incoming edges" do
      {:ok, a} = Graph.create_node(%{node_type: :function, name: "A_in"})
      {:ok, b} = Graph.create_node(%{node_type: :function, name: "B_in"})
      {:ok, c} = Graph.create_node(%{node_type: :function, name: "C_in"})

      Graph.create_edge(%{source_node_id: a.id, target_node_id: b.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: b.id, target_node_id: c.id, edge_type: :calls})

      # Traverse backwards from C
      results = Traversal.bfs(c.id, max_depth: 3, direction: :incoming)

      assert length(results) == 2
    end

    test "traverses both directions" do
      {:ok, center} = Graph.create_node(%{node_type: :function, name: "center_both"})
      {:ok, upstream} = Graph.create_node(%{node_type: :function, name: "upstream"})
      {:ok, downstream} = Graph.create_node(%{node_type: :function, name: "downstream"})

      Graph.create_edge(%{
        source_node_id: upstream.id,
        target_node_id: center.id,
        edge_type: :calls
      })

      Graph.create_edge(%{
        source_node_id: center.id,
        target_node_id: downstream.id,
        edge_type: :calls
      })

      results = Traversal.bfs(center.id, max_depth: 2, direction: :both)

      result_names = Enum.map(results, & &1.node.name)
      assert "upstream" in result_names
      assert "downstream" in result_names
    end

    test "respects max_depth limit" do
      {:ok, a} = Graph.create_node(%{node_type: :function, name: "depth_a"})
      {:ok, b} = Graph.create_node(%{node_type: :function, name: "depth_b"})
      {:ok, c} = Graph.create_node(%{node_type: :function, name: "depth_c"})
      {:ok, d} = Graph.create_node(%{node_type: :function, name: "depth_d"})

      Graph.create_edge(%{source_node_id: a.id, target_node_id: b.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: b.id, target_node_id: c.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: c.id, target_node_id: d.id, edge_type: :calls})

      results = Traversal.bfs(a.id, max_depth: 2)

      # Should find B (depth 1) and C (depth 2), but not D (depth 3)
      assert length(results) == 2
      result_names = Enum.map(results, & &1.node.name)
      assert "depth_b" in result_names
      assert "depth_c" in result_names
      refute "depth_d" in result_names
    end

    test "filters by edge types" do
      {:ok, a} = Graph.create_node(%{node_type: :function, name: "filter_a"})
      {:ok, b} = Graph.create_node(%{node_type: :function, name: "filter_b"})
      {:ok, c} = Graph.create_node(%{node_type: :module, name: "filter_c"})

      Graph.create_edge(%{source_node_id: a.id, target_node_id: b.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: a.id, target_node_id: c.id, edge_type: :imports})

      # Only follow :calls edges
      results = Traversal.bfs(a.id, edge_types: [:calls])

      assert length(results) == 1
      assert hd(results).node.name == "filter_b"
    end

    test "avoids cycles" do
      {:ok, a} = Graph.create_node(%{node_type: :function, name: "cycle_a"})
      {:ok, b} = Graph.create_node(%{node_type: :function, name: "cycle_b"})

      # Create cycle: A -> B -> A
      Graph.create_edge(%{source_node_id: a.id, target_node_id: b.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: b.id, target_node_id: a.id, edge_type: :calls})

      # Should not infinite loop
      results = Traversal.bfs(a.id, max_depth: 10)

      # Should only find B once
      assert length(results) == 1
    end
  end

  describe "shortest_path/3" do
    test "finds direct path" do
      {:ok, a} = Graph.create_node(%{node_type: :function, name: "path_a"})
      {:ok, b} = Graph.create_node(%{node_type: :function, name: "path_b"})

      Graph.create_edge(%{source_node_id: a.id, target_node_id: b.id, edge_type: :calls})

      assert {:ok, path} = Traversal.shortest_path(a.id, b.id)
      assert length(path) == 2
    end

    test "finds multi-hop path" do
      {:ok, a} = Graph.create_node(%{node_type: :function, name: "mpath_a"})
      {:ok, b} = Graph.create_node(%{node_type: :function, name: "mpath_b"})
      {:ok, c} = Graph.create_node(%{node_type: :function, name: "mpath_c"})

      Graph.create_edge(%{source_node_id: a.id, target_node_id: b.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: b.id, target_node_id: c.id, edge_type: :calls})

      assert {:ok, path} = Traversal.shortest_path(a.id, c.id)
      assert length(path) == 3
    end

    test "returns error when no path exists" do
      {:ok, a} = Graph.create_node(%{node_type: :function, name: "nopath_a"})
      {:ok, b} = Graph.create_node(%{node_type: :function, name: "nopath_b"})

      # No edge between them
      assert {:error, :no_path} = Traversal.shortest_path(a.id, b.id)
    end

    test "finds shortest path among multiple options" do
      {:ok, a} = Graph.create_node(%{node_type: :function, name: "short_a"})
      {:ok, b} = Graph.create_node(%{node_type: :function, name: "short_b"})
      {:ok, c} = Graph.create_node(%{node_type: :function, name: "short_c"})
      {:ok, d} = Graph.create_node(%{node_type: :function, name: "short_d"})

      # Short path: A -> D
      Graph.create_edge(%{source_node_id: a.id, target_node_id: d.id, edge_type: :calls})
      # Long path: A -> B -> C -> D
      Graph.create_edge(%{source_node_id: a.id, target_node_id: b.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: b.id, target_node_id: c.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: c.id, target_node_id: d.id, edge_type: :calls})

      assert {:ok, path} = Traversal.shortest_path(a.id, d.id)
      # Should find the direct path
      assert length(path) == 2
    end
  end

  describe "all_paths/3" do
    test "finds multiple paths" do
      {:ok, a} = Graph.create_node(%{node_type: :function, name: "all_a"})
      {:ok, b} = Graph.create_node(%{node_type: :function, name: "all_b"})
      {:ok, c} = Graph.create_node(%{node_type: :function, name: "all_c"})

      # Two paths: A->C and A->B->C
      Graph.create_edge(%{source_node_id: a.id, target_node_id: c.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: a.id, target_node_id: b.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: b.id, target_node_id: c.id, edge_type: :calls})

      paths = Traversal.all_paths(a.id, c.id)

      assert length(paths) == 2
    end

    test "respects limit" do
      {:ok, a} = Graph.create_node(%{node_type: :function, name: "limit_a"})
      {:ok, b} = Graph.create_node(%{node_type: :function, name: "limit_b"})
      {:ok, c} = Graph.create_node(%{node_type: :function, name: "limit_c"})

      Graph.create_edge(%{source_node_id: a.id, target_node_id: c.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: a.id, target_node_id: b.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: b.id, target_node_id: c.id, edge_type: :calls})

      paths = Traversal.all_paths(a.id, c.id, limit: 1)

      assert length(paths) == 1
    end
  end

  describe "ego_graph/2" do
    test "returns subgraph around center node" do
      {:ok, center} = Graph.create_node(%{node_type: :function, name: "ego_center"})
      {:ok, n1} = Graph.create_node(%{node_type: :function, name: "ego_n1"})
      {:ok, n2} = Graph.create_node(%{node_type: :function, name: "ego_n2"})
      {:ok, n3} = Graph.create_node(%{node_type: :function, name: "ego_n3"})

      Graph.create_edge(%{source_node_id: center.id, target_node_id: n1.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: center.id, target_node_id: n2.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: n1.id, target_node_id: n3.id, edge_type: :calls})

      result = Traversal.ego_graph(center.id, hops: 1)

      # Should include center, n1, n2 (but not n3 at hops=1)
      node_names = Enum.map(result.nodes, & &1.name)
      assert "ego_center" in node_names
      assert "ego_n1" in node_names
      assert "ego_n2" in node_names
      refute "ego_n3" in node_names
    end

    test "includes edges between nodes" do
      {:ok, center} = Graph.create_node(%{node_type: :function, name: "ego_e_center"})
      {:ok, n1} = Graph.create_node(%{node_type: :function, name: "ego_e_n1"})

      Graph.create_edge(%{source_node_id: center.id, target_node_id: n1.id, edge_type: :calls})

      result = Traversal.ego_graph(center.id, hops: 1)

      assert length(result.edges) == 1
    end
  end

  describe "compute_centrality/1" do
    test "returns centrality scores" do
      # Create hub-and-spoke pattern
      {:ok, hub} = Graph.create_node(%{node_type: :function, name: "hub"})
      {:ok, s1} = Graph.create_node(%{node_type: :function, name: "spoke1"})
      {:ok, s2} = Graph.create_node(%{node_type: :function, name: "spoke2"})
      {:ok, s3} = Graph.create_node(%{node_type: :function, name: "spoke3"})

      # All spokes point to hub
      Graph.create_edge(%{source_node_id: s1.id, target_node_id: hub.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: s2.id, target_node_id: hub.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: s3.id, target_node_id: hub.id, edge_type: :calls})

      scores = Traversal.compute_centrality(limit: 10)

      # Hub should have highest centrality
      {top_id, _top_info} = hd(scores)
      assert top_id == hub.id
    end
  end
end
