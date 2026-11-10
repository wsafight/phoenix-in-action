defmodule AuctionWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "app" layout is the only layout used by this application
  (it contains the full HTML document), matching the behaviour
  of the original Phoenix 1.4 layout.
  """
  use AuctionWeb, :html

  embed_templates "layouts/*"
end
