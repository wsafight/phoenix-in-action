defmodule AuctionWeb.Api.ChangesetJSON do
  @moduledoc """
  Renders changeset errors as JSON.
  """

  alias AuctionWeb.CoreComponents

  @doc """
  Traverses the changeset errors and returns a map of error messages. For
  example, `%{title: ["can't be blank"]}`.
  """
  def error(%{changeset: changeset}) do
    %{
      errors: Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)
    }
  end
end
