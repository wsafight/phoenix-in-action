---
title: 第1章 · 第一个 Phoenix 应用：Blog
description: 拆开一个 mix phx.new 生成的博客应用，看懂 Endpoint、Router、Controller、Context、模板各自管什么，再用嵌套 resources 和 JSON 渲染器给它加上评论和 API。
sidebar:
  order: 1
---

`mix phx.new blog` 一分钟产出的东西，其实是一个完整的 Web 应用：有 HTTP 服务器、路由、controller、数据库连接池、迁移机制，还有配套的测试骨架。代价是目录一铺开，新手根本分不清谁是谁：模板为什么在 `controllers/` 目录里？`*_html.ex` 和 `*_json.ex` 是什么角色？`lib/` 下为什么有两个平级的命名空间？

本章拆开 `ch03/blog` 这个标本看。它是 posts + comments 的博客：浏览器端有整套 CRUD 页面，文章详情页嵌着评论表单，`/api` 下还有一组只读 JSON 接口，代码已迁到 Phoenix 1.7 写法。

## 生成器留下的目录结构

先把全貌铺开：

```
lib/blog/
  app/app.ex        App context，页面侧的所有读写逻辑
  app/post.ex       Post schema + changeset
  app/comment.ex    Comment schema + changeset
  api/              API context 及配套 schema，服务 /api 接口
  application.ex    OTP 应用入口，定义 supervision tree
  repo.ex           Ecto Repo，Postgres 连接池
lib/blog_web/
  endpoint.ex       plug 链，HTTP 生命周期的入口
  router.ex         pipeline + scope + 路由表
  controllers/
    post_controller.ex      页面的 Post controller
    comment_controller.ex   嵌套评论的 controller
    post_html.ex            PostHTML 渲染模块
    post_html/              heex 模板目录
    api/                    API 的 PostController + PostJSON
  components/
    core_components.ex      <.simple_form>、<.input> 等函数组件
    layouts.ex + layouts/   两层布局模板
config/             config.exs + dev/test/prod + runtime.exs
priv/repo/migrations/   posts、comments 两份迁移
test/               DataCase、ConnCase、context 测试
```

`ch03/blog` 目录布局（只列关键文件）

最重要的分界线是 `lib/blog/` 和 `lib/blog_web/` 两个顶层命名空间。`Blog` 是业务层：Repo、context、schema，整个目录没有一个 HTTP 概念。`BlogWeb` 是 Web 层：Endpoint、Router、Controller、模板、组件，负责把请求翻译成对 `Blog` 的调用。`lib/blog.ex` 的 moduledoc 一句话说清楚 context 的职责：管理数据，不管数据来自数据库还是别处。

这个博客里有两个 context。`Blog.App` 服务浏览器页面，`Blog.API` 服务 `/api` 下的 JSON 接口，两侧各自定义一套 `Post`/`Comment` schema 映射同样的数据表。一般一个 context 就够，这是个刻意的切分：给外部消费者的 API 有自己的边界，改 API 契约不碰页面逻辑。差异后面细说。

## 启动顺序：监督树最末端才是 HTTP 服务

`mix phx.server` 起来的是一个 OTP 应用。`Blog.Application` 定义了五个子进程，启动顺序就是依赖顺序：

```elixir
  def start(_type, _args) do
    children = [
      BlogWeb.Telemetry,
      Blog.Repo,
      {DNSCluster, query: Application.get_env(:blog, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Blog.PubSub},
      # Start the Endpoint (http/https)
      BlogWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Blog.Supervisor]
    Supervisor.start_link(children, opts)
  end
```

`ch03/blog/lib/blog/application.ex`

`Blog.Repo` 是 Postgres 连接池（`use Ecto.Repo, adapter: Ecto.Adapters.Postgres`，见 `ch03/blog/lib/blog/repo.ex`），它在 Endpoint 之前启动，第一个请求进来时数据库连接已经就绪。`Phoenix.PubSub` 是本机的发布订阅进程，这个应用暂时没有订阅者，但后续的实时功能建立在它上面。`BlogWeb.Telemetry` 每 10 秒跑一次 `telemetry_poller`，metrics 定义里能看到 `blog.repo.query.*` 这类数据库指标（`ch03/blog/lib/blog_web/telemetry.ex`）。`DNSCluster` 管生产环境的 Erlang 节点发现，单机开发直接忽略。

排在最后的 `BlogWeb.Endpoint` 才是 HTTP 服务本身。配置里 `adapter: Bandit.PhoenixAdapter` 指定了实现：真正把 TCP 包解析成 `%Plug.Conn{}` 的是 Bandit，一个纯 Elixir 的 HTTP 服务器，Phoenix 1.7 起取代 Cowboy 成为默认（`ch03/blog/config/config.exs`）。

