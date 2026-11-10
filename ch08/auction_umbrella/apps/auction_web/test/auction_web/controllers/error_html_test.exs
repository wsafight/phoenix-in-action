defmodule AuctionWeb.ErrorHTMLTest do
  use AuctionWeb.ConnCase, async: true

  # Bring render/3 and render_to_string/3 for testing custom views
  import Phoenix.Template

  test "renders 404.html" do
    assert render_to_string(AuctionWeb.ErrorHTML, "404.html", "html", []) == "Not Found"
  end

  test "renders 500.html" do
    assert render_to_string(AuctionWeb.ErrorHTML, "500.html", "html", []) ==
             "Internal Server Error"
  end
end
