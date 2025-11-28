defmodule Mimo.Skills.Web do
  @moduledoc """
  Converts raw HTML to LLM-optimized Markdown using Floki.
  """

  @unwanted_tags ~w(script style nav footer svg header aside iframe noscript)

  def parse(html) when is_binary(html) and byte_size(html) > 0 do
    try do
      case Floki.parse_document(html) do
        {:ok, tree} ->
          tree
          |> remove_unwanted_tags()
          |> to_markdown()
          |> String.trim()
          |> normalize_whitespace()

        {:error, _} ->
          # Fallback: strip HTML tags
          strip_tags(html)
      end
    rescue
      _ -> strip_tags(html)
    end
  end

  def parse(_), do: ""

  defp remove_unwanted_tags(tree) do
    Floki.filter_out(tree, Enum.join(@unwanted_tags, ", "))
  rescue
    _ -> tree
  end

  defp to_markdown(tree) do
    tree
    |> Floki.traverse_and_update(&convert_node/1)
    |> Floki.text(sep: " ")
  rescue
    _ -> Floki.text(tree, sep: " ")
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
  defp convert_node({"hr", _attrs, _children}), do: {"span", [], ["\n---\n"]}
  defp convert_node({"p", _attrs, children}), do: {"span", [], children ++ ["\n\n"]}
  defp convert_node({"div", _attrs, children}), do: {"span", [], children ++ ["\n"]}
  defp convert_node({"strong", _attrs, children}), do: {"span", [], ["**"] ++ children ++ ["**"]}
  defp convert_node({"b", _attrs, children}), do: {"span", [], ["**"] ++ children ++ ["**"]}
  defp convert_node({"em", _attrs, children}), do: {"span", [], ["*"] ++ children ++ ["*"]}
  defp convert_node({"i", _attrs, children}), do: {"span", [], ["*"] ++ children ++ ["*"]}
  defp convert_node({"code", _attrs, children}), do: {"span", [], ["`"] ++ children ++ ["`"]}

  defp convert_node({"pre", _attrs, children}),
    do: {"span", [], ["\n```\n"] ++ children ++ ["\n```\n"]}

  defp convert_node({"img", attrs, _children}) do
    alt = get_attr(attrs, "alt", "image")
    src = get_attr(attrs, "src", "")
    {"span", [], ["![#{alt}](#{src})"]}
  end

  defp convert_node(node), do: node

  defp get_attr(attrs, attr_name, default) do
    case List.keyfind(attrs, attr_name, 0) do
      {^attr_name, value} -> value
      nil -> default
    end
  end

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.replace(~r/ {2,}/, " ")
  end

  defp strip_tags(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