## Endpoint：一条 plug 链就是整个 HTTP 生命周期

请求被 Bandit 解析成 `%Plug.Conn{}` 之后，按声明顺序流过 Endpoint 里每一个 plug，`plug BlogWeb.Router` 排在链条最末：

```elixir
  socket "/socket", BlogWeb.UserSocket,
    websocket: true,
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :blog,
    gzip: false,
    only: BlogWeb.static_paths()

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :blog
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
  plug BlogWeb.Router
```

`ch03/blog/lib/blog_web/endpoint.ex`

按声明顺序过一遍：

- **`socket "/socket"`** 是 Channel 的 WebSocket 入口，`mix phx.routes` 里那行 `WS /socket/websocket` 就是它注册的。`BlogWeb.UserSocket` 的 `connect/3` 现在直接放行、没有任何 channel 定义，是纯占位（`ch03/blog/lib/blog_web/channels/user_socket.ex`）。普通 HTTP 请求不走这个分支。
- **`plug Plug.Static`** 位置最靠前：路径命中 `BlogWeb.static_paths()`（`assets`、`fonts`、`images`、`favicon.ico`、`robots.txt`，定义在 `ch03/blog/lib/blog_web.ex`）就从 `priv/static` 读文件返回，后面的 plug 一个都不执行。所以给静态资源加长缓存很安全，这类请求根本到不了 router。
- **`if code_reloading?` 块**只在 `dev.exs` 配了 `code_reloader: true` 时编译进来：改完 `.ex` 或 `.heex` 不用重启，浏览器自动刷新。`Phoenix.Ecto.CheckRepoStatus` 顺手检查有没有待跑的迁移，忘了 `mix ecto.migrate` 时报一个明确的错，而不是让请求打到不存在的表上。
- **`Plug.RequestId` / `Plug.Telemetry`** 生成 request id（日志里 `Sent 200 in 3ms` 前面那串就是它）并上报 endpoint 级耗时。
- **`Plug.Parsers`** 按 `Content-Type` 解析请求体：表单（urlencoded）、文件上传（multipart）、JSON 三种都收，不认识的交给 `pass: ["*/*"]` 原样放过。解析结果进 `conn.body_params`，再合并进 `conn.params`，所以表单提交和 JSON 提交在 controller 里是同一个 map、同一种取法。
- **`Plug.MethodOverride`** 解决 HTML 的先天缺陷：表单只会发 GET 和 POST。这个 plug 在 body 解析完之后检查 POST 请求里的 `_method` 参数，把它改写成 `PUT`/`PATCH`/`DELETE`。列表页那个 Delete 链接就是这么落地成 `DELETE /posts/:id` 的。后面的 `Plug.Head` 把 `HEAD` 当 `GET` 走完全程、发响应时丢 body；`Plug.Session` 按 `@session_options` 只声明存取方式（`store: :cookie`，session 写进用 `secret_key_base` 加 `signing_salt` 签名的 cookie，用户读得到但改一个字节签名就失效），真正把 cookie 解析进 conn 的是 `:browser` pipeline 里的 `fetch_session`。

整条链没有一处是"框架魔法"，每个环节就是一个模块接 `conn` 返 `conn`，请求只是在函数间流转的数据。

## Router：resources 一行展开八条路由

Endpoint 把 conn 交给 Router。全文只有三十几行，但三个概念都在：

```elixir
defmodule BlogWeb.Router do
  use BlogWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_root_layout, html: {BlogWeb.Layouts, :root}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BlogWeb do
    pipe_through :browser

    get "/", PageController, :index

    resources "/posts", PostController do
      resources "/comments", CommentController, only: [:create]
    end
  end

  scope "/api", BlogWeb.API do
    pipe_through :api

    resources "/posts", PostController, only: [:index, :show]
  end
end
```

`ch03/blog/lib/blog_web/router.ex`

**pipeline** 是一组 plug 的命名集合，按请求形态分组。`:browser` 管线六个 plug：协商只要 HTML、把 cookie 里的 session 解析进 conn、取一次性 flash 提示、校验 CSRF token、加 `x-frame-options` 等安全响应头，最后 `put_root_layout` 指定最外层布局是 `BlogWeb.Layouts` 的 `:root` 模板。`:api` 管线只剩 `accepts ["json"]`：API 调用不带 cookie，session、flash、CSRF 那套全省掉。

**scope** 同时管两件事：路径前缀和模块命名空间。`scope "/", BlogWeb` 里的 `PostController` 指 `BlogWeb.PostController`；`scope "/api", BlogWeb.API` 里的 `PostController` 指 `BlogWeb.API.PostController`。所以 API 控制器能和 HTML 控制器同名而不同模块，路径再统一加 `/api` 前缀。

