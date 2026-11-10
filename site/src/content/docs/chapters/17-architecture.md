---
title: 第17章 · 项目全貌
description: 盘点 ch15 umbrella 的最终结构与边界、HTTP/Channel/LiveView/JSON API 各条链路的完整走向，并回顾全书演进
sidebar:
  order: 17
---

上一章给 `auction` 加上了第一个业务进程，应用的功能到此已经齐了：能浏览、能
出价、能登录、有实时更新、有 LiveView 页面、有供外部调用的接口。本章不加新功能，
回到全景把最终结构摊开看：完整走一遍 umbrella 的目录树，分清 `auction` 和
`auction_web` 两个应用的边界；再把 HTTP 和 Channel 两条链路端到端画出来，从
Bandit 接到 TCP 包到浏览器收到新出价，每一步对应哪个文件；LiveView 和 JSON API
各补一段；最后以一张演进回顾表收束全书。

## 最终目录：一棵 umbrella 树

最终的项目长这样（省略 `_build`、`deps`、`mix.lock` 等生成物）：

```text
ch15/auction_umbrella/
├── mix.exs                        # umbrella 根：apps_path + 公共 alias
├── config/
│   ├── config.exs                 # 汇集各 app 配置的入口
│   └── runtime.exs                # 启动时读环境变量（prod 用）
└── apps/
    ├── auction/                   # 领域层：数据与业务，不认识 HTTP
    │   ├── mix.exs                #   deps 只有 ecto_sql / postgrex / pbkdf2
    │   ├── lib/
    │   │   ├── auction.ex         #   context 门面，Web 层唯一入口
    │   │   └── auction/
    │   │       ├── application.ex #   OTP 入口，监督 Repo + BidCache
    │   │       ├── repo.ex        #   Ecto.Repo
    │   │       ├── item.ex        #   schema + changeset
    │   │       ├── user.ex        #   schema + 密码哈希 changeset
    │   │       ├── bid.ex         #   schema + 双外键
    │   │       ├── password.ex    #   Pbkdf2 封装
    │   │       ├── bid_cache.ex   #   GenServer：每商品最高价缓存
    │   │       └── fake_repo.ex   #   早期章节的内存实现，留存不用
    │   ├── priv/repo/             #   4 个迁移 + seeds.exs
    │   └── test/auction_test.exs
    └── auction_web/               # 界面层：HTTP + Channel + LiveView，不写 SQL
        ├── mix.exs                #   phoenix/bandit/live_view/jason + {:auction}
        ├── config/{config,dev,prod,test}.exs
        ├── lib/
        │   ├── auction_web.ex     #   controller/html/channel 的公共注入点
        │   └── auction_web/
        │       ├── application.ex #   DNSCluster + PubSub + Endpoint
        │       ├── endpoint.ex    #   plug 链 + /socket、/live 升级点
        │       ├── router.ex      #   :browser/:api 两条 pipeline + live_session
        │       ├── authenticator.ex # 查 session 的 plug
        │       ├── gettext.ex     #   i18n 后端
        │       ├── controllers/   #   item/bid/user/session + *_html/* + api/
        │       ├── channels/      #   user_socket.ex + item_channel.ex
        │       ├── live/          #   item_live/show.ex + user_auth_live.ex
        │   │       └── components/    #   layouts、core_components、global_helpers
        ├── priv/static/           #   app.js、phoenix.js、phoenix_live_view.js、app.css
        └── test/
            ├── test_helper.exs
            ├── support/{conn_case,channel_case}.ex
            └── auction_web/{components,controllers}/
```

`ch15/auction_umbrella`

根的 `mix.exs` 几乎不声明依赖（只有一个只在 dev 用的 `ex_doc`），它管两件事：
`apps_path: "apps"` 告诉 Mix 子应用在哪，alias 让常用命令在根目录一键跑通：

```elixir
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run apps/auction/priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end
```

`ch15/auction_umbrella/mix.exs`

注意 `test` 这个 alias：在根目录执行 `mix test` 会先静默建库、跑完迁移，再依次跑
每个子应用的测试。一条命令验收整个系统，下一章会完整演示。

两个子应用共享 `_build`、`deps`、`mix.lock`，靠的是各自 `mix.exs` 里四行相对路径：

```elixir
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
```

`ch15/auction_umbrella/apps/auction_web/mix.exs`

`config_path` 这一行让配置也收拢到根目录。根的 `config/config.exs` 再用通配符把
每个 app 自己的配置引回来：

```elixir
for config <- "../apps/*/config/config.exs" |> Path.expand(__DIR__) |> Path.wildcard() do
  import_config config
end
```

