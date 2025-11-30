defmodule Mimo.Tools.Dispatchers.Diagnostics do
  @moduledoc """
  Diagnostics operations dispatcher.

  Handles compile/lint/typecheck operations for multiple languages:
  - check: Compiler errors
  - lint: Linter warnings
  - typecheck: Type checker
  - all: Run all diagnostics

  Supports: Elixir, TypeScript, Python, Rust, Go

  MAPPING from SPEC-030:
  - All operations -> Diagnostics.check(path, operation: op_atom)
  """

  alias Mimo.Tools.Helpers

  @doc """
  Dispatch diagnostics operation based on args.
  """
  def dispatch(args) do
    path = args["path"]
    opts = []

    opts =
      if args["operation"] do
        case Helpers.safe_to_atom(args["operation"], Helpers.allowed_diagnostic_ops()) do
          nil -> opts
          op -> Keyword.put(opts, :operation, op)
        end
      else
        opts
      end

    opts =
      if args["language"] do
        case Helpers.safe_to_atom(args["language"], Helpers.allowed_languages()) do
          nil -> opts
          lang -> Keyword.put(opts, :language, lang)
        end
      else
        opts
      end

    opts =
      if args["severity"] do
        case Helpers.safe_to_atom(args["severity"], Helpers.allowed_severities()) do
          nil -> opts
          sev -> Keyword.put(opts, :severity, sev)
        end
      else
        opts
      end

    Mimo.Skills.Diagnostics.check(path, opts)
  end
end
