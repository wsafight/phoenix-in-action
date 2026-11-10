---
title: 第9章 · 出价：关联、嵌套路由和 preload
description: bids 表的外键与索引、belongs_to/has_many 关联声明、assoc_constraint 与 foreign_key_constraint 的分工、嵌套路由和 params 形状、两层 preload、错误路径复用商品页模板、并发出价的口子
sidebar:
  order: 9
---

上一章把用户体系立起来了：注册、登录、`Authenticator` plug 把 `current_user` 放进 `conn.assigns`。拍卖应用到这里才具备做"出价"的前提，一条 bid 光有 `amount` 不够，还得同时答出两个问题：出在哪件商品上，是谁出的。本章加 `bids` 表和 `Auction.Bid` schema，用 `belongs_to`/`has_many` 把 item、bid、user 三张表连成网；路由侧用嵌套 `resources` 生成 `POST /items/:item_id/bids`，让 URL 自己携带商品 id；读侧用两层 `preload` 一次带出商品、出价和出价人。

一条 bid 的业务字段只有 `amount`，但它牵出四个新课题：schema 之间怎么关联、嵌套路由怎么设计、preload 为什么必须显式、以及"出价必须高于当前价"这种要查库才能做的校验为什么堵不住并发。顺带说明，本章代码里还有两个真实的口子（校验失败会 500、同时出价会写进两条相同记录），也一并摆出来看，它们比任何"正确写法"都更能说明问题在哪一层。

## bids 表：先建表，再加外键

迁移分两步走。第一步只建表，只放 `amount`：

```elixir
defmodule Auction.Repo.Migrations.CreateBids do
  use Ecto.Migration

  def change do
    create table(:bids) do
      add :amount, :integer
      timestamps()
    end
  end
end
```

`ch11/auction_umbrella/apps/auction/priv/repo/migrations/20181213025720_create_bids.exs`

金额存整数，单位是美分：表单里填 `1500` 表示 $15.00，渲染时 `integer_to_currency/1` 除以 100（`ch11/auction_umbrella/apps/auction_web/lib/auction_web/global_helpers.ex`）。浮点数存钱会丢精度，整数美分是通行做法；数据库里没有 dollar 的概念，只有分。

`timestamps()` 在这里不只是惯例。bid 没有时间字段，但"出价时间"恰恰是最重要的数据之一：`inserted_at` 就是出价时间本身，后面 `get_bids_for_user` 的 `order_by: [desc: :inserted_at]` 靠它排出"最近出价"。不需要额外的 `bid_at` 列，框架给的时间戳顺手就当了业务字段。

第二步 `alter` 补上两列外键和三个索引：

```elixir
defmodule Auction.Repo.Migrations.AddAssociationsToBids do
  use Ecto.Migration

  def change do
    alter table(:bids) do
      add :item_id, references(:items)
      add :user_id, references(:users)
    end

    create index(:bids, [:item_id])
    create index(:bids, [:user_id])
    create index(:bids, [:item_id, :user_id])
  end
end
```

`ch11/auction_umbrella/apps/auction/priv/repo/migrations/20181213025907_add_associations_to_bids.exs`

`references(:items)` 一行做两件事：建一个 `item_id` 整型列，再给它加外键约束 `bids_item_id_fkey` 指向 `items.id`。从此数据库层面拒绝指向不存在商品的 bid，哪怕绕过应用直接连库写数据也一样。这条约束是 `assoc_constraint` 能在 Elixir 侧接住错误的前提：先有数据库约束会报错，Ecto 才有错误可翻译。

**`references` 没有写的 `on_delete` 选项值得看一眼。** 它的默认值是 `:nothing`（Postgres 的 `NO ACTION`）：要删一条还有 bid 引用的 item，数据库直接报 `foreign_key_violation`，拒绝执行。另外两种选择是 `on_delete: :delete_all`（删商品时连带删掉它名下所有 bid）和 `on_delete: :nilify_all`（把孤儿 bid 的 `item_id` 置成 NULL）。拍卖场景里"有出价的商品不该凭空消失"，默认值恰好是对的语义：宁可让删除失败，也不丢历史记录。注意这个行为由数据库执行，和 Elixir 代码无关；后面 schema 一节的 `foreign_key_constraint` 讲的是怎么把这个数据库错误翻译回 changeset。

三个索引对应本章要跑的查询形状：`get_item_with_bids` 按 `item_id` 找出价，`get_bids_for_user` 按 `user_id` 找出价，复合索引 `(item_id, user_id)` 留底。按主键以外的列 `WHERE` 而没有索引就是全表扫描，外键约束本身并不会自动帮你建索引。索引名由 `index` 宏自动起好：`bids_item_id_index`、`bids_user_id_index`、`bids_item_id_user_id_index`，和外键约束的 `_fkey` 后缀是两套命名习惯。

`references` 还有没写出来的选项。完整签名是 `references(:items, on_delete: :nothing, type: :bigint)`，另外还有 `foreign_key: false` 这种"只建列不建约束"的写法，分库或跨 schema 引用时才用得到。本应用里外键约束正是要的保护，不省略。

把建表和加关联拆成两个 migration 只是演示迁移可以增量演进，新项目一次 `create table` 写完即可。

