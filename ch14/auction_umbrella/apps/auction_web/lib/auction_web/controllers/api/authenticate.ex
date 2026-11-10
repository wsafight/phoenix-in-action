defmodule AuctionWeb.Api.Authenticate do
  @moduledoc """
  API write endpoints reuse the browser session cookie: `:api` pipeline fetches
  the session and `Authenticator` puts the user into assigns. This plug turns an
  anonymous request into a 401 JSON response before the controller runs.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %Auction.User{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_status(:unauthorized)
    |> json(%{errors: %{detail: "Authentication required"}})
    |> halt()
  end
end
