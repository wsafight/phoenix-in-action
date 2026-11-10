---
title: 第4章 · 请求管道
description: 在 umbrella 里新增 auction_web 应用，沿 Bandit、Endpoint、Router、Controller 的请求管道，看一个 HTTP 请求怎么变成一次领域调用
sidebar:
  order: 4
---

上一章的 `auction` 应用已经能在 iex 里返回商品列表，但用户拿不到：中间还缺一层把 HTTP 请求翻译成业务调用的东西。本章在 umbrella 里加入第二个应用 `auction_web`，它包下所有和 HTTP 有关的事：监听端口、解析请求、按 URL 分发、渲染 HTML。跑通之后，拍卖网站有了第一张页面，首页列出 `Auction.list_items()` 返回的全部商品。

要拆清楚的就是一条请求路径：Bandit → Endpoint → Router → Controller。到 controller 的 action 调 `render/3` 为止，这一章走完请求方向的全部环节；`render` 内部怎么把 assigns 变成 HTML，留给下一章。整条路径上没有一个"框架在背后做的事"，每一步都对应仓库里的一个文件、一段代码，这一章就是把它们逐个打开。

## umbrella 里的第二个应用

`auction_web` 是一个完整的 Phoenix OTP 应用，它通过 `in_umbrella` 依赖拿到 `auction` 的全部公开 API：

```elixir
  defp deps do
    [
      {:phoenix, "~> 1.7.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.5"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:auction, in_umbrella: true}
    ]
  end
```

`ch06/auction_umbrella/apps/auction_web/mix.exs`

`in_umbrella` 告诉 Mix：这个依赖不用去 Hex 下载，直接编译 `apps/auction`。所以 controller 里可以裸调 `Auction.list_items()`，两个模块看起来就像在同一个项目里。这不是错觉：umbrella 下所有应用跑在同一个 BEAM 虚拟机里，"调用另一个应用"就是一次普通的函数调用，中间没有进程边界、没有网络。编译期的依赖关系同时是 OTP 启动期的依赖关系：`auction_web` 声明依赖 `auction`，它的应用启动之前 OTP 会先把 `auction` 拉起来。

同一个文件里的 `application/0` 回调声明了 `mod: {AuctionWeb.Application, []}`，这是 OTP 应用的启动入口：应用被加载时 OTP 调用 `AuctionWeb.Application.start/2`，监督树从这里长出来。

这个 `mix.exs` 里还有四行容易滑过去的配置，它们才是 umbrella 共享机制的实现：

```elixir
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
```

`ch06/auction_umbrella/apps/auction_web/mix.exs`

子应用自己的 `_build`、`deps`、`config`、`mix.lock` 全部上移到 umbrella 根目录。`auction` 和 `auction_web` 因此共享同一份编译产物、同一份依赖、同一个 config 文件。`config/config.exs` 开头那句注释说的就是这件事："all applications in your umbrella share the same configuration and dependencies"。

:::tip
HTTP 相关的依赖（phoenix、bandit、phoenix_live_view）全部归 `auction_web`；`auction` 的 deps 里只有 `ecto_sql` 和 `postgrex`，它对 HTTP 一无所知。这就是"业务与 Web 分离"最直接的体现：将来想换掉 Phoenix，只动 `auction_web`。
:::

目录结构也值得扫一眼，`auction_web` 把 Web 层的每种角色各占一个位置：

```
apps/auction_web/
  lib/auction_web.ex               use 入口：controller/html/router 的公共 quote
  lib/auction_web/application.ex   启动 PubSub 和 Endpoint
  lib/auction_web/endpoint.ex      HTTP 生命周期
  lib/auction_web/router.ex        pipeline + 路由表
  lib/auction_web/controllers/     controller、*_html、error_*、page_html/
  lib/auction_web/components/      layouts、core_components
  lib/auction_web/channels/        user_socket（占位）
  priv/static/                     静态文件
  test/support/conn_case.ex        conn 测试的公共 setup
```

两个应用是兄弟关系，不是包含关系。`auction` 不依赖 `auction_web`，`auction_web` 依赖 `auction`。这条依赖决定了启动顺序：OTP 会先启动被依赖的应用，所以跑 `mix phx.server` 时 `auction` 的 supervision tree 先起来，`auction_web` 的后起来。