## 关联声明：belongs_to 和 has_many 是一句话的两头

Bid 是连接双方的那一方，它在 schema 里指认两个父表：

```elixir
defmodule Auction.Bid do
  use Ecto.Schema
  import Ecto.Changeset

  schema "bids" do
    field :amount, :integer
    belongs_to :item, Auction.Item
    belongs_to :user, Auction.User
    timestamps()
  end

  def changeset(bid, params \\ %{}) do
    bid
    |> cast(params, [:amount, :user_id, :item_id])
    |> validate_required([:amount, :user_id, :item_id])
    |> assoc_constraint(:item)
    |> assoc_constraint(:user)
  end
end
```

`ch11/auction_umbrella/apps/auction/lib/auction/bid.ex`

`belongs_to :item, Auction.Item` 一行做三件事：schema 上多出 `item_id` 字段（Ecto 按约定推断列名，`:item` 对应 `item_id`，可以用 `foreign_key:` 改名）、多出 `bid.item` 关联字段（未 preload 时是 `%Ecto.Association.NotLoaded{}`）、让 changeset 知道这个关联存在，后面的 `assoc_constraint` 靠它工作。`user_id` 同理。于是同一个 id 在 schema 上出现两次：一次是 `bid.item_id` 这种可以直接读的普通整数列，一次是 `bid.item` 这种指向整条父记录的关联入口。

列名推断的对称性值得记住：`belongs_to :item` 对应 `item_id` 列，`has_many :bids` 对应被引用方的 `item_id` 列。父表这边声明的 `:bids` 是复数（因为反查结果是个列表），子表那边声明的 `:item` 是单数。这个单复数约定直接影响后面写 `preload(bids: [:user])` 和 `preload: :item` 时的拼写：用错了 `preload(:bid)` 不会报"关联不存在"，会直接抛 `Ecto.QueryError`，因为 `Bid` schema 里只有 `:item` 没有 `:bid`。

Ecto 一共三种关联声明：`belongs_to`（子表持有外键，我指向父）、`has_many`/`has_one`（父表声明反查入口，子表的外键指向我）、`many_to_many`（双方都不持外键，走中间表）。bid 两头都是 `belongs_to`，父表一侧补上 `has_many`：

```elixir
  schema "items" do
    field :title, :string
    field :description, :string
    field :ends_at, :utc_datetime
    has_many :bids, Auction.Bid
    timestamps()
  end
```

`ch11/auction_umbrella/apps/auction/lib/auction/item.ex`

`has_many` 不在 `items` 表上加任何列，归属信息本来就存在 `bids.item_id` 上。它只是告诉 Ecto：查到一个 item 后，可以按 `bids.item_id` 反查出它的全部 bid，`item.bids` 这个字段才有得填。`User` schema 里同样有一行 `has_many :bids, Auction.Bid`（`ch11/auction_umbrella/apps/auction/lib/auction/user.ex`），用户主页的"最近出价"靠它。至于 `many_to_many`，商品和标签那种双向归属的关系才用得上，需要第三张 join 表，本章没有。

**建 bid 还有另一种写法**：`Ecto.build_assoc(item, :bids, %{amount: ...})`，从父记录长出一条关联已填好的子结构体。iex 里试一下就明白它做了什么：

```elixir
iex> item = Auction.get_item(1)
iex> Ecto.build_assoc(item, :bids, amount: 500, user_id: 1)
%Auction.Bid{amount: 500, item_id: 1, user_id: 1}
# item_id 已经从父 struct 上抄好了，insert 前不用自己填
```

它要求父 struct 已经在手里，适合"先有 item 再有 bid"的领域代码。本章 controller 手里本来就只有两个 id（URL 的 `item_id`、session 的 `user_id`），把 id 直接塞进 `cast` 更直接，省掉先查父记录的开销；id 对不对交给 `assoc_constraint` 兜底。两种写法等价，选哪个看你手里有什么。

## assoc_constraint 和 foreign_key_constraint：一个看前面，一个看身后

changeset 里这两行值得单独看：

```elixir
    |> validate_required([:amount, :user_id, :item_id])
    |> assoc_constraint(:item)
    |> assoc_constraint(:user)
```

`ch11/auction_umbrella/apps/auction/lib/auction/bid.ex`

三个词的分工：

- `cast` 把 `:user_id`/`:item_id` 放进白名单；上一节说"id 直接传，不走 `build_assoc`"，就是这一步接住它们。
- `validate_required` 只管填没填，`item_id` 为 nil 时根本到不了数据库。
- `assoc_constraint(:item)` 不管字段本身，它在 insert/update 时把数据库抛出的外键违规翻译成 changeset error。传一个根本不存在的 `item_id: 99999`，没有它，`Repo.insert` 抛 `Ecto.ConstraintError`；有了它，得到 `{:error, changeset}`，`item` 字段上带着 "does not exist"。

和 `assoc_constraint` 只差两个字母的 `foreign_key_constraint` 管的是另一个方向：它声明在**被引用的一方**，翻译"还有别人指着我、所以删不掉"的错误。比如将来要支持删商品，`Item` 的删除 changeset 可以写 `foreign_key_constraint(:bids)`，把 Postgres 的 `foreign_key_violation` 翻成 `bids` 字段上一条 "are still associated with this entry"，controller 拿到 `{:error, changeset}` 而不是 500。本章代码没用它：没有任何删除入口会走到它，`delete_item` 删到有 bid 的商品时就直接抛 `Ecto.ConstraintError`，这是 `on_delete: :nothing` 的代价。

