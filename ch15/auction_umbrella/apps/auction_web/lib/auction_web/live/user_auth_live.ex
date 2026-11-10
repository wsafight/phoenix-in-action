defmodule AuctionWeb.UserAuthLive do
  @moduledoc """
  on_mount hook shared by LiveViews that need `current_user`.

  `live_session` copies the Plug session into the WebSocket `session` map, so
  the `user_id` written by `SessionController.create/2` arrives here verbatim.
  """

  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    user =
      case session["user_id"] do
        nil -> nil
        id -> Auction.get_user(id)
      end

    {:cont, assign(socket, :current_user, user)}
  end
end
