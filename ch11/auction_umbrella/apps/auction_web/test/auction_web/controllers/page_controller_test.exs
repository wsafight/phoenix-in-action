defmodule AuctionWeb.PageControllerTest do
  use AuctionWeb.ConnCase

  test "GET / lists the items", %{conn: conn} do
    {:ok, _item} = Auction.insert_item(%{title: "My first item"})

    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "My first item"
  end
end
