---
title: 第11章 · JSON API：给拍卖应用加接口
description: 在 /api scope 下新增 Api.ItemController，用 *_json 模块把 item、bid、user 渲染成嵌套的 JSON 输出
sidebar:
  order: 11
---

上一章的 Channel 解决了"人"的实时体验：浏览器开着商品页，新出价自己长出来。
但浏览器不是唯一的客户端。移动端 App、合作伙伴的系统、以后可能写的前端 SPA，
都不可能去解析 HTML 页面。它们要的是能直接喂给程序的数据格式。

这一章给同一个应用加一套 JSON API，做四件事就够了：一条只剩 `accepts` 的
`:api` pipeline、一个挂在 `/api` 前缀下的 scope、`AuctionWeb.Api.ItemController`
的 `index` 和 `show` 两个只读接口，以及三个负责把 Ecto schema 手工翻译成响应 map
的 `*_json` 模块。最后产出的 JSON 嵌了三层：item 里有 bids，bid 里有 user。

## 浏览器和 JSON 客户端要的是两种 conn

HTML 页面和 JSON API 面对的是两种不同的客户端，对"连接该被怎么加工"的要求几乎相反：

- 浏览器请求是有状态的。session cookie 记着登录态，flash 靠 session 传一次性消息，
  表单提交要有 CSRF token 防止伪造，响应还要套 layout、带上安全响应头。
- API 请求是无状态的。客户端每次带着完整信息来，不存 cookie，不发 HTML 表单，
  也不需要 flash。它甚至不知道 `<html>` 是什么。

硬把 API 路由塞进 `:browser` pipeline，每一环都会出问题。客户端不带
`Accept: text/html`，第一道 `accepts` 就回 406；将来发个 POST，
`protect_from_forgery` 会因为请求里没有 CSRF token 直接拦截；
`fetch_session` 每次解析一次没人会读的 cookie，纯属浪费。

反过来的方向同样不成立：让浏览器请求走无 session 的 `:api` pipeline，
登录态、flash、CSRF 防护全部失效。Phoenix 的答案是不共享：给两种流量各配一条
pipeline，再用 scope 把 URL 前缀和模块命名空间隔开，谁也不打扰谁。

先看现有的两条 pipeline，本章一个 plug 都没有加，`:api` 是生成器留下的，
现在第一次真的用起来：

```elixir
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :put_root_layout, html: {AuctionWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug AuctionWeb.Authenticator
  end

  pipeline :api do
    plug :accepts, ["json"]
  end
```

`ch13/auction_umbrella/apps/auction_web/lib/auction_web/router.ex`

`:browser` 里七个 plug 各有各的客户：`fetch_session` 解 cookie，
`fetch_flash` 取一次性消息，`put_root_layout` 准备 HTML 外壳，
`protect_from_forgery` 校验 CSRF，`put_secure_browser_headers` 加
`x-frame-options` 这类头，`Authenticator` 把 session 里的 `user_id` 查成
`conn.assigns.current_user`。这七件事 API 客户端一件都不需要。

`:api` 只剩一个 `plug :accepts, ["json"]`，但它干了整个 pipeline 里唯一不可省的活：
内容协商。客户端发请求时会带 `Accept` 头声明自己能消化什么格式，`accepts` 拿它和
`["json"]` 比对，匹配上就把 `"json"` 写进 `conn.private.phoenix_format`，
controller 里的 `render/3` 稍后靠这个值决定输出形态。匹配不上，比如浏览器默认的
`Accept: text/html,application/xhtml+xml,...`，请求在这里就停了，直接回 406
Not Acceptable，controller 根本不会被调用。API 路由连"返回 HTML 错误页"的资格
都没有，406 的响应体由 `ErrorJSON` 渲染成 JSON（见后面"动手验证"）。

新增的路由是整个 scope 机制的三行浓缩：

```elixir
  # Other scopes may use custom stacks.
  scope "/api", AuctionWeb.Api do
    pipe_through :api

    resources "/items", ItemController, only: [:index, :show]
  end
```