一句话记：`assoc_constraint` 保护"我指向的东西必须存在"，`foreign_key_constraint` 保护"想删我，先让指着我的东西消失"。

## context：四个函数，两种 preload

```elixir
  def insert_bid(params) do
    %Bid{}
    |> Bid.changeset(params)
    |> @repo.insert()
  end

  def new_bid, do: Bid.changeset(%Bid{})

  def get_item_with_bids(id) do
    id
    |> get_item()
    |> @repo.preload(bids: [:user])
  end

  def get_bids_for_user(user) do
    query =
      from(b in Bid,
        where: b.user_id == ^user.id,
        order_by: [desc: :inserted_at],
        preload: :item,
        limit: 10
      )

    @repo.all(query)
  end
```

`ch11/auction_umbrella/apps/auction/lib/auction.ex`

前两个是熟面孔，沿用了前几章 `insert_item`/`new_item` 的成对模式：`insert_bid` 走 changeset 落库，`new_bid` 造一个空 changeset 给表单用。表单需要"一个 bid 形状的数据源"才知道渲染哪些字段、名字前缀叫什么，不是真的要插一条空记录；这也是 `<.form for={@bid}>` 能接受 changeset 而不是只接受 struct 的原因，phoenix_html 的 FormData 协议对 `%Ecto.Changeset{}` 有专门实现。

`get_item_with_bids` 的关键在 `preload(bids: [:user])`，这是个两层 preload。为什么是两层而不是一层：`item.bids` 只把该商品的 bid 记录查出来，每条 bid 的 `user` 字段还是 `NotLoaded`；模板里要写 `bid.user.username`，就得再往下 preload 一层。列表写法 `bids: [:user]` 的意思是"先 preload item 的 bids，再对每条 bid preload 它的 user"。

Ecto 把嵌套 preload 编译成批量查询，开 Ecto 日志（默认 dev 环境 `log: :debug` 已经开着）能看到三条 SQL 依次发出：

```text
SELECT ... FROM "items"  WHERE id = $1
SELECT ... FROM "bids"   WHERE "item_id" = $1        -- 一批
SELECT ... FROM "users"  WHERE "id" = ANY($1)        -- IN 所有 user_id
```

总共三条，不会退化成每条 bid 单独查一次 user 的 N+1：Ecto 先收集所有 bid 的 `user_id`，再用一条 `IN` 查询把 user 全部捞出，在内存里按 id 对号入座挂回去。

没有 preload 会怎样：关联字段默认是 `%Ecto.Association.NotLoaded{}`，访问 `bid.user.username` 直接抛异常，不是返回 nil。这是 Ecto 的刻意设计，一次字段访问不该悄悄变成一次数据库往返，要谁的数据就显式 preload 谁。商品页如果只 preload `bids` 不带 `:user`，模板访问 `bid.user.username` 时就撞上这个异常。

顺带一提，Ecto 还能把多级关联收成一层：`has_many :bidders, through: [:bids, :user]` 就能直接从 item 拿到"出价过的用户"列表。代码里没用 `through`，因为页面要的是带金额的 bid 列表，不是去重后的用户集合，中间那层 bid 本身就是主角。

`item.bids` preload 出来的列表还有个没写出来的性质：无序。`preload` 走的是 `WHERE item_id = $1`，没有 `ORDER BY`，Postgres 返回什么顺序就是什么顺序，生产库上通常是插入序但没有任何保证。当前页面 bid 少看不出来，要真按价格排序得把 preload 换成自定义查询：

```elixir
|> @repo.preload(bids: {from(b in Bid, order_by: [desc: :amount]), [:user]})
```

`preload` 接受 `{query, nested_preloads}` 的二元组，这就是"按需求定制关联查询"的入口，本章没用到但值得知道在哪。

`get_bids_for_user` 演示另一种 preload 写法：写在 `from` 查询里的 `preload: :item`。效果相同，取用户最近 10 条 bid 时顺手带出每条对应的商品，用户主页才能直接写 `bid.item.title`。两种写法各管一段：`preload:` 选项在查询发出前就声明"这条查询顺便带什么"，适合构造查询时就知道要关联的场景；`Repo.preload/2` 对已查出的 struct 事后补数据，适合 `get_item_with_bids` 这种先 `get!` 拿到记录、再决定带什么的两步走。

顺带看 `get_bids_for_user` 的排序：`order_by: [desc: :inserted_at]` 按出价时间倒序，`limit: 10` 截出最近 10 条。这个查询接在 `UserController.show` 里（`ch11/auction_umbrella/apps/auction_web/lib/auction_web/controllers/user_controller.ex`），`/users/:id` 页面 "Recent bids" 区域的数据就是它给的。模板的渲染方式反过来验证了 `preload: :item` 的必要性：

```heex
<p :for={bid <- @bids}>
  <strong>{formatted_datetime(bid.inserted_at)}</strong>
  -- {integer_to_currency(bid.amount)} for
  <em><.link navigate={~p"/items/#{bid.item}"}>{bid.item.title}</.link></em>
</p>
```

