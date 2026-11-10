defmodule AuctionTest do
  use ExUnit.Case
  doctest Auction

  test "list_items/0 returns the items" do
    assert is_list(Auction.list_items())
  end
end
