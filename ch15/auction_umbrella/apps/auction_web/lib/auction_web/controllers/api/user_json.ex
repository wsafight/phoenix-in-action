defmodule AuctionWeb.Api.UserJSON do
  @moduledoc """
  Renders users as JSON.
  """

  def user(%{user: user}) do
    %{
      type: "user",
      id: user.id,
      username: user.username
    }
  end
end