`ch11/auction_umbrella/apps/auction_web/lib/auction_web/controllers/user_html/show.html.heex`

每条 bid 都要显示 `bid.item.title` 并链回商品页。`preload: :item` 如果去掉，这里又是满屏 `NotLoaded` 异常；而如果没有 `has_many :bids` 那行声明，`from(b in Bid, where: b.user_id == ^user.id)` 这样的手写查询其实照样能查，声明的价值在 `Repo.preload(user, :bids)` 和 `user.bids` 这类"从父出发"的入口，查询本身只需要知道列名。

## 嵌套路由：item_id 从 URL 进 params

```elixir
    resources "/items", ItemController,
      only: [
        :index,
        :show,
        :new,
        :create,
        :edit,
        :update
      ] do
      resources "/bids", BidController, only: [:create]
    end
```

`ch11/auction_umbrella/apps/auction_web/lib/auction_web/router.ex`

`resources` 可以套 `resources`。里面那行展开后生成的只有一条：

```
POST /items/:item_id/bids  →  AuctionWeb.BidController.create/2
```

URL 段按父资源的单数命名为 `:item_id`，Phoenix 把它放进 params 的 `"item_id"` 键。表单 POST 到 `/items/3/bids` 时，body 里的 `bid[amount]=1500` 先被 `Plug.Parsers` 解析成 `%{"bid" => %{"amount" => "1500"}}`，path 参数再合并进来，`conn.params` 最终长成：

```elixir
%{"item_id" => "3", "bid" => %{"amount" => "1500"}}
```

controller 的函数头能一次 match 出两块数据，靠的就是这个形状。

嵌套路由继承外层 scope 的一切：`POST /items/:item_id/bids` 同样过 `:browser` pipeline，CSRF 校验、session 解析、`Authenticator` 一个都不少。后面会看到这意味着两件事：裸 `curl` POST 会被 `protect_from_forgery` 先拦下，而不是被登录检查拦下；进得了 `create` 的请求，`conn.assigns.current_user` 一定已经放好了。

为什么把 `item_id` 放进 URL 而不是表单隐藏字段：语义上"对 3 号商品出价"本来就是请求目标的一部分，不是表单数据；工程上放 URL 里 controller 不用信任 body，也不用在出错时把隐藏字段传回模板。嵌套的代价是子资源失去独立 URL，这正合适：bid 没有自己的详情页或编辑页，没人会单独 GET 一条 bid，所以只开 `[:create]` 一个 action。`mix phx.routes` 里也只有这一行 bid 相关路由。

只开 `create` 还有个业务上的理由：拍卖场景里出价记录本身就该是不可变的账本。出了价不能改、不能收回（删 bid 等于篡改历史），所以 `update`/`edit`/`delete`/`show` 都没有存在的意义。RESTful 路由的 `only:` 在这里不是随便裁剪，是把"bid 只能被创建"这条领域规则直接写进路由表。

嵌套可以多深？Phoenix 允许无限套娃，但两层基本就是合理深度的上限了。`items/:item_id/bids/:bid_id/reports` 这种三层 URL 里，中间那层 id 多半是冗余的（bid id 本身已经能定位它属于哪个 item），只会让 controller 多几个要校验的 path 参数。本应用停在两层，正好卡在"表达父子关系"和"参数不冗余"的平衡点上。

## BidController：三个来源的数据在 create 里会师

这里有个设计上的小选择值得先想清楚：出价表单放在哪。

RESTful 的"标准做法"是给 bid 也开 `new`/`create` 一对，像 Item 那样做一个独立的 `/items/:id/bids/new` 表单页。本应用没走这条路，理由有两个：bid 只有一个字段，为它单开一页太浪费；"出价"这个动作在 UX 上本来就该发生在看商品的地方，用户盯着当前价才决定出多少。所以只保留 `create` 一个写入口，把表单嵌进 `items/:id` 的 show 页，让商品页同时承担展示和表单两个职责。这也解释了为什么 `BidController` 连 `new` action 都没有：表单的数据源 `new_bid()` changeset 是由 `ItemController.show` 准备的，下一节会看到。

```elixir
defmodule AuctionWeb.BidController do
  use AuctionWeb, :controller

  plug :require_logged_in_user

  def create(conn, %{"bid" => %{"amount" => amount}, "item_id" => item_id}) do
    user_id = conn.assigns.current_user.id

    case Auction.insert_bid(%{amount: amount, item_id: item_id, user_id: user_id}) do
      {:ok, bid} ->
        redirect(conn, to: ~p"/items/#{bid.item_id}")

      {:error, bid} ->
        item = Auction.get_item(item_id)

        conn
        |> put_view(html: AuctionWeb.ItemHTML)
        |> render(:show, item: item, bid: bid)
    end
  end

  defp require_logged_in_user(%{assigns: %{current_user: nil}} = conn, _opts) do
    conn
    |> put_flash(:error, "Nice try, friend. You must be logged in to bid.")
    |> redirect(to: ~p"/items")
    |> halt()
  end

  defp require_logged_in_user(conn, _opts), do: conn
end
```

`ch11/auction_umbrella/apps/auction_web/lib/auction_web/controllers/bid_controller.ex`