两棵树各自独立。`auction` 的目前还是空的，因为 `FakeRepo` 只是模块属性，不需要进程：

```elixir
    children = [
      # Starts a worker by calling: Auction.Worker.start_link(arg)
      # {Auction.Worker, arg},
    ]
```

`ch06/auction_umbrella/apps/auction/lib/auction/application.ex`

`auction_web` 启动三个子进程：

```elixir
    children = [
      {DNSCluster, query: Application.get_env(:auction_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AuctionWeb.PubSub},
      AuctionWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: AuctionWeb.Supervisor]
    Supervisor.start_link(children, opts)
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web/application.ex`

`Phoenix.PubSub` 是本机的发布订阅进程，第 12 章 Channel 向浏览器广播新出价用的就是它。它和 Endpoint 由 `config.exs` 里的 `pubsub_server: AuctionWeb.PubSub` 关联起来，`AuctionWeb.Endpoint.broadcast/3` 广播时找的就是这个进程。`AuctionWeb.Endpoint` 才是 HTTP 服务器本身。`DNSCluster` 管生产环境的分布式 Erlang 节点发现，本章用不到，可以忽略。策略用 `one_for_one`：PubSub 挂了只重启 PubSub，不会把 Endpoint 一起拖下水。

`config_change/3` 也值得看一眼：release 热更新配置时 OTP 会回调它，`Application` 再把变化转发给 Endpoint，让它重新读取 `url`、`http` 这类配置，不用重启整个应用。

`mix phx.server` 在 umbrella 根目录执行，但它起的不只是 `auction_web`：整个 umbrella 下的应用按依赖顺序全部启动。这个任务本身做的也很少：它把 `:phoenix` 应用的 `serve_endpoints` 环境变量置为 true，然后转调 `mix run --no-halt`。Endpoint 在监督树里启动时查到这个标志才会拉起 Bandit 监听，所以 `iex -S mix` 里应用全起来了却没有 HTTP 服务，两边都想要就 `iex -S mix phx.server`。

## Endpoint：一条 plug 链就是整个 HTTP 生命周期

Endpoint 是 Phoenix 对 Web 服务器的抽象，它本身也是一个 plug：请求进来后按声明顺序流过链上每个 plug，最后一个 `plug AuctionWeb.Router` 把请求交给路由器。

`use Phoenix.Endpoint, otp_app: :auction_web` 这个参数告诉 Endpoint 去哪个应用配置里找自己。`config :auction_web, AuctionWeb.Endpoint, ...` 写的每一项，`Phoenix.Endpoint` 都通过 `otp_app` 找到，暴露成 `AuctionWeb.Endpoint.config(:url)` 这样的访问口。作为监督树的孩子，Endpoint 启动时干两件事：把这套配置读进来，然后拉起 Bandit 的监听进程。之后每个进来的连接都会跑一遍这个模块的 plug 链。所以 Endpoint 同时是"配置容器"和"每请求执行的函数"，两层身份都在这一个 `use` 里展开。

宏展开的背后是 `Plug.Builder`：那些 `plug X, opts` 调用不进运行时代码，是编译期的数据，`__before_compile__` 时整个列表被拼成一个 `call/2`，嵌套调用 `Plug.Static.call(...)`、`Plug.Parsers.call(...)`……链的顺序就是声明的顺序，运行期就是一串函数调用。

先看配置。`config.exs` 告诉 Endpoint 用哪个 HTTP 服务器实现、对外 URL、出错时找哪个模块渲染错误页：

```elixir
config :auction_web, AuctionWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  secret_key_base: "BOXCxqrqQfa7YvmeIHA2Ojl430zkjfOogywxCF9k8HaknMngwrIMGUItbB21r0YP",
  render_errors: [
    formats: [html: AuctionWeb.ErrorHTML, json: AuctionWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AuctionWeb.PubSub,
  live_view: [signing_salt: "xQHRCmB+"]
```

`ch06/auction_umbrella/config/config.exs`

