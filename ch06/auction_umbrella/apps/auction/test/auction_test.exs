defmodule AuctionTest do
  use ExUnit.Case
  doctest Auction

  test "lists items from the fake repo" do
    assert [%Auction.Item{} | _] = Auction.list_items()
  end
end