函数头的 pattern match 就是参数路由表。`%{"bid" => %{"amount" => amount}, "item_id" => item_id}` 同时从 URL 和表单各取一块。这个 match 本身就是第一道过滤：body 里如果没有 `bid[amount]`（比如直接 `curl -d 'amount=100'`），函数头不匹配，Phoenix 抛 `Phoenix.ActionClauseError` 回 400，根本进不了函数体。请求形状不对的请求在入口处就被丢掉，不需要在函数里写防御代码。

一次出价请求从表单提交到 `create` 被调用，中间经过了这些站：

```text
POST /items/3/bids  (body: bid[amount]=1500, cookie: _auction_web_key)
  → :browser pipeline（fetch_session 解出 user_id → Authenticator 查 User →
     assign(:current_user, user)）
  → 路由匹配 POST /items/:item_id/bids → BidController
  → plug :require_logged_in_user（current_user 为 nil 就 302 走人）
  → create(conn, %{"item_id" => "3", "bid" => %{"amount" => "1500"}})
```

**`user_id` 来自 session，不来自表单。** `conn.assigns.current_user.id` 是 `Authenticator` plug 从签名 cookie 里的 `user_id` 查出来的用户，客户端改不了。注意 `Bid.changeset` 的 `cast` 名单里确实有 `:user_id`，那是给 iex 和将来内部调用留的口子；web 入口的安全边界画在 controller 这一行：它自己拼 `%{amount:, item_id:, user_id:}` 三个键的干净 map 交给 `Auction.insert_bid`，请求 body 里就算塞了 `bid[user_id]=1` 冒充别人，也因为不在这个拼装的 map 里被原样丢掉。信任边界不在 changeset，在这个手写 map。

这套"controller 过滤 + changeset 放行"的分工是设计取舍，不是唯一答案。更保守的做法是把 `Bid.changeset` 的 cast 名单收窄到 `[:amount]`，再单开一个 `insert_bid` 专用的内部函数 `put_change` 两个 id，让 changeset 从根上不接受外部传入的外键。本章代码没这么写，因为 web 入口只有一个、controller 的过滤已经够清楚；哪天再开 JSON API 或多处调用方，这层收口才值得补。

**`plug :require_logged_in_user` 守住入口。** controller 级的函数 plug，在每个 action 前跑。未登录时 `current_user` 是 nil，第一个子句命中：flash 警告、重定向、`halt()` 掐断 pipeline，`create` 根本执行不到。没有它，`current_user.id` 就是 `nil.id`，直接 `KeyError`。

这是本章第二种守门方式，可以和 `UserController` 里那个 plug 对比着看：`require_logged_in_user` 只问"登录了吗"（authentication），`prevent_unauthorized_access` 问的是"是不是本人"（authorization），把 `current_user.id` 和 URL 里的 `:id` 对一遍。出价只需要前者：任何登录用户都允许对任何商品出价，没有"这是谁的 bid"可越权。

为什么这个 plug 放在 controller 里而不是 pipeline 里：`:browser` pipeline 是公共通道，首页、商品列表、登录页都从它过，不能一刀切要求登录。守门粒度是"这个 controller 的每个 action 都要登录"，而 `BidController` 只有 `create` 一个 action，`plug :require_logged_in_user` 写在模块顶部不加 `when` 过滤正好覆盖全部。等哪天给 bid 加上 `GET /items/:id/bids` 列表页（公开可读），才需要 `when action in [:create]` 收窄范围。

另一个细节：plug 在函数头 match 之前跑。未登录用户发一个形状完全不对的请求（没有 `bid[amount]`），拿到的还是 302 而不是 400，登录检查先于参数匹配执行，这是 plug 链的位置决定的。

**成功走 redirect**：`redirect` 回商品页是一次完整的 PRG。浏览器重新发起 GET，`ItemController.show` 重新查出带 bids 的 item，页面刷新就是新状态；用户再按刷新也不会重复提交。

**失败走 render，并且是换过 view 的 render。** 校验失败时拿到 `{:error, changeset}`。理想响应是回到商品页标出错误，但商品页归 `ItemController.show` 管，模板在 `ItemHTML` 里；Phoenix 按惯例给 `BidController` 推导的渲染模块是 `AuctionWeb.BidHTML`，而 controllers/ 下根本没有 `bid_html/` 目录。`put_view(html: AuctionWeb.ItemHTML)` 显式换掉渲染模块，`render(:show, ...)` 渲染的就是 `item_html/show.html.heex`，失败的 changeset 以 `@bid` 的身份进去，表单组件读出错误原样展示。redirect 保不住 changeset（它是一次新请求，assigns 清零），所以失败路径只能 render 不能跳转。

`put_view` 的 key 对应 `formats` 声明：`html: AuctionWeb.ItemHTML` 只在渲染 HTML 格式时生效。本应用 `:controller` quote 里 `formats: [:html, :json]` 两种都开了，但这里只换 html 的 view，JSON 格式（如果哪天给 bid 加 API）仍走默认推导，互不影响。

变量名 `{:error, bid}` 也有点误导性：它不是 bid，是带错误的 changeset。代码里沿用这个名字是因为模板里 `@bid` 这个 assign 名本来就是"表单的 bid 数据源"，不管里面是干净的还是带错的，都喂给同一个 `<.form>`。

