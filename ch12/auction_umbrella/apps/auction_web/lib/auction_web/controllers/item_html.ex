defmodule AuctionWeb.ItemHTML do
  use AuctionWeb, :html

  alias AuctionWeb.BidHTML

  embed_templates "item_html/*"
end