**resources** 是 RESTful 路由的缩写宏。`resources "/posts", PostController` 一行展开成八条，嵌套的 `resources "/comments"` 让子资源路径自动带上父 id。跑一遍 `mix phx.routes`，三行声明的实际产出是：

```
GET     /                        BlogWeb.PageController :index
GET     /posts                   BlogWeb.PostController :index
GET     /posts/:id/edit          BlogWeb.PostController :edit
GET     /posts/new               BlogWeb.PostController :new
GET     /posts/:id               BlogWeb.PostController :show
POST    /posts                   BlogWeb.PostController :create
PATCH   /posts/:id               BlogWeb.PostController :update
PUT     /posts/:id               BlogWeb.PostController :update
DELETE  /posts/:id               BlogWeb.PostController :delete
POST    /posts/:post_id/comments BlogWeb.CommentController :create
GET     /api/posts               BlogWeb.API.PostController :index
GET     /api/posts/:id           BlogWeb.API.PostController :show
WS      /socket/websocket        BlogWeb.UserSocket
```

`mix phx.routes` 输出（`ch03/blog` 目录下执行）

几处值得记住的细节：`PUT` 和 `PATCH` 分两条但都映射到 `:update`，controller 不用区分；`/posts/new` 和 `/posts/:id` 同时存在不冲突，路径段是逐段匹配的，`new` 永远先命中静态段；嵌套资源把参数名改成了 `post_id` 而不是 `id`，`POST /posts/3/comments` 进来的 params 是 `%{"post_id" => "3", "comment" => %{...}}`，"给哪篇文章发评论"所需的信息天然齐全；`only:` 负责裁剪动作，所以评论只有 `create` 一条，API 只有 `index`/`show` 两条。

`use BlogWeb, :router` 展开成 `use Phoenix.Router, helpers: false` 加 `import Plug.Conn`、`import Phoenix.Controller`（定义见 `ch03/blog/lib/blog_web.ex`）。`helpers: false` 是 1.7 的变化：不再生成 `post_path(conn, :show, post)` 这类 helper，URL 统一用 `~p` sigil 写，编译期对着路由表对账，写错路径是编译警告而不是运行时 404。

## Controller：conn 进、conn 出的调度函数

`resources "/posts"` 展开出的七个动作，对应 `PostController` 里七个同名函数。形状最说明问题的三个：

```elixir
  def index(conn, _params) do
    posts = App.list_posts()
    render(conn, "index.html", posts: posts)
  end

  def create(conn, %{"post" => post_params}) do
    case App.create_post(post_params) do
      {:ok, post} ->
        conn
        |> put_flash(:info, "Post created successfully.")
        |> redirect(to: ~p"/posts/#{post}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    post = App.get_post_with_comments!(id)
    new_comment = App.change_comment(%App.Comment{})
    render(conn, "show.html", post: post, new_comment: new_comment)
  end
```

`ch03/blog/lib/blog_web/controllers/post_controller.ex`（`new`/`edit`/`update`/`delete` 按同一模式展开，文件头 `use BlogWeb, :controller` 加 `alias Blog.App`）

controller 刻意保持很薄：不查库、不拼 SQL，每个 action 只做三件事，从 `params` 取参、调 `Blog.App` context、决定响应方式。几个值得说透的点：

**params 的形状**。`conn.params` 是 query string、path 参数、请求体参数三方合并的 map，key 全是字符串。`create` 的函数头直接模式匹配 `%{"post" => post_params}`：表单字段的 name 是 `post[title]`、`post[body]` 这种写法，`Plug.Parsers` 把它们嵌套成 `%{"post" => %{"title" => ..., "body" => ...}}`。URL 里的 `id` 始终是字符串，`Repo.get!` 内部会负责转换。

**`render/3` 做了什么**。`render(conn, "index.html", posts: posts)` 内部大致四步：pipeline 里 `accepts` 协商出的 `conn.private.phoenix_format` 决定这是 HTML 响应；`posts: posts` 这类 assigns 合并进 `conn.assigns`（模板里的 `@posts` 由此而来）；按"controller 名字 + 格式后缀"的约定找到 `BlogWeb.PostHTML`，调它的 `"index.html"` 模板函数得到 iodata；最后套上 layout 写进响应体。返回值还是 `conn`，所以能直接交给 `case` 分支。

**`~p` sigil 和 `Phoenix.Param`**。`~p"/posts/#{post}"` 在编译期检查这条路径在路由表里存在，运行时再把 `#{post}` 插值进去。能把整个 struct 插值成 `"3"`，是因为 Ecto schema 实现了 `Phoenix.Param` 协议，默认取 `:id` 字段。

