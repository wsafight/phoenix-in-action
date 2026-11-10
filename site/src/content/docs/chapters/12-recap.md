---
title: 第12章 · 收尾：测试体系与全貌
description: 盘点 ch14 umbrella 的最终结构与边界、HTTP 和 Channel 两条链路的完整走向、ConnCase/ChannelCase/Sandbox 三层测试体系，回顾全书演进并展望延伸方向
sidebar:
  order: 12
---

这是最后一章。上一章把 JSON API 加上了，拍卖应用的功能到此为止已经齐了：能浏览、
能出价、能登录、有实时更新、有供外部调用的接口。本章不加新功能，做三件收尾的事：
把最终版 umbrella 的目录和边界完整走一遍，看清每个模块住在哪里、归谁管；把两条
链路端到端画出来，从 Bandit 接到 TCP 包到浏览器收到新出价，每一步对应哪个文件；
最后把测试体系讲透，`ConnCase`、`ChannelCase`、SQL Sandbox 各自解决什么问题，
`ItemControllerTest` 为什么这样写。

## 最终目录：一棵 umbrella 树

最终的项目长这样（省略 `_build`、`deps`、`mix.lock` 等生成物）：

```text
ch14/auction_umbrella/
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
    │   │       ├── application.ex #   OTP 入口，只监督 Repo
    │   │       ├── repo.ex        #   Ecto.Repo
    │   │       ├── item.ex        #   schema + changeset
    │   │       ├── user.ex        #   schema + 密码哈希 changeset
    │   │       ├── bid.ex         #   schema + 双外键
    │   │       ├── password.ex    #   Pbkdf2 封装
    │   │       └── fake_repo.ex   #   早期章节的内存实现，留存不用
    │   ├── priv/repo/             #   4 个迁移 + seeds.exs
    │   └── test/auction_test.exs
    └── auction_web/               # 界面层：HTTP + Channel，不写 SQL
        ├── mix.exs                #   phoenix/bandit/live_view/jason + {:auction}
        ├── config/{config,dev,prod,test}.exs
        ├── lib/
        │   ├── auction_web.ex     #   controller/html/channel 的公共注入点
        │   └── auction_web/
        │       ├── application.ex #   DNSCluster + PubSub + Endpoint
        │       ├── endpoint.ex    #   plug 链 + /socket 升级点
        │       ├── router.ex      #   :browser/:api 两条 pipeline + 两个 scope
        │       ├── authenticator.ex # 查 session 的 plug
        │       ├── gettext.ex     #   i18n 后端
        │       ├── controllers/   #   item/bid/user/session + *_html/* + api/
        │       ├── channels/      #   user_socket.ex + item_channel.ex
        │       └── components/    #   layouts、core_components、global_helpers
        ├── priv/static/           #   app.js、phoenix.js、app.css、images
        └── test/
            ├── test_helper.exs
            ├── support/{conn_case,channel_case}.ex
            └── auction_web/{components,controllers}/
```

`ch14/auction_umbrella`

根的 `mix.exs` 几乎不声明依赖（只有一个只在 dev 用的 `ex_doc`），它管两件事：
`apps_path: "apps"` 告诉 Mix 子应用在哪，alias 让常用命令在根目录一键跑通：

```elixir
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end
```

`ch14/auction_umbrella/mix.exs`

注意 `test` 这个 alias：在根目录执行 `mix test` 会先静默建库、跑完迁移，再依次跑
每个子应用的测试。一条命令验收整个系统，本章后面会完整演示。

两个子应用共享 `_build`、`deps`、`mix.lock`，靠的是各自 `mix.exs` 里四行相对路径：

```elixir
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
```

`ch14/auction_umbrella/apps/auction_web/mix.exs`

`config_path` 这一行让配置也收拢到根目录。根的 `config/config.exs` 再用通配符把
每个 app 自己的配置引回来：

```elixir
for config <- "../apps/*/config/config.exs" |> Path.expand(__DIR__) |> Path.wildcard() do
  import_config config
end
```