`adapter: Bandit.PhoenixAdapter` 是关键的一行：HTTP 服务器用 Bandit，一个纯 Elixir 实现，Phoenix 1.7 起取代 Cowboy 成为默认。Endpoint 只定义接口，真正把 TCP 包解析成 `%Plug.Conn{}` 的是 Bandit。换服务器的成本是零：把这一行改成 `adapter: Phoenix.Endpoint.Cowboy2Adapter`、加个 `plug_cowboy` 依赖，应用代码一行不用动。Bandit 胜在纯 Elixir（少一层 Erlang/Cowboy 依赖，进程模型和调试栈都更统一），Cowboy 胜在久经考验，对绝大多数应用二者没有区别。

`dev.exs` 再补上 `http: [ip: {127, 0, 0, 1}, port: 4000]`、`code_reloader: true` 这类开发专用项，还有 `live_reload.patterns`：文件一改，浏览器自动刷新，连 `priv/static/assets` 下的 css、js 变化也监视。`check_origin: false` 是开发期的方便门，WebSocket 和表单提交不校验来源，本机调试随便连；生产环境务必恢复校验。生产环境的 `secret_key_base` 挪到了 `config/runtime.exs`，启动时才从环境变量读，所以密钥不会进版本库。

`test.exs` 里有一行值得记住：`config :phoenix, :plug_init_mode, :runtime`。plug 的 `init/1` 默认在编译期跑（产出编译进 BEAM，运行时更快），开发测试改成运行期，换来更快的编译速度。这条配置解释了为什么 Endpoint 文件里的 `plug` 宏两边都吃得开。

下面是 Endpoint 的全文，请求进入应用后做的每一件事都在这里。文件不长，但它同时是两种东西：给 `Plug.Builder` 的"组装说明书"，和给 OTP 的"启动蓝图"。`@session_options` 是模块属性，`socket`/`plug` 是宏，全在编译期定形；`start_link` 里拉起的监听进程，才是它在运行时的形态。

`@session_options` 单独提出来当模块属性，是因为 `plug` 宏的参数是编译期求值的：`store: :cookie`、`key`、`signing_salt` 这些值在 `Plug.Session.init/1` 被调用时就烤进了 BEAM，模块里只声明一次，链上引用的是同一份。

```elixir
defmodule AuctionWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :auction_web

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_auction_web_key",
    signing_salt: "jmVVQ88F",
    same_site: "Lax"
  ]

  socket "/socket", AuctionWeb.UserSocket,
    websocket: true,
    longpoll: false

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :auction_web,
    gzip: false,
    only: AuctionWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug AuctionWeb.Router
end
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web/endpoint.ex`

在过每个 plug 之前，先想清楚数据怎么流。Bandit 收到请求后构造一个 `%Plug.Conn{}` 结构体，里面装着 method、path、headers、body 的引用，以及一块给框架内部用的 `private` map。之后每个 plug 拿到这个 conn，改点什么（写 `params`、写 `private`、写 response header），返回一个新 conn，交给下一个 plug。conn 不可变，所谓"流转"就是不断产出一个字段略不同的新结构体。中间任何一个 plug 都可以直接 `send_resp` 并 `halt`，链条就地终止，后面的 plug 连运行的机会都没有。

conn 上值得认识几个字段：`req_headers`、`params`、`body_params` 装输入；`assigns` 是给你存业务数据的口袋，controller 写给模板看的东西都在这；`private` 归框架内部用（`phoenix_format`、`plug_session` 都藏在里面）；`resp_body`、`status`、`resp_headers` 装输出；`state` 记录请求走到哪一步，从 `:unset` 一路变到 `:sent`。业务数据走 `assigns`，框架内部信息走 `private`，分工很清楚。

整条链由 `Plug.Builder` 编译出来：`plug` 宏只是往模块属性里追加一条记录，模块编译完成时这些记录被合成一个 `call/2`，请求方向就是一串嵌套的函数调用。每个 plug 的 `init/1` 先跑一次，`call/2` 拿到的是 init 的产物；`init` 默认在编译期跑，所以 `plug` 选项里不能有运行期才知道的值，dev/test 环境那条 `plug_init_mode: :runtime` 就是把它挪到运行时换编译速度。Endpoint 文件读起来像配置，跑起来是一段编译好的代码。

按声明顺序过一遍：