**create 的失败分支为什么不 redirect**。`{:error, changeset}` 时重渲染 `new.html`，把同一个 changeset 传给表单，它带着校验错误和用户已填的值，表单组件靠它回填、标红错误字段。改成 redirect 的话，新的 GET 请求拿到的是全新空 changeset，错误和输入全丢。

**`show` 多传的一个 assign**。`new_comment` 是 `App.change_comment(%App.Comment{})` 造的空 changeset，详情页底部的评论表单要靠它生成字段。`get_post_with_comments!/1` 把评论列表提前加载好，模板里 `@post.comments` 才能直接用。

`use BlogWeb, :controller` 展开的关键两行在 `blog_web.ex` 里：`use Phoenix.Controller, formats: [:html, :json], layouts: [html: BlogWeb.Layouts]`。`formats` 声明该 controller 能响应 HTML 和 JSON 两种格式；`layouts` 指定 HTML 响应套 `BlogWeb.Layouts`。同一段 quote 末尾的 `unquote(verified_routes())` 注入 `~p` sigil，controller 和模板共用同一份编译期路由检查（`ch03/blog/lib/blog_web.ex`）。

## Context：两个命名空间，两套取舍

controller 背后，`Blog.App` 集中页面侧的全部读写。`list_posts`、`get_post!`、`create_post`/`update_post`/`delete_post` 都是"构造 changeset → Repo 操作"的三行函数，值得展开的是这两个：

```elixir
  def get_post_with_comments!(id) do
    get_post!(id)
    |> Repo.preload(:comments)
  end

  def create_comment_for_post(attrs, post_id) do
    get_post!(post_id)
    |> Ecto.build_assoc(:comments)
    |> Comment.changeset(attrs)
    |> Repo.insert()
  end
```

`ch03/blog/lib/blog/app/app.ex`

`create_comment_for_post/2` 是嵌套路由在数据层的对应写法：`Ecto.build_assoc(:comments)` 在父 Post 上构造一个已挂好 `post_id` 的 `%Comment{}`，之后走普通的 changeset + insert 流程，controller 不需要知道外键叫什么。`Repo.preload(:comments)` 一次查出所有评论塞进 `post.comments`，没有这行预加载，`post.comments` 会抛 `Ecto.Association.NotLoaded`。

schema 分两半：`schema` 块声明表结构和关联，`changeset/2` 声明哪些外部字段允许进来、哪些必须存在：

```elixir
  schema "posts" do
    field :body, :string
    field :title, :string
    has_many :comments, Blog.App.Comment, on_delete: :delete_all

    timestamps()
  end

  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
  end
```

`ch03/blog/lib/blog/app/post.ex`

`cast(attrs, [:title, :body])` 是白名单：表单或 API 请求多塞的字段（比如伪造一个 `post_id` 或者 `id`）会被直接丢掉，这是 Ecto 防 mass assignment 的默认姿势。`has_many` 上的 `on_delete: :delete_all` 表示删文章时 Ecto 负责连带删评论，弥补外键 `on_delete: :nothing`（数据库层不级联）留的缺口。

表结构由 `priv/repo/migrations/` 定义，comments 表通过 `references` 指向 posts 并加索引，嵌套路由的 `post_id` 就落在这个外键上：

```elixir
  def change do
    create table(:comments) do
      add :name, :string
      add :body, :text
      add :post_id, references(:posts, on_delete: :nothing)

      timestamps()
    end

    create index(:comments, [:post_id])
  end
```

`ch03/blog/priv/repo/migrations/20181204053603_create_comments.exs`

`Blog.API` 是第二个 context，函数清单跟 `Blog.App` 几乎逐行平行（`ch03/blog/lib/blog/api/api.ex`），但两处 schema 的写法有意不同：

```elixir
  schema "comments" do
    field :name, :string
    field :body, :string
    belongs_to :post, Blog.API.Post

    timestamps()
  end

  @doc false
  def changeset(%Comment{} = comment, attrs) do
    comment
    |> cast(attrs, [])
    |> validate_required([])
  end
```

`ch03/blog/lib/blog/api/comment.ex`

两处不对称。第一处：关联声明方式不同。`Blog.App.Comment` 用 `field :post_id, :id` 手动声明外键，`Blog.API.Comment` 用 `belongs_to :post`（自动生成 `post_id` 字段、支持双向 preload）。两边读同一张表，功能等价，是迁移时保留的写法差异。

第二处更实质：API 侧两个 changeset 都是 `cast(attrs, [])`，白名单是空的，`Blog.API.create_post(%{"title" => "x"})` 会把所有字段丢弃、插进一行 title、body 全为 nil 的记录（iex 里一试便知）。这个 context 的写函数目前没有任何调用者，页面走 `Blog.App`，API 路由又被 `only: [:index, :show]` 裁成了只读，所以是安静的死代码。真要开放 API 写入，第一件事就是把白名单补上。