还有个边界情况顺路看一眼：往不存在的商品上出价，比如 `POST /items/99999/bids`。`insert_bid` 的 `assoc_constraint` 把外键违规翻成 `{:error, changeset}`，落进失败分支，接着 `Auction.get_item(99999)` 抛 `Ecto.NoResultsError`。Phoenix 默认把这个异常映射成 404，响应本身是对的，只是绕了条弯路：校验先失败、查 item 再 404。严格说"对不存在的商品出价"该在更早的地方 404，但现在的行为至少不是 500。

这个失败路径还藏着一个真 bug：它取 item 用的是 `Auction.get_item(item_id)`，不带 preload，而 `show.html.heex` 第一屏就是 `:for={bid <- @item.bids}`。只要 `Bid.changeset` 拦下任何一次出价（`amount` 留空，或传进 `abc` 这种 cast 失败的值），重渲染的页面就会对着 `NotLoaded` 遍历，直接 500。改成 `Auction.get_item_with_bids(item_id)` 才能修好，"动手验证"一节会撞上它。

这类 bug 之所以容易漏，是因为触发它的入口藏得深：正常浏览商品页走的是 `get_item_with_bids`，一切正常；只有"表单校验失败"这条分支换了数据源，分支里的 item 才没带 bids。测试覆盖如果只在 iex 里试 `insert_bid` 的返回值，根本走不到这步。它同时说明一件事：模板对 `@item.bids` 的假设（"这个字段一定是加载好的"）是靠两处调用方分别维护的，一处漏了 preload 就是运行时异常，编译期不会发现。

还有一件事这个 controller 没做也值得注意：它没检查 `item.ends_at` 是不是已经过了。`Item.changeset` 只在创建商品时校验"截止时间不能是过去"，但那是"上架"时的校验；拍卖截止后继续出价，代码里没有任何拦截。规则缺口又添一条，和"必须高于最高价"是同一类问题，都留给练习了。

## 同一个 @bid，两条渲染路径

商品页是出价表单的宿主，`ItemController.show` 给它备料：

```elixir
  def show(conn, %{"id" => id}) do
    item = Auction.get_item_with_bids(id)
    bid = Auction.new_bid()
    render(conn, :show, item: item, bid: bid)
  end
```

`ch11/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_controller.ex`

`@bid` 有两个来源：正常打开页面时是 `new_bid()` 给的干净 changeset，出价失败时是 `BidController` 传过来的带错 changeset。模板只认 `@bid` 不认来源，上一节 `put_view` 那套复用成立的前提就是它。`@current_user` 是 `Authenticator` 早放进 `conn.assigns` 的，`render` 时 conn.assigns 会并入模板 assigns，所以失败重渲染时登录状态和表单显隐不受影响。

```heex
<div style="display: flex; flex-direction: row;">
  <div style="flex: 1">
    <h2>Current bids</h2>
    <p :for={bid <- @item.bids}>
      {integer_to_currency(bid.amount)} <em>from {bid.user.username}</em>
    </p>
  </div>

  <div style="flex: 1">
    <%= if @current_user do %>
      <h2>Place your bid!</h2>

      <.form :let={f} for={@bid} action={~p"/items/#{@item}/bids"}>
        <%= if @bid.action do %>
          <div class="alert alert-danger">
            Unfortunately, there are errors in your
            submission. Please correct them below.
          </div>
        <% end %>

        <div class="form-group">
          <.input field={f[:amount]} type="number" label="Bid amount" />
        </div>

        <.button type="submit" class="btn btn-primary">Submit</.button>
      </.form>
    <% end %>
  </div>
</div>
```

`ch11/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_html/show.html.heex`

几个细节：

- 左栏 `:for` 遍历 `@item.bids`，`bid.user.username` 能直接点出来，全靠 `get_item_with_bids` 的两层 preload；少任何一层这里都是 `NotLoaded`。
- `integer_to_currency(bid.amount)` 按美分渲染，库里的 `1500` 显示成 `$15.00`。
- `if @current_user` 把表单藏起来只是顺手，真正的拦截在 `require_logged_in_user` plug：不带 session 直接 POST 请求根本进不了 `create`。界面层永远不替代服务端校验。
- `action={~p"/items/#{@item}/bids"}`：`~p` 在编译期和路由表对账，`@item` struct 经 `Phoenix.Param` 协议取 `id` 插值，生成的就是嵌套路由 `POST /items/3/bids`。
- `<.input field={f[:amount]}>` 生成的 `name` 是 `bid[amount]`：`<.form for={@bid}>` 从 changeset 的 `Bid` schema 推出表单名 `bid`，这正是 controller 里 `%{"bid" => ...}` 那个键的来历。
- `type="number"` 给浏览器一个数字输入框，但它只是 UX 提示，不是校验：`<input type="number">` 可以填负数，浏览器 DevTools 里手改 `type` 更是想发什么发什么，server 端 `Bid.changeset` 才是唯一算数的地方。
- `@bid.action` 是错误横幅的开关：`new_bid()` 造的空 changeset `action` 是 nil，横幅不渲染；`Repo.insert` 跑过一次后 `action` 变成 `:insert`，失败回来时横幅出现。同一个模板靠这一个字段区分"首次打开"和"刚校验失败"。