- **`socket "/socket", AuctionWeb.UserSocket`** 是 Channel 的入口，第 12 章浏览器的 WebSocket 在这里完成升级。socket 的匹配发生在 plug 链之外：path 命中前缀的连接直接交给对应 handler 做协议升级，不再进入下面的 plug 链。这个区别很重要，`socket` 和 `plug` 看着都是链上的条目，其实分管两条路：`plug` 处理一次请求的生命周期，`socket` 把一个 HTTP 连接切换成 WebSocket 这种长连接协议，连接存活期间没有"请求"这回事。现在 `UserSocket` 只是占位，`connect/3` 无条件放行、`id/1` 返回 nil 表示匿名 socket，普通 HTTP 请求不会走这个分支。
- **`plug Plug.Static`** 位置最靠前：只要路径命中 `static_paths()`（`assets`、`fonts`、`images`、`favicon.ico`、`robots.txt`），直接从 `priv/static` 读文件、`send_resp`、`halt`，后面的 plug 一个都不执行。`at: "/"` 表示这些路径挂在站点根下，`from: :auction_web` 表示从 `:auction_web` 应用的 `priv/static` 目录取文件。所以给 CSS 加长缓存很安全，这类请求根本到不了路由器。
- **`if code_reloading?` 块**只在 `dev.exs` 里 `code_reloader: true` 时编译进去。注意它是编译期的 `if`，不是运行期判断：`code_reloading?` 在编译时读取应用配置，条件不成立这三个条目压根不存在于 BEAM 里，生产环境零开销。块里的 `socket "/phoenix/live_reload/socket"` 和上面 `socket "/socket"` 是同一类声明，`Phoenix.LiveReloader.Socket` 在浏览器和服务器之间撑一条 WebSocket，模板或静态文件一改就推消息过去刷新页面。
- **`Plug.RequestId` / `Plug.Telemetry`** 生成 request id（就是日志里 `[info] Sent 200 in 3ms` 前面那串），并向 telemetry 上报 endpoint 级耗时。`event_prefix: [:phoenix, :endpoint]` 决定事件名：`[:phoenix, :endpoint, :start]` 和 `[:phoenix, :endpoint, :stop]`，Phoenix 自己的 logger 挂在这两个事件上才有那行日志，以后想接指标系统也是订阅它们。它们放最前面，后面的所有 plug 都能用同一个 id 记日志。
- **`Plug.Parsers`** 按 `Content-Type` 解析请求体：表单（urlencoded）、文件上传（multipart）、JSON 三种。解析结果进 `conn.body_params`，再合并进 `conn.params`；`pass: ["*/*"]` 表示不认识的 Content-Type 就放行，不解析也不报错。`json_decoder: Phoenix.json_library()` 读的是 `config.exs` 里 `config :phoenix, :json_library, Jason`，deps 里的 `{:jason, "~> 1.2"}` 就在这派上用场；换成别的 JSON 库只改配置，Endpoint 不用动。
- **`Plug.MethodOverride`** 处理一个现实限制：HTML 表单只会发 GET 和 POST。这个 plug 在 body 解析完之后检查 POST 请求里的 `_method` 参数，把 `conn.method` 改写成 `PUT`/`PATCH`/`DELETE`。第 8 章的删除按钮靠的就是它。
- **`Plug.Head`** 把 `HEAD` 请求当 `GET` 处理，发送响应时丢掉 body。`HEAD` 是浏览器和缓存用来探资源的，方法改成 `GET` 就能复用同一条路由，只是响应不发送内容体。
- **`Plug.Session`** 管会话。`@session_options` 里 `store: :cookie` 表示 session 内容直接放在浏览器 cookie 里，用 `secret_key_base` 加 `signing_salt` 签名：用户读得到，但改一个字节签名就失效。它把解码好的 session 塞进 `conn.private.plug_session`，第 10 章的登录态就存在这里。`same_site: "Lax"` 顺带挡掉一部分跨站请求带 cookie 的场景，和后面的 CSRF 校验是两层防线。
- **`plug AuctionWeb.Router`** 前面的都是前置处理，到这里才按 URL 分发。

这个顺序不是随手写的，有几条硬依赖。`Plug.MethodOverride` 必须排在 `Plug.Parsers` 之后，因为 `_method` 参数要从解析过的 `conn.params` 里取；颠倒过来它永远找不到参数。`Plug.Session` 必须排在 `AuctionWeb.Router` 之前，因为 router 里的 `fetch_session` plug 读的正是 `Plug.Session` 写进 `conn.private` 的那份数据。`Plug.Static` 放最前则纯是效率：静态文件不值得过一遍 session、parser 和路由器。