`ch13/auction_umbrella/apps/auction_web/lib/auction_web/router.ex`

`scope "/api", AuctionWeb.Api` 一行声明了两层前缀：

1. **URL 前缀**：块内路由的路径全部加 `/api`，`resources "/items"` 注册出来的是
   `GET /api/items` 和 `GET /api/items/:id`。
2. **模块前缀**：`ItemController` 这个"裸名"实际解析成
   `AuctionWeb.Api.ItemController`。它和浏览器用的 `AuctionWeb.ItemController`
   是两个模块、两个文件，互相看不见对方，将来 API 版要改签名、加字段，HTML 版
   一行都不用动。

`pipe_through :api` 把上面那条单 plug 管线接到这个 scope 的每条路由上。
`only: [:index, :show]` 是刻意的收窄：`resources` 默认会展开成七条路由，
这里只要两个只读接口，写操作（`create`、`update`、`delete`）涉及认证和参数
校验，留给收尾章再谈。

文件组织跟着模块名走，`controllers/` 下多了一个 `api/` 子目录：

```text
apps/auction_web/lib/auction_web/controllers/
├── api/
│   ├── item_controller.ex    # AuctionWeb.Api.ItemController
│   ├── item_json.ex          # AuctionWeb.Api.ItemJSON
│   ├── bid_json.ex           # AuctionWeb.Api.BidJSON
│   └── user_json.ex          # AuctionWeb.Api.UserJSON
├── item_controller.ex        # AuctionWeb.ItemController（浏览器版）
├── item_html.ex
└── ...
```

`ch13/auction_umbrella/apps/auction_web/lib/auction_web/controllers/`

## Api.ItemController：和 HTML 版几乎逐行相同

控制器的全文只有十行：

```elixir
defmodule AuctionWeb.Api.ItemController do
  use AuctionWeb, :controller

  def index(conn, _params) do
    items = Auction.list_items()
    render(conn, "index.json", items: items)
  end

  def show(conn, %{"id" => id}) do
    item = Auction.get_item_with_bids(id)
    render(conn, "show.json", item: item)
  end
end
```

`ch13/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/item_controller.ex`

把它和第 7 章起就没怎么变过的浏览器版放在一起看：

```elixir
  def index(conn, _params) do
    items = Auction.list_items()
    render(conn, "index.html", items: items)
  end

  def show(conn, %{"id" => id}) do
    item = Auction.get_item_with_bids(id)
    bid = Auction.new_bid()
    render(conn, "show.html", item: item, bid: bid)
  end
```

`ch13/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_controller.ex`

两个文件里取数的两行一模一样：同一个 `Auction.list_items()`、同一个
`Auction.get_item_with_bids(id)`。差别只有两处：

- API 的 `show` 不调用 `Auction.new_bid()`。HTML 版需要它是因为详情页嵌着出价
  表单，`new_bid` 返回的空 changeset 是表单的骨架；JSON 响应里没有表单，
  这个 changeset 对 API 消费者是噪音。
- `render` 的模板名从 `"index.html"` 换成 `"index.json"`。这一个后缀决定了
  响应走 JSON 编码而不是 heex 模板。

控制器到这里就结束了。没有 JSON 序列化代码，没有 `Jason.encode`，没有
`put_resp_content_type`。controller 的职责仍然是"取数 + 指定格式"，
和 HTML 时代完全相同。变化全部发生在 `render/3` 内部的分发上。

## "index.json" 怎么找到 ItemJSON

分发的规则写在 `use AuctionWeb, :controller` 展开后的两行里：

```elixir
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: AuctionWeb.Layouts]
```

`ch13/auction_umbrella/apps/auction_web/lib/auction_web.ex`

`formats: [:html, :json]` 声明这个 controller 认识两种输出格式。
`render(conn, "index.json", items: items)` 从模板名里拆出两样东西：格式 `json`
（和 `phoenix_format` 对账）加 action 名 `index`。然后按约定找渲染模块：把
controller 模块名的 `Controller` 后缀换成大写的格式名 `JSON`，
`Api.ItemController` 对应 `Api.ItemJSON`。最后调用
`ItemJSON.index(%{items: items})`，把这个函数的返回值交给 JSON 编码器。

