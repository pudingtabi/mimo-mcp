defmodule Mimo.Utils.InputValidationTest do
  use ExUnit.Case, async: true

  alias Mimo.Utils.InputValidation

  describe "validate_limit/2" do
    test "returns default for nil" do
      assert InputValidation.validate_limit(nil) == 10
      assert InputValidation.validate_limit(nil, default: 50) == 50
    end

    test "clamps negative values to min" do
      assert InputValidation.validate_limit(-1) == 1
      assert InputValidation.validate_limit(-100) == 1
    end

    test "clamps values above max" do
      assert InputValidation.validate_limit(9999, max: 100) == 100
      assert InputValidation.validate_limit(1_000_000) == 1000  # default max
    end

    test "accepts valid integers" do
      assert InputValidation.validate_limit(50) == 50
      assert InputValidation.validate_limit(1) == 1
    end

    test "converts string to integer" do
      assert InputValidation.validate_limit("50") == 50
      assert InputValidation.validate_limit("abc") == 10  # falls back to default
    end

    test "converts float to integer" do
      assert InputValidation.validate_limit(50.7) == 50
    end
  end

  describe "validate_offset/2" do
    test "returns 0 for nil" do
      assert InputValidation.validate_offset(nil) == 0
    end

    test "clamps negative values to 0" do
      assert InputValidation.validate_offset(-50) == 0
      assert InputValidation.validate_offset(-1) == 0
    end

    test "accepts valid offsets" do
      assert InputValidation.validate_offset(100) == 100
      assert InputValidation.validate_offset(0) == 0
    end

    test "clamps to max" do
      assert InputValidation.validate_offset(200_000, max: 10_000) == 10_000
    end
  end

  describe "validate_threshold/2" do
    test "returns default for nil" do
      assert InputValidation.validate_threshold(nil) == 0.5
      assert InputValidation.validate_threshold(nil, default: 0.3) == 0.3
    end

    test "clamps to 0.0-1.0 range" do
      assert InputValidation.validate_threshold(-0.5) == 0.0
      assert InputValidation.validate_threshold(1.5) == 1.0
    end

    test "accepts valid thresholds" do
      assert InputValidation.validate_threshold(0.7) == 0.7
    end
  end

  describe "validate_depth/2" do
    test "returns default for nil" do
      assert InputValidation.validate_depth(nil) == 3
    end

    test "clamps to max" do
      assert InputValidation.validate_depth(100, max: 10) == 10
    end

    test "enforces minimum of 1" do
      assert InputValidation.validate_depth(-5) == 1
      assert InputValidation.validate_depth(0) == 1
    end
  end

  describe "validate_timeout/2" do
    test "returns default for nil" do
      assert InputValidation.validate_timeout(nil) == 30_000
    end

    test "clamps to min/max" do
      assert InputValidation.validate_timeout(500) == 1_000  # min is 1000
      assert InputValidation.validate_timeout(1_000_000) == 300_000  # default max
    end
  end
end