## heex 模板：编译进 `*HTML` 模块的函数

`render(conn, "index.html", ...)` 找到的"模板"，不是一个运行时读盘的文件，而是 `BlogWeb.PostHTML` 模块上由 `embed_templates` 编译出来的函数：

```elixir
defmodule BlogWeb.PostHTML do
  use BlogWeb, :html

  import PhoenixHTMLHelpers.Format

  embed_templates "post_html/*"

  def date(date_to_display), do: Date.to_string(date_to_display)
end
```

`ch03/blog/lib/blog_web/controllers/post_html.ex`

模板文件为什么在 `controllers/` 目录下：`embed_templates "post_html/*"` 的 glob 相对于模块文件所在目录解析，`post_html.ex` 放在 `controllers/`，模板目录 `controllers/post_html/` 就跟它贴在一起。渲染模块就近挨着它的 controller，这是生成器的约定，不是框架限制。

`embed_templates` 把目录下每个 `.heex` 编译成模块上的一个函数：`index.html.heex` 变成名叫 `"index.html"` 的模板函数，heex 源码在编译期内嵌进 BEAM 文件，渲染时不做任何文件 IO。`use BlogWeb, :html` 给这个模块配齐 HTML 工具：`use Phoenix.Component`（能写函数组件）、`import Phoenix.HTML`（转义）、`import BlogWeb.CoreComponents`（`<.simple_form>` 等组件进作用域）、`verified_routes()`（`~p` 注入），定义都在 `blog_web.ex` 的 `html_helpers/0` 里。

`PostHTML` 同时也是展示辅助函数的家：模板里的 `date(post.inserted_at)` 是模块里手写的 `date/1`，`text_to_html(comment.body)`（换行转段落、自动转义）来自 `import PhoenixHTMLHelpers.Format`。heex 的语法就三样：`{expr}` 插值（自动 HTML 转义）、`:for`/`:if` 这类写在标签上的指令、`<.name>` 开头的函数组件。列表页一次用全：

```heex
    <tr :for={post <- @posts}>
      <td nowrap>{date(post.inserted_at)}</td>
      <td nowrap><strong>{post.title}</strong></td>
      <td>{post.body}</td>

      <td class="text-right">
        <span>
          <.link href={~p"/posts/#{post}"} class="btn btn-default btn-xs">Show</.link>
        </span>
        <span>
          <.link href={~p"/posts/#{post}/edit"} class="btn btn-default btn-xs">Edit</.link>
        </span>
        <span>
          <.link
            href={~p"/posts/#{post}"}
            method="delete"
            data-confirm="Are you sure?"
            class="btn btn-danger btn-xs"
          >
            Delete
          </.link>
        </span>
      </td>
    </tr>
```

`ch03/blog/lib/blog_web/controllers/post_html/index.html.heex`

Delete 链接值得展开讲，它串起了前面三个环节。`method="delete"` 和 `data-confirm` 渲染出来是 `data-method`/`data-confirm` 属性，root layout 里引入的 `priv/static/assets/phoenix_html.js` 监听点击，动态构造一个带 `_method=delete` 和 CSRF token 的表单 POST 出去；请求回到服务器，`Plug.Parsers` 解 body、`Plug.MethodOverride` 把方法改写成 DELETE、`protect_from_forgery` 验 token，router 才看到 `DELETE /posts/:id`。这层"属性约定 + JS 桥 + plug 改写"是全栈协作出来的。

## 布局是两层模板，`<.simple_form>` 是普通组件

渲染页面时 Phoenix 套两层模板。最外层 root layout 由 router 的 `put_root_layout` 指定，是 HTML 骨架：

```heex
    <meta name="csrf-token" content={get_csrf_token()} />
    <title>Blog · Phoenix Framework</title>
    <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
    <script defer phx-track-static src={~p"/assets/phoenix.js"}>
    </script>
    <script defer phx-track-static src={~p"/assets/phoenix_html.js"}>
    </script>
    <script defer phx-track-static src={~p"/assets/app.js"}>
    </script>
  </head>
  <body>
    {@inner_content}
  </body>
</html>
```

`ch03/blog/lib/blog_web/components/layouts/root.html.heex`（节选 `<head>` 后半到结尾）

三个 script 标签按顺序挂 `phoenix.js`（Socket/Channel 客户端）、`phoenix_html.js`（上面说的 data-method 桥）、`app.js`，都是 `priv/static` 下的普通文件，`Plug.Static` 直接服务，这个应用没有 JS 打包器。`<meta name="csrf-token">` 把头里的 token 交给 JS 层，表单桥接时带回给 `protect_from_forgery` 校验。

