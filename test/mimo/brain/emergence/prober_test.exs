defmodule Mimo.Brain.Emergence.ProberTest do
  use Mimo.DataCase, async: true

  alias Mimo.Brain.Emergence.{Prober, Pattern}

  describe "capability_domains/0" do
    test "returns all defined capability domains" do
      domains = Prober.capability_domains()

      assert is_map(domains)
      assert Map.has_key?(domains, :code_analysis)
      assert Map.has_key?(domains, :code_generation)
      assert Map.has_key?(domains, :debugging)
      assert Map.has_key?(domains, :research)
      assert Map.has_key?(domains, :file_operations)
      assert Map.has_key?(domains, :memory_management)
      assert Map.has_key?(domains, :reasoning)
      assert Map.has_key?(domains, :communication)
    end

    test "each domain has description, tools, and keywords" do
      domains = Prober.capability_domains()

      for {_name, config} <- domains do
        assert is_binary(config[:description])
        assert is_list(config[:tools])
        assert is_list(config[:keywords])
        assert Enum.any?(config[:keywords])
      end
    end
  end

  describe "probe_types/0" do
    test "returns valid probe types" do
      types = Prober.probe_types()

      assert :validation in types
      assert :boundary in types
      assert :generalization in types
      assert :composition in types
    end
  end

  describe "classify_pattern_domain/1" do
    test "classifies code analysis pattern" do
      pattern = %Pattern{
        id: "test-1",
        description: "Find definition of function and analyze references",
        components: [%{"tool" => "code"}, %{"tool" => "code"}],
        strength: 0.7,
        success_rate: 0.8
      }

      assert Prober.classify_pattern_domain(pattern) == :code_analysis
    end

    test "classifies debugging pattern" do
      pattern = %Pattern{
        id: "test-2",
        description: "Fix error by diagnosing the issue and troubleshooting",
        components: [%{"tool" => "code"}, %{"tool" => "terminal"}, %{"tool" => "file"}],
        strength: 0.7,
        success_rate: 0.8
      }

      assert Prober.classify_pattern_domain(pattern) == :debugging
    end

    test "classifies research pattern" do
      pattern = %Pattern{
        id: "test-3",
        description: "Search web for documentation and lookup information",
        components: [%{"tool" => "web"}, %{"tool" => "memory"}],
        strength: 0.7,
        success_rate: 0.8
      }

      assert Prober.classify_pattern_domain(pattern) == :research
    end

    test "classifies file operations pattern" do
      pattern = %Pattern{
        id: "test-4",
        description: "Read file contents and edit multiple files",
        components: [%{"tool" => "file"}, %{"tool" => "file"}, %{"tool" => "file"}],
        strength: 0.7,
        success_rate: 0.8
      }

      assert Prober.classify_pattern_domain(pattern) == :file_operations
    end

    test "defaults to reasoning for unclear patterns" do
      pattern = %Pattern{
        id: "test-5",
        description: "Do something interesting",
        components: [],
        strength: 0.7,
        success_rate: 0.8
      }

      assert Prober.classify_pattern_domain(pattern) == :reasoning
    end
  end

  describe "generate_probe_task/2" do
    setup do
      pattern = %Pattern{
        id: "test-pattern",
        description: "A test pattern for probing",
        components: [%{"tool" => "code"}, %{"tool" => "file"}],
        strength: 0.6,
        success_rate: 0.75
      }

      {:ok, pattern: pattern}
    end

    test "generates validation task", %{pattern: pattern} do
      task = Prober.generate_probe_task(pattern, type: :validation)

      assert task.pattern_id == pattern.id
      assert task.probe_type == :validation
      assert is_binary(task.description)
      assert is_list(task.expected_tools)
    end

    test "generates boundary task", %{pattern: pattern} do
      task = Prober.generate_probe_task(pattern, type: :boundary)

      assert task.probe_type == :boundary
      assert is_binary(task.description)
    end

    test "generates generalization task", %{pattern: pattern} do
      task = Prober.generate_probe_task(pattern, type: :generalization)

      assert task.probe_type == :generalization
      assert is_binary(task.description)
    end

    test "generates composition task", %{pattern: pattern} do
      task = Prober.generate_probe_task(pattern, type: :composition)

      assert task.probe_type == :composition
      assert is_binary(task.description)
    end
  end

  describe "probe_pattern/2" do
    test "returns probe result with required fields" do
      pattern = %Pattern{
        id: "test-pattern",
        description: "Test pattern",
        components: [%{"tool" => "code"}],
        strength: 0.7,
        success_rate: 0.8
      }

      task = Prober.generate_probe_task(pattern, type: :validation)
      result = Prober.probe_pattern(pattern, task)

      assert result.pattern_id == pattern.id
      assert result.task == task
      assert is_boolean(result.success)
      assert is_number(result.confidence)
      assert result.confidence >= 0 and result.confidence <= 1
      assert %DateTime{} = result.probed_at
    end
  end

  describe "probe_candidates/1" do
    test "returns list of probe candidate maps" do
      # Note: This may return empty list if no patterns exist
      candidates = Prober.probe_candidates(limit: 5)

      assert is_list(candidates)

      for candidate <- candidates do
        assert is_map(candidate)
        assert Map.has_key?(candidate, :id)
        assert Map.has_key?(candidate, :domain)
        assert Map.has_key?(candidate, :probe_priority)
      end
    end
  end

  describe "capability_summary/0" do
    test "returns summary with required fields" do
      summary = Prober.capability_summary()

      assert is_map(summary)
      assert Map.has_key?(summary, :domains)
      assert Map.has_key?(summary, :total_patterns)
      assert Map.has_key?(summary, :domain_count)
      assert Map.has_key?(summary, :strongest_domains)
      assert Map.has_key?(summary, :weakest_domains)
      assert %DateTime{} = summary.updated_at
    end

    test "domains contains aggregate metrics" do
      summary = Prober.capability_summary()

      for {_domain, stats} <- summary.domains do
        assert is_binary(stats.description)
        assert is_integer(stats.pattern_count)
        assert is_number(stats.avg_strength)
        assert is_number(stats.avg_success_rate)
        assert is_integer(stats.total_occurrences)
      end
    end
  end
end
