defmodule AuctionWeb.SessionController do
  use AuctionWeb, :controller

  def new(conn, _params) do
    render(conn, :new, form: login_form(%{}))
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password} = user_params}) do
    case Auction.get_user_by_username_and_password(username, password) do
      %Auction.User{} = user ->
        conn
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Successfully logged in")
        |> redirect(to: ~p"/users/#{user}")

      _ ->
        conn
        |> put_flash(:error, "That username and password combination cannot be found")
        |> render(:new, form: login_form(user_params))
    end
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> redirect(to: ~p"/items")
  end

  defp login_form(params), do: Phoenix.Component.to_form(params, as: :user)
end