内层 `app.html.heex` 是默认布局，放导航和主体容器，`<.flash_group flash={@flash} />` 渲染 flash 消息，`{@inner_content}` 是页面内容的注入点（`ch03/blog/lib/blog_web/components/layouts/app.html.heex`）。`BlogWeb.Layouts` 和 `PostHTML` 同一种写法：`use BlogWeb, :html` 加 `embed_templates "layouts/*"`（`ch03/blog/lib/blog_web/components/layouts.ex`）。渲染顺序是先调 `PostHTML` 的 `"show.html"` 函数得到内容放进 `assigns.inner_content`，再依次套 app 和 root 两层外壳。

新建和编辑页共用一份表单。`new.html.heex` 主体只有一行：

```heex
<h2>New Post</h2>

<.post_form changeset={@changeset} action={~p"/posts"} />
```

`ch03/blog/lib/blog_web/controllers/post_html/new.html.heex`

`<.post_form>` 不是从别处 import 的组件，就是同目录的 `post_form.html.heex`：`embed_templates` 编译出来的每个模板函数本身就是函数组件，`index.html` 可以像组件一样调用 `post_form.html`，把 `changeset` 和 `action` 作为 assigns 传进去。这就是 1.7 里 partial 的形态。`edit.html.heex` 只差一个 `action={~p"/posts/#{@post}"}`。

```heex
<.simple_form :let={f} for={@changeset} action={@action}>
  <div :if={@changeset.action} class="alert alert-danger">
    <p>Oops, something went wrong! Please check the errors below.</p>
  </div>

  <.input field={f[:title]} type="text" label="Title" />
  <.input field={f[:body]} type="textarea" label="Body" />

  <:actions>
    <.button class="btn btn-primary">Submit</.button>
  </:actions>
</.simple_form>
```

`ch03/blog/lib/blog_web/controllers/post_html/post_form.html.heex`

几个对应关系：

- `for={@changeset}` 接收 `Ecto.Changeset`，`<.form>` 内部通过 `Phoenix.HTML.FormData` 协议把它转成 `%Phoenix.HTML.Form{}`。表单因此自带校验错误和已填值，create 失败重渲染时输入不丢。
- `:let={f}` 是组件向调用方回传变量的语法，`f` 就是那个 Form 结构。
- `f[:title]` 从 Form 里取出 `%Phoenix.HTML.FormField{}`，`<.input>` 靠它拿到 name、id、value、errors。
- `<:actions>` 是具名 slot，`<.simple_form>` 把它渲染成按钮区。
- `@changeset.action` 只有在 changeset 真的执行过（insert/update 失败过）才非 nil，所以红色提示只在提交失败后出现，第一次打开表单时没有。

这些组件没有一个来自框架内部，全部是生成器留在 `core_components.ex` 里的普通函数组件，用 `~H` sigil 在 `.ex` 文件里写 heex，`attr`/`slot` 声明在编译期校验调用方传的参数和 slot。打开就能看到 `<.simple_form>` 只是 `<.form>` 外面包一层 slot 约定、`render_slot(@inner_block, f)` 把 Form 回传给 `<.input>`；`input/1` 按 `type` 分 clauses 渲染不同标签，错误消息经 `translate_error/1` 走 Gettext。样式不满意直接改这个文件，没有第三方组件库要覆盖（`ch03/blog/lib/blog_web/components/core_components.ex`）。

## 嵌套资源：评论表单的完整回路

文章详情页把整条嵌套链路跑了一遍：上半部分渲染 `@post.comments`，下半部分是手动拼的评论表单：

```heex
<.simple_form :let={f} for={@new_comment} action={~p"/posts/#{@post}/comments"}>
  <div>
    <label>
      Name:<br />
      <input type="text" name={f[:name].name} id={f[:name].id} value={f[:name].value} />
    </label>
  </div>
  <div>
    <label>
      Comment:<br />
      <textarea name={f[:body].name} id={f[:body].id}>{f[:body].value}</textarea>
    </label>
  </div>
  <:actions>
    <.button>Submit Comment</.button>
  </:actions>
</.simple_form>
```

`ch03/blog/lib/blog_web/controllers/post_html/show.html.heex`（节选评论表单）

这里没用 `<.input>`，而是直接读 `f[:name]` 这个 `FormField` 的 `name`/`id`/`value` 手写原生标签，name 是 `comment[name]` 这种嵌套写法，提交后 params 里就有 `comment` 这组。需要完全控制字段结构时，这层信息始终拿得到。

`action` 正好打到嵌套路由 `POST /posts/:post_id/comments`。对应的 controller 只剩一个 action，params 里同时有 `post_id` 和 `comment` 两组：

