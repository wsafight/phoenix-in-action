---
title: 第16章 · OTP 进程
description: 在 ch15 上给 auction 应用加 BidCache：一个被监督的 GenServer 缓存每商品最高价，insert_bid 顺手更新它，崩溃时监督者拉起新进程、cache-aside 回落到 SQL，把"let it crash"落到真实代码上
sidebar:
  order: 16
---

到现在为止，`auction` 应用的监督树里只有一个孩子：`{Auction.Repo, []}`。
领域层没有自己的进程——FakeRepo 是常量列表，Ecto Repo 是 Ecto 管的
连接池，业务逻辑全部以"函数"形态存在，不需要常驻。

本章给它加第二个孩子：`Auction.BidCache`，一个被监督的 GenServer。
它干的事非常具体：把"每个商品目前的最高出价"缓存在内存里，列表页、
详情页以后不用再对 `bids` 表跑 `SELECT max(amount)`。这不是性能优化
练习，是拿它当"进程长什么样、监督树怎么兑现 let it crash"的最小可
运行示例——崩一次给你看。

## `BidCache`：一个 GenServer 的全文

```elixir
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

  def fetch(item_id) do
    GenServer.call(@name, {:fetch, item_id})
  end

  def put(item_id, amount) do
    GenServer.cast(@name, {:put, item_id, amount})
  end

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
```

`ch15/auction_umbrella/apps/auction/lib/auction/bid_cache.ex`

GenServer 的三段接口各管一件事：`init` 决定进程出生时的状态（这里是
一个空 map，`item_id => 最高价`）；`handle_call` 处理需要回复的
同步调用（`fetch` 读当前值、`fill` 把数据库算出来的权威值写回去）；
`handle_cast` 处理"发了就忘"的异步通知（`put` 新出价）。

注意 `put` 的语义：它不是盲写，是 `max(current, amount)`。出价可能
乱序到达（两个浏览器几乎同时出价、Channel 推送先到还是后到说不准），
缓存只关心"见过的最大数"，不关心到达顺序。乱序写不进更小值，这是
缓存不会退化的唯一保证。

## 挂进监督树

```elixir
    children = [
      # Starts a worker by calling: Auction.Worker.start_link(arg)
      # {Auction.Worker, arg},
      {Auction.Repo, []},
      {Auction.BidCache, []}
    ]
```

`ch15/auction_umbrella/apps/auction/lib/auction/application.ex`

`{Auction.BidCache, []}` 告诉 Supervisor 启动它时调
`Auction.BidCache.start_link([])`（`start_link/1` 是 `use GenServer`
给的标准 child spec 入口）。`one_for_one` 策略下它崩了只重启它自己，
`Auction.Repo` 不动。

挂在 `auction` 这棵树上而不是 `auction_web`，和第 3 章 deps 归属
一个道理：数据缓存归领域层管，Web 层不感知缓存进程的存在，调
`Auction.highest_bid` 就行。

## `highest_bid`：cache-aside 模式

```elixir
  @doc """
  The highest bid amount for `item_id`, or `nil` when the item has no bids.

  Reads the `BidCache` first and only touches the database on a miss. When
  `BidCache` isn't running (including the moments right after a crash and
  restart), the cache-aside pattern falls back to SQL and refills the cache.
  """
  def highest_bid(item_id) do
    if cache_running?() do
      case BidCache.fetch(item_id) do
        :miss -> read_highest_bid_from_repo(item_id)
        amount -> amount
      end
    else
      read_highest_bid_from_repo(item_id)
    end
  end

  defp read_highest_bid_from_repo(item_id) do
    amount = @repo.one(from b in Bid, where: b.item_id == ^item_id, select: max(b.amount))

    if cache_running?() && amount do
      BidCache.fill(item_id, amount)
    end

    amount
  end

  defp maybe_update_cache(bid) do
    if cache_running?(), do: BidCache.put(bid.item_id, bid.amount)
  end

  defp cache_running?, do: Process.whereis(BidCache) != nil
```

`ch15/auction_umbrella/apps/auction/lib/auction.ex`

`highest_bid` 的读路径是教科书式的 cache-aside：

1. 先问缓存，`BidCache.fetch` 命中就直接返回，一条 SQL 都不发；
2. 缓存回 `:miss`（冷启动、或刚崩完被重启了），走 `read_highest_bid_from_repo`
   真查 `SELECT max(amount)`，查到就把结果 `fill` 进缓存再返回；
3. `BidCache` 进程压根没起来（监督者还没来得及拉起、或者测试环境
   手动没启动），`cache_running?` 守门直接走 SQL，缓存这层透明消失。

`Process.whereis(BidCache)` 返回进程注册名对应的 pid；`BidCache` 是用
`name: __MODULE__` 注册的 GenServer，名字在模块属性 `@name` 里写着。
`whereis` 返回 `nil` 就是"这个进程不存在"——这一步是"缓存不可用时
照常工作"的兜底，没有它 `BidCache` 一崩整个 `highest_bid` 跟着死。

