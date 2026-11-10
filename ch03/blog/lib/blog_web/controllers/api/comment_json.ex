defmodule BlogWeb.API.CommentJSON do
  alias Blog.API.Comment

  @doc """
  Renders a single comment.
  """
  def data(%Comment{} = comment) do
    %{id: comment.id, name: comment.name, body: comment.body}
  end
end