用一行伪代码表示渲染模块的解析规则：

```elixir
# Api.ItemController + "index.json"  →  Api.ItemJSON.index(assigns)
```

对比 HTML 侧的完整链路，更容易看清 `*_json` 在什么位置：

```text
浏览器版：  render(conn, "index.html", items: items)
           → ItemHTML.index(assigns) → embed_templates 编译出的模板函数
           → heex 输出 HTML 字符串 → 套 layout → send_resp

JSON 版：  render(conn, "index.json", items: items)
           → ItemJSON.index(assigns) → 普通函数，返回普通 map
           → Jason 编码成 JSON 字符串 → send_resp（没有 layout）
```

`*_json` 模块没有 `embed_templates`，也没有对应的 `.json.eex` 文件目录。
每个 action 对应的就是一个"action 名 + assigns map"的普通函数：`index/1`、
`show/1`。HTML 侧要模板文件是因为输出是一长串文本，插值、循环、转义都需要
一套语法；JSON 的输出本来就是 Elixir 数据结构，map 里面套 map 和列表，函数体
就能写完，模板这层抽象在这里没有存在的必要。

编码由 `Phoenix.json_library()` 配置的 Jason 完成（`config :phoenix,
:json_library, Jason`，在 `ch13/auction_umbrella/config/config.exs`）。渲染
函数只要保证返回的 map 里全是 Jason 认识的类型：map、list、字符串、数字、
布尔、nil，以及实现了 `Jason.Encoder` 协议的结构体。`DateTime` 实现了这个协议，
所以 `ends_at` 不用处理，直接放进取值里就会变成 ISO8601 字符串。

## ItemJSON：白名单式的手工翻译

```elixir
defmodule AuctionWeb.Api.ItemJSON do
  alias AuctionWeb.Api.BidJSON

  def index(%{items: items}) do
    %{data: for(item <- items, do: item(item))}
  end

  def show(%{item: item}) do
    %{data: item_with_bids(item)}
  end

  defp item_with_bids(item) do
    %{
      type: "item",
      id: item.id,
      title: item.title,
      description: item.description,
      ends_at: item.ends_at,
      bids: for(bid <- item.bids, do: BidJSON.bid(%{bid: bid}))
    }
  end

  defp item(item) do
    %{
      type: "item",
      id: item.id,
      title: item.title,
      description: item.description,
      ends_at: item.ends_at
    }
  end
end
```

`ch13/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/item_json.ex`

`index/1` 和 `show/1` 是 Phoenix 会调的两个入口，参数就是 controller 传进去的
assigns，各自包一层 `%{data: ...}` 再往下分发。这个 `data` 键是常见 API 习惯：
将来想往响应顶层加 `meta`（分页信息）、加 `links`，不动 `data` 的形状就行。

真正值得看的是两个 `defp` 函数，它们体现了手工翻译的三层取舍。

**第一，字段是白名单，不是全量导出。** 模块没有写 `Map.from_struct(item)`，
更没有 `Jason.encode!(item)`。schema 里的 `inserted_at`、`updated_at`、`__meta__`
这类内部字段一概不放行。更关键的是这个决定对未来的保护：哪天给 `items` 表加了
内部字段（比如成本价、来源标记），只要没人回来改这个函数，新字段就永远漏不出
API。全量导出正好相反，schema 每加一个字段，API 契约就悄悄变一次。

多出来的 `type: "item"` 也是这个思路的正面：客户端拿到异构列表或者要缓存时，
`type` 让它不用靠"有没有 `amount` 字段"去猜对象是什么。

**第二，index 和 show 给两种深度。** `index` 走 `item/1`，不含 `bids`；
`show` 走 `item_with_bids/1`，带上完整的出价数组。这不是代码洁癖，是有成本
依据的：列表接口一次返回几十上百条 item，每条都嵌 bids，响应体会翻好几倍，
数据库还要多跑 N 次关联查询，而列表的消费者九成情况下只想要标题和截止时间。
"列表给摘要、详情给全量"是 API 设计里最常见的粒度划分，Elixir 里就是两个
函数的事。

