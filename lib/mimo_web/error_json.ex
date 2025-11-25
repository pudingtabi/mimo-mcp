defmodule MimoWeb.ErrorJSON do
  @moduledoc """
  JSON error rendering for the Universal Aperture API.
  """

  def render("404.json", _assigns) do
    %{error: "Not found"}
  end

  def render("500.json", _assigns) do
    %{error: "Internal server error"}
  end

  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end
