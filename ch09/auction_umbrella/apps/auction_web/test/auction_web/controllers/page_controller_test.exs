defmodule AuctionWeb.PageControllerTest do
  use AuctionWeb.ConnCase

  test "GET /", %{conn: conn} do
    {:ok, _item} = Auction.insert_item(%{title: "test item"})
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ "test item"
  end
end
