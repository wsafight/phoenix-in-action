defmodule AuctionWeb.GlobalHelpers do
  @moduledoc """
  Conveniences for rendering values across the whole interface,
  such as currency and date formatting helpers.
  """

  def integer_to_currency(cents) do
    dollars_and_cents =
      cents
      |> Decimal.div(100)
      |> Decimal.round(2)

    "$#{dollars_and_cents}"
  end

  def formatted_datetime(datetime) do
    Timex.format!(datetime, "{YYYY}-{0M}-{0D} {h12}:{m}:{s}{am}")
  end
end