`ch15/auction_umbrella/config/config.exs`

于是一种回环结构：入口在根，内容分到各 app 自己的 `config/`。`apps/auction_web/config/config.exs`
管 endpoint、日志、JSON 库；`apps/auction/config/config.exs` 管 Repo 连接参数；
各自再 `import_config "#{config_env()}.exs"` 分环境覆盖。根的 `config/runtime.exs`
每次启动时才执行，`DATABASE_URL`、`SECRET_KEY_BASE`、`PHX_HOST`、`PORT` 从这里
读环境变量，编译期配置和运行时机密分开。

## 两个应用的边界

这棵树里最重要的一条线在 `apps/` 中间：`auction` 管"是什么"，`auction_web` 管
"怎么给人看"。

看 deps 最直观。`auction` 的依赖是 `ecto_sql`、`postgrex`、`pbkdf2_elixir`，
它对 HTTP 一无所知；`auction_web` 的依赖是 phoenix、bandit、phoenix_ecto、
phoenix_html、phoenix_live_view、gettext、jason、dns_cluster、timex，外加一行
`{:auction, in_umbrella: true}`。`in_umbrella` 告诉 Mix：这个依赖不去 Hex 下载，
直接编译 `apps/auction`，没有版本号约束，改了 `auction` 的代码重新编译就生效。
单向依赖保证业务层不可能反过来引用 Web 层的模块。

`Auction` 模块是系统唯一的业务入口，Web 层从不直接碰 `Auction.Repo`。文件顶部
三行概括了这个应用：

```elixir
  alias Auction.{Bid, BidCache, Item, User, Password}
  import Ecto.Query

  @repo Auction.Repo
```

`ch15/auction_umbrella/apps/auction/lib/auction.ex`

`@repo` 这个模块属性是"把仓库抽象成接口"留下的痕迹：第 2 章起它指向内存实现
`Auction.FakeRepo`，第 6 章换真数据库只改了这一行，所有调用点原封不动。
`lib/auction/fake_repo.ex` 还留在代码库里，没有调用方了，留着见证这个替换有多
便宜。

门面里的函数覆盖全部用例：item 的 `list_items/0`、`get_item/1`、`insert_item/1`、
`update_item/2`、`delete_item/1`、`new_item/0`、`edit_item/1`；user 的
`get_user/1`、`insert_user/1`、`get_user_by_username_and_password/2`；bid 的
`insert_bid/1`、`new_bid/0`、`get_bid/1`、`get_item_with_bids/1`、
`get_bids_for_user/1`、`highest_bid/1`。
最复杂的一条查询（"某用户最近的十条出价"）也只是 `from` 里组合
`where`/`order_by`/`preload`/`limit` 再 `@repo.all(query)`。查询能力始终藏在
context 内部，Web 层拿到的只有结果。

这个边界在两个 `application.ex` 里也看得清。`auction` 的监督树有两个孩子：
`{Auction.Repo, []}` 之外还有第 16 章加入的 `{Auction.BidCache, []}`——一个被
监督的 Ecto Repo 加一个 GenServer 缓存，就是数据层的全部运行时。`auction_web` 的监督树多两个角色：

```elixir
    children = [
      {DNSCluster, query: Application.get_env(:auction_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AuctionWeb.PubSub},
      AuctionWeb.Endpoint
    ]
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/application.ex`

`Phoenix.PubSub` 是 Channel 广播的地基：`BidController` 里那句
`AuctionWeb.Endpoint.broadcast/3` 经由它找到所有订阅者（config 里
`pubsub_server: AuctionWeb.PubSub` 把两者连起来）。`AuctionWeb.Endpoint` 是
HTTP 服务器本身。`DNSCluster` 管生产环境的节点发现，开发环境 `:ignore` 掉，
可以不管。两棵监督树合起来：

```text
Auction.Supervisor              AuctionWeb.Supervisor
├── Auction.Repo                ├── DNSCluster（dev 下不启动）
│   （DBConnection 连接池）      ├── Phoenix.PubSub ── topic "item:*" 的订阅者
└── Auction.BidCache            └── AuctionWeb.Endpoint
    （GenServer 内存缓存）           ├── Bandit（HTTP/WS 监听 :4000）
                                    ├── plug 链 → Router → controller
                                    ├── UserSocket → ItemChannel 进程
                                    └── /live socket → ItemLive.Show 进程
```

进程模型和模块边界是同一套分工：`auction` 底下是数据库连接加进程内缓存，
`auction_web` 底下全是跟人打交道的进程。

## HTTP 链路：从 Bandit 到 HTML



