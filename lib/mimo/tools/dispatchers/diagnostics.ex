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

    opts =
      []
      |> maybe_add_opt(:operation, args["operation"], Helpers.allowed_diagnostic_ops())
      |> maybe_add_opt(:language, args["language"], Helpers.allowed_languages())
      |> maybe_add_opt(:severity, args["severity"], Helpers.allowed_severities())

    Mimo.Skills.Diagnostics.check(path, opts)
  end

  defp maybe_add_opt(opts, _key, nil, _allowed), do: opts

  defp maybe_add_opt(opts, key, value, allowed) do
    case Helpers.safe_to_atom(value, allowed) do
      nil -> opts
      atom -> Keyword.put(opts, key, atom)
    end
  end
end
