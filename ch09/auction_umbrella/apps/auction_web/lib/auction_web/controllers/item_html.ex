defmodule AuctionWeb.ItemHTML do
  @moduledoc """
  This module contains pages rendered by ItemController.

  See the `item_html` directory for all templates available.
  """
  use AuctionWeb, :html

  import PhoenixHTMLHelpers.Form, only: [datetime_select: 2]

  embed_templates "item_html/*"
end
