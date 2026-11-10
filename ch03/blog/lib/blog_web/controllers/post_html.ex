defmodule BlogWeb.PostHTML do
  @moduledoc """
  This module contains pages rendered by PostController.

  See the `post_html` directory for all templates available.
  """
  use BlogWeb, :html

  import PhoenixHTMLHelpers.Format

  embed_templates "post_html/*"

  def date(date_to_display), do: Date.to_string(date_to_display)
end