## 校验的边界：changeset 挡得住脏数据，挡不住并发

现在的 `Bid.changeset` 只验两件事：字段填了没有、引用存不存在。一个拍卖系统至少还差两条规则：

1. `amount` 必须为正。字段自身的属性，一行 `validate_number(:amount, greater_than: 0)` 就能补上；
2. `amount` 必须高于当前最高价。要查库才知道"当前"是多少。

第二条的思路是在 changeset 里加自定义校验，按 `get_field(changeset, :item_id)` 查出该商品当前 max(amount) 再比较。示意代码（仓库里没有这段，留给你写）：

```elixir
|> validate_number(:amount, greater_than: 0)
|> validate_highest_bid()

# defp validate_highest_bid(changeset) 里：
# item_id = get_field(changeset, :item_id)
# 查出该 item 的 max(bids.amount)，比它大才放行，
# 否则 add_error(changeset, :amount, "must be higher than current bid")
```

但就算补上，也只是把洞变小，没有堵死。**先查再写这个动作不是原子的**：两个用户同时出 1600，都读到"当前最高 1500"，各自校验通过，数据库里写下两条 1600，谁赢看运气。changeset 在校验和落库之间隔着时间，这段时间里另一个请求可以改库，应用层的比较天然带着竞态。

根治得把判断推进数据库，让"查最高价"和"写新价"之间没有第三者插进来的空隙。典型做法是在事务里先锁住 item 行：

```elixir
Repo.transaction(fn ->
  # SELECT * FROM items WHERE id = $1 FOR UPDATE
  # 拿到锁之后再查 max(bids.amount)、比较、insert
  # 另一个并发请求会卡在 FOR UPDATE 上，等这里提交才能读到新状态
end)
```

行锁把"先读后写"变成串行的：拿到锁的请求做完判断，后来的请求解锁时看到的已经是新出价。另一条路是给 item 加 `highest_bid_amount` 列，出价时用它做条件更新（`UPDATE items SET highest_bid_amount = $1 WHERE id = $2 AND highest_bid_amount < $1`），一条 SQL 把比较和写入合成原子操作，不满足 `WHERE` 的行零更新，直接当失败处理。这些超出本章范围，现在的代码就是把这个口子开着，"动手验证"里两个窗口同时出价能亲眼看到它。

也因为"高于最高价"这条规则不存在，当前应用允许越出越低：1500 之后出 10 分照样成功。这不是渲染 bug，是规则缺失。

## 八道检查，两道缺口

把整条链路按"一次出价请求经过的每一道检查"排一遍，能看清每一层各自的职责和各自的盲区：

```text
请求形状     Plug.Parsers / 函数头 match   形状不对 → 400
CSRF        protect_from_forgery         伪造表单 → 403
登录态      require_logged_in_user       未登录 → 302
身份归属    user_id 从 session 取         冒充别人出价 → 不可能
字段值      validate_required / cast     空值、类型错 → changeset error
外键存在    assoc_constraint             幽灵 item/user → changeset error
数据合法性  （缺口）高于最高价              没有这条校验 → 漏洞
并发        （缺口）锁或数据库约束         同时出价 → 两条同价记录
```

左边是"谁检查"，右边是"检查不通过会怎样"。越往上越早被拒，成本越低；changeset 是应用层最后一道，数据库约束是最终底线。本章代码里两道缺口都标出来了，都不是 bug 级别的问题，是"还没做的功能"。

## 动手验证

```bash
cd ch11/auction_umbrella
mix deps.get
mix ecto.migrate
mix phx.server
```

先跑 `mix phx.routes | grep bid`，应该看到唯一的 bid 路由 `POST /items/:item_id/bids`，嵌套声明的产物就这一条。

`seeds.exs` 在本章只是个注释占位，iex 里先把测试数据备好（也可以走界面注册、新建商品）：

```elixir
iex> {:ok, item} = Auction.insert_item(%{title: "Test item", description: "...", ends_at: ~U[2030-01-01 00:00:00Z]})
iex> {:ok, user} = Auction.insert_user(%{username: "neo", email_address: "neo@x.com", password: "secret", password_confirmation: "secret"})
```

然后直接调 context，把这一章的关键点逐个验证一遍：

```elixir
iex> Auction.insert_bid(%{amount: 1000, item_id: 1, user_id: 1})
{:ok, %Auction.Bid{amount: 1000, item_id: 1, user_id: 1, ...}}

iex> Auction.insert_bid(%{amount: 500, item_id: 99999, user_id: 1})
{:error, %Ecto.Changeset{errors: [item: {"does not exist", ...}], ...}}
# assoc_constraint(:item) 把外键违规翻译成了校验错误

iex> item = Auction.get_item_with_bids(1)
iex> hd(item.bids).user.username
"neo"   # 两层 preload：bids 和每个 bid 的 user 都是真数据

iex> Auction.get_item(1).bids
#Ecto.Association.NotLoaded<association :bids is not loaded>
# 对照组：不带 preload 拿到的就是这个占位 struct

iex> item2 = Auction.Repo.preload(Auction.get_item_with_bids(1), bids: [:user])
iex> item2 == item
true    # preload 对已加载的关联是幂等的，不会重复发查询

iex> Auction.get_bids_for_user(Auction.get_user(1))
[%Auction.Bid{item: %Auction.Item{title: "...", ...}, ...}]
# from 里的 preload: :item，每条 bid 顺手带出商品

iex> Ecto.build_assoc(Auction.get_item(1), :bids, amount: 99, user_id: 1)
%Auction.Bid{amount: 99, item_id: 1, user_id: 1}
# build_assoc 的等价写法，item_id 自动从父 struct 上抄过来
```