注意 `index` 也因此不需要 preload：`item/1` 不碰 `item.bids`，那条
`%Ecto.Association.NotLoaded{}` 安安静静躺在结构体里，Jason 不会看见它。
`list_items()` 不用为它改。

**第三，嵌套靠函数调用串起来。** `bids` 字段的值是对 `item.bids` 的每个元素调一次
`BidJSON.bid(%{bid: bid})` 收回来的列表。嵌套的深度由调用链决定，而不是由任何
配置声明。

:::note[render_many / render_one]
`Phoenix.Controller` 其实提供了 `render_many(collection, view, template)` 和
`render_one(resource, view, template)` 两个帮手，本质就是帮你写这个 `for` 循环
和 nil 判断。本章代码直接用 `for` 推导式 + 显式调用 `BidJSON.bid/1`，效果一样，
但输出 shape 完全摆在眼前，嵌 `user` 这种第二层关联时也更自由。`render_one`
的参数固定是"一个资源"，这里给 bid 配 user 的组合靠它反而绕。
:::

## BidJSON 与 UserJSON：嵌套往下再传一层

```elixir
defmodule AuctionWeb.Api.BidJSON do
  alias AuctionWeb.Api.UserJSON

  def bid(%{bid: bid}) do
    %{
      type: "bid",
      id: bid.id,
      amount: bid.amount,
      user: bid.user && UserJSON.user(%{user: bid.user})
    }
  end
end
```

`ch13/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/bid_json.ex`

```elixir
defmodule AuctionWeb.Api.UserJSON do
  def user(%{user: user}) do
    %{
      type: "user",
      id: user.id,
      username: user.username
    }
  end
end
```

`ch13/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/user_json.ex`

每个资源一个 `*_json` 模块，模块里一个公开的渲染函数。`ItemJSON` 的
`item_with_bids` 调 `BidJSON.bid/1`，`BidJSON.bid/1` 再调 `UserJSON.user/1`，
三层调用链对应 JSON 里三层嵌套。每个模块只需要认识自己的 schema，谁也不用
知道整条链长什么样，`ItemJSON` 连 `user` 这个字段的存在都看不到。

`UserJSON` 的白名单是三个模块里最严的：`User` schema 里有 `hashed_password`
和 `email_address`，前者无论如何都不能出 API，后者属于个人隐私看业务需要。
这里只放 `id` 和 `username`。手写翻译函数在这件事上又赢一次：哪怕哪天
`User` schema 多了 `phone` 字段，`UserJSON` 不改，API 就不漏。

## `bid.user &&` 挡住什么，挡不住什么

`BidJSON` 里这行值得停下来：

```elixir
user: bid.user && UserJSON.user(%{user: bid.user})
```

`bid.user` 是 `belongs_to` 关联，它有两个"不是用户"的取值，行为完全不同：

- **`nil`。** 出价没有关联用户（数据库里 `user_id` 为 NULL）时，`bid.user`
  就是 `nil`。`&&` 在这里短路，`user` 字段输出 JSON 的 `null`，
  `UserJSON.user/1` 不会被调用。这是 `&&` 真正能挡的情况。
- **`%Ecto.Association.NotLoaded{}`。** preload 没做时，`bid.user` 是这样一个
  结构体。它是 truthy 的，`&&` 放它过去，`UserJSON.user` 里访问
  `user.id` 直接抛 `KeyError`，因为 `NotLoaded` 的 map 里没有 `:id` 键。

所以 `&&` 的用途只有一个：给"关联在数据库里真的是空"兜底。它不是 preload
缺失的防护网，也不该是。preload 掉了，程序应该响亮地崩在开发或测试阶段，
而不是沉默地输出一堆 `null` 让用户去猜。这也是为什么下一节的两次 preload
一步都不能省，JSON 层没有替数据层兜底的设计。

