defmodule Mimo.Benchmark.SyntheticLOCOMOTest do
  use ExUnit.Case, async: true

  alias Mimo.Benchmark.SyntheticLOCOMO

  describe "generate/3" do
    test "generates the requested number of conversations" do
      conversations = SyntheticLOCOMO.generate(5, 10, 5)

      assert length(conversations) == 5
    end

    test "each conversation has required fields" do
      [conv | _] = SyntheticLOCOMO.generate(1, 10, 5)

      assert is_binary(conv["conversation_id"])
      assert is_list(conv["turns"])
      assert is_list(conv["questions"])
    end

    test "generates correct number of turns" do
      [conv | _] = SyntheticLOCOMO.generate(1, 15, 5)

      assert length(conv["turns"]) == 15
    end

    test "turns have required structure" do
      [conv | _] = SyntheticLOCOMO.generate(1, 5, 3)
      [turn | _] = conv["turns"]

      assert is_binary(turn["speaker"])
      assert turn["speaker"] in ["user", "assistant"]
      assert is_binary(turn["text"])
      assert is_integer(turn["turn"])
    end

    test "generates approximately requested number of questions" do
      [conv | _] = SyntheticLOCOMO.generate(1, 20, 12)

      # Should be close to 12 (rounding may cause slight variation)
      assert length(conv["questions"]) >= 10
      assert length(conv["questions"]) <= 14
    end

    test "questions have required structure" do
      [conv | _] = SyntheticLOCOMO.generate(1, 20, 10)
      [question | _] = conv["questions"]

      assert is_binary(question["id"])
      assert question["type"] in ["factual", "temporal", "multi_hop"]
      assert is_binary(question["text"])
      assert is_binary(question["answer"]) or is_nil(question["answer"])
    end

    test "generates all three question types" do
      [conv | _] = SyntheticLOCOMO.generate(1, 30, 15)
      types = Enum.map(conv["questions"], & &1["type"]) |> Enum.uniq()

      assert "factual" in types
      assert "temporal" in types
      assert "multi_hop" in types
    end

    test "conversation IDs are unique" do
      conversations = SyntheticLOCOMO.generate(10, 5, 3)
      ids = Enum.map(conversations, & &1["conversation_id"])

      assert length(Enum.uniq(ids)) == 10
    end

    test "alternates speakers correctly" do
      [conv | _] = SyntheticLOCOMO.generate(1, 6, 2)
      speakers = Enum.map(conv["turns"], & &1["speaker"])

      assert speakers == ["user", "assistant", "user", "assistant", "user", "assistant"]
    end
  end

  describe "edge cases" do
    test "handles minimum values" do
      conversations = SyntheticLOCOMO.generate(1, 1, 1)

      assert length(conversations) == 1
      assert length(hd(conversations)["turns"]) == 1
      # With only 1 turn, can only generate 1 factual question (no temporal/multi-hop)
      assert length(hd(conversations)["questions"]) <= 1
    end

    test "handles zero questions gracefully" do
      [conv | _] = SyntheticLOCOMO.generate(1, 5, 0)

      # With 0 questions requested, should return empty list
      assert conv["questions"] == []
    end

    test "handles single turn with multiple questions requested" do
      [conv | _] = SyntheticLOCOMO.generate(1, 1, 10)

      # With 1 turn, can only generate max 1 factual question
      assert length(conv["questions"]) <= 1
    end
  end
end
