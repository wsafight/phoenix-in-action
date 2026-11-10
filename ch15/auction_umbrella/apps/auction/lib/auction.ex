defmodule Auction do
  @moduledoc """
  Provides functions for interacting with the database layer of an Auction application.

  In order to keep database concerns separate from the rest of an application, these
  functions are provided. Any interaction you need to do with the database can be done
  from within these functions. See an individual function's documentation for more
  information and usage examples (like `Auction.get_user_by_username_and_password/2`).
  """

  alias Auction.{Bid, BidCache, Item, User, Password}
  import Ecto.Query

  @repo Auction.Repo

  def list_items do
    @repo.all(Item)
  end

  def get_item(id) do
    @repo.get!(Item, id)
  end

  def get_item_by(attrs) do
    @repo.get_by(Item, attrs)
  end

  def insert_item(attrs) do
    %Item{}
    |> Item.changeset(attrs)
    |> @repo.insert()
  end

  def delete_item(%Auction.Item{} = item), do: @repo.delete(item)

  def update_item(%Auction.Item{} = item, updates) do
    item
    |> Item.changeset(updates)
    |> @repo.update()
  end

  def new_item, do: Item.changeset(%Item{})

  def edit_item(id) do
    get_item(id)
    |> Item.changeset()
  end

  def get_user(id), do: @repo.get!(User, id)

  def new_user, do: User.changeset_with_password(%User{})

  def insert_user(params) do
    %User{}
    |> User.changeset_with_password(params)
    |> @repo.insert()
  end

  @doc """
  Retrieves a User from the database matching the provided username and password

  ## Return values

  Depending on what is found in the database, two different values could be
  returned:

    * a `Auction.User` struct: An `Auction.User` record was found that matched
      the `username` and `password` that was provided.
    * `false`: No `Auction.User` could be found with the provided `username`
      and `password`.

  You can then use the returned value to determine whether or not the User is
  authorized in your application. If an `Auction.User` is _not_ found based on
  `username`, the computational work of hashing a password is still done.

  ## Examples

      iex> insert_user(%{username: "geo", password: "example", password_confirmation: "example", email_address: "test@example.com"})
      ...> result = get_user_by_username_and_password("geo", "example")
      ...> match?(%Auction.User{username: "geo"}, result)
      true

      iex> get_user_by_username_and_password("no_user", "bad_password")
      false
  """
  def get_user_by_username_and_password(username, password) do
    with user when not is_nil(user) <- @repo.get_by(User, %{username: username}),
         true <- Password.verify_with_hash(password, user.hashed_password) do
      user
    else
      _ -> Password.dummy_verify()
    end
  end

  def insert_bid(params) do
    case %Bid{} |> Bid.changeset(params) |> @repo.insert() do
      {:ok, bid} = ok ->
        maybe_update_cache(bid)
        ok

      error ->
        error
    end
  end

  @doc """
  The highest bid amount for `item_id`, or `nil` when the item has no bids.

  Reads the `BidCache` first and only touches the database on a miss. When
  `BidCache` isn't running (including the moments right after a crash and
  restart), the cache-aside pattern falls back to SQL and refills the cache.
  """
  def highest_bid(item_id) do
    if cache_running?() do
      case BidCache.fetch(item_id) do
        :miss -> read_highest_bid_from_repo(item_id)
        amount -> amount
      end
    else
      read_highest_bid_from_repo(item_id)
    end
  end

  defp read_highest_bid_from_repo(item_id) do
    amount = @repo.one(from b in Bid, where: b.item_id == ^item_id, select: max(b.amount))

    if cache_running?() && amount do
      BidCache.fill(item_id, amount)
    end

    amount
  end

  defp maybe_update_cache(bid) do
    if cache_running?(), do: BidCache.put(bid.item_id, bid.amount)
  end

  defp cache_running?, do: Process.whereis(BidCache) != nil

  def get_bid(id) do
    @repo.get!(Bid, id)
    |> @repo.preload(:user)
  end

  def new_bid, do: Bid.changeset(%Bid{})

  def get_item_with_bids(id) do
    id
    |> get_item()
    |> @repo.preload(bids: from(b in Bid, order_by: [desc: b.inserted_at]))
    |> @repo.preload(bids: [:user])
  end

  def get_bids_for_user(user) do
    query =
      from(b in Bid,
        where: b.user_id == ^user.id,
        order_by: [desc: :inserted_at],
        preload: :item,
        limit: 10
      )

    @repo.all(query)
  end
end
