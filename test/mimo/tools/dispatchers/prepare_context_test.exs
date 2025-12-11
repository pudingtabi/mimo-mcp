defmodule Mimo.Tools.Dispatchers.PrepareContextTest do
  use ExUnit.Case, async: true

  alias Mimo.SemanticStore.Triple
  alias Mimo.Tools.Dispatchers.PrepareContext

  test "extract_relationships handles triple structs and map forms" do
    triple = %Triple{subject_id: "alice", predicate: "contains", object_id: "bob"}

    semantic_store = %{
      "relationships" => %{
        "outgoing" => [triple],
        "incoming" => []
      }
    }

    result = PrepareContext.extract_relationships_for_test(semantic_store)

    assert is_list(result)
    assert Enum.any?(result, fn s -> String.contains?(s, "alice contains bob") end)
  end

  test "extract_relationships handles map forms with string keys" do
    rel = %{"subject" => "carol", "predicate" => "likes", "object" => "dave"}

    semantic_store = %{
      "relationships" => %{
        "outgoing" => [rel],
        "incoming" => []
      }
    }

    result = PrepareContext.extract_relationships_for_test(semantic_store)
    assert Enum.any?(result, fn s -> String.contains?(s, "carol likes dave") end)
  end

  test "extract_relationships handles incoming relationships and pred alias" do
    rel_in = %{"subject_id" => "eric", "pred" => "contains", "object_id" => "fiona"}

    semantic_store = %{
      "relationships" => %{
        "outgoing" => [],
        "incoming" => [rel_in]
      }
    }

    result = PrepareContext.extract_relationships_for_test(semantic_store)
    assert Enum.any?(result, fn s -> String.contains?(s, "eric contains fiona") end)
  end
end
