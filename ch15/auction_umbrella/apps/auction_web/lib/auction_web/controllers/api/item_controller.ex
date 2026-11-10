defmodule AuctionWeb.Api.ItemController do
  use AuctionWeb, :controller

  plug AuctionWeb.Api.Authenticate when action in [:create]

  def index(conn, _params) do
    items = Auction.list_items()
    render(conn, "index.json", items: items)
  end

  def show(conn, %{"id" => id}) do
    item = Auction.get_item_with_bids(id)
    render(conn, "show.json", item: item)
  end

  def create(conn, %{"item" => item_params}) do
    case Auction.insert_item(item_params) do
      {:ok, item} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", ~p"/api/items/#{item.id}")
        |> render("show.json", item: Auction.get_item_with_bids(item.id))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: AuctionWeb.Api.ChangesetJSON)
        |> render("error.json", changeset: changeset)
    end
  end
end
