defmodule AuctionWeb.ItemHTML do
  use AuctionWeb, :html

  embed_templates "item_html/*"

  @doc """
  Renders year/month/day/hour/minute selects for a datetime form
  field, emitting the same nested params (`item[ends_at][year]`, ...)
  that the removed `Phoenix.HTML.Form.datetime_select/3` produced.
  """
  attr :field, Phoenix.HTML.FormField, required: true

  def datetime_select(assigns) do
    name = Phoenix.HTML.Form.input_name(assigns.field.form, assigns.field.field)
    id = Phoenix.HTML.Form.input_id(assigns.field.form, assigns.field.field)
    value = datetime_values(assigns.field.value)

    assigns =
      assigns
      |> assign(:name, name)
      |> assign(:id, id)
      |> assign(:value, value)

    ~H"""
    <select name={"#{@name}[year]"} id={"#{@id}_year"}>
      {Phoenix.HTML.Form.options_for_select(year_options(@value), @value[:year])}
    </select>
    <select name={"#{@name}[month]"} id={"#{@id}_month"}>
      {Phoenix.HTML.Form.options_for_select(1..12, @value[:month])}
    </select>
    <select name={"#{@name}[day]"} id={"#{@id}_day"}>
      {Phoenix.HTML.Form.options_for_select(1..31, @value[:day])}
    </select>
    —
    <select name={"#{@name}[hour]"} id={"#{@id}_hour"}>
      {Phoenix.HTML.Form.options_for_select(0..23, @value[:hour])}
    </select>
    :
    <select name={"#{@name}[minute]"} id={"#{@id}_minute"}>
      {Phoenix.HTML.Form.options_for_select(0..59, @value[:minute])}
    </select>
    """
  end

  defp datetime_values(%{year: _, month: _, day: _, hour: _, minute: _} = value) do
    %{
      year: value.year,
      month: value.month,
      day: value.day,
      hour: value.hour,
      minute: value.minute
    }
  end

  defp datetime_values(%{} = params) do
    # Raw params map, e.g. after a failed changeset cast
    for part <- ~w(year month day hour minute),
        value = params[part] || params[String.to_atom(part)],
        into: %{},
        do: {String.to_atom(part), value}
  end

  defp datetime_values(_), do: %{}

  defp year_options(%{year: year}) when is_integer(year) do
    (year - 5)..(year + 5)
  end

  defp year_options(%{year: year}) when is_binary(year) do
    case Integer.parse(year) do
      {year, ""} -> (year - 5)..(year + 5)
      _ -> year_options(%{})
    end
  end

  defp year_options(_) do
    year = DateTime.utc_now().year
    (year - 5)..(year + 5)
  end
end
