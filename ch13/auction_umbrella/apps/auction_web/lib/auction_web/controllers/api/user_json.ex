defmodule AuctionWeb.Api.UserJSON do
  def user(%{user: user}) do
    %{
      type: "user",
      id: user.id,
      username: user.username
    }
  end
end