第 4 章第一次画请求链路时上面只有一条 `GET /`。现在全应用摊开了，以
`POST /items/7/bids`（登录用户出价）为例走一遍：

```text
TCP 包
  → Bandit：解析出 %Plug.Conn{}
  → Endpoint 分叉：socket "/socket" 和 "/live" 只拦 WS 升级，HTTP 继续走 plug 链
    Plug.Static（命中 assets/ 就直接回文件，本例不命中）
    → Plug.RequestId / Plug.Telemetry（日志里的 request id）
    → Plug.Parsers（urlencoded body → conn.body_params）
    → Plug.MethodOverride（HTML 表单不会发 DELETE，靠 _method 改写；
      /logout 那条 delete 路由就靠它）
    → Plug.Head / Plug.Session（cookie 里读出签名的 session）
  → Router pipeline :browser
    accepts ["html"] → fetch_session → fetch_flash
    → protect_from_forgery（校验表单里的 CSRF token）
    → put_secure_browser_headers
    → AuctionWeb.Authenticator（get_session(:user_id)
      → Auction.get_user(id) → assign :current_user）
  → 路由行 POST /items/:item_id/bids（resources 嵌套出来的）
  → BidController：
    plug :require_logged_in_user（current_user 为 nil 就 flash + halt）
    create/2 模式匹配 %{"bid" => %{"amount" => _}, "item_id" => "7"}
    → Auction.insert_bid(...) → Auction.Repo → PostgreSQL
    → 成功：render_to_string 局部模板 + Endpoint.broadcast + redirect
  → 303 回浏览器 → 浏览器再发 GET /items/7 → ItemController.show/2
    → Auction.get_item_with_bids(7)（两次 preload：bids 按时间倒序 + bid.user）
    → render(conn, "show.html")
    → ItemHTML 的 "show.html" 模板函数（embed_templates 编译产物）
    → 套 Layouts 的 "app" 布局（{@inner_content} 注入点）
  → send_resp → HTML 字符串
```

每一步都能在代码里点名。嵌套路由来自 `resources "/items" ... do
resources "/bids", BidController, only: [:create] end`，URL 里的 `7` 落到
params 的 `"item_id"` 键上；`Authenticator` 是 `:browser` pipeline 的最后一个
plug，所有 HTML 页面共享同一份登录态查询；`require_logged_in_user` 是写在
controller 顶部的函数 plug，只守 `BidController` 一个。

渲染侧还有一层容易忽略的分工：模板函数和布局。`embed_templates "item_html/*"`
把 `item_html/show.html.heex` 编译成 `ItemHTML` 模块上的 `"show.html"` 函数，
`use Phoenix.Controller, layouts: [html: AuctionWeb.Layouts]` 声明所有 HTML
响应外面再套 `Layouts`。本项目只有 `app.html.heex` 一层布局，它自己就是完整
HTML 文档（含 doctype 和 `<head>`），等于把生成器默认的 root/app 两层并成了
一层。要拆开也容易：root 管 `<html>`/`<head>`/`<body>` 骨架，app 管导航和
flash，`put_root_layout`/`put_layout` 可以按 action 覆盖。

`BidController` 的 error 分支用到了一个不常见的函数：

```elixir
      {:error, bid} ->
        item = Auction.get_item(item_id)

        conn
        |> put_view(html: AuctionWeb.ItemHTML)
        |> render("show.html", item: item, bid: bid)
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/controllers/bid_controller.ex`

Phoenix 默认按 controller 名找渲染模块，`BidController` 会配 `BidHTML`。但出价
失败时要重画的是商品详情页，那模板住在 `ItemHTML` 里：`put_view(html: ...)`
临时换掉渲染模块，再照常 `render("show.html", ...)`。`put_view`、
`put_layout`、`put_root_layout` 是同一族工具：渲染目标、内层布局、外层骨架，
三层都可以在 action 里按需改写。

错误响应也走同一套机制。endpoint 配置里 `render_errors` 声明
`formats: [html: AuctionWeb.ErrorHTML, json: AuctionWeb.ErrorJSON]` 加
`layout: false`，controller
抛 `Ecto.NoResultsError`（比如 `get_item!` 查一个不存在的 id）时，Phoenix 接住
异常，按协商出的 format 调 `ErrorHTML.render("404.html", assigns)` 或
`ErrorJSON.render("404.json", assigns)`。默认实现只有一行
`status_message_from_template`：`"404.html"` 翻译成人话 "Not Found"。下一章
会看到，这种纯函数模块是最省事的测试对象。

## Channel 链路：一条出价怎么长到别人的屏幕上

实时推送是全应用唯一跨越"请求-响应"边界的链路，值得单独画一遍。

