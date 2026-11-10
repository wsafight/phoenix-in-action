defmodule AuctionWeb.Api.ItemJSON do
  alias AuctionWeb.Api.BidJSON

  def index(%{items: items}) do
    %{data: for(item <- items, do: item(item))}
  end

  def show(%{item: item}) do
    %{data: item_with_bids(item)}
  end

  defp item_with_bids(item) do
    %{
      type: "item",
      id: item.id,
      title: item.title,
      description: item.description,
      ends_at: item.ends_at,
      bids: for(bid <- item.bids, do: BidJSON.bid(%{bid: bid}))
    }
  end

  defp item(item) do
    %{
      type: "item",
      id: item.id,
      title: item.title,
      description: item.description,
      ends_at: item.ends_at
    }
  end
end
