---
title: 第14章 · API 写接口
description: 在 ch14 上给 JSON API 补齐写路径：:api 管线接 session、Authenticate 守门、POST /api/items 和 POST /api/items/:id/bids、changeset 错误翻成 JSON、201/422/401 三种回包形状
sidebar:
  order: 14
---

上一章的 API 只开了两个读口：`GET /api/items` 和 `GET /api/items/:id`。
一个只能看的接口价值有限——外部系统最想干的事是把出价写进来。
本章把 API 补成可写的：`POST /api/items` 建商品、`POST /api/items/:id/bids`
出价，登录态复用浏览器同一份 session cookie，失败时把 changeset 的错误
翻成 JSON 而不是甩出 HTML 调试页。

代码落在 `ch14/auction_umbrella`，也就是上一章的同一份快照往前再走一步。

## :api 管线多两个 plug

之前 `:api` 管线刻意只有 `accepts ["json"]`，理由是 API 客户端"不需要 session"。
这个结论对读接口成立，对写接口不成立：`POST /api/items/7/bids` 必须知道
**是谁**在出价，而"你是谁"在本应用里的唯一载体就是 cookie 里那份 session。
所以写接口的第一件事，是把 session 这条线接进 `:api`：

```elixir
  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug AuctionWeb.Authenticator
  end
```

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/router.ex`

多出来的两行全是复用：`fetch_session` 是 `:browser` 里那位（它依赖 Endpoint
的 `Plug.Session`，cookie 解码在那一层早就做好）；`AuctionWeb.Authenticator`
也是同一个模块，`get_session(:user_id)` 查到用户就 `assign :current_user`。
两个界面在"你是谁"这件事上共用了同一条流水线，`current_user` 的语义
在两个 scope 里完全一样。

代价也得说清楚：session 是 cookie 带的，这条 API 认证路线只对"能存
cookie 的客户端"友好——浏览器、curl、带 cookie jar 的脚本。给手机 App
或第三方后端发 API，通常用 token 而不是 cookie（`Phoenix.Token` 一行就能
签，`UserSocket` 的 `connect` 注释里就是这条思路）。session cookie 走通
最简单的一条路，token 化留作后面的练习。

注意没有 `protect_from_forgery`：它校验的是表单提交的 CSRF token，API
客户端的 body 是 JSON，走不通这条路，靠 cookie 的 `SameSite=Lax` 和
"写接口必须登录"两层防线撑着。

## 路由：嵌套 scope 加 create

```elixir
  scope "/api", AuctionWeb.Api do
    pipe_through :api

    resources "/items", ItemController, only: [:index, :show, :create] do
      resources "/bids", BidController, only: [:create]
    end
  end
```

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/router.ex`

`resources` 嵌套在第 11 章的浏览器路由里见过一次：子资源的路径自动带上
父资源的 id 段，`POST /api/items/:item_id/bids` 里 `:item_id` 就是这么来的。
`only: [:create]` 依然是刻意的收窄——写接口只放建，不改不删。

## Api.Authenticate：把 401 挡在 controller 前面

```elixir
defmodule AuctionWeb.Api.Authenticate do
  @moduledoc """
  API write endpoints reuse the browser session cookie: `:api` pipeline fetches
  the session and `Authenticator` puts the user into assigns. This plug turns an
  anonymous request into a 401 JSON response before the controller runs.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %Auction.User{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_status(:unauthorized)
    |> json(%{errors: %{detail: "Authentication required"}})
    |> halt()
  end
end
```

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/authenticate.ex`

它和浏览器侧的 `require_logged_in_user`（第 10 章 `BidController` 里的函数
plug）做的是同一件事，但出口不一样。浏览器版没登录就 `put_flash` 加
`redirect`：人能看到提示再被送回列表页。API 客户端没有界面，`redirect` 对
它是噪音，正确答案是 `401` 加一个 JSON 错误体，`halt()` 就地截断管线。

两个守门函数共享同一份语义（`current_user` 为 nil 就拒），差别全部在
"用什么形式拒绝"上——这又是 context 之外、渲染层各管各的一段证据。

## Api.BidController.create：一次插入，三处落地

```elixir
defmodule AuctionWeb.Api.BidController do
  use AuctionWeb, :controller

  plug AuctionWeb.Api.Authenticate when action in [:create]

  def create(conn, %{"amount" => amount, "item_id" => item_id}) do
    case Auction.insert_bid(%{
           amount: amount,
           item_id: item_id,
           user_id: conn.assigns.current_user.id
         }) do
      {:ok, bid} ->
        bid = Auction.get_bid(bid.id)

        html =
          Phoenix.Template.render_to_string(
            AuctionWeb.BidHTML,
            "bid",
            "html",
            bid: bid
          )

        AuctionWeb.Endpoint.broadcast("item:#{item_id}", "new_bid", %{body: html})

        conn
        |> put_status(:created)
        |> put_resp_header("location", ~p"/api/items/#{bid.item_id}")
        |> render("show.json", bid: bid)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: AuctionWeb.Api.ChangesetJSON)
        |> render("error.json", changeset: changeset)
    end
  end
