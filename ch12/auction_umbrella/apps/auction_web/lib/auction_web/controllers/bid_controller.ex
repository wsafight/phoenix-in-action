defmodule AuctionWeb.BidController do
  use AuctionWeb, :controller

  plug :require_logged_in_user

  def create(conn, %{"bid" => %{"amount" => amount}, "item_id" => item_id}) do
    case Auction.insert_bid(%{
           amount: amount,
           item_id: item_id,
           user_id: conn.assigns.current_user.id
         }) do
      {:ok, bid} ->
        html =
          Phoenix.Template.render_to_iodata(AuctionWeb.BidHTML, "bid", "html",
            bid: bid,
            username: conn.assigns.current_user.username
          )
          |> IO.iodata_to_binary()

        AuctionWeb.Endpoint.broadcast("item:#{item_id}", "new_bid", %{body: html})
        redirect(conn, to: ~p"/items/#{bid.item_id}")

      {:error, bid} ->
        item = Auction.get_item_with_bids(item_id)

        conn
        |> put_view(html: AuctionWeb.ItemHTML)
        |> render(:show, item: item, bid: bid)
    end
  end

  defp require_logged_in_user(%{assigns: %{current_user: nil}} = conn, _opts) do
    conn
    |> put_flash(:error, "Nice try, friend. You must be logged in to bid.")
    |> redirect(to: ~p"/items")
    |> halt()
  end

  defp require_logged_in_user(conn, _opts), do: conn
end
