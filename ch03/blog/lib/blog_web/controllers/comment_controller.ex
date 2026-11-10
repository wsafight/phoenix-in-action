defmodule BlogWeb.CommentController do
  use BlogWeb, :controller

  alias Blog.App

  def create(conn, %{"post_id" => post_id, "comment" => comment_params}) do
    case App.create_comment_for_post(comment_params, post_id) do
      {:ok, comment} ->
        conn
        |> put_flash(:info, "Thanks for submitting your comment.")
        |> redirect(to: ~p"/posts/#{comment.post_id}")

      {:error, %Ecto.Changeset{} = _changeset} ->
        conn
        |> put_flash(:warning, "Your comment was not submitted successfully")
        |> redirect(to: ~p"/posts/#{post_id}")
    end
  end
end
