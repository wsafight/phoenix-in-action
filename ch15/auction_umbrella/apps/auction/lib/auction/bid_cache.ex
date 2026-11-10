defmodule Auction.BidCache do
  @moduledoc """
  Keeps the highest bid amount per item in memory so `Auction.highest_bid/1`
  doesn't have to aggregate over the bids table on every read.

  The cache is deliberately throwaway: it warms up lazily from the database on
  first read, and if this GenServer crashes the supervisor restarts it empty —
  the next `highest_bid/1` call transparently falls back to SQL and refills it.
  Losing the cache is a missed optimization, never an error.
  """

  use GenServer

  @name __MODULE__

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Returns the highest bid for `item_id` from the cache, or `:miss`.
  """
  def fetch(item_id) do
    GenServer.call(@name, {:fetch, item_id})
  end

  @doc """
  Records a bid amount for `item_id`. Only updates the entry when the new
  amount is higher, so out-of-order events can't regress the cache.
  """
  def put(item_id, amount) do
    GenServer.cast(@name, {:put, item_id, amount})
  end

  @doc """
  Stores an exact `amount` for `item_id` (used when refilling from the repo,
  where the value is authoritative rather than one of many bids).
  """
  def fill(item_id, amount) do
    GenServer.call(@name, {:fill, item_id, amount})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:fetch, item_id}, _from, maxima) do
    {:reply, Map.get(maxima, item_id, :miss), maxima}
  end

  def handle_call({:fill, item_id, amount}, _from, maxima) do
    {:reply, amount, Map.put(maxima, item_id, amount)}
  end

  @impl true
  def handle_cast({:put, item_id, amount}, maxima) do
    current = Map.get(maxima, item_id, 0)
    {:noreply, Map.put(maxima, item_id, max(current, amount))}
  end
end
