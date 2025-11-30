defmodule Mimo.Code.TreeSitter.Native do
  @moduledoc """
  Native NIF bindings for Tree-Sitter parser.

  This module loads the Rust NIF that provides Tree-Sitter parsing capabilities.
  Do not call these functions directly - use `Mimo.Code.TreeSitter` instead.
  """

  use Rustler,
    otp_app: :mimo_mcp,
    crate: :tree_sitter_nif,
    path: "native/tree_sitter"

  @doc false
  def init_resources, do: error()

  @doc false
  def parse(_source, _language), do: error()

  @doc false
  def parse_incremental(_source, _old_tree, _edits), do: error()

  @doc false
  def get_sexp(_tree), do: error()

  @doc false
  def get_symbols(_tree), do: error()

  @doc false
  def get_references(_tree), do: error()

  @doc false
  def query(_tree, _pattern), do: error()

  @doc false
  def supported_languages, do: error()

  @doc false
  def language_for_extension(_ext), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