end
```

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/bid_controller.ex`

`plug ... when action in [:create]` 这个守卫让 `Authenticate` 只拦
`create`——index/show 这类读接口保持匿名可读，和第 10 章在
`BidController` 顶部给单个 controller 上锁是同一手法，只是从函数 plug
换成了模块 plug。

`create` 成功路径做了三件互不相关的事，按顺序排：

1. **`Auction.get_bid(bid.id)` 重查一遍。** `insert_bid` 刚返回的 bid 里
   `user` 关联是 `NotLoaded`，`BidJSON` 渲染 `user` 字段时会抛 `KeyError`。
   context 里新增的 `get_bid/1` 只做一件事：`@repo.get!(Bid, id)` 之后
   `preload(:user)`，把渲染需要的关联补齐。这一步和第 11 章"preload 两次
   才能嵌出 user"是同一个纪律，只是写在 context 里，调用方更省事。
2. **`render_to_string` + `broadcast`。** 浏览器出价时 `BidController`
   渲 `bid.html.heex` 再广播；API 出价要的是同一件事——让盯着页面的人
   实时看到新出价，不管那条出价从哪个界面来。直接抄 `BidController` 的
   三行：渲染同一个模板、广播到同一个 topic。`Endpoint.broadcast` 不认识
   调用方是 HTML controller 还是 API controller，消息一到 PubSub 两边
   的浏览器都长出新出价。
3. **`put_status(:created)` + `location` 头 + `render`。** `201 Created`
   是写接口的标准成功码，`location` 头告诉客户端新资源在哪：
   `~p"/api/items/#{bid.item_id}"` 展开成 `/api/items/7`，这是资源归属
   的惯例写法（bid 住在 item 下）。`render("show.json", bid: bid)`
   走到 `Api.BidJSON.show/1`：

```elixir
  def show(%{bid: bid}) do
    %{data: bid(%{bid: bid})}
  end
```

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/bid_json.ex`

`show/1` 是新加的，和 `ItemJSON` 一个形状：入口函数包一层 `%{data: ...}`，
细节留给 `bid/1`。这层壳是为以后加 `meta`、`links` 留的口子。

## Api.ItemController.create：同款三件套

```elixir
  plug AuctionWeb.Api.Authenticate when action in [:create]

  def create(conn, %{"item" => item_params}) do
    case Auction.insert_item(item_params) do
      {:ok, item} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", ~p"/api/items/#{item.id}")
        |> render("show.json", item: Auction.get_item_with_bids(item.id))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: AuctionWeb.Api.ChangesetJSON)
        |> render("error.json", changeset: changeset)
    end
  end
```

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/item_controller.ex`

结构完全对称：守卫、201、`location`、错误分支。两点不同值得单独说：

- **成功之后重查了一遍 `get_item_with_bids`。** `insert_item` 返回的
  item 里 `bids` 是 `NotLoaded`，`ItemJSON.show` 走 `data_with_bids`
  会读 `item.bids`，直接传刚插入的 struct 就抛 `KeyError`。返回前
  先按 id 重查、带上 preload，API 的形状和 `GET /api/items/:id` 的
  `show` 完全一致——客户端把"刚建完的响应"和"查询单条"当同一种
  对象处理。
- **`location` 用 `#{item.id}`。** 和 bid 那边一样，新资源的 URL
  指回它自己的 `show` 端点。

## ChangesetJSON：把错误也翻成 JSON