这条链上还少了几个"标准件"：`mix phx.new` 在带 Ecto 的项目里会多生成一个 `plug Phoenix.Ecto.CheckRepoStatus`，数据库迁移没跑就在页面上报警；本章的 `auction_web` 还没连数据库，生成器没放它。等后面 Ecto 进场，这条 plug 会回到链上。

还有一条对称的法则：请求按声明顺序流过，响应按反序收尾。很多 plug（`Plug.Session` 写 `Set-Cookie`，`protect_from_forgery` 写 CSRF cookie）用 `register_before_send` 注册了一个回调，等到链条末端有人调 `send_resp`，这些回调按后进先出的顺序执行，最后才轮到 Bandit 把 HTTP 报文写回 socket。所以"plug 链"其实是请求方向的一次遍历加响应方向的一次回调栈，数据载体始终是同一个 conn。

`Plug.Session` 放在响应方向收尾，正是它工作方式的一部分：cookie 不能在你读 session 的时候就写，得等所有处理都做完、session 最终定型了再写回响应头。如果 `put_session` 发生在 controller 里，等 action 返回 `send_resp` 时 `Plug.Session` 的 `before_send` 才把更新后的 session 编码签好塞进 `Set-Cookie`。这条"读在请求头、写在响应尾"的对称性，每个有副作用的 plug 都遵守。

## Router：pipeline 先加工 conn，scope 再按 URL 分发

```elixir
defmodule AuctionWeb.Router do
  use AuctionWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AuctionWeb do
    pipe_through :browser

    get "/", PageController, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", AuctionWeb do
  #   pipe_through :api
  # end
end
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web/router.ex`

Router 只有三个概念：pipeline、scope、路由行，组合起来覆盖了所有 Web 应用的共性需求。

pipeline 是一组 plug 的别名，编译时展开成一条私有的 plug 链。`:browser` 管线里五个 plug 依次执行：

- `accepts ["html"]` 检查 `Accept` 头，客户端不接受 HTML 就返回 406。协商结果写进 `conn.private.phoenix_format`，controller 的 `render/3` 靠它决定渲染哪个格式。
- `fetch_session` 启用 session 的读写接口：`Plug.Session` 只负责把 cookie 解出来放进 `conn.private.plug_session`，`fetch_session` 标记它可用之后，`get_session`/`put_session` 才能工作，第 10 章写 `put_session(:user_id, ...)` 依赖这一步。没有 Endpoint 里 `Plug.Session` 在先，它会直接报错，这就是上面说的顺序依赖的另一半。
- `fetch_flash` 把 flash 消息（"保存成功"这类一次性提示）从 session 里取出来，放进 `conn.private.phoenix_flash`，渲染时复制进 assigns。
- `protect_from_forgery` 校验 CSRF token，挡住跨站伪造表单。它还会生成一对 token 存进进程字典，layout 里的 `get_csrf_token()` 取的就是这份 masked token。
- `put_secure_browser_headers` 给响应加 `x-frame-options` 等安全头。

`:api` 管线只有 `accepts ["json"]`：API 客户端既没有 cookie 也没有 flash，那几个 plug 全部省掉。管线的设计意图就是按请求形态分组，浏览器一条线，JSON 客户端一条线。它不是"API 专属"的硬编码，`pipeline` 就是个宏起的别名，想给后台管理页单开一条加了认证的 `:admin` 管线，声明了 `pipe_through` 就行。

scope 把路径前缀、模块前缀和 pipeline 绑在一起。`scope "/", AuctionWeb` 的意思是：这个作用域里的路由，`PageController` 实际指 `AuctionWeb.PageController`，`pipe_through :browser` 让里面每条路由都先过 `:browser` 管线。把 scope 路径改成 `"/api"`，所有路由路径就都带上 `/api` 前缀，第 13 章的 JSON API 用的就是这个机制。scope 之间互不影响，文件末尾注释掉的 `scope "/api"` 就是在提示：API 路由挂到 `"/api"` 前缀、过 `:api` 管线，浏览器路由原样不动。