## `insert_bid` 顺手更新缓存

```elixir
  def insert_bid(params) do
    case %Bid{} |> Bid.changeset(params) |> @repo.insert() do
      {:ok, bid} = ok ->
        maybe_update_cache(bid)
        ok

      error ->
        error
    end
  end
```

`ch15/auction_umbrella/apps/auction/lib/auction.ex`

插入成功才更新缓存，`maybe_update_cache` 里 `cache_running?` 再守
一层：cache 没起来的时候 `insert_bid` 不能跟着失败，写入路径对缓存
零依赖。这个 if 看着多，但它兑现了 doc 里那句"缓存是优化，不是依赖"。

## 崩一次给你看

监督树的"let it crash"一直是概念，这次它是真的。`Process.exit/2` 用
`:kill` 发一条致命信号——和普通 `raise` 不同，`:kill` 不可捕获，
进程当场死：

```elixir
iex> pid = Process.whereis(Auction.BidCache)
#PID<0.324.0>
iex> Process.exit(pid, :kill)
true
iex> Process.whereis(Auction.BidCache)
#PID<0.455.0>
```

第二个 `whereis` 返回了一个**新 pid**——`Auction.Supervisor` 检测到
孩子死了，按 `one_for_one` 立刻拉了一个新的 `BidCache`，`init` 又跑
了一遍、状态回到空 map。

缓存里的数据呢？没了——进程死了，map 跟着死。这正是 `highest_bid`
的 `cache_running?` 和 `:miss` 分支存在的理由：

```elixir
iex> Auction.highest_bid(1)
1200
```

`fetch` 命中新进程、返回 `:miss`，`read_highest_bid_from_repo` 查
`SELECT max(amount)` 拿 1200，`fill` 回缓存，返回 1200。用户完全无感。
再调一次，这次 `:miss` 变成命中，SQL 不再发。

这就是"让它崩"的全部含义：进程可以死，系统不可以死。缓存设计成
"状态可重建"的，进程丢了对调用方只是回到慢路径一次，不是错误。
监督者负责拉起新进程，cache-aside 负责让它无感——两层各管一半，
拼出来的才是容错。

## 动手验证

```sh
cd ch15/auction_umbrella
mix setup
iex -S mix
```

**第一步：插入两条出价，看缓存跟着长。**

```elixir
iex> {:ok, item} = Auction.insert_item(%{title: "otp item", ends_at: DateTime.utc_now()})
iex> Auction.insert_bid(%{amount: 500, item_id: item.id, user_id: 1})
iex> Auction.BidCache.fetch(item.id)
500
iex> Auction.insert_bid(%{amount: 800, item_id: item.id, user_id: 1})
iex> Auction.BidCache.fetch(item.id)
800
```

`insert_bid` 成功路径里 `maybe_update_cache` 把新金额写进去，
`fetch` 直接命中，没有 SQL 日志。

**第二步：杀掉缓存进程。**

```elixir
iex> Process.exit(Process.whereis(Auction.BidCache), :kill)
true
iex> Process.whereis(Auction.BidCache)
#PID<0.xxx.0>
```

新 pid 立刻就位，`init` 重新跑，`state` 回到 `%{}`。

**第三步：highest_bid 自动回源。**

```elixir
iex> Auction.highest_bid(item.id)
800
```

`fetch` 返回 `:miss`，走 `SELECT max(amount)` 查 800，`fill` 回缓存。
再调一次，这次命中。

**第四步：验证写路径对缓存零依赖。** `Supervisor.which_children(
Auction.Supervisor)` 或 `Process.exit` 杀掉 `BidCache` 之后立刻
`Auction.insert_bid(...)`，插入照常成功——`maybe_update_cache` 里的
`cache_running?` 没让失败的 cast 拖累写库。

## 小结

- `BidCache` 是 `auction` 监督树的第二个孩子，`{Auction.BidCache, []}`
  一行把它挂上；`name: __MODULE__` 让 `Process.whereis(BidCache)` 能
  找到它。
- `highest_bid` 走 cache-aside：`fetch` 命中直接回，`:miss` 走
  `max(amount)` 查询再 `fill` 回填；`cache_running?` 守边界，缓存
  进程没起来时退化成纯 SQL。
- `insert_bid` 成功才 `put` 更新，失败分支不碰缓存；`put` 内部
  `max(current, amount)` 保证乱序事件不会让缓存退化。
- 监督树真正兑现"let it crash"：进程死掉，`one_for_one` 立刻拉起
  新进程，空缓存由 cache-aside 自己暖回来。用户看到的只是多一次
  SQL，不是错误。

下一章回到全景收尾：把最终 umbrella 的目录树、两个应用的边界、
HTTP/Channel/LiveView/JSON API 各条链路完整摊开，看每一行代码住在哪。