浏览器走一遍完整链路：

1. 未登录打开 `/items/1`：看得到 "Current bids" 列表，看不到出价框。
2. 直接 `curl -i -X POST http://localhost:4000/items/1/bids -d 'bid[amount]=100'`：返回 403，`protect_from_forgery` 比登录校验跑得更靠前。带着浏览器登录的 cookie 再 POST，才会落到 `require_logged_in_user` 手里被重定向回 `/items`。
3. 登录后出 `1500`：重定向回商品页，列表出现 `$15.00 from <你的用户名>`。
4. 再出一个 `10`：居然成功了，这就是"高于最高价"规则缺失的现场。
5. 出价框留空直接提交：500，`protocol Enumerable not implemented for Ecto.Association.NotLoaded`，就是 `BidController` 错误路径里 `get_item` 没有 preload bids 的那个 bug。
6. 开两个浏览器（或一个正常窗口一个隐身窗口）登录不同用户，两边同时填同样金额提交：两条一模一样的 bid 都进了库，竞态的现场。
7. 访问 `/users/:id`："Recent bids" 列出最近 10 条出价，每条链回对应商品，数据来自 `get_bids_for_user` 的 `preload: :item`。
8. 打开浏览器 DevTools 的 Network 面板再出一次价：请求的 Form Data 里只有 `bid[amount]` 和 `_csrf_token`，没有 `user_id`。`user_id` 不在线上走，它在服务端的 session 里。

最后看一眼数据库层留下的东西：

```bash
psql -d auction -c '\d bids'
```

输出里能看到 `item_id`/`user_id` 两列、`bids_item_id_fkey`/`bids_user_id_fkey` 两个外键约束（`Foreign-key constraints` 一节），以及三个索引。schema 的 `belongs_to`、迁移的 `references`、changeset 的 `assoc_constraint`，在这张表里合流成同一件事。

再试一下 `on_delete: :nothing` 的实际效果：在 psql 里 `DELETE FROM items WHERE id = 1;`（前提是该 item 已有 bid），会得到 `ERROR: update or delete on table "items" violates foreign key constraint "bids_item_id_fkey"`。数据库自己守住了"有出价的商品不能凭空消失"，这是 `foreign_key_constraint` 想在 Elixir 层接住的那种错误的本来面目。

## 一条 bid 的完整生命周期

把本章所有零件按时间顺序串起来，一次成功出价长这样：

```text
浏览器 POST /items/3/bids  (body: bid[amount]=1500, cookie 带 session)
  → :browser pipeline（CSRF / session / Authenticator 放入 current_user）
  → Router 匹配嵌套路由，item_id="3" 进 params
  → BidController.require_logged_in_user：current_user 非 nil，放行
  → create：amount + item_id + session 的 user_id 拼成 map
  → Auction.insert_bid → Bid.changeset（cast → required → assoc_constraint）
  → Repo.insert → Postgres 写 bids 行，外键约束兜底
  → redirect 302 → 浏览器 GET /items/3
  → ItemController.show → get_item_with_bids（三条 SQL 的嵌套 preload）
  → show.html.heex：@item.bids 列表 + @bid 空 changeset 表单
```

写一条路，读一条路，中间靠 redirect 换方向。bid 的"存在感"完全由关联决定：表上两个外键、schema 上两个 `belongs_to`、查询里两层 preload，少一环就在某处变成 `NotLoaded` 或 `ConstraintError`。

## 小结

- `belongs_to` 声明外键归属，`has_many` 声明反查入口；列只存在于子表，关联字段默认 `NotLoaded`，要数据就得显式 `preload`，两层关联就写两层 `preload(bids: [:user])`。
- `cast` 收 id、`validate_required` 挡空、`assoc_constraint` 翻译"引用不存在"；`foreign_key_constraint` 管相反方向，翻译"被引用删不掉"，它属于被删那一方的 changeset。
- 嵌套 `resources` 生成 `POST /items/:item_id/bids`，path 参数以 `item_id` 进 `conn.params` 和表单 body 合并；`user_id` 必须由 controller 从 session 拼进去，信任边界在手写 map 不在 changeset。
- 出价失败要带着 changeset 回商品页，`put_view(html: AuctionWeb.ItemHTML)` 把渲染模块换成宿主页面，`@bid` 一个 assign 服务正常渲染和错误渲染两条路径。
- "高于当前价"这类跨记录校验，changeset 做得到查库比较，做不到原子；根治靠行锁或数据库约束。本章代码把口子留着，两个窗口同时出价就能复现。

下一章处理"出价之后的广播"：现在 A 用户出价成功，B 用户屏幕上什么都不会发生，要用 Phoenix Channel 把新 bid 实时推到所有正在看这件商品的浏览器。
