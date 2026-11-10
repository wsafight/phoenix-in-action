defmodule AuctionWeb.Api.BidJSON do
  alias AuctionWeb.Api.UserJSON

  def bid(%{bid: bid}) do
    %{
      type: "bid",
      id: bid.id,
      amount: bid.amount,
      user: bid.user && UserJSON.user(%{user: bid.user})
    }
  end
end
