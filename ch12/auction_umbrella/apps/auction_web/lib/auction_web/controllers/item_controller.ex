defmodule AuctionWeb.ItemController do
  use AuctionWeb, :controller

  def index(conn, _params) do
    items = Auction.list_items()
    render(conn, :index, items: items)
  end

  def show(conn, %{"id" => id}) do
    item = Auction.get_item_with_bids(id)
    bid = Auction.new_bid()
    render(conn, :show, item: item, bid: bid)
  end

  def new(conn, _params) do
    item = Auction.new_item()
    render(conn, :new, item: item)
  end

  def create(conn, %{"item" => item_params}) do
    case Auction.insert_item(item_params) do
      {:ok, item} -> redirect(conn, to: ~p"/items/#{item}")
      {:error, item} -> render(conn, :new, item: item)
    end
  end

  def edit(conn, %{"id" => id}) do
    item = Auction.edit_item(id)
    render(conn, :edit, item: item)
  end

  def update(conn, %{"id" => id, "item" => item_params}) do
    item = Auction.get_item(id)

    case Auction.update_item(item, item_params) do
      {:ok, item} -> redirect(conn, to: ~p"/items/#{item}")
      {:error, item} -> render(conn, :edit, item: item)
    end
  end
end
