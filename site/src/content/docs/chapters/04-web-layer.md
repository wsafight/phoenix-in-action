---
title: 第4章 · auction_web：给应用接上 HTTP
description: 在 umbrella 项目里新增 auction_web 应用，沿 Bandit、Endpoint、Router、Controller、heex 模板的完整链路，把 Auction.list_items() 渲染成首页
sidebar:
  order: 4
---

上一章的 `auction` 应用已经能在 iex 里返回商品列表，但用户拿不到：中间还缺一层把 HTTP 请求翻译成业务调用的东西。本章在 umbrella 里加入第二个应用 `auction_web`，它包下所有和 HTTP 有关的事：监听端口、解析请求、按 URL 分发、渲染 HTML。跑通之后，拍卖网站有了第一张页面，首页列出 `Auction.list_items()` 返回的全部商品。

要拆清楚的就是一条请求路径：Bandit → Endpoint → Router → Controller → 模板。外加 Phoenix 1.7 的模板组织方式（`*_html.ex` + `embed_templates` + `components/layouts`）和去掉打包器之后的静态资源服务。整条路径上没有一个"框架在背后做的事"，每一步都对应仓库里的一个文件、一段代码，这一章就是把它们逐个打开。

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

`Phoenix.PubSub` 是本机的发布订阅进程，第 10 章 Channel 向浏览器广播新出价用的就是它。它和 Endpoint 由 `config.exs` 里的 `pubsub_server: AuctionWeb.PubSub` 关联起来，`AuctionWeb.Endpoint.broadcast/3` 广播时找的就是这个进程。`AuctionWeb.Endpoint` 才是 HTTP 服务器本身。`DNSCluster` 管生产环境的分布式 Erlang 节点发现，本章用不到，可以忽略。策略用 `one_for_one`：PubSub 挂了只重启 PubSub，不会把 Endpoint 一起拖下水。

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

- **`socket "/socket", AuctionWeb.UserSocket`** 是 Channel 的入口，第 10 章浏览器的 WebSocket 在这里完成升级。socket 的匹配发生在 plug 链之外：path 命中前缀的连接直接交给对应 handler 做协议升级，不再进入下面的 plug 链。这个区别很重要，`socket` 和 `plug` 看着都是链上的条目，其实分管两条路：`plug` 处理一次请求的生命周期，`socket` 把一个 HTTP 连接切换成 WebSocket 这种长连接协议，连接存活期间没有"请求"这回事。现在 `UserSocket` 只是占位，`connect/3` 无条件放行、`id/1` 返回 nil 表示匿名 socket，普通 HTTP 请求不会走这个分支。
- **`plug Plug.Static`** 位置最靠前：只要路径命中 `static_paths()`（`assets`、`fonts`、`images`、`favicon.ico`、`robots.txt`），直接从 `priv/static` 读文件、`send_resp`、`halt`，后面的 plug 一个都不执行。`at: "/"` 表示这些路径挂在站点根下，`from: :auction_web` 表示从 `:auction_web` 应用的 `priv/static` 目录取文件。所以给 CSS 加长缓存很安全，这类请求根本到不了路由器。
- **`if code_reloading?` 块**只在 `dev.exs` 里 `code_reloader: true` 时编译进去。注意它是编译期的 `if`，不是运行期判断：`code_reloading?` 在编译时读取应用配置，条件不成立这三个条目压根不存在于 BEAM 里，生产环境零开销。块里的 `socket "/phoenix/live_reload/socket"` 和上面 `socket "/socket"` 是同一类声明，`Phoenix.LiveReloader.Socket` 在浏览器和服务器之间撑一条 WebSocket，模板或静态文件一改就推消息过去刷新页面。
- **`Plug.RequestId` / `Plug.Telemetry`** 生成 request id（就是日志里 `[info] Sent 200 in 3ms` 前面那串），并向 telemetry 上报 endpoint 级耗时。`event_prefix: [:phoenix, :endpoint]` 决定事件名：`[:phoenix, :endpoint, :start]` 和 `[:phoenix, :endpoint, :stop]`，Phoenix 自己的 logger 挂在这两个事件上才有那行日志，以后想接指标系统也是订阅它们。它们放最前面，后面的所有 plug 都能用同一个 id 记日志。
- **`Plug.Parsers`** 按 `Content-Type` 解析请求体：表单（urlencoded）、文件上传（multipart）、JSON 三种。解析结果进 `conn.body_params`，再合并进 `conn.params`；`pass: ["*/*"]` 表示不认识的 Content-Type 就放行，不解析也不报错。`json_decoder: Phoenix.json_library()` 读的是 `config.exs` 里 `config :phoenix, :json_library, Jason`，deps 里的 `{:jason, "~> 1.2"}` 就在这派上用场；换成别的 JSON 库只改配置，Endpoint 不用动。
- **`Plug.MethodOverride`** 处理一个现实限制：HTML 表单只会发 GET 和 POST。这个 plug 在 body 解析完之后检查 POST 请求里的 `_method` 参数，把 `conn.method` 改写成 `PUT`/`PATCH`/`DELETE`。第 7 章的删除按钮靠的就是它。
- **`Plug.Head`** 把 `HEAD` 请求当 `GET` 处理，发送响应时丢掉 body。`HEAD` 是浏览器和缓存用来探资源的，方法改成 `GET` 就能复用同一条路由，只是响应不发送内容体。
- **`Plug.Session`** 管会话。`@session_options` 里 `store: :cookie` 表示 session 内容直接放在浏览器 cookie 里，用 `secret_key_base` 加 `signing_salt` 签名：用户读得到，但改一个字节签名就失效。它把解码好的 session 塞进 `conn.private.plug_session`，第 8 章的登录态就存在这里。`same_site: "Lax"` 顺带挡掉一部分跨站请求带 cookie 的场景，和后面的 CSRF 校验是两层防线。
- **`plug AuctionWeb.Router`** 前面的都是前置处理，到这里才按 URL 分发。