**第一条路是建连。** 页面加载时 `app.js` 无条件 `new Phoenix.Socket("/socket")`
并 connect；再用 URL 正则判断自己是不是商品详情页，是才
`socket.channel(`item:${itemId}`, {})` 并 join。

WS 握手到达 Endpoint 时被 `socket "/socket", AuctionWeb.UserSocket` 拦下升级，
之后的连接就不走 plug 链了。`UserSocket` 里一行
`channel "item:*", AuctionWeb.ItemChannel` 注册着 topic 到 channel 模块的路由
（`ch15/auction_umbrella/apps/auction_web/lib/auction_web/channels/user_socket.ex`）。
每个 join 成功的 `item:<id>` 订阅会启动一个 `ItemChannel` 进程，挂在 PubSub
的该 topic 下。`ItemChannel.join/3` 用二进制模式匹配 `"item:" <> _item_id`
放行所有 item topic：

```elixir
  @impl true
  def join("item:" <> _item_id, _params, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_in("new_bid", params, socket) do
    broadcast!(socket, "new_bid", params)
    {:noreply, socket}
  end
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/channels/item_channel.ex`

`handle_in` 是给客户端留的第二条入口：浏览器直接 push `new_bid` 也会被转发。
本应用没用它，广播全部发生在服务端。

**第二条路是广播。** `BidController.create/2` 插入成功后，先把局部模板
`bid.html.heex` 渲染成 HTML 字符串，再广播、重定向：

```elixir
        html =
          Phoenix.Template.render_to_string(
            AuctionWeb.BidHTML,
            "bid",
            "html",
            bid: bid,
            username: conn.assigns.current_user.username
          )

        AuctionWeb.Endpoint.broadcast("item:#{item_id}", "new_bid", %{body: html})
        redirect(conn, to: ~p"/items/#{bid.item_id}")
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/controllers/bid_controller.ex`

`Endpoint.broadcast` 把消息交给 `AuctionWeb.PubSub`，PubSub 投递给所有订阅
`item:7` 的 channel 进程，各自经 socket transport 推给自己的浏览器。广播的是
渲染好的 HTML 不是原始数据，客户端不需要模板能力。

**第三条路是上屏。** 浏览器收到事件，`data.body` 就是那串 `<p>...</p>`：

```javascript
  channel.on("new_bid", data => {
    console.log("new_bid message received", data)
    const elem = document.getElementById("bids")
    elem.insertAdjacentHTML("afterbegin", data.body)
  })
```

`ch15/auction_umbrella/apps/auction_web/priv/static/assets/app.js`

`insertAdjacentHTML("afterbegin", ...)` 把新出价插到 `#bids` 容器最顶部，和
服务端 `order_by: [desc: b.inserted_at]` 的倒序吻合。

第 15 章之后，这条链路还有第二个客户端。LiveView 进程在 mount 时订阅同一个
`item:<id>` topic，广播落到它的 `handle_info`，重查 `get_item_with_bids` 再算
diff 推回浏览器。对 PubSub 来说 channel 和 LiveView 只是两个普通订阅者，广播的
`Endpoint.broadcast` 一行没改过。

**首屏和推送共用同一份模板。** `bid_html/bid.html.heex` 只有三行：

```heex
<p>
  {integer_to_currency(@bid.amount)}
  <em>from {Map.get(@bid.user, :username) || assigns[:username]}</em>
</p>
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/controllers/bid_html/bid.html.heex`

`Map.get(@bid.user, :username) || assigns[:username]` 兼容两条路径：SSR 时
`bid.user` 是 preload 出来的关联，广播时关联没加载，由 controller 显式传
`username`。首屏在 `show.html.heex` 里以函数组件形式复用同一模板：

```heex
    <div id="bids">
      <AuctionWeb.BidHTML.bid :for={bid <- @item.bids} bid={bid} />
    </div>
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_html/show.html.heex`

"一条出价长什么样"在整个系统里只有一个定义，首屏渲染和广播推送消费同一个
模板函数。

## JSON API 的形态

`controllers/api/` 下共七个文件：`item_controller.ex`、`bid_controller.ex`、
`authenticate.ex` 加 `item_json.ex`、`bid_json.ex`、`user_json.ex`、
`changeset_json.ex` 四个渲染模块。controller 薄得只剩取数和写入口：

```elixir
  def show(conn, %{"id" => id}) do
    item = Auction.get_item_with_bids(id)
    render(conn, "show.json", item: item)
  end
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/item_controller.ex`
（`index` 同理，`Auction.list_items()` 之后 `render(conn, "index.json", ...)`）

