---
title: 第18章 · 测试体系
description: test_helper 与 Sandbox 打地基，ConnCase/ChannelCase/DataCase 三个 case 模板各有分工，shared 连接所有权让 endpoint 进程共用事务，ItemControllerTest 示范断言风格，最后把整套测试跑一遍并展望全书之后的方向
sidebar:
  order: 18
---

上一章把项目全貌摊开看了一遍：目录树、应用边界、两条链路。还剩下最后一个问题：
怎么证明它工作，并且以后改动时继续证明。这一章讲测试。测试按"离数据库和离
HTTP 的距离"分成三层，每一层有自己的模板。

## 地基：test_helper、Sandbox、test/support

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

## 三个 case 模板：ConnCase、ChannelCase、DataCase

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

## 沙箱的两种用法：手动 checkout 与 start_owner!

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

## 测试怎么断言：context 当裁判，渲染层直测

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

## 完整跑一遍

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

## 动手验证

在 umbrella 根目录跑完整测试套件，预期两套全绿：

```bash
cd ch14/auction_umbrella
mix setup
mix test
```

再看一眼完整路由表，三条"产品线"在同一张表里：

```bash
mix phx.routes AuctionWeb.Router
```

输出里应该能认全上一章讲过的每一站：

```text
  GET     /                         AuctionWeb.ItemController :index
  GET     /login                    AuctionWeb.SessionController :new
  POST    /login                    AuctionWeb.SessionController :create
  DELETE  /logout                   AuctionWeb.SessionController :delete
  GET     /items                    AuctionWeb.ItemController :index
  GET     /items/:id/edit           AuctionWeb.ItemController :edit
  GET     /items/new                AuctionWeb.ItemController :new
  GET     /items/:id                AuctionWeb.ItemController :show
  POST    /items                    AuctionWeb.ItemController :create
  PATCH   /items/:id                AuctionWeb.ItemController :update
  PUT     /items/:id                AuctionWeb.ItemController :update
  POST    /items/:item_id/bids      AuctionWeb.BidController :create
  GET     /users/new                AuctionWeb.UserController :new
  GET     /users/:id                AuctionWeb.UserController :show
  POST    /users                    AuctionWeb.UserController :create
  GET     /api/items                AuctionWeb.Api.ItemController :index
  GET     /api/items/:id            AuctionWeb.Api.ItemController :show
  POST    /api/items                AuctionWeb.Api.ItemController :create
  POST    /api/items/:item_id/bids  AuctionWeb.Api.BidController :create
```

（Channel 的 `item:*` 不在 `phx.routes` 里，它注册在 `UserSocket` 的
`channel` 宏上。）

最后 `mix phx.server` 起服务，`curl -H "Accept: application/json"
http://localhost:4000/api/items/1` 看 API；再开两个浏览器窗口停在同一个
`/items/:id`，一个窗口登录后出价，另一个的出价列表实时多出一条。那条 `<p>`
就是 `bid.html.heex` 渲染、PubSub 广播、`insertAdjacentHTML` 上屏的全链路成果。

## 还能往哪走

上一章末尾的回顾表停在了这一章。书到这里收尾，但这个应用还能顺着已有的分层
继续延伸：

- **LiveView：第 15 章已经做过。** `{:phoenix_live_view, "~> 1.0"}` 早就在
  `auction_web` 的依赖列表里，item 详情页在那章改成了服务端渲染的 LiveView，
  `app.js` 里手写的 socket/channel 代码整段退场，broadcast 由 `handle_info`
  接管。
- **API 写接口：第 14 章已经做过。** 那一章给 `:api` pipeline 接上了
  session，`Api.Authenticate` 守门，`POST /api/items` 和
  `POST /api/items/:id/bids` 都通了。
- **Presence。** 可以继续往上延伸：`Phoenix.Presence` 挂在 `item:*` topic
  上就有"N 人正在围观本场拍卖"，配合 `ends_at` 做倒计时竞价更有现场感。
- **定时任务。** `ends_at` 还可以不只是展示字段：在 `auction` 里加个
  GenServer 定时器或引 Oban，到点结算赢家、发通知。这类进程挂在
  `Auction.Supervisor` 下，和 `Auction.Repo` 做邻居，Web 层依旧不用知道。
- **发布。** `config/runtime.exs` 已把 `DATABASE_URL`、`SECRET_KEY_BASE` 等
  运行时配置收好，`mix release` 可以把整棵 umbrella 打成一个 release，直接
  部署。

## 小结

- `test_helper.exs` 两行打地基：`ExUnit.start()` 加
  `Sandbox.mode(Auction.Repo, :manual)`；`config/test.exs` 里把连接池换成
  `Ecto.Adapters.SQL.Sandbox`，`elixirc_paths` 让 `test/support/` 只在 test
  环境编译
- 测试按层配模板：`ConnCase` 注入 conn、endpoint 和 `~p` 验证路由，
  `ChannelCase` 注入 channel 工具，`auction` 侧手动 `Sandbox.checkout`；
  `start_owner!` 的 `shared: not tags[:async]` 让非 async 测试里的 endpoint
  进程也能用上同一条事务连接
- `ItemControllerTest` 示范了"用 context 当裁判、正反路径成对验证"，
  `ErrorHTMLTest` 示范了跳过整条链直测纯函数渲染模块，`doctest` 让文档和
  可执行断言合成一份
- 全书到此收尾：应用能跑、能测，继续延伸的方向——Presence、定时结算、
  `mix release`——都能在现有分层里各就各位