这个顺序不是随手写的，有几条硬依赖。`Plug.MethodOverride` 必须排在 `Plug.Parsers` 之后，因为 `_method` 参数要从解析过的 `conn.params` 里取；颠倒过来它永远找不到参数。`Plug.Session` 必须排在 `AuctionWeb.Router` 之前，因为 router 里的 `fetch_session` plug 读的正是 `Plug.Session` 写进 `conn.private` 的那份数据。`Plug.Static` 放最前则纯是效率：静态文件不值得过一遍 session、parser 和路由器。

这条链上还少了几个"标准件"：`mix phx.new` 在带 Ecto 的项目里会多生成一个 `plug Phoenix.Ecto.CheckRepoStatus`，数据库迁移没跑就在页面上报警；本章的 `auction_web` 还没连数据库，生成器没放它。等下一章 Ecto 进场，这条 plug 会回到链上。

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
- `fetch_session` 启用 session 的读写接口：`Plug.Session` 只负责把 cookie 解出来放进 `conn.private.plug_session`，`fetch_session` 标记它可用之后，`get_session`/`put_session` 才能工作，第 8 章写 `put_session(:user_id, ...)` 依赖这一步。没有 Endpoint 里 `Plug.Session` 在先，它会直接报错，这就是上面说的顺序依赖的另一半。
- `fetch_flash` 把 flash 消息（"保存成功"这类一次性提示）从 session 里取出来，放进 `conn.private.phoenix_flash`，渲染时复制进 assigns。
- `protect_from_forgery` 校验 CSRF token，挡住跨站伪造表单。它还会生成一对 token 存进进程字典，layout 里的 `get_csrf_token()` 取的就是这份 masked token。
- `put_secure_browser_headers` 给响应加 `x-frame-options` 等安全头。

`:api` 管线只有 `accepts ["json"]`：API 客户端既没有 cookie 也没有 flash，那几个 plug 全部省掉。管线的设计意图就是按请求形态分组，浏览器一条线，JSON 客户端一条线。注意它不是"API 专属"的硬编码，`pipeline` 就是个宏起的别名，想给后台管理页单开一条加了认证的 `:admin` 管线，声明了 `pipe_through` 就行。

