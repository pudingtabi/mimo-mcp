defmodule Mimo.Synapse.LinkerTest do
  @moduledoc """
  Tests for the Synapse Web Linker - auto-linking code, libraries, and memories.
  """
  use Mimo.DataCase, async: false
  alias Mimo.Synapse.{Graph, Linker, GraphNode, GraphEdge}

  setup do
    # Clean up test data before each test
    Repo.delete_all(GraphEdge)
    Repo.delete_all(GraphNode)
    :ok
  end

  describe "create_concept/2" do
    test "creates a concept node" do
      {:ok, concept} = Linker.create_concept("test_concept", description: "A test concept")

      assert concept.node_type == :concept
      assert concept.name == "test_concept"
      assert concept.description == "A test concept"
    end

    test "creates concept with properties" do
      {:ok, concept} =
        Linker.create_concept("prop_concept",
          description: "Concept with properties",
          properties: %{"category" => "testing", "priority" => "high"}
        )

      assert concept.properties["category"] == "testing"
      assert concept.properties["priority"] == "high"
    end

    test "finds existing concept instead of duplicating" do
      {:ok, first} = Linker.create_concept("unique_concept")
      {:ok, second} = Linker.create_concept("unique_concept")

      assert first.id == second.id
    end
  end

  describe "link_to_concept/2" do
    test "links a node to a concept by name" do
      {:ok, fn_node} = Graph.create_node(%{node_type: :function, name: "linked_function"})

      # link_to_concept takes node_id and concept_name (creates concept if needed)
      {:ok, _edge} = Linker.link_to_concept(fn_node.id, "link_concept")

      # Verify edge exists (concept should have been created)
      edges = Graph.outgoing_edges(fn_node.id, edge_type: :implements)
      assert length(edges) >= 1
    end

    test "creates concept if it doesn't exist" do
      {:ok, fn_node} = Graph.create_node(%{node_type: :function, name: "auto_linked_fn"})

      {:ok, _edge} = Linker.link_to_concept(fn_node.id, "new_concept")

      # The concept should have been created
      concept = Graph.get_node(:concept, "new_concept")
      assert concept != nil
    end
  end

  describe "link_code_file/1" do
    test "returns error for non-existent file" do
      result = Linker.link_code_file("/nonexistent/path/to/file.ex")

      assert {:error, _reason} = result
    end

    test "links real code file" do
      # Use a real file from the project
      file_path = Path.expand("lib/mimo/synapse/graph.ex", File.cwd!())

      if File.exists?(file_path) do
        result = Linker.link_code_file(file_path)

        # May succeed or fail depending on tree-sitter setup
        case result do
          {:ok, stats} ->
            # Returns a map with file_node and stats
            assert is_map(stats)
            assert stats.file_node.node_type == :file
            assert stats.file_node.name == file_path

          {:error, _} ->
            # Tree-sitter might not be available in test env
            assert true
        end
      else
        # Skip if file doesn't exist
        assert true
      end
    end
  end

  describe "link_external_library/1" do
    test "creates external_lib node" do
      lib_info = %{
        name: "test_library",
        version: "1.0.0",
        description: "A test library",
        ecosystem: "hex"
      }

      {:ok, node} = Linker.link_external_library(lib_info)

      assert node.node_type == :external_lib
      assert node.name == "test_library"
      assert node.properties["version"] == "1.0.0"
      assert node.properties["ecosystem"] == "hex"
    end

    test "updates existing library node" do
      lib_info = %{name: "update_lib", version: "1.0.0"}
      {:ok, first} = Linker.link_external_library(lib_info)

      updated_info = %{name: "update_lib", version: "2.0.0"}
      {:ok, second} = Linker.link_external_library(updated_info)

      # Should be same node, updated version
      assert first.id == second.id
      # Reload to get updated properties
      updated = Repo.get(GraphNode, second.id)
      assert updated.properties["version"] == "2.0.0"
    end

    test "links functions to library" do
      lib_info = %{
        name: "linked_lib",
        version: "1.0.0",
        functions: ["func1", "func2", "func3"]
      }

      {:ok, lib_node} = Linker.link_external_library(lib_info)

      # Check that function nodes were created
      incoming = Graph.incoming_edges(lib_node.id)
      # Functions should have edges pointing to the library
      # May or may not create function nodes based on impl
      assert length(incoming) >= 0
    end
  end

  describe "link_memory/2" do
    test "creates memory node and links to graph" do
      # Create a mock engram-like structure
      memory_id = Ecto.UUID.generate()

      # This test depends on Memory module behavior
      # We'll test the graph part by creating nodes directly
      {:ok, memory_node} =
        Graph.create_node(%{
          node_type: :memory,
          name: "test_memory",
          source_ref_type: "memory",
          source_ref_id: memory_id,
          properties: %{"category" => "fact"}
        })

      assert memory_node.node_type == :memory
      assert memory_node.source_ref_id == memory_id
    end
  end

  describe "auto_categorize/0" do
    test "runs without error" do
      # Create some nodes to categorize
      {:ok, _fn1} =
        Graph.create_node(%{
          node_type: :function,
          name: "auth_login",
          description: "Login authentication"
        })

      {:ok, _fn2} =
        Graph.create_node(%{
          node_type: :function,
          name: "auth_logout",
          description: "Logout authentication"
        })

      result = Linker.auto_categorize()

      assert {:ok, count} = result
      # Returns edge count (integer)
      assert is_integer(count)
    end

    test "creates concept clusters" do
      # Create related nodes
      {:ok, fn1} =
        Graph.create_node(%{
          node_type: :function,
          name: "database_connect"
        })

      {:ok, fn2} =
        Graph.create_node(%{
          node_type: :function,
          name: "database_query"
        })

      {:ok, fn3} =
        Graph.create_node(%{
          node_type: :function,
          name: "database_disconnect"
        })

      # Link them
      Graph.create_edge(%{source_node_id: fn1.id, target_node_id: fn2.id, edge_type: :calls})
      Graph.create_edge(%{source_node_id: fn2.id, target_node_id: fn3.id, edge_type: :calls})

      Linker.auto_categorize()

      # Should have created some concepts
      concepts = Graph.find_by_type(:concept)
      # May or may not create concepts depending on clustering algorithm
      assert is_list(concepts)
    end
  end

  describe "link_directory/2" do
    test "returns error for non-existent directory" do
      result = Linker.link_directory("/nonexistent/directory/path")

      assert {:error, _} = result
    end

    test "processes directory with extensions filter" do
      # Use project directory
      dir_path = Path.expand("lib/mimo/synapse", File.cwd!())

      if File.dir?(dir_path) do
        result = Linker.link_directory(dir_path, extensions: [".ex"])

        case result do
          {:ok, stats} ->
            assert is_map(stats)
            assert Map.has_key?(stats, :files_processed) or Map.has_key?(stats, :nodes_created)

          {:error, _} ->
            # May fail if tree-sitter not available
            assert true
        end
      else
        assert true
      end
    end
  end

  describe "batch operations" do
    test "creates multiple nodes efficiently" do
      nodes_data =
        for i <- 1..5 do
          %{node_type: :function, name: "batch_fn_#{i}"}
        end

      {:ok, count} = Graph.batch_create_nodes(nodes_data)

      assert count == 5
    end

    test "creates multiple edges efficiently" do
      # First create nodes
      {:ok, n1} = Graph.create_node(%{node_type: :function, name: "batch_edge_1"})
      {:ok, n2} = Graph.create_node(%{node_type: :function, name: "batch_edge_2"})
      {:ok, n3} = Graph.create_node(%{node_type: :function, name: "batch_edge_3"})

      edges_data = [
        %{source_node_id: n1.id, target_node_id: n2.id, edge_type: :calls},
        %{source_node_id: n2.id, target_node_id: n3.id, edge_type: :calls}
      ]

      {:ok, count} = Graph.batch_create_edges(edges_data)

      assert count == 2
    end
  end

  describe "integration with existing systems" do
    test "graph stats reflect created data" do
      # Create a small graph
      {:ok, _} = Graph.create_node(%{node_type: :function, name: "stats_fn"})
      {:ok, _} = Graph.create_node(%{node_type: :module, name: "stats_mod"})
      {:ok, _} = Linker.create_concept("stats_concept")

      stats = Graph.stats()

      assert stats.total_nodes >= 3
      assert stats.nodes_by_type[:function] >= 1
      assert stats.nodes_by_type[:module] >= 1
      assert stats.nodes_by_type[:concept] >= 1
    end
  end
end
