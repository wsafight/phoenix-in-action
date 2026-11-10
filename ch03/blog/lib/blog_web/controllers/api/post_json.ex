defmodule BlogWeb.API.PostJSON do
  alias Blog.API.Post
  alias BlogWeb.API.CommentJSON

  @doc """
  Renders a list of posts.
  """
  def index(%{posts: posts}) do
    %{data: for(post <- posts, do: post(post))}
  end

  @doc """
  Renders a single post.
  """
  def show(%{post: post}) do
    %{data: post_with_comments(post)}
  end

  defp post(%Post{} = post) do
    %{id: post.id, title: post.title, body: post.body}
  end

  defp post_with_comments(%Post{} = post) do
    %{
      id: post.id,
      title: post.title,
      body: post.body,
      comments: for(comment <- post.comments, do: CommentJSON.data(comment))
    }
  end
end