（顺带一提，`Bid.changeset` 里 `validate_required(:user_id)` 保证写进来的出价
都带用户，理论上 `bid.user` 为 `nil` 的分支很难走到。但这是渲染层的防线，
不应该依赖"数据层永远完美"这种假设。）

## 取数没有改一行：get_item_with_bids 的两次 preload

JSON 里能出现三层嵌套，依赖的是第 9 章为 HTML 详情页写好的这个函数，
本章一行都没有改：

```elixir
  def get_item_with_bids(id) do
    id
    |> get_item()
    |> @repo.preload(bids: from(b in Bid, order_by: [desc: b.inserted_at]))
    |> @repo.preload(bids: [:user])
  end
```

`ch13/auction_umbrella/apps/auction/lib/auction.ex`

两次 `preload` 的分工是：

1. `@repo.preload(bids: from(b in Bid, order_by: [desc: b.inserted_at]))`
   加载 item 的全部 bids，并且按 `inserted_at` 倒序，最新的出价排最前。
   `preload` 接一个 query 而不是裸关联名，才能在加载关联的同时带上排序条件。
2. `@repo.preload(bids: [:user])` 对每个已加载的 bid 再加载它的 `user`。
   这就是 `bids → user` 这层嵌套的物理来源。

少掉第二步，`bid.user` 就是上节说的 `%Ecto.Association.NotLoaded{}`，
`BidJSON` 渲染到 `user` 字段时抛 `KeyError`，整个请求以 500 收场。
换句话说，`show` 的 JSON shape（item → bids → user）是这个函数的三步管道
决定的：取数函数把关联装进结构体，渲染层只是把装好的结构体抄成 map。

## 一个 context，两个界面

把这一章的改动摊开，会发现一件值得记住的事：API 上线，`Auction` 模块、
`Auction.Bid`、`Auction.Item`、`Auction.User` 的代码零改动。所有新代码都住在
`auction_web` 的 `controllers/api/` 目录里。

这是第 3 章 umbrella 拆分埋下的回报。业务函数 `list_items()`、
`get_item_with_bids(id)` 对"调用者是 HTML controller 还是 JSON controller"
完全无感，它们返回的是 `%Item{}` 结构体；怎么把结构体变成 HTTP 响应，是各自
渲染层的事。HTML 版把结构体喂给 heex 模板，JSON 版把它喂给手工 map，两条渲染
路径独立演化，取数路径天然共享。

这个结构对将来的接口同样成立。加一个 GraphQL 端点，resolver 里写的还是
`Auction.get_item_with_bids(id)`；加 LiveView 出价面板，mount 里还是
`Auction.list_items()`；甚至加一个 CLI 工具或者定时任务，要的数据还是这几个
函数。新界面只新增"渲染"代码，不新增"取数"代码，context 是系统里唯一一份
业务事实。

## 动手验证

在 `ch13/auction_umbrella` 目录下先把环境跑起来（数据库第一次需要
`mix setup`：装依赖、建库、跑迁移和种子数据）：

```bash
cd ch13/auction_umbrella
mix setup
```

**第一步：看路由表。** `mix phx.routes` 输出里能看到两行新路由，控制器名字
带上了 `Api.` 命名空间：

```bash
GET  /api/items      AuctionWeb.Api.ItemController :index
GET  /api/items/:id  AuctionWeb.Api.ItemController :show
```

`mix phx.routes` 同时是验证"模块前缀"机制的地方：如果哪行写的是
`AuctionWeb.ItemController`，说明 scope 的第二个参数没生效。

**第二步：起服务，要 JSON。**

```bash
mix phx.server
```

`accepts` plug 检查 `Accept` 头，所以 curl 必须显式声明（不带的话，
curl 默认发 `Accept: */*`，`*/*` 其实也能通过协商，但浏览器那种
`text/html` 优先的头就会被 406 拒掉）：

```bash
curl -H "Accept: application/json" http://localhost:4000/api/items
```

响应形如（`data` 数组对应 `ItemJSON.index/1` 返回的 `%{data: ...}`，字段值
取决于你数据库里实际有什么）：