路由宏不止 `get` 一个：`post`、`put`、`patch`、`delete` 各自对应一个 HTTP 方法，还有一个 `resources "/items", ItemController` 会一次展开成 index、show、new、create、edit、update、delete 七条 RESTful 路由，商品的增删改查页面靠的就是它。

路由本身只有一行模式匹配。`get "/", PageController, :index` 展开后大致是：收到 `GET /` 时调用 `AuctionWeb.PageController.index(conn, params)`。

在底层，router 编译后也是一组函数子句：每条路由生成一个 `match` 子句（匹配 method 和 path 段），匹配后把 path 参数绑进 `params`，然后调用对应 controller。所有路由的清单存在模块的 `__routes__/0` 函数里，`mix phx.routes` 和 `~p` sigil 编译期校验读的都是它。路由表不是运行时的数据结构，而是编译期就冻结的代码，这是 Phoenix 路由快的原因之一。

`use AuctionWeb, :router` 会展开成：

```elixir
  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
    end
  end
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web.ex`

`helpers: false` 是 Phoenix 1.7 的变化：不再生成 `Routes.page_path` 这类 path helper 函数，URL 统一用 `~p` sigil 写。`~p` 的妙处在于它在编译期干活：编译器读 `AuctionWeb.Router.__routes__/0` 查这个路径对应的 verb 和 pattern，存在就展开成一个普通字符串，不存在就发编译警告。静态资源路径走另一份清单，`verified_routes` 里 `statics: AuctionWeb.static_paths()` 声明的那一组；写 `~p"/assets/app.css"` 编译期就核对过，`~p"/asset/app.css"` 少个 s 都过不了。`mix phx.routes` 打出来的路由表和 `~p` 检查用的是同一份数据，所以两边永远一致。

`~p` 里写插值没问题，`~p"/items/#{item.id}"` 是把 pattern 的 `/items/:id` 段拿去对账，不是把拼好的整串送去匹配。路由参数的类型 Phoenix 不管，它是字符串替换，校验的是"这条路径形状在路由表里存在"。

## Controller：action 就是一个 conn 进、conn 出的函数

浏览器请求过了 pipeline，就到达分发的终点：

```elixir
defmodule AuctionWeb.PageController do
  use AuctionWeb, :controller

  def index(conn, _params) do
    items = Auction.list_items()
    render(conn, "index.html", items: items)
  end
end
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web/controllers/page_controller.ex`

`index/2` 是 Phoenix controller action 的标准形状：输入 `%Plug.Conn{}` 和 `params`，输出还是一个 `%Plug.Conn{}`，只不过里面已经写好了 status、header 和 body。

body 里就两行，但责任划分很清楚：`Auction.list_items()` 是领域调用，controller 不知道底下是 `FakeRepo` 还是数据库；`render/3` 负责把数据变成响应。action 的职责就是翻译 HTTP 和领域之间的调用约定，业务逻辑留在 `auction` 那边。

第二个参数 `_params` 是查询字符串、path 绑定和请求体参数三者的合并。这里首页连路径参数都没有，下划线前缀标成"不用"；等出现 `/items/:id` 这样的路由，它就是 `params["id"]` 的来源。注意它的 key 是字符串不是原子，因为参数来自外部输入，给每个请求都造原子会把 atom 表撑爆。

controller 本身也是 plug。`use Phoenix.Controller` 给模块生成了 `init/1` 和 `call/2`，`call/2` 的第二个参数就是路由里写的 action 原子 `:index`。router 匹配到 `GET /` 之后调用的其实是 `PageController.call(conn, :index)`，`call` 再分发到 `index/2`。所以 controller 和 plug 链的接口完全统一，plug、pipeline、controller 是同一种东西：吃 conn、吐 conn 的函数或模块。

`render/3` 内部做四件事：先从 `conn.private.phoenix_format` 确定要渲染 HTML（这个值就是 pipeline 里 `accepts` 协商出来的），再把 `items:` 这类 assigns 合并进 `conn.assigns`，然后按命名约定找到渲染模块、调同名模板函数拿到渲染结果，最后套上 layout、`send_resp`。`send_resp` 把结果写进 conn 的响应体，`conn.state` 从此变成 `:sent`，前面注册的 `before_send` 回调按反序跑一遍。渲染模块怎么挑、layout 怎么套是这一段的约定细节，下一章拆开看。

