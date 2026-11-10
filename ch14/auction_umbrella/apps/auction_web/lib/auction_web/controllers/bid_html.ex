defmodule AuctionWeb.BidHTML do
  @moduledoc """
  This module contains pages rendered by BidController.

  See the `bid_html` directory for all templates available.
  """
  use AuctionWeb, :html

  embed_templates "bid_html/*"
end
