defmodule AuctionTest do
  use ExUnit.Case
  doctest Auction

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Auction.Repo)
  end

  test "list_items/0 returns the items" do
    assert is_list(Auction.list_items())
  end
end
