defmodule AuctionWeb.Api.BidJSON do
  @moduledoc """
  Renders bids as JSON.
  """

  def bid(%{bid: bid}) do
    %{
      type: "bid",
      id: bid.id,
      amount: bid.amount,
      user: AuctionWeb.Api.UserJSON.user(%{user: bid.user})
    }
  end
end