scope 把路径前缀、模块前缀和 pipeline 绑在一起。`scope "/", AuctionWeb` 的意思是：这个作用域里的路由，`PageController` 实际指 `AuctionWeb.PageController`，`pipe_through :browser` 让里面每条路由都先过 `:browser` 管线。把 scope 路径改成 `"/api"`，所有路由路径就都带上 `/api` 前缀，第 11 章的 JSON API 用的就是这个机制。scope 之间互不影响，文件末尾注释掉的 `scope "/api"` 就是在提示：API 路由挂到 `"/api"` 前缀、过 `:api` 管线，浏览器路由原样不动。

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

有个细节值得注意：controller 本身也是 plug。`use Phoenix.Controller` 给模块生成了 `init/1` 和 `call/2`，`call/2` 的第二个参数就是路由里写的 action 原子 `:index`。router 匹配到 `GET /` 之后调用的其实是 `PageController.call(conn, :index)`，`call` 再分发到 `index/2`。所以 controller 和 plug 链的接口完全统一，plug、pipeline、controller 是同一种东西：吃 conn、吐 conn 的函数或模块。

`render/3` 内部做四件事：

1. 从 `conn.private.phoenix_format` 确定要渲染 HTML（这个值就是 pipeline 里 `accepts` 协商出来的）；
2. 把 `items:` 等 assigns 合并进 `conn.assigns`；
3. 按命名约定找到模板模块：`PageController` 去掉 `Controller` 后缀换 `HTML`，得到 `AuctionWeb.PageHTML`，调它的 `"index.html"` 函数拿到 iodata；
4. 套上 layout（见下一节）后 `send_resp`，把结果写进 conn 的响应体，`conn.state` 从此变成 `:sent`，前面注册的 `before_send` 回调按反序跑一遍。

`send_resp` 是个标记动作：它先把 `resp_body`、`status` 写进 conn，回调栈跑完后 conn 回到 router 的 `call/2`、回到 Endpoint，最后回到 Bandit，由 HTTP 服务器把这一串值翻译成 wire 上的报文。action 本身不碰 socket，它只是"组装了一份响应数据"。

`render` 的第一个参数除了 `"index.html"` 这种带格式的完整模板名，也可以只写 atom `:index`，它会拿 conn 的 `phoenix_format` 补全成 `"index.html"`。写全名的好处是模板文件名和调用点直接对得上，一眼能搜到。

`use AuctionWeb, :controller` 展开后是 `use Phoenix.Controller`、`use Gettext`、`import Plug.Conn` 和 `verified_routes()`（定义见 `ch06/auction_umbrella/apps/auction_web/lib/auction_web.ex` 的 `controller/0` quote），关键在开头两行：

```elixir
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: AuctionWeb.Layouts]
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web.ex`

`formats: [:html, :json]` 声明这个 controller 能响应两种格式；`layouts: [html: AuctionWeb.Layouts]` 指明 HTML 响应要套 `Layouts` 模块里的 layout。同一个 quote 末尾的 `unquote(verified_routes())` 注入 `~p` sigil，controller 和模板里都能写 `~p"/items/#{item.id}"`，路径和路由表在编译期绑定。中间夹的 `use Gettext, backend: AuctionWeb.Gettext` 提供 `gettext`/`dgettext` 翻译宏，现在只有错误消息走它，多语言是后面的事。

`import Plug.Conn` 顺手把 `send_resp`、`put_resp_content_type`、`put_session` 这些函数带进 controller 作用域，所以 action 里可以直接写 `put_session(conn, :user_id, id)` 而不需要 `Plug.Conn.put_session(...)`。

## `*_html.ex` + `embed_templates`：模板就是函数

Phoenix 1.4 时代有一层 `PageView`：模板文件运行时读盘、eex 编译一次、再调 `PageView.render/2`。1.7 砍掉了这层：

```elixir
defmodule AuctionWeb.PageHTML do
  use AuctionWeb, :html

  embed_templates "page_html/*"
end
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web/controllers/page_html.ex`

`embed_templates` 在编译期扫 `page_html/` 目录，把每个 `.heex` 文件编译成模块上的一个函数：`index.html.heex` 变成名叫 `"index.html"` 的模板函数。所谓编译成函数，是 heex 引擎把模板里的文本和插值拼成一段返回 iodata 的函数体，assigns 以 `@` 语法注入成函数参数。模板内容整个内嵌进 BEAM 文件，运行时没有任何文件 IO；配合 code reloader，开发模式改了 heex 文件重新编译这个模块就行。

