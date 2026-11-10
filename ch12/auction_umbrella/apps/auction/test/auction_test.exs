defmodule AuctionTest do
  use ExUnit.Case
  doctest Auction

  test "new_item/0 returns an empty changeset" do
    assert %Ecto.Changeset{} = Auction.new_item()
  end
end
