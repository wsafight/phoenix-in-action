defmodule AuctionTest do
  use ExUnit.Case
  alias Auction.{Item, Repo}
  import Ecto.Query
  doctest Auction

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  describe "list_items/0" do
    setup do
      {:ok, item1} = Repo.insert(%Item{title: "Item 1"})
      {:ok, item2} = Repo.insert(%Item{title: "Item 2"})
      %{items: [item1, item2]}
    end

    test "returns all Items in the database", %{items: items} do
      assert items == Auction.list_items()
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
  end

  describe "update_item/2" do
    test "updates the Item with the attributes provided" do
      {:ok, item} = Repo.insert(%Item{title: "Item 1"})
      {:ok, updated} = Auction.update_item(item, %{title: "Updated Item"})
      assert updated.title == "Updated Item"
      assert Auction.get_item(item.id).title == "Updated Item"
    end

    test "returns an error changeset for invalid attributes" do
      {:ok, item} = Repo.insert(%Item{title: "Item 1"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Auction.update_item(item, %{title: "ab"})

      assert "should be at least 3 character(s)" in errors_on(changeset).title
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