```json
{
  "data": [
    {
      "type": "item",
      "id": 1,
      "title": "baseball glove",
      "description": "well-worn",
      "ends_at": "2026-12-01T12:00:00Z"
    }
  ]
}
```

注意列表里没有 `bids` 键，这是 `item/1` 的摘要版本。`ends_at` 是 `DateTime`
结构体，Jason 按协议自动转成了 ISO8601 字符串，手工 map 里不需要任何转换。

**第三步：详情接口看嵌套。** 先确保这条 item 下已有出价（浏览器登录后在
`/items/:id` 页面出一个），然后：

```bash
curl -H "Accept: application/json" http://localhost:4000/api/items/1
```

这次 `bids` 和每条的 `user` 都出来了，shape 正好就是
`ItemJSON → BidJSON → UserJSON` 三个函数嵌出来的：

```json
{
  "data": {
    "type": "item",
    "id": 1,
    "title": "baseball glove",
    "description": "well-worn",
    "ends_at": "2026-12-01T12:00:00Z",
    "bids": [
      {
        "type": "bid",
        "id": 3,
        "amount": 2500,
        "user": { "type": "user", "id": 1, "username": "alice" }
      }
    ]
  }
}
```

**第四步：验证 406 和错误格式。** 故意用 HTML 的 Accept 头访问：

```bash
curl -i -H "Accept: text/html" http://localhost:4000/api/items
```

返回 `HTTP/1.1 406 Not Acceptable`，响应体是 JSON：
`{"errors":{"detail":"Not Acceptable"}}`。这份 JSON 来自 `ErrorJSON`，
Endpoint 配置 `render_errors: [formats: [html: ..., json: AuctionWeb.ErrorJSON]]`
（`ch13/auction_umbrella/apps/auction_web/config/config.exs`）按协商的格式
挑错误渲染模块，`render(template, _)` 把 `"406.json"` 翻成标准状态短语。
换句话说，JSON 客户端连出错都不需要会读 HTML。

**第五步：跑测试。** 在 umbrella 根目录：

```bash
mix test
```

根 `mix.exs` 把 `test` 别名定义成了
`["ecto.create --quiet", "ecto.migrate", "test"]`：先静默建测试库、跑迁移，
再依次跑 `auction` 和 `auction_web` 两个子应用的测试。`auction_test.exs`
里的 `Ecto.Adapters.SQL.Sandbox.checkout(Repo)` 给每个测试包一层数据库事务，
测完回滚。目前没有专门断言 `/api/items` 的测试，但 `AuctionTest` 覆盖的
`list_items/0`、`get_item/1` 正是 API 依赖的那几个函数。给 API 端点补
controller 测试是下一章的内容。

## 小结

- `:api` pipeline 只有 `plug :accepts, ["json"]`：API 流量无 session、无
  flash、无 CSRF、无登录态，内容协商失败在 pipeline 里就以 406 终结。
- `scope "/api", AuctionWeb.Api` 一次声明 URL 前缀和模块前缀，`ItemController`
  解析为 `AuctionWeb.Api.ItemController`，和浏览器版彻底分开。
- `render(conn, "index.json", ...)` 由 `formats: [:html, :json]` 分发到
  `Api.ItemJSON.index/1`；`*_json` 模块里的函数收 assigns、返回普通 map，
  Jason 负责编码，没有模板文件这一层。
- JSON shape 是手工列出来的白名单：schema 加字段不会自动泄露，`hashed_password`
  这类字段天然进不了响应；`index` 给摘要、`show` 给嵌套全量。
- `bid.user &&` 只挡 `nil`，挡不住 `%Ecto.Association.NotLoaded{}`：后者
  是 truthy，会抛 `KeyError`，所以 `get_item_with_bids` 的两次 preload
  一步都不能少。
- 两个界面共用同一个 `Auction` context，本章没改 `auction` 应用的一行代码；
  以后加任何新界面，改的都只是渲染层。

下一章是整个项目的收尾：给 `Auction` context 和各 controller 建测试体系，
补全 API 的写接口（比如用 API 出价），再从顶层回看这个从 `mix phx.new`
一路长出来的应用最终的完整结构。