更准确地说，heex 引擎产出的不是字符串，是一个 `%Phoenix.LiveView.Rendered{}` 结构：模板里的静态文本编译期就拼成 iodata 片段，动态插值只留"到 assigns 里取什么"的指针。调模板函数得到的是这棵树，`send_resp` 把它编码成 iodata 流给 Bandit。所以渲染一个大列表几乎没有字符串拷贝，BEAM 擅长的就是给 socket 喂 iodata 而不是拼完整字符串。

文件名里的 `.html` 不是装饰：模板名按点拆成 `(template, format)` 两段，`"index.html"` 意味着"index 模板的 HTML 变体"。同一个 `index` 可以有 `index.json.heex`，controller 的 `formats` 声明加 `accepts` 协商出的 format 决定渲染哪一份。

`use AuctionWeb, :html` 展开后分两层（定义都在 `auction_web.ex`）。外层是 `use Phoenix.Component`，它给模块带来 function component 的能力：`<.flash />` 这种标签语法、`~H` sigil、`attr`/`slot` 声明。然后是 `import Phoenix.Controller, only: [get_csrf_token: 0, view_module: 1, view_template: 1]`，让模板代码能取 CSRF token。内层 `html_helpers()` 再补四个：`use Gettext`（翻译宏）、`import Phoenix.HTML`（HTML 转义）、`import AuctionWeb.CoreComponents`（flash 等组件进作用域）、`verified_routes()`（`~p`）。所以 `index.html.heex` 里写 `{item.title}` 时 heex 引擎会自动转义输出，XSS 不需要你手动防。

`use Phoenix.Component` 同时是 `embed_templates` 模块和 function component 模块的地基：`PageHTML` 拿它接 `embed_templates` 产出的模板函数，`CoreComponents` 拿它定义 `<.flash>` 这类函数组件，两边共享同一套 `~H`、assigns、attr 机制。"模板模块"和"组件模块"在 Phoenix 1.7 里其实是同种东西，都是一组以 assigns 为输入、返回渲染结果的函数，差别只在写 `.ex` 还是写 `.heex`。

三个 `use AuctionWeb, ...` 背后是同一个小技巧：`AuctionWeb.__using__/1` 拿到 `:controller`、`:html`、`:router` 这样的参数，`apply` 到同名函数上，每个函数返回一段 `quote` 注入调用者。全项目 Web 层的公共依赖集中在这一个文件里，想给所有 controller 加东西，改 `controller/0` 这一个 quote 就行。

`use AuctionWeb, :verified_routes` 走的是同一个机制，只不过它不在上面列出的三组里，而是直接对应 `verified_routes()` 这个 quote，把 `~p` sigil 单独注入。`ConnCase` 用它就是这个原因：测试只需要路由校验，不需要 `Phoenix.Controller` 那一整套。

`index.html.heex` 现在长这样：

```heex
<ul>
  <li :for={item <- @items}>
    <strong>{item.title}</strong>: {item.description}
  </li>
</ul>
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web/controllers/page_html/index.html.heex`

两个 heex 语法点：

- `:for={item <- @items}` 是 heex 的 comprehension，对列表每个元素渲染一次 `<li>`。旧 eex 要写 `<%= for item <- @items do %>` 循环块，heex 把它做成了 HTML 属性。
- `{expr}` 是插值，`{item.title}` 就是旧的 `<%= item.title %>`。属性值和文本节点里都用大括号，不再有 `<%= %>` 标签。

`@items` 来自 controller `render(conn, "index.html", items: items)` 里的 `items:` assigns。heex 编译时 `@items` 展开成对 assigns map 的取值，模板函数签名就是 `(assigns)`。

`PageHTML` 这种模块在 1.7 里的角色叫"渲染模块"，它和 controller 一一对应只是约定，不是机制：`render/3` 按 `PageController` → `PageHTML` 的名字推导，你也可以让两个 controller 共用同一个渲染模块，或者绕开约定直接调 `Phoenix.Template.render_to_string(AuctionWeb.PageHTML, "index", "html", assigns)` 拿字符串，测试里 `error_html_test.exs` 用的就是这个接口。