`send_resp` 是个标记动作：它先把 `resp_body`、`status` 写进 conn，回调栈跑完后 conn 回到 router 的 `call/2`、回到 Endpoint，最后回到 Bandit，由 HTTP 服务器把这一串值翻译成 wire 上的报文。action 本身不碰 socket，它只是"组装了一份响应数据"。

`render` 的第一个参数除了 `"index.html"` 这种带格式的完整模板名，也可以只写 atom `:index`，它会拿 conn 的 `phoenix_format` 补全成 `"index.html"`。写全名的好处是模板文件名和调用点直接对得上，一眼能搜到。

`use AuctionWeb, :controller` 展开后是 `use Phoenix.Controller`、`use Gettext`、`import Plug.Conn` 和 `verified_routes()`（定义见 `ch06/auction_umbrella/apps/auction_web/lib/auction_web.ex` 的 `controller/0` quote）。`use Phoenix.Controller` 那行还带着 `formats` 和 `layouts` 两个声明：controller 能响应哪些格式、HTML 套哪个 layout，都在那里指定，下一章用得到。同一个 quote 末尾的 `unquote(verified_routes())` 注入 `~p` sigil，controller 和模板里都能写 `~p"/items/#{item.id}"`，路径和路由表在编译期绑定。中间夹的 `use Gettext, backend: AuctionWeb.Gettext` 提供 `gettext`/`dgettext` 翻译宏，现在只有错误消息走它，多语言是后面的事。

`import Plug.Conn` 顺手把 `send_resp`、`put_resp_content_type`、`put_session` 这些函数带进 controller 作用域，所以 action 里可以直接写 `put_session(conn, :user_id, id)` 而不需要 `Plug.Conn.put_session(...)`。

## 动手验证

在 umbrella 根目录启动：

```sh
cd ch06/auction_umbrella
mix deps.get
mix phx.server
```

控制台出现 `[info] Running AuctionWeb.Endpoint with Bandit ... at 127.0.0.1:4000`，说明 Endpoint 起来了。

先跑 `mix phx.routes` 看路由表。这个任务要在 `apps/auction_web` 目录里跑，umbrella 根目录的 Mix 项目没有 router 可列：

```sh
cd apps/auction_web && mix phx.routes && cd ../..
```

输出里能找到这一行（它读的就是 router 编译出来的 `__routes__/0`）：

```
  GET  /    AuctionWeb.PageController :index
```

然后请求首页，重点看响应头：

```sh
curl -i http://localhost:4000/
```

响应头里能看到这一章经过的痕迹：`x-request-id` 是 `Plug.RequestId` 生成的，`x-frame-options: SAMEORIGIN` 是 `put_secure_browser_headers` 加的。响应体的 HTML 是 controller 里那个 `render/3` 的产物，怎么渲染出来是下一章的事，这里只确认一件事：请求从 Bandit 一路走到 action、又带着响应回来了。

## 小结

一个 HTTP 请求在 `auction_web` 里的请求方向路径：

```
TCP → Bandit → Endpoint（Plug.Static / Session / Parsers ...）
    → Router（pipeline :browser → scope "/"）
    → PageController.index/2（conn → conn）
    → send_resp → before_send 回调反序执行 → HTML 回给浏览器
```

每个环节都是一个 plug 或一个函数，输入输出都是 `%Plug.Conn{}`，没有隐藏的全局状态，request 只是一段在函数间流转的数据。

回头看整个 `auction_web`，"接 HTTP"被拆成了各司其职的四块：Endpoint 管所有请求都要做的事（解析、会话、静态文件），Router 管按路径和客户端形态分流，Controller 管把一次 HTTP 调用翻译成领域调用再翻译回来，渲染模块管把数据变成响应体。前两块是本章的内容，最后一块是下一章的。这张分工图后面每一章都在用：CRUD 是给 Router 加路由、给 controller 加 action；登录是往 `:browser` 管线塞 session 读写；Channel 是 Endpoint 上面已经占位的那条 `socket "/socket"` 分支。

下一章把 `render/3` 的出口端拆开：`embed_templates` 怎么把 heex 模板编译成模块上的函数、Layouts 怎么给页面套外壳、出错时谁按格式渲染错误页、`priv/static` 的静态资源在没有打包器之后怎么服务。