```elixir
  def create(conn, %{"post_id" => post_id, "comment" => comment_params}) do
    case App.create_comment_for_post(comment_params, post_id) do
      {:ok, comment} ->
        conn
        |> put_flash(:info, "Thanks for submitting your comment.")
        |> redirect(to: ~p"/posts/#{comment.post_id}")

      {:error, %Ecto.Changeset{} = _changeset} ->
        conn
        |> put_flash(:warning, "Your comment was not submitted successfully")
        |> redirect(to: ~p"/posts/#{post_id}")
    end
  end
```

`ch03/blog/lib/blog_web/controllers/comment_controller.ex`（`BlogWeb.CommentController`）

失败分支用 `redirect` 而不是 `render`，和 `PostController.create` 正好相反的取舍：评论表单寄宿在文章详情页，重渲染得把 post、new_comment 一整套 assigns 重新备齐，不如打回文章页用 flash 提示。代价是失败时评论输入会丢，这是嵌套表单的常见妥协。

顺带一个小坑：`<.flash>` 组件的 `attr :kind` 只接受 `:info` 和 `:error`（`core_components.ex` 里 `values: [:info, :error]`），这里 `put_flash(:warning, ...)` 写入的 flash 进了 `conn.private.phoenix_flash` 但不会被 `flash_group` 渲染出来。真要显示警告，得给 `flash` 组件的 values 加上 `:warning`。

## JSON API：同一套路由，换一层渲染模块

`/api` scope 下的控制器和 HTML 版几乎一样，alias 换成 `Blog.API`，render 目标从 `"*.html"` 换成 `"*.json"`：

```elixir
  def index(conn, _params) do
    posts = API.list_posts()
    render(conn, "index.json", posts: posts)
  end

  def show(conn, %{"id" => id}) do
    post = API.get_post_with_comments!(id)
    render(conn, "show.json", post: post)
  end
```

`ch03/blog/lib/blog_web/controllers/api/post_controller.ex`（`BlogWeb.API.PostController`，`alias Blog.API`）

`"show.json"` 的解析和 HTML 是同一套约定：controller 模块叫 `BlogWeb.API.PostController`，渲染模块就是同目录去掉 `Controller` 换上格式后缀的 `BlogWeb.API.PostJSON`。区别是 JSON 侧没有模板文件，`embed_templates` 不参与，渲染函数就是与动作同名的普通函数，收 assigns map，返回 Jason 能编码的数据结构：

```elixir
  def index(%{posts: posts}) do
    %{data: for(post <- posts, do: post(post))}
  end

  def show(%{post: post}) do
    %{data: post_with_comments(post)}
  end

  defp post(%Post{} = post) do
    %{id: post.id, title: post.title, body: post.body}
  end

  defp post_with_comments(%Post{} = post) do
    %{
      id: post.id,
      title: post.title,
      body: post.body,
      comments: for(comment <- post.comments, do: CommentJSON.data(comment))
    }
  end
```

`ch03/blog/lib/blog_web/controllers/api/post_json.ex`（`BlogWeb.API.PostJSON`，alias 略）

`render/3` 调 `PostJSON.show(%{post: post})` 拿到 map，交给 Jason 编码后写进响应。`CommentJSON.data/1` 更短，只返回 `%{id:, name:, body:}` 三个字段（`ch03/blog/lib/blog_web/controllers/api/comment_json.ex`）。

手写 map 是刻意的：输出字段一目了然，将来 schema 加了字段不会自动泄进 API 响应，要泄得显式写进 `post/1`。`post_with_comments` 依赖 `API.get_post_with_comments!/1` 里那行 `Repo.preload(:comments)`，没有它 `post.comments` 会抛 `Ecto.Association.NotLoaded`，两个 context 都各备了一份这个函数不是巧合。

错误响应也有对称的处理：`config.exs` 里 `render_errors` 配了 `html: BlogWeb.ErrorHTML, json: BlogWeb.ErrorJSON`。`get_post_with_comments!` 查不到文章抛 `Ecto.NoResultsError`，Phoenix 规范成 404，JSON 请求走 `ErrorJSON` 拿到 `%{errors: %{detail: "Not Found"}}`（`ch03/blog/lib/blog_web/controllers/error_json.ex`）。注意这是 prod/test 下的样子：dev 开了 `debug_errors: true`，同样的请求先被 `Plug.Debugger` 截住，返回带堆栈和 `params` 的调试页（实测 `curl /api/posts/999` 拿到的是 HTML 调试页而不是 JSON），生产部署才是结构化错误。

## 动手验证

应用依赖 PostgreSQL，`dev.exs` 里配的是 `postgres`/`postgres`@`localhost`，库名 `blog_dev`。先确认本地 5432 能连，然后：