heex 不只是换了套语法。eex 把模板当字符串拼接，编译器看不懂里面是不是 HTML；heex 在编译期解析标签结构，`<li>` 忘了闭合、组件调错名字、少传 required 的 attr，都在编译时报出来，错误信息直接定位到 heex 文件行号。模板从"渲染时才会碰到的字符串"变成了编译期检查过的代码，这是它和 eex 拉开差距的地方。

## Layout：套在外面的第二层模板

渲染 `index.html` 时 Phoenix 还要回答两个问题：要不要套 layout，套哪个。

`use Phoenix.Controller, layouts: [html: AuctionWeb.Layouts]` 已经给出答案：所有 HTML 响应走 `AuctionWeb.Layouts`。它也是 `embed_templates` 模块：

```elixir
defmodule AuctionWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  """
  use AuctionWeb, :html

  embed_templates "layouts/*"
end
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web/components/layouts.ex`

标准 Phoenix 1.7 项目其实有两层 layout：最外层 `root.html.heex` 是 HTML 骨架（doctype、`<head>`），基本不变；内层 `app.html.heex` 放导航和主体容器。分两层是为了 LiveView 这类"换内层不换骨架"的场景。本项目页面少，只保留了 `app.html.heex`，它本身就是完整 HTML 文档，等于把 root 和 app 合成了一份。`embed_templates "layouts/*"` 把目录下每个 `.heex` 编成同名函数，`app.html.heex` 就是 `Layouts` 上的 `"app"` 模板函数：

```heex
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta http-equiv="X-UA-Compatible" content="IE=edge" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="csrf-token" content={get_csrf_token()} />
    <title>AuctionWeb · Phoenix Framework</title>
    <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
    <script defer phx-track-static type="text/javascript" src={~p"/assets/phoenix.js"}>
    </script>
    <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
    </script>
  </head>
  <body>
    ...
    <main role="main" class="container">
      <.flash_group flash={@flash} />
      {@inner_content}
    </main>
  </body>
</html>
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web/components/layouts/app.html.heex`

渲染顺序是从里往外：Phoenix 先调 `PageHTML` 的 `"index.html"` 函数得到 `<ul>...</ul>`，放进 `assigns.inner_content`，再调 `Layouts` 的 `"app"` 函数渲染外层文档。`{@inner_content}` 就是每张页面内容的注入点。所以模板渲染是纯粹的函数组合，inner 的输出当 outer 的输入，没有"先 layout 再往里塞"的黑魔法。某个 action 不想套外壳，给 `render` 传 `layout: false` 就能跳过这一步，JSON 响应默认就没 layout。

`<meta name="csrf-token" content={get_csrf_token()}>` 和前面埋的伏笔对上了：`protect_from_forgery` 在 pipeline 里生成的 masked token，layout 渲染时用 `get_csrf_token()` 取出来。Channel 接上之后，JS 会从这行 meta 里读 token 去连 WebSocket。

`<.flash_group flash={@flash} />` 是一个 function component，定义在 `CoreComponents` 里：

```elixir
  attr :flash, :map, required: true, doc: "the map of flash messages"

  def flash_group(assigns) do
    ~H"""
    <.flash kind={:info} flash={@flash} />
    <.flash kind={:error} flash={@flash} />
    """
  end
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web/components/core_components.ex`

function component 就是一个接收 assigns、返回 `~H` 模板的函数，加 `attr` 声明参数。`attr :flash, :map, required: true` 会在编译期检查：任何 `<.flash_group />` 忘传 `flash` 都会编译警告，组件接口有了 eex 时代没有的契约。`~H` sigil 让 `.ex` 文件里也能写 heex，内部又调两个 `<.flash kind={...} />`。`<.flash>` 里有个 `:if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}`：要么渲染传入的 inner block，要么从 flash map 里按 kind 取消息，取不到整个 `<div>` 不输出。

