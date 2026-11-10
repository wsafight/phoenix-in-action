defmodule AuctionTest do
  use ExUnit.Case
  doctest Auction

  test "list_items/0 returns the fake items" do
    assert [%Auction.Item{} | _] = Auction.list_items()
  end
end
