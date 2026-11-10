defmodule AuctionWeb.ItemLive.Show do
  use AuctionWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AuctionWeb.PubSub, "item:#{id}")
    end

    socket =
      socket
      |> assign(:page_title, "Item #{id}")
      |> assign(:item, Auction.get_item_with_bids(id))
      |> assign(:form, to_form(Auction.new_bid()))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>{@item.title}</h1>

    <ul>
      <li><strong>Description:</strong> {@item.description}</li>
      <li><strong>Auction ends at:</strong> {@item.ends_at}</li>
    </ul>

    <div style="display: flex; flex-direction: row;">
      <div style="flex: 1">
        <h2>Current bids</h2>
        <p :for={bid <- @item.bids} id={"bid-#{bid.id}"}>
          {integer_to_currency(bid.amount)} <em>from {bid.user.username}</em>
        </p>
      </div>

      <div style="flex: 1">
        <%= if @current_user do %>
          <h2>Place your bid!</h2>
          <.form :let={f} for={@form} phx-submit="save">
            <div class="form-group">
              <.input field={f[:amount]} type="number" label="Bid amount" />
            </div>
            <.button type="submit" phx-disable-with="Placing...">Submit</.button>
          </.form>
        <% else %>
          <p>
            <.link navigate={~p"/login"}>Log in</.link> to place a bid.
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("save", %{"bid" => %{"amount" => amount}}, socket) do
    item = socket.assigns.item

    case Auction.insert_bid(%{
           amount: amount,
           item_id: item.id,
           user_id: socket.assigns.current_user.id
         }) do
      {:ok, _bid} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Auction.new_bid()))
         |> reload_item()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # Another bid landed — either in this LiveView, in another browser tab, over
  # the HTML form, or through the JSON API. Refetch so `bids` keeps its
  # server-side ordering.
  @impl true
  def handle_info(%{event: "new_bid"}, socket) do
    {:noreply, reload_item(socket)}
  end

  defp reload_item(socket) do
    assign(socket, :item, Auction.get_item_with_bids(socket.assigns.item.id))
  end
end
