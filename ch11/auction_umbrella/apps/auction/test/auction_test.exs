defmodule AuctionTest do
  use ExUnit.Case
  alias Auction.{Bid, Item, Repo, User}
  import Ecto.Query
  doctest Auction, import: true

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  describe "list_items/0" do
    setup do
      {:ok, item1} = Repo.insert(%Item{title: "Item 1"})
      {:ok, item2} = Repo.insert(%Item{title: "Item 2"})
      {:ok, item3} = Repo.insert(%Item{title: "Item 3"})
      %{items: [item1, item2, item3]}
    end

    test "returns all Items in the database", %{items: items} do
      assert items == Auction.list_items()
    end
  end

  describe "get_item/1" do
    setup do
      {:ok, item1} = Repo.insert(%Item{title: "Item 1"})
      {:ok, item2} = Repo.insert(%Item{title: "Item 2"})
      %{items: [item1, item2]}
    end

    test "returns a single Item based on id", %{items: items} do
      item = Enum.at(items, 1)
      assert item == Auction.get_item(item.id)
    end
  end

  describe "get_item_with_bids/1" do
    setup do
      {:ok, user} =
        Auction.insert_user(%{
          username: "testuser",
          email_address: "test@example.com",
          password: "password",
          password_confirmation: "password"
        })

      {:ok, item} = Auction.insert_item(%{title: "test item"})

      {:ok, bid} = Auction.insert_bid(%{amount: 500, user_id: user.id, item_id: item.id})
      %{item: item, user: user, bid: bid}
    end

    test "returns the Item with its bids and each bid's user preloaded",
         %{item: item, user: user, bid: bid} do
      result = Auction.get_item_with_bids(item.id)

      assert result.id == item.id
      assert [loaded_bid] = result.bids
      assert loaded_bid.id == bid.id
      assert %User{} = loaded_bid.user
      assert loaded_bid.user.id == user.id
    end
  end

  describe "insert_item/1" do
    test "adds an Item to the database" do
      count_query = from(i in Item, select: count(i.id))
      before_count = Repo.one(count_query)
      {:ok, _item} = Auction.insert_item(%{title: "test item"})
      assert Repo.one(count_query) == before_count + 1
    end

    test "the Item in the database has the attributes provided" do
      attrs = %{title: "test item", description: "test description"}
      {:ok, item} = Auction.insert_item(attrs)
      assert item.title == attrs.title
      assert item.description == attrs.description
    end

    test "it returns an error on error" do
      assert {:error, _changeset} = Auction.insert_item(%{foo: :bar})
    end
  end

  describe "insert_user/1" do
    test "creates a User with a hashed password" do
      {:ok, user} =
        Auction.insert_user(%{
          username: "testuser",
          email_address: "test@example.com",
          password: "password",
          password_confirmation: "password"
        })

      assert %User{} = user
      assert user.username == "testuser"
      assert is_binary(user.hashed_password)
      refute user.hashed_password == "password"
    end

    test "returns an error when the password confirmation does not match" do
      assert {:error, _changeset} =
               Auction.insert_user(%{
                 username: "testuser",
                 email_address: "test@example.com",
                 password: "password",
                 password_confirmation: "different"
               })
    end
  end

  describe "get_user_by_username_and_password/2" do
    setup do
      {:ok, user} =
        Auction.insert_user(%{
          username: "testuser",
          email_address: "test@example.com",
          password: "password",
          password_confirmation: "password"
        })

      %{user: user}
    end

    test "returns the User when the credentials match", %{user: user} do
      found = Auction.get_user_by_username_and_password("testuser", "password")
      assert found.id == user.id
    end

    test "returns false when the username does not exist" do
      refute Auction.get_user_by_username_and_password("nouser", "password")
    end

    test "returns false when the password is wrong" do
      refute Auction.get_user_by_username_and_password("testuser", "wrongpassword")
    end
  end

  describe "insert_bid/1" do
    setup do
      {:ok, user} =
        Auction.insert_user(%{
          username: "testuser",
          email_address: "test@example.com",
          password: "password",
          password_confirmation: "password"
        })

      {:ok, item} = Auction.insert_item(%{title: "test item"})
      %{user: user, item: item}
    end

    test "adds a Bid to the database", %{user: user, item: item} do
      {:ok, bid} = Auction.insert_bid(%{amount: 500, user_id: user.id, item_id: item.id})
      assert %Bid{} = bid
      assert bid.amount == 500
    end

    test "returns an error changeset with invalid params" do
      assert {:error, _changeset} = Auction.insert_bid(%{foo: :bar})
    end
  end

  describe "get_bids_for_user/1" do
    test "returns the user's bids with the item preloaded" do
      {:ok, user} =
        Auction.insert_user(%{
          username: "testuser",
          email_address: "test@example.com",
          password: "password",
          password_confirmation: "password"
        })

      {:ok, item} = Auction.insert_item(%{title: "test item"})

      {:ok, _bid} = Auction.insert_bid(%{amount: 500, user_id: user.id, item_id: item.id})

      [bid] = Auction.get_bids_for_user(user)
      assert bid.user_id == user.id
      assert %Item{} = bid.item
      assert bid.item.id == item.id
    end
  end
end