`@flash` 是 `fetch_flash` plug 放进 `conn.private.phoenix_flash` 的 flash map，渲染时被复制进 assigns。目前还没有代码写过 flash，两个组件渲染出来是空的；等第 7 章 `put_flash` 出现，这里才会真的显示提示。

## 出错时谁渲染错误页

路由分发的途中出了问题，响应由 `render_errors` 配置接管：`formats: [html: AuctionWeb.ErrorHTML, json: AuctionWeb.ErrorJSON]`。404、500 这类页面不走 `Layouts`，配置里 `layout: false` 写死了这一点，避免错误页自身再触发错误。

`ErrorHTML` 的实现几乎是个壳：

```elixir
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
```

`ch06/auction_umbrella/apps/auction_web/lib/auction_web/controllers/error_html.ex`

`"404.html"` 映射到 `"Not Found"`，`"500.html"` 映射到 `"Internal Server Error"`，状态语从模板名推出来，不用真准备 404 个模板。想给某个状态码做定制页面，再按名字补 `render/2` 子句。

`ErrorJSON` 是同构的另一份，`render/2` 返回 `%{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}`，`accepts` 协商出 `json` 的请求就拿这份。两个模块由 `render_errors` 的 `formats` 列表分发，错误页的格式选择和正常响应走同一条协商。

这套渲染只在生产环境生效：`dev.exs` 里 `debug_errors: true`，开发期抛异常直接给你 Phoenix 的调试页，堆栈、assigns、conn 全列出来，比 "Internal Server Error" 有用得多。

## 静态资源：没有打包器之后 `priv/static` 的组织

本章的静态资源全在 `priv/static/assets/`：

```
priv/static/
  assets/app.css       站点样式
  assets/app.js        站点脚本（目前是占位注释）
  assets/phoenix.js    Phoenix 官方 JS（Socket、Channel 客户端）
  favicon.ico
  images/phoenix.png
  robots.txt
```

三个各自独立的机制在这里配合。一是 `Plug.Static` 的白名单：`only: AuctionWeb.static_paths()` 只放行 `static_paths()` 声明过的前缀（`assets`、`fonts`、`images`、`favicon.ico`、`robots.txt`），路径不在白名单里继续往下走 router。选项里 `gzip: false` 现在关着，部署时跑了 `mix phx.digest` 要改成 `true`，它会优先发 `.css.gz` 这类预压缩文件。二是 `phx-track-static`：layout 里 `<link>`、`<script>` 上的这个属性是给 `mix phx.digest` 用的标记，生产构建的资源文件名会带 hash（`app-abc123.css`），digest 任务扫过所有编译过的模板，把带这个标记的 URL 替换成 digest 版本，同时生成 `cache_manifest.json`；`prod.exs` 里的 `cache_static_manifest` 指向它，运行时 `~p` 和 `Plug.Static` 都按清单改名服务。三是 `~p` 的编译期校验：写错 `/assets/app.css` 的路径当场警告，不用等浏览器报 404。

`phoenix.js` 是从 `deps/phoenix/priv/static/` 复制过来的官方客户端，提供 `window.Phoenix.Socket` 和 `window.Phoenix.Channel`。不走 webpack 打包之后，`import {Socket} from "phoenix"` 那套没了，`app.html.heex` 改用两个 `<script defer>` 标签按顺序加载：`phoenix.js` 先于 `app.js`，这样 `app.js` 里才能直接用 `window.Phoenix.Socket`。`defer` 让两个文件并行下载、按声明顺序执行，浏览器细节照旧，只是构建工具没了。

`app.js` 现在整文件是一段说明性注释，告诉你 Channel 还没接上：

```js
// We no longer use a bundler like webpack: assets are served
// straight from priv/static/assets. The `phoenix.js` asset is
// loaded before this file in the layout, so `window.Phoenix`
// is available when channels are wired up.
//
//   let socket = new Phoenix.Socket("/socket", {params: {token: window.userToken}})
//   socket.connect()
//
//   let channel = socket.channel("topic:subtopic", {})
//   channel.join()
//     ...
```

`ch06/auction_umbrella/apps/auction_web/priv/static/assets/app.js`

