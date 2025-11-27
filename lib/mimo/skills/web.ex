defmodule Mimo.Skills.Web do
  @moduledoc """
  Converts raw HTML to LLM-optimized Markdown using Floki.
  """

  @unwanted_tags ~w(script style nav footer svg header aside iframe)
  @block_elements ~w(p div section article main)

  def parse(html) when is_binary(html) do
    html
    |> Floki.parse_document!()
    |> Floki.filter_out(@unwanted_tags)
    |> to_markdown()
    |> String.trim()
  end

  defp to_markdown(tree) do
    tree
    |> Floki.traverse_and_update(&convert_node/1)
    |> Floki.text(sep: "")
  end

  defp convert_node({"h1", _attrs, children}), do: {"span", [], ["# " | children] ++ ["\n\n"]}
  defp convert_node({"h2", _attrs, children}), do: {"span", [], ["## " | children] ++ ["\n\n"]}
  defp convert_node({"h3", _attrs, children}), do: {"span", [], ["### " | children] ++ ["\n\n"]}
  defp convert_node({"h4", _attrs, children}), do: {"span", [], ["#### " | children] ++ ["\n\n"]}
  defp convert_node({"h5", _attrs, children}), do: {"span", [], ["##### " | children] ++ ["\n\n"]}
  defp convert_node({"h6", _attrs, children}), do: {"span", [], ["###### " | children] ++ ["\n\n"]}

  defp convert_node({"a", attrs, children}) do
    url = get_attr(attrs, "href", "")
    {"span", [], ["["] ++ children ++ ["](#{url})"]}
  end

  defp convert_node({"li", _attrs, children}), do: {"span", [], ["- " | children] ++ ["\n"]}
  defp convert_node({"br", _attrs, _children}), do: {"span", [], ["\n"]}
  defp convert_node({"hr", _attrs, _children}), do: {"span", [], ["\n\n---\n\n"]}

  defp convert_node({"img", attrs, _children}) do
    alt = get_attr(attrs, "alt", "image")
    src = get_attr(attrs, "src", "")
    {"span", [], ["![#{alt}](#{src})"]}
  end

  defp convert_node({tag, attrs, children}) when tag in @block_elements do
    {"span", attrs, children ++ ["\n\n"]}
  end

  defp convert_node(node), do: node

  defp get_attr(attrs, attr_name, default) do
    case List.keyfind(attrs, attr_name, 0) do
      {^attr_name, value} -> value
      nil -> default
    end
  end
end