```bash
cd ch03/blog
mix deps.get
mix ecto.setup    # ecto.create + ecto.migrate + run priv/repo/seeds.exs
mix phx.server
```

`ecto.setup` 是 `mix.exs` 里定义的 alias，把建库、跑迁移、执行种子文件串成一条（种子文件目前只有注释）。看到 `[info] Running BlogWeb.Endpoint with Bandit ... at 127.0.0.1:4000` 就起来了，`http://localhost:4000/posts` 是空的列表页，走一遍"New Post → 提交 → Show → 发评论"就能看到嵌套路由生效。另外项目根目录的 `README.md` 是更早版本生成器留的，里面 `cd assets && npm install` 一句已经过期：这个应用没有 `assets/` 目录，JS/CSS 是 `priv/static` 下的普通文件。

另开终端跑 `iex -S mix`，直接验证 context 层：

```elixir
iex> Blog.App.create_post(%{title: "hello", body: "first post"})
{:ok, %Blog.App.Post{...}}
iex> Blog.App.create_post(%{})          # 校验失败的形状
{:error, #Ecto.Changeset<errors: [title: {"can't be blank", _}, body: {"can't be blank", _}], ...>}
iex> Blog.App.create_comment_for_post(%{name: "me", body: "nice"}, 1)
{:ok, %Blog.App.Comment{post_id: 1, ...}}
iex> Blog.App.get_post_with_comments!(1).comments |> length()
1
iex> Blog.API.create_post(%{"title" => "x"})   # API 侧 changeset 白名单是空的
{:ok, %Blog.API.Post{title: nil, body: nil, ...}}
```

`iex -S mix` 会话（`ch03/blog` 目录下执行）

`mix phx.routes` 对照前面那张路由表。然后 curl 打 JSON API：

```bash
curl -s http://localhost:4000/api/posts
# {"data":[{"body":"first post","id":1,"title":"hello"}]}

curl -s http://localhost:4000/api/posts/1
# {"data":{"body":"first post","comments":[{"body":"nice","id":1,"name":"me"}],"id":1,"title":"hello"}}

curl -s http://localhost:4000/api/posts/999
# dev 下返回 Plug.Debugger 调试页（HTML，带 Ecto.NoResultsError 堆栈）
```

顺手试一个反例：`curl -X POST http://localhost:4000/posts -d 'post[title]=x'` 会吃 403。curl 没有 CSRF token，`protect_from_forgery` 直接拒掉，这从侧面验证了 `:browser` pipeline 在干活。HTML 侧创建的文章和评论会原样出现在 JSON 响应里，两侧读写同一张表，只是 context 和渲染模块不同。

最后跑测试。`mix.exs` 的 aliases 把 `test` 重新定义成 `ecto.create --quiet` + `ecto.migrate` + `test`，所以直接 `mix test` 会先确保 `blog_test` 库存在再跑，不用手动建测试库：

```bash
mix test
# ...................
# Finished in 0.1 seconds
# Result: 19 passed
```

19 个用例里 `Blog.AppTest` 两个 describe 块占 16 个，其余是 `ErrorHTMLTest`（2 个）和 `PageControllerTest`（1 个）。测试侧基建值得扫一眼：`test/support/data_case.ex` 用 `Ecto.Adapters.SQL.Sandbox` 给每个测试检出沙箱连接，`conn_case.ex` 用 `Phoenix.ConnTest.build_conn()` 造测试 conn，不起服务器（`test.exs` 里 `server: false`）。

## 小结

- 一个请求的路径是 Bandit → Endpoint plug 链 → Router（pipeline 加工 conn，scope 按 URL 分发）→ Controller action → `*HTML`/`*JSON` 渲染模块。每一环都是普通模块，conn 进去 conn 出来。
- `resources` 一行换八条路由（PUT/PATCH 各一条都进 `:update`），嵌套后 `post_id` 自动进 params，数据层用 `Ecto.build_assoc` 挂好外键再走普通 changeset 流程。
- 1.7 的模板是 `embed_templates` 编译进 `*HTML` 模块的函数，同目录模板互为函数组件。`<.simple_form>`、`<.input>` 定义在 `core_components.ex`，可读可改。
- 页面和 API 共用同一份路由语法和业务表，区别只在 scope 的模块前缀、pipeline 的取舍、`cast` 白名单和渲染模块。这个博客里 `Blog.App` 和 `Blog.API` 两个 context 就是这条边界的物理形态。

:::tip[下一章]
Blog 的骨架是生成器给的，context、schema、controller 一次到位，适合用来认路，不适合用来学"怎么设计"。下一章换一个起点：拍卖应用的领域核心先写成三个普通 Elixir 模块（Item struct、FakeRepo、context API），不建表、不起 Web，先在 iex 里把领域层的形状调对。
:::