留占位而不是删掉，是因为这个文件同时回答两个问题：JS 资源以后放哪（`priv/static/assets`，直接当静态文件发），和 Channel 的客户端代码长什么样（注释里的 `new Phoenix.Socket("/socket", ...)`，正是 Endpoint 里 `socket "/socket"` 声明对应的客户端）。第 10 章把它取消注释就能用。

CSS 那头简单得多：`app.css` 是一份 Milligram 骨架样式加几条项目自定义规则（`alert-info`、`phx-logo`、header 布局），layout 里的 `.container` 和导航条靠的就是它。没有打包器也没有 import 链，一个文件就是全部样式，对这本书的页面量够用了。

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

然后请求首页：

```sh
curl -i http://localhost:4000/
```

响应头里能看到这一章经过的痕迹：`x-request-id` 是 `Plug.RequestId` 生成的，`x-frame-options: SAMEORIGIN` 是 `put_secure_browser_headers` 加的。响应 HTML 里能搜到三条商品，比如：

```html
<strong>My first item</strong>: A tasty item sure to please
```

这三条数据来自 `auction` 应用的 `FakeRepo`：`PageController.index/2` 读出来，`index.html.heex` 用 `:for` 渲染成 `<li>`。再试一个静态文件：

```sh
curl -i http://localhost:4000/assets/app.css
```

`Plug.Static` 在最前面就返回了，`x-request-id` 这类 header 都没有，它没走到链的下半截。浏览器打开 `http://localhost:4000` 能看到带样式的完整页面。顺带可以试一个边角：`dev.exs` 里 `dev_routes: true` 给开发路由留了口子，`/dev` 前缀是保留的，但本项目没装 live dashboard 和 swoosh，实际挂不上路由，访问会 404。等以后依赖到位，dashboard 和邮件预览会自动出现在这个前缀下。

`mix test` 在 umbrella 根目录跑会跑两个应用的测试，其中 `page_controller_test.exs` 的断言 `assert html_response(conn, 200) =~ "My first item"` 做的就是 curl 刚干的事：

```elixir
  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "My first item"
  end
```

`ch06/auction_umbrella/apps/auction_web/test/auction_web/controllers/page_controller_test.exs`

`get(conn, ~p"/")` 里的 `get` 不是 HTTP 客户端，而是 `Phoenix.ConnTest` 提供的测试辅助：拿 `Plug.Test` 造出来的 conn 直接送进 Endpoint 的 plug 链，不经过 TCP。`test.exs` 里 `server: false`，测试不用真起服务器。`setup` 里那个初始 conn 来自 `Phoenix.ConnTest.build_conn()`，是 `ConnCase` 的 `using` 块准备好的；同一个块还 `use AuctionWeb, :verified_routes`，所以测试里也能写 `~p"/"`，和运行时代码共享同一份编译期校验。

## 小结

一个 HTTP 请求在 `auction_web` 里的完整路径：

```
TCP → Bandit → Endpoint（Plug.Static / Session / Parsers ...）
    → Router（pipeline :browser → scope "/"）
    → PageController.index/2（conn → conn）
    → PageHTML "index.html" 模板函数
    → Layouts "app" 模板函数（包一层外壳）
    → send_resp → before_send 回调反序执行 → HTML 回给浏览器
```

每个环节都是一个 plug 或一个函数，输入输出都是 `%Plug.Conn{}` 或者 assigns map，没有隐藏的全局状态，request 只是一段在函数间流转的数据。

回头看整个 `auction_web`，"接 HTTP"被拆成了各司其职的四块：Endpoint 管所有请求都要做的事（解析、会话、静态文件），Router 管按路径和客户端形态分流，Controller 管把一次 HTTP 调用翻译成领域调用再翻译回来，`*_html` 和 `Layouts` 管把数据变成 HTML。四块之间靠 `Plug.Conn` 和 assigns 传递数据，谁也不碰别人的内部。这张分工图后面每一章都在用：CRUD 是给 Router 加路由、给 controller 加 action；登录是往 `:browser` 管线塞 session 读写；Channel 是 Endpoint 上面已经占位的那条 `socket "/socket"` 分支。

下一章把 `FakeRepo` 换成真的 Ecto Repo：`Auction.list_items()` 开始查 PostgreSQL，商品数据从内存列表变成数据库表。
