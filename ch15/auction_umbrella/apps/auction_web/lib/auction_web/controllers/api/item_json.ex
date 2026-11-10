defmodule AuctionWeb.Api.ItemJSON do
  @moduledoc """
  Renders items as JSON.
  """

  alias AuctionWeb.Api.BidJSON

  def index(%{items: items}) do
    %{data: for(item <- items, do: data(item))}
  end

  def show(%{item: item}) do
    %{data: data_with_bids(item)}
  end

  defp data(item) do
    %{
      type: "item",
      id: item.id,
      title: item.title,
      description: item.description,
      ends_at: item.ends_at
    }
  end

  defp data_with_bids(item) do
    item
    |> data()
    |> Map.put(:bids, for(bid <- item.bids, do: BidJSON.bid(%{bid: bid})))
  end
end
