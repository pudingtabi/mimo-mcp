defmodule Mimo.Tools.Dispatchers.KnowledgeTest do
  use Mimo.DataCase

  alias Mimo.Tools.Dispatchers.Knowledge

  describe "dispatch_link/1" do
    @tag :tmp_dir
    test "returns JSON-serializable result", %{tmp_dir: tmp_dir} do
      # Create a test file
      test_file = Path.join(tmp_dir, "test.ex")
      File.write!(test_file, """
      defmodule TestModule do
        def test_function do
          :ok
        end
      end
      """)

      # Call dispatch_link
      result = Knowledge.dispatch(%{"operation" => "link", "path" => test_file})

      # Should return success
      assert {:ok, data} = result

      # Should have file_node (formatted as map, not struct)
      assert is_map(data)
      
      # If file_node is present, it should be a plain map
      if Map.has_key?(data, :file_node) && data.file_node do
        assert is_map(data.file_node)
        refute is_struct(data.file_node)
        
        # Should have expected keys from format_graph_node
        assert Map.has_key?(data.file_node, :id)
        assert Map.has_key?(data.file_node, :type)
        assert Map.has_key?(data.file_node, :name)
      end

      # Most importantly: should be JSON-encodable
      assert {:ok, _json} = Jason.encode(data)
    end
  end
end