```elixir
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
```

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/changeset_json.ex`

错误分支里 `put_view(json: AuctionWeb.Api.ChangesetJSON)` 和第 11 章在
`BidController` 里 `put_view(html: AuctionWeb.ItemHTML)` 是同一个工具：
渲染目标和 action 的命名对不上时，临时换掉渲染模块。`BidController`
的失败要重画 `ItemHTML` 的 show 页，所以换 `html:`；`Api.BidController`
的失败要渲 changeset 错误，所以换 `ChangesetJSON` 并渲 `"error.json"`。

`ChangesetJSON.error/1` 只有一行真代码：
`Ecto.Changeset.traverse_errors/2` 把 changeset 里 `errors` 列表里的
`{msg, opts}` 元组逐条交给 `CoreComponents.translate_error/1`——就是
heex 表单里 `<.input>` 用来把校验错误翻成红字的那个函数。HTML 表单和
JSON 接口共享同一份错误翻译，输出形状是标准的 `%{field => [msg]}`：

```json
{"errors":{"title":["should be at least 3 character(s)"]}}
```

`422 Unprocessable Entity` 是这个形状的标准回包码：请求格式没错，
语义校验没过。

## 动手验证

```sh
cd ch14/auction_umbrella
mix setup
mix phx.server
```

**第一步：看路由。** 两条写路由出现在 `/api` scope 下：

```text
POST    /api/items                AuctionWeb.Api.ItemController :create
POST    /api/items/:item_id/bids  AuctionWeb.Api.BidController :create
```

**第二步：匿名写，应该 401。** 不带任何凭据直接出价：

```sh
curl -i -X POST http://localhost:4000/api/items/1/bids \
  -H 'Content-Type: application/json' -d '{"amount": 100}'
```

返回 `401 Unauthorized`，body 是 `{"errors":{"detail":"Authentication required"}}`——
`Authenticate` 在 controller 之前就把请求拦下了，`insert_bid` 根本没被调到。

**第三步：带上 session 再写。** 先用浏览器登录一次（没有账号就去
`/users/new` 注册），然后拿 cookie。命令行复刻登录的最笨办法是先抓
登录页的 CSRF token：

```sh
# 1) 拿 cookie + 读登录页里的 csrf token
curl -s -c /tmp/cookies.txt http://localhost:4000/login -o /tmp/login.html
TOKEN=$(grep -o 'csrf-token" content="[^"]*"' /tmp/login.html | sed 's/.*content="//;s/"//')

# 2) POST /login 走一遍 SessionController.create，拿到签好名的 session cookie
#    （alice/secret123 换成你刚注册的账号）
curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt -X POST http://localhost:4000/login \
  -d "_csrf_token=$TOKEN&user[username]=alice&user[password]=secret123" -o /dev/null -w '%{http_code}\n'
```

浏览器里登录一次更省事，cookie 存在浏览器里；命令行这边拿到的
`/tmp/cookies.txt` 是同一份签名 session，两边等价。

**第四步：出价写进去。**

```sh
curl -s -b /tmp/cookies.txt -X POST http://localhost:4000/api/items/1/bids \
  -H 'Content-Type: application/json' -d '{"amount": 1500}' -w '\nHTTP %{http_code}\n'
```

```json
{"data":{"id":2,"type":"bid","user":{"id":1,"type":"user","username":"alice"},"amount":1500}}
HTTP 201
```

`location` 响应头里是 `/api/items/1`，客户端拿到可以直接接着 `GET`。

**第五步：看着页面被推送。** 浏览器停在 `http://localhost:4000/items/1`
（保持频道连着），再发一次上面的 curl。浏览器顶端的出价列表会自己长出
一条 `from alice`——API 写进去的数据，Channel 广播照旧工作，这是
"两条渲染路径共享一份取数和广播"最直接的证据。

**第六步：422 的形状。** 发一个 `title` 太短的新商品：

```sh
curl -s -b /tmp/cookies.txt -X POST http://localhost:4000/api/items \
  -H 'Content-Type: application/json' -d '{"item":{"title":"x"}}' -w '\nHTTP %{http_code}\n'
```

```json
{"errors":{"title":["should be at least 3 character(s)"]}}
HTTP 422
```

`ChangesetJSON` 把 `title` 的 `validate_length` 失败翻成了前端能直接
展示的 map，和 HTML 表单红字用的是同一个 `translate_error`。

## 小结

- `:api` 管线接上 `fetch_session` + `Authenticator` 后，API 写接口复用
  浏览器同一份 session；`Api.Authenticate` 在管线末端把匿名请求拦成
  `401`，controller 只管业务。
- 两个 `create` 长得一样：`insert_*` → 重查补 preload → `201` +
  `location` + `render("show.json")`；失败统一 `put_view(json:
  ChangesetJSON)` + `422` + `%{errors: %{field => [msg]}}`。
- `Api.BidController` 出价成功照样 `Endpoint.broadcast`：Channel 链路
  不知道也不关心写入是从哪个界面来的。
- 写接口的认证边界现在是"cookie 能到的客户端"；真正的第三方接入，
  下一步该给 API 发 `Phoenix.Token`，把 session 换成 Authorization 头。

下一章换个方向：不用 JS 手写 DOM 更新，把 item 详情页整页交给
LiveView，出价表单、新出价推送、`current_user` 全部由服务端渲染管起来。
