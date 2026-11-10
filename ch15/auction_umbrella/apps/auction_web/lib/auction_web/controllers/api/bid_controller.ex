defmodule AuctionWeb.Api.BidController do
  use AuctionWeb, :controller

  plug AuctionWeb.Api.Authenticate when action in [:create]

  def create(conn, %{"amount" => amount, "item_id" => item_id}) do
    case Auction.insert_bid(%{
           amount: amount,
           item_id: item_id,
           user_id: conn.assigns.current_user.id
         }) do
      {:ok, bid} ->
        bid = Auction.get_bid(bid.id)

        html =
          Phoenix.Template.render_to_string(
            AuctionWeb.BidHTML,
            "bid",
            "html",
            bid: bid
          )

        AuctionWeb.Endpoint.broadcast("item:#{item_id}", "new_bid", %{body: html})

        conn
        |> put_status(:created)
        |> put_resp_header("location", ~p"/api/items/#{bid.item_id}")
        |> render("show.json", bid: bid)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: AuctionWeb.Api.ChangesetJSON)
        |> render("error.json", changeset: changeset)
    end
  end
end