`ch14/auction_umbrella/config/config.exs`

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
  alias Auction.{Bid, Item, User, Password}
  import Ecto.Query

  @repo Auction.Repo
```

`ch14/auction_umbrella/apps/auction/lib/auction.ex`

`@repo` 这个模块属性是"把仓库抽象成接口"留下的痕迹：第 2 章起它指向内存实现
`Auction.FakeRepo`，第 5 章换真数据库只改了这一行，所有调用点原封不动。
`lib/auction/fake_repo.ex` 还留在代码库里，没有调用方了，留着见证这个替换有多
便宜。

门面里的函数覆盖全部用例：item 的 `list_items/0`、`get_item/1`、`insert_item/1`、
`update_item/2`、`delete_item/1`、`new_item/0`、`edit_item/1`；user 的
`get_user/1`、`insert_user/1`、`get_user_by_username_and_password/2`；bid 的
`insert_bid/1`、`new_bid/0`、`get_item_with_bids/1`、`get_bids_for_user/1`。
最复杂的一条查询（"某用户最近的十条出价"）也只是 `from` 里组合
`where`/`order_by`/`preload`/`limit` 再 `@repo.all(query)`。查询能力始终藏在
context 内部，Web 层拿到的只有结果。

这个边界在两个 `application.ex` 里也看得清。`auction` 的监督树只有一个孩子
`{Auction.Repo, []}`：一个被监督的 Ecto Repo 就是数据层的全部运行时，没有缓存
进程、没有常驻 Task，因为不需要。`auction_web` 的监督树多两个角色：

```elixir
    children = [
      {DNSCluster, query: Application.get_env(:auction_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AuctionWeb.PubSub},
      AuctionWeb.Endpoint
    ]
```

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/application.ex`

`Phoenix.PubSub` 是 Channel 广播的地基：`BidController` 里那句
`AuctionWeb.Endpoint.broadcast/3` 经由它找到所有订阅者（config 里
`pubsub_server: AuctionWeb.PubSub` 把两者连起来）。`AuctionWeb.Endpoint` 是
HTTP 服务器本身。`DNSCluster` 管生产环境的节点发现，开发环境 `:ignore` 掉，
可以不管。两棵监督树合起来：

```text
Auction.Supervisor          AuctionWeb.Supervisor
└── Auction.Repo            ├── DNSCluster（dev 下不启动）
    （DBConnection 连接池）  ├── Phoenix.PubSub ── topic "item:*" 的订阅者
                            └── AuctionWeb.Endpoint
                                ├── Bandit（HTTP/WS 监听 :4000）
                                ├── plug 链 → Router → controller
                                └── UserSocket → ItemChannel 进程
```

进程模型和模块边界是同一套分工：`auction` 底下只有数据库连接，`auction_web`
底下全是跟人打交道的进程。

## HTTP 链路：从 Bandit 到 HTML



第 4 章第一次画请求链路时上面只有一条 `GET /`。现在全应用摊开了，以
`POST /items/7/bids`（登录用户出价）为例走一遍：

```text
TCP 包
  → Bandit：解析出 %Plug.Conn{}
  → Endpoint 分叉：socket "/socket" 只拦 WS 升级，HTTP 继续走 plug 链
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

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/bid_controller.ex`

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
`status_message_from_template`：`"404.html"` 翻译成人话 "Not Found"。后面会
看到，这种纯函数模块是最省事的测试对象。

## Channel 链路：一条出价怎么长到别人的屏幕上

实时推送是全应用唯一跨越"请求-响应"边界的链路，值得单独画一遍。

**第一条路是建连。** 页面加载时 `app.js` 无条件 `new Phoenix.Socket("/socket")`
并 connect；再用 URL 正则判断自己是不是商品详情页，是才
`socket.channel(`item:${itemId}`, {})` 并 join。

WS 握手到达 Endpoint 时被 `socket "/socket", AuctionWeb.UserSocket` 拦下升级，
之后的连接就不走 plug 链了。`UserSocket` 里一行
`channel "item:*", AuctionWeb.ItemChannel` 注册着 topic 到 channel 模块的路由
（`ch14/auction_umbrella/apps/auction_web/lib/auction_web/channels/user_socket.ex`）。
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

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/channels/item_channel.ex`

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

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/bid_controller.ex`

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

`ch14/auction_umbrella/apps/auction_web/priv/static/assets/app.js`

`insertAdjacentHTML("afterbegin", ...)` 把新出价插到 `#bids` 容器最顶部，和
服务端 `order_by: [desc: b.inserted_at]` 的倒序吻合。

**关键是首屏和推送共用同一份模板。** `bid_html/bid.html.heex` 只有三行：

```heex
<p>
  {integer_to_currency(@bid.amount)}
  <em>from {Map.get(@bid.user, :username) || assigns[:username]}</em>
</p>
```

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/bid_html/bid.html.heex`

`Map.get(@bid.user, :username) || assigns[:username]` 兼容两条路径：SSR 时
`bid.user` 是 preload 出来的关联，广播时关联没加载，由 controller 显式传
`username`。首屏在 `show.html.heex` 里以函数组件形式复用同一模板：

```heex
    <div id="bids">
      <AuctionWeb.BidHTML.bid :for={bid <- @item.bids} bid={bid} />
    </div>
```

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_html/show.html.heex`

"一条出价长什么样"在整个系统里只有一个定义，首屏渲染和广播推送消费同一个
模板函数。

## JSON API 的形态

`controllers/api/` 下共四个文件：`item_controller.ex` 加 `item_json.ex`、
`bid_json.ex`、`user_json.ex` 三个渲染模块。controller 薄得只剩取数：

```elixir
  def show(conn, %{"id" => id}) do
    item = Auction.get_item_with_bids(id)
    render(conn, "show.json", item: item)
  end
```

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/item_controller.ex`
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

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/item_json.ex`

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

`ch14/auction_umbrella/apps/auction_web/lib/auction_web/controllers/api/bid_json.ex`

`UserJSON` 只给 `type`/`id`/`username`，`hashed_password` 挡在白名单外。
`show` 里 `bid.user` 拿得到数据，靠 `Auction.get_item_with_bids/1` 里
`preload(bids: [:user])` 的第二次预加载：取数逻辑早就为页面写好了，API 白用。
`*_html` 和 `*_json` 是同一个机制的两个实例：一个编译 `.heex` 成模板函数，
一个手写函数返回 map 交给 Jason 编码，controller 对两者都只说一句
`render(conn, ...)`。

## 测试体系

功能齐了，还剩一件事：怎么证明它工作，并且以后改动时继续证明。测试按"离数据库
和离 HTTP 的距离"分成三层，每一层有自己的模板。

### 地基：test_helper、Sandbox、test/support

`auction` 和 `auction_web` 的 `test/test_helper.exs` 内容一样，就两行：

```elixir
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Auction.Repo, :manual)
```

`ch14/auction_umbrella/apps/auction_web/test/test_helper.exs`

第二行把 Repo 切到手动模式：连接不再自动 checkout，谁要查库谁显式申请。这是
整套事务隔离的前提，没有它 `checkout`/`start_owner!` 会以 `:auto` 模式直接失败。
配套的还有 `apps/auction/config/test.exs` 里的两行：测试库 `auction_test`，
以及 `pool: Ecto.Adapters.SQL.Sandbox`，连接池换成沙箱实现，每条连接可以包在
一个永不提交的事务里。

`auction_web` 多了个 `test/support/` 目录放 case 模板，`mix.exs` 用
`elixirc_paths` 保证它们只在 test 环境编译：

```elixir
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
```

`ch14/auction_umbrella/apps/auction_web/mix.exs`

### 三个 case 模板：ConnCase、ChannelCase、DataCase

`test/support/` 里的文件都是 `ExUnit.CaseTemplate`：测试模块写
`use AuctionWeb.ConnCase` 时，`using` 块里的 quote 在该测试模块内展开注入
imports 和 attribute，`setup` 回调每个测试跑一遍。本项目有两个，先说
`ConnCase`：

```elixir
  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AuctionWeb.Endpoint

      use AuctionWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AuctionWeb.ConnCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Auction.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
```

`ch14/auction_umbrella/apps/auction_web/test/support/conn_case.ex`

`using` 块注入三样东西：`@endpoint`（`get`/`post` 这些测试函数靠它知道往哪个
endpoint 发请求）；`use AuctionWeb, :verified_routes`（把 `~p` sigil 带进测试，
测试里写 `get(conn, ~p"/items/#{item}")` 会在编译期和路由表对账，路径写错编译
就警告，不用等运行时 404）；`Phoenix.ConnTest` 的全套工具（`build_conn/0`、
`get`/`post`/`put`/`delete`、`html_response/2`、`json_response/2`、
`redirected_to/1`）。

`setup tags` 做两件事：`start_owner!` 开一条包着事务的连接并把测试进程登记为
访问者，`on_exit` 里 `stop_owner` 回滚收尾；`build_conn()` 造一个干净的
`%Plug.Conn{}` 放进 context，测试函数才能写成 `test "...", %{conn: conn}`。
`tags` 装着 ExUnit 标签，`use AuctionWeb.ConnCase, async: true` 会进
`tags[:async]`，`shared` 选项靠它定，下一节展开。

`ChannelCase` 是同款结构的频道版本：

```elixir
  using do
    quote do
      # The default endpoint for testing
      @endpoint AuctionWeb.Endpoint

      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
    end
  end

  setup _tags do
    :ok
  end
```

`ch14/auction_umbrella/apps/auction_web/test/support/channel_case.ex`

导入换成了 `Phoenix.ChannelTest`：`connect/3`（模拟 socket 握手）、
`subscribe_and_join/4`、`push/3`、`assert_broadcast/3` 这些 channel 专用工具。
`setup` 是空的，因为本应用的 channel 逻辑根本不碰数据库：`ItemChannel` 只做
join 放行和事件转发，测试它不需要沙箱连接。以后 channel 里要查库，把
`ConnCase` 那套 `start_owner!` 搬过来就行。

Phoenix 生成器通常还会产出第三个模板 `DataCase`：给"直接操作 schema 和 Repo"
的测试用，注入 `errors_on/1` 这类 changeset 断言工具，setup 里做
`Sandbox.checkout`。本项目规模小，`test/support/` 里没有它；`auction` 应用把
checkout 直接写进测试的 `setup`，效果等价。

### 沙箱的两种用法：手动 checkout 与 start_owner!

`auction` 子应用的测试直接用 `ExUnit.Case`，没有 case 模板：

```elixir
defmodule AuctionTest do
  use ExUnit.Case
  alias Auction.{Item, Repo}
  import Ecto.Query
  doctest Auction, import: true

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end
```

`ch14/auction_umbrella/apps/auction/test/auction_test.exs`

`Sandbox.checkout(Repo)` 让测试进程自己成为一条连接的持有者，这条连接包在
事务里；测试结束进程退出，连接归还，事务回滚，每个测试看到的数据库都像新的。
`describe` 块里再叠一层 `setup` 插三条 item，通过 context 传给 test 函数。

`auction_web` 侧换成 `start_owner!`/`stop_owner` 的写法，区别有两处。第一是
所有权：`checkout` 由测试进程自己持有连接，`start_owner!` 单起一个 owner
进程代持（返回的 pid 就是它），测试崩了也有 `stop_owner` 兜底。第二是
`shared` 选项，`shared: not tags[:async]` 这句值得拆开读：

- **非 async 测试开 shared。** `post conn, "/items", ...` 的请求并不是在
  测试进程里跑完就算：`Phoenix.ConnTest` 走 endpoint 的 `call/2`，dispatch
  到别的进程执行 plug 链和 controller。连接若只归测试进程私有，controller
  里 `Auction.list_items()` 一查库就报 ownership 错误；shared 模式把这条连接
  对所有进程开放，任何进程来借都用它。非 async 测试串行跑，同一时刻只有一个
  测试开着 shared，互不干扰，这也是"碰数据库的测试不能标 async"的原因。
- **async 测试不开。** `ErrorHTMLTest` 这种纯渲染测试标了 `async: true`，
  `start_owner!` 给它一条非共享连接：反正不查库，开 shared 反而会跟并行跑着
  的非 async 测试抢沙箱模式。

再往下还有一个默认生效的事实：`config/test.exs` 里 `server: false`，测试期间
Bandit 不监听端口。`get conn, "/"` 走 `Plug.Test` 构造 conn 直接调
`Endpoint.call/2`：plug 链、pipeline、controller、模板渲染全真，省掉的只有
TCP 和进程切换。

### 测试怎么断言：context 当裁判，渲染层直测

仓库里唯一一份"实弹"测试是 `ItemControllerTest`：

```elixir
  describe "POST /items" do
    test "with valid params, creates a new Item", %{conn: conn} do
      before_count = Enum.count(Auction.list_items())
      post conn, "/items", %{"item" => %{"title" => "Item 1"}}
      assert Enum.count(Auction.list_items()) == before_count + 1
    end

    test "with valid params, redirects to the new Item", %{conn: conn} do
      conn = post conn, "/items", %{"item" => %{"title" => "Item 1"}}
      assert redirected_to(conn) =~ ~r|/items/\d+|
    end

    test "with invalid params, does not create a new Item", %{conn: conn} do
      before_count = Enum.count(Auction.list_items())
      post conn, "/items", %{"item" => %{"bad_param" => "Item 1"}}
      assert Enum.count(Auction.list_items()) == before_count
    end

    test "with invalid params, shows the new Item form", %{conn: conn} do
      conn = post conn, "/items", %{"item" => %{"bad_param" => "Item 1"}}
      assert html_response(conn, 200) =~ "<h1>New Item</h1>"
    end
  end
```

`ch14/auction_umbrella/apps/auction_web/test/auction_web/controllers/item_controller_test.exs`

这份测试有三个讲究的地方：

- **用 context 当裁判。** 断言不读 `Auction.Repo`，而是调
  `Auction.list_items()`：测试和 controller 走同一个公共 API，验证的是对外
  承诺的行为，不是内部实现。
- **正反路径成对验证。** 合法/非法参数 × 数据层效果/HTTP 响应两两组合：合法
  则数量 +1 且 `redirected_to` 指向新详情页；非法则数量不变且重渲染表单。
  `"bad_param"` 不在 `cast` 白名单里，changeset 校验落空，正好走
  `{:error, ...}` 分支；params 的 `%{"item" => %{...}}` 嵌套形状和 heex 表单
  提交上来的一模一样。
- **响应断言到字符串。** `html_response(conn, 200) =~ "<h1>New Item</h1>"`
  确认重渲染的是 `new.html`。

另外两类测试展示了"跳过整条链"的写法。`ErrorHTMLTest` 直接测渲染模块：

```elixir
  # Bring render/3 and render_to_string/3 for testing custom views
  import Phoenix.Template

  test "renders 404.html" do
    assert render_to_string(AuctionWeb.ErrorHTML, "404", "html", []) == "Not Found"
  end
```

`ch14/auction_umbrella/apps/auction_web/test/auction_web/controllers/error_html_test.exs`

`Phoenix.Template.render_to_string/4` 跳过 plug 管线直接调渲染模块：
`*_html`/`*_json` 都是纯函数，输入 assigns、输出字符串或 map，最适合 async
单测。`AuctionTest` 里的 `doctest Auction, import: true` 是另一种形态：
`@doc` 里的 `iex>` 示例被当测试跑，文档和可执行断言合成一份。

`test/auction_web/` 下还有 `page_html_test.exs` 和 `components/layouts_test.exs`，
都只有 `use AuctionWeb.ConnCase, async: true` 没有 test 块，是生成器留下的空壳。
顺带一提，`PageController` 在演进中被 `ItemController` 取代了（`/` 现在指向
`ItemController.index`），`PageHTML` 和它的空测试是留下的脚手架遗迹。

### 完整跑一遍

在 umbrella 根目录执行 `mix test`，先跑根 alias 建库迁移，然后每个子应用各跑
一轮：

```text
==> auction
......

Finished in 0.1 seconds (0.1s async, 0.1s sync)
2 doctests, 5 tests, 0 failures

==> auction_web
.......

Finished in 0.4 seconds (0.4s async, 0.4s sync)
7 tests, 0 failures
```

`auction` 侧 5 个普通测试加 `@doc` 提取出的 2 个 doctest；`auction_web` 侧
`ItemControllerTest` 5 个加 `ErrorHTMLTest` 2 个，两个空壳模块不占数。

这套体系还没盖满：channel 无测试（`ChannelCase` 备好待用），session、user、
bid 三个 controller 也没有用例。但骨架摆好了：给 `BidController` 补测试时，
`init_test_session` 把 `user_id` 塞进去就能模拟登录态，模式照抄
`ItemControllerTest`。

## 演进回顾：一章一个脚印

| 章 | 代码目录 | 新增能力 | 关键文件/概念 |
| --- | --- | --- | --- |
| 第 1 章 | `ch03/blog` | 生成器骨架 | `mix phx.new`、Endpoint/Router/模板初识 |
| 第 2 章 | `ch04` | 无框架领域层 | `Auction`、`Item`、`FakeRepo` 内存仓库 |
| 第 3 章 | `ch05` | umbrella 化 | `apps/` 拆分、`application.ex`、OTP 应用 |
| 第 4 章 | `ch06` | Web 层骨架 | `auction_web`、plug 链、`*_html` + `embed_templates` |
| 第 5 章 | `ch07` | 真数据库 | `Ecto.Repo`、items 迁移、`@repo` 换实现 |
| 第 6 章 | `ch08` | 可校验写入 | changeset、`insert_item` |
| 第 7 章 | `ch09` | Items 全套 CRUD | heex 表单、redirect、flash |
| 第 8 章 | `ch10` | 用户与认证 | Pbkdf2、session、`Authenticator` plug |
| 第 9 章 | `ch11` | 出价 | `belongs_to` 关联、嵌套路由 `/items/:id/bids` |
| 第 10 章 | `ch12` | 实时推送 | `UserSocket`、`ItemChannel`、`app.js` |
| 第 11 章 | `ch13` | JSON API | `/api` scope、`Api.ItemController`、`*_json` |
| 第 12 章 | `ch14` | 测试与收尾 | `ConnCase`/`ChannelCase`、Sandbox、全貌 |

回看这个表，每章都只是在旧结构上加一层：FakeRepo 换成真库没动过门面，Web 层
加进来没动过领域层，Channel 和 API 复用的都是已有的 `Auction` 函数。没有一步
推翻过已有决策，分层的好处到这里才真正兑现。

## 还能往哪走

- **LiveView。** `{:phoenix_live_view, "~> 1.0"}` 早就在 `auction_web` 的依赖
  列表里（heex 组件、`~H` sigil 都来自这个包）。item 详情页是最自然的试验田：
  出价列表和表单交给 LiveView 服务端渲染，`app.js` 里手写的 socket/channel
  代码整段退场，broadcast 可以让 `handle_info` 接管。
- **Presence。** `Phoenix.Presence` 挂在 `item:*` topic 上就有"N 人正在围观
  本场拍卖"，配合 `ends_at` 做倒计时竞价更有现场感。
- **带状态的 API。** `/api` 只有只读端点。下一步给 API client 发
  `Phoenix.Token`（`UserSocket.connect/3` 里的 `token` 参数就是留好的口子），
  加 `POST /api/items/:id/bids`，再配一条 `json_response` 测试。
- **定时任务。** `ends_at` 只是展示字段。在 `auction` 里加个 GenServer 定时器
  或引 Oban，到点结算赢家、发通知：这类进程挂在 `Auction.Supervisor` 下，
  和 `Auction.Repo` 做邻居，Web 层依旧不用知道。
- **发布。** `config/runtime.exs` 已把 `DATABASE_URL`、`SECRET_KEY_BASE` 等
  运行时配置收好，`mix release` 可以把整棵 umbrella 打成一个 release。

## 动手验证

在 umbrella 根目录跑完整测试套件，预期两套全绿：

```bash
cd ch14/auction_umbrella
mix setup
mix test
```

再看一眼完整路由表，三条"产品线"在同一张表里：

```bash
mix phx.routes
```

输出里应该能认全本章讲过的每一站：

```text
  GET     /                     AuctionWeb.ItemController :index
  GET     /login                AuctionWeb.SessionController :new
  POST    /login                AuctionWeb.SessionController :create
  DELETE  /logout               AuctionWeb.SessionController :delete
  GET     /items                AuctionWeb.ItemController :index
  GET     /items/:id/edit       AuctionWeb.ItemController :edit
  GET     /items/new            AuctionWeb.ItemController :new
  GET     /items/:id            AuctionWeb.ItemController :show
  POST    /items                AuctionWeb.ItemController :create
  PATCH   /items/:id            AuctionWeb.ItemController :update
  PUT     /items/:id            AuctionWeb.ItemController :update
  POST    /items/:item_id/bids  AuctionWeb.BidController :create
  GET     /users/:id            AuctionWeb.UserController :show
  GET     /users/new            AuctionWeb.UserController :new
  POST    /users                AuctionWeb.UserController :create
  GET     /api/items            AuctionWeb.Api.ItemController :index
  GET     /api/items/:id        AuctionWeb.Api.ItemController :show
```

（Channel 的 `item:*` 不在 `phx.routes` 里，它注册在 `UserSocket` 的
`channel` 宏上。）

最后 `mix phx.server` 起服务，`curl -H "Accept: application/json"
http://localhost:4000/api/items/1` 看 API；再开两个浏览器窗口停在同一个
`/items/:id`，一个窗口登录后出价，另一个的出价列表实时多出一条。那条 `<p>`
就是 `bid.html.heex` 渲染、PubSub 广播、`insertAdjacentHTML` 上屏的全链路成果。

## 小结

- umbrella 根目录靠共享 `_build`/`deps`/`mix.lock` 和根 alias 把两个应用拧成
  一个项目；`config_path` 指回根目录，根 `config.exs` 再通配引回各 app 的配置，
  `runtime.exs` 管全部运行时机密
- 边界即分工：`auction` 的 deps 只有 ecto/pbkdf2，监督树只有 Repo；
  `auction_web` 包揽 HTTP 与 Channel，`{:auction, in_umbrella: true}` 让它单向
  依赖业务层。HTTP 链路每一站（plug 链、pipeline、Authenticator、controller、
  `*_html`、layout）和 Channel 链路每一跳（socket、channel 进程、PubSub、
  broadcast、客户端插 DOM）都能在代码里点名
- 测试按层配模板：`ConnCase` 注入 conn、endpoint 和 `~p` 验证路由，
  `ChannelCase` 注入 channel 工具，`auction` 侧手动 `Sandbox.checkout`；
  `start_owner!` 的 `shared: not tags[:async]` 让非 async 测试里的 endpoint
  进程也能用上同一条事务连接。`ItemControllerTest` 示范了"用 context 当裁判、
  正反路径成对验证"
- 全书到此收尾，结构是开放的：LiveView、Presence、写接口、定时结算、
  `mix release`，都能在现有分层里各就各位
