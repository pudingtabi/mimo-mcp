defmodule Mimo.ProceduralStore.ValidatorTest do
  @moduledoc """
  Unit tests for Procedural Store definition validator.

  SPEC-007: Validates FSM definition correctness.
  """
  use ExUnit.Case, async: true
  alias Mimo.ProceduralStore.Validator

  describe "validate/1 - required fields" do
    test "accepts valid definition with all required fields" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{}
        }
      }

      assert :ok = Validator.validate(definition)
    end

    test "rejects definition missing initial_state" do
      definition = %{
        "states" => %{"start" => %{}}
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "initial_state"))
    end

    test "rejects definition missing states" do
      definition = %{
        "initial_state" => "start"
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "states"))
    end

    test "rejects non-map definition" do
      assert {:error, errors} = Validator.validate("not a map")
      assert Enum.any?(errors, &String.contains?(&1, "must be a map"))
    end
  end

  describe "validate/1 - initial_state validation" do
    test "rejects initial_state not found in states" do
      definition = %{
        "initial_state" => "nonexistent",
        "states" => %{
          "start" => %{}
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "not found in states"))
    end

    test "rejects non-string initial_state" do
      definition = %{
        "initial_state" => 123,
        "states" => %{
          "start" => %{}
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "must be a string"))
    end
  end

  describe "validate/1 - states validation" do
    test "accepts terminal state without transitions" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{}
        }
      }

      assert :ok = Validator.validate(definition)
    end

    test "rejects non-map state definition" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => "invalid"
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "must be a map"))
    end

    test "rejects non-map states" do
      definition = %{
        "initial_state" => "start",
        "states" => "invalid"
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "states must be a map"))
    end
  end

  describe "validate/1 - action validation" do
    test "accepts valid action with module and function" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "action" => %{
              "module" => "MyModule",
              "function" => "execute"
            }
          }
        }
      }

      assert :ok = Validator.validate(definition)
    end

    test "rejects action without module" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "action" => %{
              "function" => "execute"
            }
          }
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "missing 'module'"))
    end

    test "rejects action without function" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "action" => %{
              "module" => "MyModule"
            }
          }
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "missing 'function'"))
    end

    test "rejects non-map action" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "action" => "invalid"
          }
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "action must be a map"))
    end
  end

  describe "validate/1 - transitions validation" do
    test "accepts valid transitions" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "transitions" => [
              %{"event" => "success", "target" => "done"}
            ]
          },
          "done" => %{}
        }
      }

      assert :ok = Validator.validate(definition)
    end

    test "rejects transition without event" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "transitions" => [
              %{"target" => "done"}
            ]
          },
          "done" => %{}
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "missing 'event'"))
    end

    test "rejects transition without target" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "transitions" => [
              %{"event" => "success"}
            ]
          }
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "missing 'target'"))
    end

    test "rejects transition to non-existent state" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "transitions" => [
              %{"event" => "success", "target" => "nonexistent"}
            ]
          }
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "non-existent states"))
    end

    test "rejects non-list transitions" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "transitions" => "invalid"
          }
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "must be a list"))
    end

    test "rejects non-map transition" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "transitions" => ["invalid"]
          },
          "done" => %{}
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "must be a map"))
    end
  end

  describe "validate/1 - orphan state detection" do
    test "detects unreachable states" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "transitions" => [
              %{"event" => "success", "target" => "middle"}
            ]
          },
          "middle" => %{
            "transitions" => [
              %{"event" => "success", "target" => "done"}
            ]
          },
          "done" => %{},
          # Not reachable from start
          "orphan" => %{}
        }
      }

      assert {:error, errors} = Validator.validate(definition)
      assert Enum.any?(errors, &String.contains?(&1, "unreachable"))
      assert Enum.any?(errors, &String.contains?(&1, "orphan"))
    end

    test "accepts all states reachable" do
      definition = %{
        "initial_state" => "start",
        "states" => %{
          "start" => %{
            "transitions" => [
              %{"event" => "success", "target" => "middle"},
              %{"event" => "error", "target" => "error_state"}
            ]
          },
          "middle" => %{
            "transitions" => [
              %{"event" => "success", "target" => "done"}
            ]
          },
          "error_state" => %{},
          "done" => %{}
        }
      }

      assert :ok = Validator.validate(definition)
    end
  end

  describe "validate/1 - complex valid definitions" do
    test "accepts complex multi-path definition" do
      definition = %{
        "initial_state" => "validate",
        "states" => %{
          "validate" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.Validate",
              "function" => "execute"
            },
            "transitions" => [
              %{"event" => "success", "target" => "process"},
              %{"event" => "error", "target" => "validation_failed"}
            ]
          },
          "process" => %{
            "action" => %{
              "module" => "MyApp.Steps.Process",
              "function" => "execute"
            },
            "transitions" => [
              %{"event" => "success", "target" => "complete"},
              %{"event" => "error", "target" => "rollback"}
            ]
          },
          "rollback" => %{
            "action" => %{
              "module" => "MyApp.Steps.Rollback",
              "function" => "execute"
            },
            "transitions" => [
              %{"event" => "success", "target" => "failed"}
            ]
          },
          "validation_failed" => %{},
          "complete" => %{},
          "failed" => %{}
        }
      }

      assert :ok = Validator.validate(definition)
    end

    test "accepts looping definition" do
      definition = %{
        "initial_state" => "check",
        "states" => %{
          "check" => %{
            "action" => %{
              "module" => "MyApp.Steps.Check",
              "function" => "execute"
            },
            "transitions" => [
              %{"event" => "retry", "target" => "wait"},
              %{"event" => "done", "target" => "complete"}
            ]
          },
          "wait" => %{
            "action" => %{
              "module" => "Mimo.ProceduralStore.Steps.Delay",
              "function" => "execute"
            },
            "transitions" => [
              %{"event" => "success", "target" => "check"}
            ]
          },
          "complete" => %{}
        }
      }

      assert :ok = Validator.validate(definition)
    end
  end
end