它和 HTML 版用同一个 `Auction` 函数集：取数不分家，分的只是出口。
`render(conn, "show.json", item: item)` 按格式后缀找到 `ItemJSON.show/1`，
渲染层按 action 名分发，`index` 给摘要、`show` 嵌全量 bids：

```elixir
  def index(%{items: items}) do
    %{data: for(item <- items, do: data(item))}
  end

  def show(%{item: item}) do
    %{data: data_with_bids(item)}
  end

  defp data_with_bids(item) do
    item
    |> data()
    |> Map.put(:bids, for(bid <- item.bids, do: BidJSON.bid(%{bid: bid})))
  end
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/item_json.ex`

`data/1` 是白名单，只放行 `type`/`id`/`title`/`description`/`ends_at` 五个字段；
嵌套链条 `ItemJSON → BidJSON → UserJSON` 每层各管一段：

```elixir
    %{
      type: "bid",
      id: bid.id,
      amount: bid.amount,
      user: AuctionWeb.Api.UserJSON.user(%{user: bid.user})
    }
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/bid_json.ex`

`UserJSON` 只给 `type`/`id`/`username`，`hashed_password` 挡在白名单外。
`show` 里 `bid.user` 拿得到数据，靠 `Auction.get_item_with_bids/1` 里
`preload(bids: [:user])` 的第二次预加载：取数逻辑早就为页面写好了，API 白用。
`*_html` 和 `*_json` 是同一个机制的两个实例：一个编译 `.heex` 成模板函数，
一个手写函数返回 map 交给 Jason 编码，controller 对两者都只说一句
`render(conn, ...)`。

写路径按第 14 章的形状走：`Api.Authenticate` 把匿名请求拦成 `401`，成功
`put_status(:created)` 加 `location` 头，changeset 失败交给 `ChangesetJSON`
翻成 `422` 的 `%{errors: %{field => [msg]}}`。

## 演进回顾：一章一个脚印

| 章 | 代码目录 | 新增能力 | 关键文件/概念 |
| --- | --- | --- | --- |
| 第 1 章 | `ch03/blog` | 生成器骨架 | `mix phx.new`、Endpoint/Router/模板初识 |
| 第 2 章 | `ch04` | 无框架领域层 | `Auction`、`Item`、`FakeRepo` 内存仓库 |
| 第 3 章 | `ch05` | umbrella 化 | `apps/` 拆分、`application.ex`、OTP 应用 |
| 第 4 章 | `ch06` | 请求管道 | `auction_web`、plug 链、pipeline |
| 第 5 章 | `ch06` | 渲染管线 | `*_html` + `embed_templates`、Layouts、Plug.Static |
| 第 6 章 | `ch07` | 真数据库 | `Ecto.Repo`、items 迁移、`@repo` 换实现 |
| 第 7 章 | `ch08` | 可校验写入 | changeset、`insert_item` |
| 第 8 章 | `ch09` | Items 全套 CRUD | heex 表单、redirect、flash |
| 第 9 章 | `ch10` | 用户注册 | `users` 表、Pbkdf2、`hashed_password` |
| 第 10 章 | `ch10` | 登录与守门 | session、`Authenticator`、函数 plug |
| 第 11 章 | `ch11` | 出价 | `belongs_to` 关联、嵌套路由 `/items/:id/bids` |
| 第 12 章 | `ch12` | 实时推送 | `UserSocket`、`ItemChannel`、`app.js` |
| 第 13 章 | `ch13` | JSON API | `/api` scope、`Api.ItemController`、`*_json` |
| 第 14 章 | `ch14` | API 写接口 | `Api.Authenticate`、POST 路由、`ChangesetJSON` |
| 第 15 章 | `ch15` | LiveView 出价 | `ItemLive.Show`、`live_session`、`handle_info` |
| 第 16 章 | `ch15` | OTP 进程 | `BidCache` GenServer、cache-aside、监督重启 |
| 第 17 章 | `ch15` | 项目全貌 | 目录树、应用边界、链路总览 |
| 第 18 章 | `ch14` | 测试体系 | `ConnCase`/`ChannelCase`、Sandbox、`mix test` |

回看这个表，每章都只是在旧结构上加一层：FakeRepo 换成真库没动过门面，Web 层
加进来没动过领域层，Channel、API 和 LiveView 复用的都是已有的 `Auction` 函数。
没有一步
推翻过已有决策，分层的好处到这里才真正兑现。

全景看完了。下一章补最后一块：怎么证明这个系统工作，并且以后改动时继续证明
——`ConnCase`、`ChannelCase`、SQL Sandbox 各自解决什么问题，`mix test`
一次把整棵树跑绿。

