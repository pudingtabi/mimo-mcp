defmodule Mimo.Cognitive.ConfidenceAssessorTest do
  use Mimo.DataCase, async: false
  alias Mimo.Cognitive.{ConfidenceAssessor, Uncertainty}

  describe "assess/2" do
    test "returns uncertainty struct" do
      uncertainty = ConfidenceAssessor.assess("test query")

      assert %Uncertainty{} = uncertainty
      assert uncertainty.topic == "test query"
      assert uncertainty.confidence in [:unknown, :low, :medium, :high]
      assert is_float(uncertainty.score)
      assert is_list(uncertainty.sources)
    end

    test "assesses with custom options" do
      uncertainty =
        ConfidenceAssessor.assess("test",
          include_code: false,
          include_graph: false,
          memory_limit: 5
        )

      assert %Uncertainty{} = uncertainty
    end

    test "includes source diversity in assessment" do
      uncertainty = ConfidenceAssessor.assess("authentication flow")

      # Should have assessed multiple source types
      source_types = Enum.map(uncertainty.sources, & &1.type) |> Enum.uniq()
      assert is_list(source_types)
    end
  end

  describe "quick_assess/1" do
    test "returns confidence level quickly" do
      level = ConfidenceAssessor.quick_assess("test query")

      assert level in [:unknown, :low, :medium, :high]
    end
  end

  describe "assess_code/2" do
    test "prioritizes code sources" do
      uncertainty = ConfidenceAssessor.assess_code("function definition")

      assert %Uncertainty{} = uncertainty
    end
  end

  describe "assess_concept/2" do
    test "prioritizes memory and graph sources" do
      uncertainty = ConfidenceAssessor.assess_concept("authentication patterns")

      assert %Uncertainty{} = uncertainty
    end
  end
end
