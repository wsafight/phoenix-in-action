---
title: 第8章 · Items CRUD
description: 一行 resources 展开成整套路由，ItemController 六个 action 两两成对，heex 表单吃 changeset，redirect + flash 完成 PRG，_method 补齐 HTML 不会说的动词
sidebar:
  order: 8
---

上一章把 `Item.changeset/2` 立了起来：`cast` 做白名单，`validate_required`、`validate_length`、自定义的 `validate_change` 逐层把关，context 的 `insert_item`/`update_item` 一律返回 `{:ok, item}` 或 `{:error, %Ecto.Changeset{}}`。但这些函数目前只在 iex 里跑过，用户还没有一个页面可点。本章把 changeset 接到 HTML 上，代码快照在 `ch09/auction_umbrella`：路由器加一行 `resources "/items"`，`ItemController` 管六个 action，heex 表单组件吃 changeset，写库成功走 `put_flash` + `redirect`，校验失败带错误原地重渲。

CRUD 的难点不在写库，在 HTTP 的边界。表单页和提交处理是两个独立请求，用户输入、校验错误、成功提示这三样东西都得跨请求搬运。这一章实际就是看 Phoenix 怎么搬它们。

## `resources "/items"` 展开成八条路由

上一章每个 action 手写一条 `get`。Item 有六个 action，手写既啰嗦又容易拼错路径，按 REST 惯例生成的 `resources` 宏一次给全：

```elixir
  scope "/", AuctionWeb do
    pipe_through :browser

    get "/", PageController, :index

    resources "/items", ItemController,
      only: [
        :index,
        :show,
        :new,
        :create,
        :edit,
        :update
      ]
  end
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/router.ex`

`resources` 默认生成完整的 REST 路由表，也就是 7 个 action 对应 8 条路由（PATCH 和 PUT 都落到 `:update`）。本项目用 `only:` 砍掉了 `:delete`，展开后是：

| 方法 + 路径 | action | 干什么 |
| --- | --- | --- |
| GET `/items` | `:index` | 列表页 |
| GET `/items/new` | `:new` | 渲染新建表单 |
| POST `/items` | `:create` | 处理新建提交 |
| GET `/items/:id` | `:show` | 详情页 |
| GET `/items/:id/edit` | `:edit` | 渲染编辑表单 |
| PATCH `/items/:id` | `:update` | 处理编辑提交 |
| PUT `/items/:id` | `:update` | 同上 |
| DELETE `/items/:id` | `:delete` | 未启用，`only:` 排除了 |

注意 `:new` 排在 `:show` 前面没有冲突：`/items/new` 是字面路径，`/items/:id` 是参数段，路由按声明顺序匹配时 `new` 先接住 `/items/new` 这个字符串。

`:new` 和 `:create`、`:edit` 和 `:update` 是两两成对的：前者是 GET，只负责渲染表单；后者是 POST 或 PUT/PATCH，负责处理表单提交。表单页和提交页被拆成两次请求，这不是冗余，是后面 PRG 闭环和校验分流的前提。

`resources` 的兄弟选项也顺手认识一下：`only:` 白名单、`except:` 黑名单，以及把 `:new` 单独收进 `member`/`collection` 作用域的写法。本章用不到更多，第 11 章嵌套的 `resources "/bids"` 会再见到它。

pipeline 那几行也有一个小变化：`:browser` 末尾多了 `plug :put_root_layout, html: {AuctionWeb.Layouts, :root}`，声明 HTML 响应套两层 layout，模板渲完先嵌进 `app.html`，再嵌进 `root.html` 的 HTML 骨架。讲到 flash 的时候会看到它。

## 只读的两个 action：和上一章一样薄

```elixir
  def index(conn, _params) do
    items = Auction.list_items()
    render(conn, "index.html", items: items)
  end

  def show(conn, %{"id" => id}) do
    item = Auction.get_item(id)
    render(conn, "show.html", item: item)
  end
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_controller.ex`

action 的形状没有变：conn 进、conn 出，中间调一下 context 再 `render/3`。`"index.html"` 里的 `.html` 会被拆成模板名 `index` + 格式 `html`，对应 `ItemHTML` 模块上 `index(assigns)` 这个编译出来的模板函数。

`Auction.get_item/1` 内部是 `@repo.get!`（第 6 章定的），id 不存在时抛 `Ecto.NoResultsError`。phoenix_ecto 给这个异常实现了 `Plug.Exception` 协议，映射到 404（实现就在 `deps/phoenix_ecto/lib/phoenix_ecto/plug.ex`），Phoenix 会自动渲成错误页，所以 `show` 和后面的 `update` 都不用先判断存在性。

## `new` 和 `edit`：表单页传的是 changeset，不是 struct

```elixir
  def new(conn, _params) do
    changeset = Auction.new_item()
    render(conn, "new.html", changeset: changeset)
  end
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_controller.ex`

```elixir
  def edit(conn, %{"id" => id}) do
    changeset = Auction.edit_item(id)
    render(conn, "edit.html", changeset: changeset)
  end
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_controller.ex`

两个 action 只做一件事：把一个 changeset 交给模板。为什么不能直接传 `%Item{}`？因为表单组件从 changeset 里要拿三样东西：

1. **字段清单和类型**。`cast` 白名单决定表单上有哪些输入框，`changeset.types` 决定每个框渲成什么控件（`:utc_datetime` 会对应日期控件）。
2. **当前值**。编辑场景下 `changeset.data` 是从库里读出的 Item，输入框要回填旧值；提交失败重渲时 `changeset.params` 里是用户刚敲的输入，也要回填。
3. **校验状态**。`changeset.errors` 装着逐字段错误，`changeset.action` 标记这份 changeset 是不是刚被 Repo 拒绝过，模板据此决定要不要显示错误。

context 侧就是把 Item 包成 changeset，零成本：

```elixir
  def new_item, do: Item.changeset(%Item{})

  def edit_item(id) do
    get_item(id)
    |> Item.changeset()
  end
```

`ch09/auction_umbrella/apps/auction/lib/auction.ex`

`Item.changeset/2` 的第二个参数默认 `%{}`（第 7 章定义的），所以这两个调用等于"对一份空数据或已有数据跑一遍 cast + 校验"。有个容易忽略的细节：`Item.changeset(%Item{})` 跑完校验后 `errors` 里**已经**有 `title` 的 `can't be blank`，`valid?` 也是 `false`。但首次打开的表单页不该显示错误。区分开关是 `changeset.action`：手工构造的 changeset `action` 是 `nil`，被 `Repo.insert`/`update` 拒绝的 changeset `action` 是 `:insert`/`:update`。phoenix_ecto 给 `Ecto.Changeset` 实现的 `Phoenix.HTML.FormData` 协议里，正是靠 `action` 是不是 `nil` 决定要不要把 errors 交给表单渲染。这个开关后面会反复用到。

在 iex 里看一眼这份"表单原料"的实际长相（dev 数据库里要先有一条记录，`mix ecto.setup` 或手动 `insert_item` 一条都行）：

```elixir
iex> cs = Auction.new_item()
iex> {cs.valid?, cs.action, cs.errors, cs.data.__meta__.state}
{false, nil, [title: {"can't be blank", [validation: :required]}], :built}

iex> cs2 = Auction.edit_item(1)
iex> {cs2.valid?, cs2.action, cs2.data.__meta__.state}
{true, nil, :loaded}

iex> {:error, bad} = Auction.insert_item(%{"title" => "x"})
iex> {bad.action, bad.params}
{:insert, %{"title" => "x"}}
iex> bad.errors
[title: {"should be at least %{count} character(s)",
  [count: 3, validation: :length, kind: :min, type: :string]}]
```

一张表单生命周期里会碰到三种 changeset 状态：干净的 `action: nil`（`new`/`edit` 刚渲出来）；`data` 是 `:built` 还是 `:loaded` 区分"新建"和"改已有记录"（这个状态还决定了表单 method，后面细说）；被 Repo 拒绝后 `action` 被盖上 `:insert`/`:update`，`errors` 里装 `{msg, opts}` 元组，`params` 里留着用户这次的输入。`{:error, changeset}` 分支能原地重渲出一张带错的表单，靠的就是这三个字段各就各位。

## `create` 和 `update`：一次 `case`，两条出路

提交处理是整章的核心模式。先看 `create`：

```elixir
  def create(conn, %{"item" => item_params}) do
    case Auction.insert_item(item_params) do
      {:ok, item} ->
        conn
        |> put_flash(:info, "Item created successfully.")
        |> redirect(to: ~p"/items/#{item}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_controller.ex`

逐层拆：

- **`%{"item" => item_params}`**：表单里所有输入框的 name 都渲染成 `item[title]`、`item[description]` 这样的方括号形式，`Plug.Parsers` 解析 urlencoded body 时自动把它们收进 `"item"` 这个 map。键是字符串不是 atom，外面传进来的参数永远是字符串键。
- **`Auction.insert_item(item_params)`**：内部是 `%Item{} |> Item.changeset(attrs) |> @repo.insert()`。context 对外的契约就两条：`{:ok, item}` 或 `{:error, changeset}`，controller 拿 `case` 接住。
- **成功分支是 `redirect`**：`redirect(to: ~p"/items/#{item}")` 返回 302 加 `Location` 头，让浏览器重新发一个 GET 去详情页。`~p` 是 verified route，编译期和路由表对账；`item` 是 struct，`Phoenix.Param` 协议自动取它的 `id` 拼进路径（`id` 是 `nil` 会直接抛错，所以这条路只能用于已落库的 Item）。
- **`put_flash(:info, ...)`**：在 conn 上挂一条一次性消息，下一个请求渲染时显示。机制后面细说。
- **失败分支是 `render`**：同一个 conn、同一个请求，把 Repo 退回的带错误 changeset 再交回 `new.html`。用户输入和错误全在这个 changeset 里，原地渲染才能回填表单、显示错误。

`update` 结构相同，只是先从路径里取 id、查出旧数据再更新：

```elixir
  def update(conn, %{"id" => id, "item" => item_params}) do
    item = Auction.get_item(id)

    case Auction.update_item(item, item_params) do
      {:ok, item} ->
        conn
        |> put_flash(:info, "Item updated successfully.")
        |> redirect(to: ~p"/items/#{item}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "edit.html", changeset: changeset)
    end
  end
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_controller.ex`

`%{"id" => id, "item" => item_params}` 这一个模式匹配同时拆了两种来源：`"id"` 来自路径参数，`"item"` 来自表单 body，Phoenix 把它们合并在 `conn.params` 里。`get_item` 用的是 bang 版本，id 有问题直接 404，更新一个不存在的拍品的机会都不给。

为什么 `update` 要先 `get_item`？因为 `Item.changeset/2` 的 cast 要拿"当前值"和"新输入"做 diff：`changes` 里只该有真正变了的字段，没动的字段就不发 SET 子句。`get_item` 读出的 loaded struct 就是那个"当前值"，同时也是表单 method 判定的依据，没有这次读取，`changeset.data.__meta__.state` 就不会是 `:loaded`，后面的 PUT 判定无从谈起。

:::tip
`update` 一次提交发两次查询：先 `SELECT` 拿旧记录，再 `UPDATE` 写回。对拍品这个体量无所谓；真要省掉一次查询，`Repo.update` 也可以直接对一份"只带 id 的裸 struct + changes"动手，但那样就拿不到 diff 和乐观锁语义，一般不建议。
:::

## 成功 redirect、失败 render：PRG 闭环

为什么分流要长这样？

**成功时 `redirect`** 就是 Post/Redirect/Get 模式。POST `/items` 完成后浏览器收到 302，转而发起 `GET /items/5`。前一个 POST 请求就此"消费"掉了：用户刷新详情页，刷新的是那个 GET，浏览器不会弹"是否重新提交表单"，数据也不会被重复插入。如果成功分支也走 `render`，URL 就停在 `/items`，刷新等于重发 POST，再插一条。

**失败时必须 `render`**，因为能救场的数据全是请求内状态。`changeset.errors`（逐字段错误）和 `changeset.params`（用户输入）存在这次请求的 conn 和 assigns 里，302 到另一个 URL 时它们过不去，下一个请求拿到的只会是空表单。flash 只能捎一段字符串，装不下一份 changeset。所以校验失败没有别的选法：同一个 conn 上重渲 `new.html`，URL 停在 `/items`（POST 的目标），表单带错，输入回填。代价是这个状态下刷新浏览器会触发"重新提交表单"的警告，这是原地渲染不可避免的副作用。

两个分支合起来就是一张状态转移图：表单页（GET，`action: nil`）→ 提交 → 成功则跳到下一个 GET，失败则带着 `action: :insert`/`:update` 回到刚才那张表单。changeset 从 context 出发，绕一圈又回到同一个模板，只是身上多了错误。

顺眼看一眼两个出口对 conn 做的事。`render/3` 往 `conn.assigns` 里合并模板参数，调模板函数拿到 iodata，`send_resp` 写 200 和 body，同一个 conn 直接返回。`redirect/2` 更简单：`conn |> put_resp_header("location", url) |> send_resp(302, "")`，body 是空的，真正的工作全由浏览器后续的 GET 完成。一个 action 只能走其中一个：`send_resp` 之后 conn 就是"已应答"状态，再来一次响应操作会抛 `Plug.Conn.AlreadySentError`。

## `put_flash`：一条消息借 session 走一个请求

redirect 之后渲染的是 `show` action 的模板，它和 `create` 的 assigns 毫不共享，"创建成功"这句话只能借 session 捎过去。链条分四步：

1. `put_flash(:info, msg)` 把消息写进 `conn.assigns.flash`（一个普通 map）。
2. `fetch_flash` plug（早就在 `:browser` pipeline 里）注册了一个 `before_send` 钩子：响应发出去前，如果 flash 非空且状态码是 3xx，就把整个 flash map 塞进 session 的 `"phoenix_flash"` 键；否则从 session 里删掉它。所以 flash 只在 redirect 之后存活，且只活一次。
3. 浏览器带 cookie 发起下一个 GET。session 是签名 cookie（endpoint 的 `@session_options` 里 `store: :cookie`，用 `signing_salt` 签名），内容用户读得到但改不了。
4. 新请求里 `fetch_session` 解出 session，`fetch_flash` 把 `"phoenix_flash"` 读进 `conn.assigns.flash`，模板里以 `@flash` 可用。

显示的位置在布局里。`app.html` 的 `<main>` 开头放着 `<.flash_group flash={@flash} />`：

```heex
<header>
  <section class="container">
    <nav role="navigation">
      <ul>
        <li><a href="https://hexdocs.pm/phoenix/overview.html">Get Started</a></li>
      </ul>
    </nav>
    <a href="http://phoenixframework.org/" class="phx-logo">
      <img src={~p"/images/phoenix.png"} alt="Phoenix Framework Logo" />
    </a>
  </section>
</header>
<main role="main" class="container">
  <.flash_group flash={@flash} />
  {@inner_content}
</main>
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/components/layouts/app.html.heex`

`<.flash_group>` 是 `CoreComponents` 里定义的两个 `<.flash>`（`:info` 和 `:error` 各一），内部用 `Phoenix.Flash.get(@flash, @kind)` 取消息，`:if` 判断没消息就不渲节点。所以"Item created successfully."显示一次之后，再刷新页面它就没了：GET `/items/5` 那次响应发出前，`before_send` 里走的是 `delete_session` 分支，session cookie 被重写，"phoenix_flash" 键已经不在了。

最外层还有 `root.html.heex` 这层骨架（doctype、`<head>`、三个 `<script>`），靠 pipeline 里的 `put_root_layout` 套上。渲染顺序是模板函数 → `app`（导航 + `<main>` + flash）→ `root`（HTML 骨架），`{@inner_content}` 是每一层的注入点。

## `ItemHTML` 与 `embed_templates`：模板就是函数

controller 侧看完了，转到渲染一侧。Phoenix 1.7 没有独立的 view 层，每个 controller 配一个 `*HTML` 模块：

```elixir
defmodule AuctionWeb.ItemHTML do
  @moduledoc """
  This module contains pages rendered by ItemController.

  See the `item_html` directory for all templates available.
  """
  use AuctionWeb, :html

  import PhoenixHTMLHelpers.Form, only: [datetime_select: 2]

  embed_templates "item_html/*"
end
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_html.ex`

模板参数里还有一个隐形的 `@conn`：`render` 会把 `conn` 自己放进 assigns，所以任何模板都能拿到 `@conn`，本章用不到，知道有就行。

- `use AuctionWeb, :html` 引入 `Phoenix.Component`（能写 `<.item_form ... />` 这种函数组件调用）、`import Phoenix.HTML`（转义）、`import AuctionWeb.CoreComponents`（`<.simple_form>`、`<.input>`、`<.button>`、`<.error>`、`<.label>`、`<.flash>` 全在这）以及 `~p` verified routes。
- `embed_templates "item_html/*"` 把同目录每个 `.heex` 文件编译成模块上的一个函数：`new.html.heex` 变成 `new(assigns)`，`item_form.html.heex` 变成 `item_form(assigns)`。文件名里两个扩展名都剥掉，所以 `render(conn, "new.html")` 最终调到的就是 `ItemHTML.new(assigns)`。
- `import PhoenixHTMLHelpers.Form` 那行是历史遗留的接法：`form_for`、`text_input`、`datetime_select` 这批 1.4 时代的表单 helper 被挪出了 `phoenix_html` 主包，单独住在 `phoenix_html_helpers` 依赖里（`mix.exs` 有 `{:phoenix_html_helpers, "~> 1.0"}`）。`ends_at` 字段要用 `datetime_select/2`，所以需要显式 import。

:::tip
controller 找哪个 `*HTML` 模块、套哪层 layout，默认都从 `use Phoenix.Controller` 的配置推出来：`ItemController` 自动对应 `ItemHTML`，layout 自动用 `AuctionWeb.Layouts` 的 `app`。单个 action 想打破默认可以用 `put_view/2` 和 `put_layout/2`：`conn |> put_layout(false)` 是裸渲（不套 layout），`put_view(conn, OtherHTML)` 换模板模块。本章六个 action 全走默认，一次都没用到它们。
:::

## `item_form.html.heex`：一个组件伺候两个 action

新建和编辑的表单字段完全一样，只是提交的 URL 不同，抽成一个函数组件：

```heex
<.simple_form :let={f} for={@changeset} action={@action}>
  <div :if={@changeset.action} class="alert alert-danger">
    Unfortunately, there are errors in your
    submission. Please correct them below.
  </div>

  <.input field={f[:title]} type="text" label="Title" />
  <.input field={f[:description]} type="textarea" label="Description" />

  <div class="form-group">
    <.label for={f[:ends_at].id}>Auction ends at</.label>
    {datetime_select(f, :ends_at)}
    <.error :for={msg <- Enum.map(f[:ends_at].errors, &translate_error/1)}>{msg}</.error>
  </div>

  <:actions>
    <.button>Submit</.button>
  </:actions>
</.simple_form>
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_html/item_form.html.heex`

这块模板信息密度高，逐段拆。

### `<.simple_form>` 展开后是 `<.form>` + `to_form`

`<.simple_form>` 本身只是 `CoreComponents` 里的一层薄包装：

```elixir
  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      {render_slot(@inner_block, f)}
      <div :for={action <- @actions} class="form-actions">
        {render_slot(action, f)}
      </div>
    </.form>
    """
  end
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/components/core_components.ex`

`for={@for}` 原样传给 `<.form>`，`{@rest}` 把 `action` 这类属性透传过去（`simple_form` 的 `rest` attr 用 `include` 白名单收下了 `action`、`method`、`enctype` 等）。真正的转换发生在 `<.form>` 内部：它调 `Phoenix.Component.to_form/2`，后者按数据的协议实现把 changeset 转成 `%Phoenix.HTML.Form{}`。`Ecto.Changeset` 的实现住在 phoenix_ecto 里，做的事可以列全：

- **`name`**：取 `changeset.data` 的 schema 模块名，下划线化成 `"item"`。表单 name 前缀由此而来，`item[title]` 进 `params["item"]["title"]`，就是 controller 里 `%{"item" => item_params}` 的来源。
- **`params`**：`changeset.params` 原样带上。这是失败重渲时输入回填的数据源。
- **`errors`**：`action` 是 `nil` 或 `:ignore` 时给空列表，否则给 `changeset.errors`。空表单不报红的机制在这。
- **`options` 里塞 `method`**：决定 `<form>` 写什么 method，规则下面单独说。
- **主键塞进 `hidden`**：`data` 的主键值（比如 `id`）收集起来留作隐藏字段。

`<.form>` 拿到 `%Phoenix.HTML.Form{}` 后渲染 `<form action=... method=...>`。两个隐藏 input 是它自动加的：method 不是 get/post 时先放一个 `name="_method"` 的隐藏框，method 是 post 时再放一个 `name="_csrf_token"` 的隐藏框给 `protect_from_forgery` 配对。`:let={f}` 把这个 form 对象以 `f` 的名字暴露给内部块，等价于旧写法 `form_for @changeset, @action, fn f ->`。

### `f[:field]` 和 `<.input>`：一个字段的全部要素打包

`f[:title]` 走的是 `%Phoenix.HTML.Form{}` 的 `Access` 实现，取出 `%Phoenix.HTML.FormField{}`，里面打包了 `id`（`item_title`）、`name`（`item[title]`）、`value` 和 `errors`（从 `form.errors` 里按字段名过滤出来的那几条）。

`<.input field={f[:title]}>` 拿到这个 struct 后做两次分派（都在 `CoreComponents.input/1`）：先把 `errors` 逐条过 `translate_error` 转成显示文本、把 `name`/`value` 填进 assigns，再按 `type` 选模板。`type="textarea"` 走 textarea 分支，其余走普通 `<input>` 分支。每个分支都干同样三件事：渲染 label、渲染带 `is-invalid` 样式类的输入框（`@errors != []` 时加）、用 `<.error :for>` 逐条列出错误。

字段值从哪来是 `input_value` 定死的顺序：`changes` → `params` → `data`。首次打开编辑页，`changes` 空、`params` 空，用 `data` 里的旧值回填；校验失败重渲，`params` 里是这次提交的原始输入，用户敲的东西一个字符不丢。

把一条错误消息从 context 走到 `<span class="help-block">` 的完整旅程串一遍：`validate_length(:title, min: 3)` 在 changeset 上留下 `[title: {"should be at least %{count} character(s)", [count: 3, ...]}]` 这条 `errors` 记录 → Repo 拒绝后 changeset 带着 `action: :insert` 回到 controller → `FormData.to_form` 因为 `action` 非 `nil` 把 `errors` 原样塞进 `%Phoenix.HTML.Form{}` → `f[:title]` 的 `Access.fetch` 按字段名过滤出这一条 → `<.input>` 里 `Enum.map(field.errors, &translate_error(&1))` 把 `{msg, opts}` 元组经 Gettext 翻成 `should be at least 3 character(s)`（`count: 3` 插进 `%{count}`）→ `<.error :for>` 逐条渲成 span。每个环节都是纯数据变换，没有一处隐藏的字符串拼接。

### `datetime_select`：不属于 `<.input>` 的控件

`ends_at` 是 `:utc_datetime`，`phoenix_ecto` 上报的输入类型是 `datetime_select`，但 `<.input>` 的 `type` 白名单里没有这个值，所以它退回 1.4 时代的写法：`datetime_select(f, :ends_at)` 渲染年、月、日、时、分五个 `<select>`。五个下拉的 name 分别是 `item[ends_at][year]`、`item[ends_at][month]` 这样，提交后在 params 里又聚合回嵌套 map `%{"ends_at" => %{"year" => "2026", "month" => "11", ...}}`，`cast` 再把它组装成 `~U[...]` 交给 `:utc_datetime` 字段，日期在参数层和字段层之间的来回拆装全自动。

`datetime_select` 没有 `<.input>` 那种自动错误展示，所以模板里手写了一行 `<.error :for={msg <- Enum.map(f[:ends_at].errors, &translate_error/1)}>{msg}</.error>`：先取 `f[:ends_at].errors`（`{msg, opts}` 元组列表），`translate_error/1` 经 Gettext 翻成文本（`opts[:count]` 存在时走 `dngettext` 的复数规则），再逐个渲成 `<span class="help-block">`。

### `<div :if={@changeset.action}>`：顶部总错误条

`:if` 是 heex 的条件指令，表达式为真才渲染这个节点。`@changeset.action` 是 `nil`（首次进表单页）时不显示，是 `:insert` 或 `:update`（刚被 Repo 拒绝）时显示。注意它判断的是 changeset 而不是 form 对象，因为模板的 assigns 里拿到的还是原 changeset，`to_form` 的转换只发生在 `<.form>` 内部。

### `<:actions>` slot

`<.simple_form>` 声明了 `slot :actions`，写在 `<:actions>...</:actions>` 里的内容会渲到 `<div class="form-actions">` 中，凑在表单末尾。可以放多个 slot 实例，`:for={action <- @actions}` 逐个渲染。

## `new.html.heex` 和 `edit.html.heex`：同一个表单，不同的 URL

有了共享组件，两个页面薄得只剩标题和一行调用：

```heex
<h1>New Item</h1>

<.item_form changeset={@changeset} action={~p"/items"} />
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_html/new.html.heex`

```heex
<h1>Edit {@changeset.data.title}</h1>

<.item_form changeset={@changeset} action={~p"/items/#{@changeset.data}"} />
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_html/edit.html.heex`

- `edit` 的标题用 `{@changeset.data.title}`：`changeset.data` 就是传进 `Item.changeset/2` 的那个原始 Item，"修改前"的值随时可取；`changeset.changes` 里则是"将要改成"的值。
- `~p"/items/#{@changeset.data}"` 里嵌的是整个 struct，`Phoenix.Param.to_param/1` 取它的 `id`。新建表单不能这么写，因为 `%Item{}` 的 `id` 是 `nil`，`to_param` 会直接抛 `ArgumentError`；语义上新建本来就该 POST 到集合路径 `/items`。
- 两个模板都没写 HTTP method。`<.form>` 不看 `action` 长什么样，只看 changeset 底层数据的状态，规则在 phoenix_ecto 的 FormData 实现里，两行：

```elixir
    defp form_for_method(%{__meta__: %{state: :loaded}}), do: "put"
    defp form_for_method(_), do: "post"
```

`ch09/auction_umbrella/deps/phoenix_ecto/lib/phoenix_ecto/html.ex`

`edit` 的 changeset 包着从库里读出的 struct，`__meta__.state == :loaded`，所以 method 取 `"put"`；`<.form>` 发现它不是 get/post，就把 `<form>` 写成 `method="post"` 再加 `<input type="hidden" name="_method" value="put">`。`new` 的 changeset 包着空的 `%Item{}`（`state` 是 `:built`），method 就是 `"post"`。同一个 `<.item_form>` 组件不需要一个 if/else，新建和编辑的区别全编码在 changeset 自己身上。

编辑表单实际渲出来的样子（`id` 和 token 是运行时值，做了截断）：

```html
<form action="/items/1" method="post">
  <input name="_method" type="hidden" hidden value="put">
  <input name="_csrf_token" type="hidden" hidden value="cVItN...">
  <input id="item_title" name="item[title]" type="text" value="Road Bike" ...>
  ...
</form>
```

浏览器只会发出 `POST /items/1`，`Plug.MethodOverride` 读到 `_method=put` 之后把 method 改写成 PUT，路由才匹配到 `:update`。后面 `_method` 一节把整条链再完整过一遍。

## `index` 和 `show`：没有表单的两页

```heex
<ul>
  <li :for={item <- @items}>
    <strong><a href={~p"/items/#{item}"}>{item.title}</a></strong> — {item.description}
  </li>
</ul>
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_html/index.html.heex`

```heex
<h1>{@item.title}</h1>

<ul>
  <li><strong>Description:</strong> {@item.description}</li>
  <li><strong>Auction ends at:</strong> {@item.ends_at}</li>
</ul>
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_html/show.html.heex`

`:for={item <- @items}` 是 heex 的列表推导指令，等价于旧 eex 的 `<%= for ... do %>` 块。链接全部走 `~p`，拼错路径在编译期就报警，不用等 404。

注意到两页都没有放"编辑"入口，也没有"新建"链接：index 只有标题列表，show 只有字段展示。页面之间的导航此时全靠 URL：`/items/new`、`/items/:id/edit` 得手输。这不是疏忽，是这个阶段故意的留白，入口和权限要一起设计，下一章加了登录之后，导航栏才有东西可挂。

## `_method`：HTML 只会 GET 和 POST，PUT/DELETE 全靠演

到这里还差最后一块拼图。路由表里 `PATCH /items/:id`、`PUT /items/:id`、`DELETE /items/:id` 这些方法，HTML 规范里的 `<form>` 根本不会发，它只认 GET 和 POST。REST 动词是靠一个约定参数 `_method` 模拟出来的，整个模拟链在仓库里有两条具体路径。

**表单路径**：`<.form>` 已经把 `_method=put` 藏进编辑表单（上一节讲过）。这条链路不需要任何 JavaScript。

**链接路径**：要在一个链接上发 DELETE，写法是 `<.link href={~p"/items/#{item}"} method="delete">`，渲染出来的 `<a>` 带 `data-method="delete"`、`data-to` 和 `data-csrf` 三个属性。点击时 `phoenix_html.js` 的全局 click 监听器发现这两个 `data-*`，就动态造一个隐藏表单提交掉：

```js
  function handleClick(element, targetModifierKey) {
    var to = element.getAttribute("data-to"),
        method = buildHiddenInput("_method", element.getAttribute("data-method")),
        csrf = buildHiddenInput("_csrf_token", element.getAttribute("data-csrf")),
        form = document.createElement("form"),
        submit = document.createElement("input"),
        target = element.getAttribute("target");

    form.method = (element.getAttribute("data-method") === "get") ? "get" : "post";
    form.action = to;
    form.style.display = "none";
    // ...
    form.appendChild(csrf);
    form.appendChild(method);
    document.body.appendChild(form);

    submit.type = "submit";
    form.appendChild(submit);
    submit.click();
  }
```

`ch09/auction_umbrella/apps/auction_web/priv/static/assets/phoenix_html.js`

点击被换成一次 POST 提交，body 里带 `_method=delete` 和 `_csrf_token`。同一个文件里还有个 `phoenix.link.click` 监听处理 `data-confirm`（弹 `window.confirm` 确认框）。这个脚本在 `root.html.heex` 里加载，跟在 `phoenix.js` 后面：

```heex
    <script defer phx-track-static src={~p"/assets/phoenix.js"}>
    </script>
    <script defer phx-track-static src={~p"/assets/phoenix_html.js"}>
    </script>
    <script defer phx-track-static src={~p"/assets/app.js"}>
    </script>
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/components/layouts/root.html.heex`

**服务端接住 `_method`** 的是 endpoint 里那个不起眼的一行：

```elixir
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug AuctionWeb.Router
```

`ch09/auction_umbrella/apps/auction_web/lib/auction_web/endpoint.ex`

`Plug.MethodOverride` 只做一件事：检查 POST 请求的 body 里有没有 `_method`，有就把 `conn.method` 改写成那个值。它的位置不能挪：必须在 `Plug.Parsers` 之后（body 得先解析出来 `_method` 才读得到），必须在 `Router` 之前（分发前 method 就得改掉）。改写之后路由表里 `PUT /items/:id` 命中 `update`，`DELETE /items/:id` 命中 `delete`。

顺路把 `_csrf_token` 的归宿也说清楚：pipeline 里的 `protect_from_forgery` 对非 GET 请求要比对 `params["_csrf_token"]` 和 session 里存的 token，对不上就是 403，整个请求根本到不了 controller。`<.form>` 自动渲染的隐藏框、`phoenix_html.js` 复制进动态表单的 `data-csrf`，喂的都是这个 plug。所以"删一条数据"这种操作没有 JS 也能跑（纯 `_method` 表单），但少了 CSRF token 谁也别想跑，伪造站点的表单拿不到签名 token。

**那为什么没有删除商品的按钮？** 因为路由的 `only:` 把 `:delete` 排除了，`ItemController` 也没有 `delete` action，模板上自然没有 `method="delete"` 的链接。但 context 的口子留着：

```elixir
  def delete_item(%Auction.Item{} = item), do: @repo.delete(item)
```

`ch09/auction_umbrella/apps/auction/lib/auction.ex`

要放开删除，就是路由 `only:` 里加 `:delete`、controller 补一个 `delete` action、详情页放一个 `method="delete"` 链接，三段各一行的事，整条 `_method` 链路已经在等它。下一章的 `delete "/logout"` 路由和 `Log out` 链接用的就是这套机制。

## 一次提交的完整旅程

把 `create` 成功那次 POST 从头到尾串一遍，本章所有部件都在这条线上：

```
POST /items
  body: _csrf_token=...&item[title]=Road Bike&item[ends_at][year]=2026&...
    │
    ▼
Endpoint: Plug.Parsers 解析 body → conn.body_params = %{"item" => %{...}}
          Plug.MethodOverride（body 里没有 _method，放行）
          Plug.Session → fetch cookie 里的 session
    │
    ▼
Router → :browser pipeline
          accepts → fetch_session → fetch_flash → protect_from_forgery
          → put_secure_browser_headers → put_root_layout
    │
    ▼
ItemController.create(conn, %{"item" => item_params})
    │
    ▼
Auction.insert_item(params) → Item.changeset → Repo.insert → {:ok, item}
    │
    ▼
put_flash + redirect → send_resp 302, Location: /items/5
  before_send 钩子把 flash 写进 session cookie
    │
    ▼
浏览器 GET /items/5（session cookie 带回）
  fetch_flash 把 "phoenix_flash" 读进 assigns
    │
    ▼
ItemController.show → ItemHTML.show(assigns) → Layouts.app → Layouts.root
  <.flash_group> 渲出 "Item created successfully."，响应发出前 flash 从 session 删除
```

失败路径在前半段完全一样，分叉只在 `case` 那里：`{:error, changeset}` 不 redirect、不写 session，同一个 conn 上 `render(conn, "new.html", changeset: changeset)` 直接返回 200，用户看到的就是带错误的原表单。

## 动手验证

在 umbrella 根目录准备依赖、库和服务：

```bash
cd ch09/auction_umbrella
mix deps.get
mix ecto.create && mix ecto.migrate
mix phx.server
```

先看路由表。umbrella 项目里 `mix phx.routes` 必须显式给 Router 模块：

```bash
mix phx.routes AuctionWeb.Router
```

输出应该和这张表一致：

```
  GET    /                AuctionWeb.PageController :index
  GET    /items           AuctionWeb.ItemController :index
  GET    /items/:id/edit  AuctionWeb.ItemController :edit
  GET    /items/new       AuctionWeb.ItemController :new
  GET    /items/:id       AuctionWeb.ItemController :show
  POST   /items           AuctionWeb.ItemController :create
  PATCH  /items/:id       AuctionWeb.ItemController :update
  PUT    /items/:id       AuctionWeb.ItemController :update
```

PATCH 和 PUT 两行都指向 `:update`，没有 DELETE 行。然后浏览器里把表单闭环走一遍：

1. 打开 `http://localhost:4000/items/new`，什么都不填直接 Submit。页面原地重新渲染，顶部出现 "Unfortunately, there are errors in your submission."，Title 下方是 `can't be blank`。看地址栏：URL 是 `/items`（POST 的目标），不是 `/items/new`，这是 `render` 而不是 `redirect` 的签名。再刷新会弹浏览器的"重新提交表单"确认。
2. 输入一个两字符的 title 再提交，错误换成 `should be at least 3 character(s)`，`validate_length(:title, min: 3)` 生效，刚才输入的两个字符回填在框里。
3. 把 ends_at 选成过去的日期，提交后 `ends_at` 下面出现 `ends_at cannot be in the past`，这是 `Item.changeset/2` 里 `validate_change` 的自定义错误。
4. 全部填合法提交，被 302 带到 `/items/:id`，页面顶部出现 `alert-info` 提示 "Item created successfully."。再刷新一次提示消失，数据还在。
5. 回到 `/items` 点标题进详情，地址栏改成 `/items/:id/edit` 进编辑页。开发者工具里看这个表单：`<form method="post" action="/items/5">`，内部藏着 `<input name="_method" type="hidden" hidden value="put">` 和 `<input name="_csrf_token" type="hidden" hidden value="...">`。改个 title 提交，flash 变成 "Item updated successfully."。

最后跑测试。根目录 `mix test` 会触发 alias 里的 `ecto.create --quiet` 和 `ecto.migrate`，然后两个应用各自跑 ExUnit：

```bash
mix test
```

`auction` 的 `auction_test.exs` 用 SQL Sandbox 包住 `list_items/0` 断言，`auction_web` 的 `page_controller_test.exs` 里 `Auction.insert_item(%{title: "test item"})` 直接插数据再断言首页能渲出来，总共 4 个测试全绿。

## 小结

本章把 Item 的 CRUD 页面全部接通，值得带走的脉络：

- `resources "/items"` 按 REST 惯例展开成"表单页 + 提交处理"成对的路由，`only:` 控制开放范围，PATCH/PUT 共享 `:update`。
- 表单页和提交处理是两个请求，changeset 是跨越它们的载体：字段清单、当前值、校验状态、提交历史（`action`）全打包在一个 struct 里。
- `<.simple_form for={@changeset}>` 内部 `to_form` 转 `%Phoenix.HTML.Form{}`，name 前缀生成 `"item"` 参数 map，`f[:field]` 取 `%Phoenix.HTML.FormField{}` 交给 `<.input>`；method 由 `__meta__.state` 决定，loaded 变 PUT，新建是 POST。
- 写库成功 `put_flash` + `redirect` 构成 PRG，消息借 session cookie 活一个请求；失败原地 `render`，因为 errors 和用户输入只在请求内存在。
- HTML 只认 GET/POST，PUT/DELETE 靠 `_method` 演：表单藏隐藏 input，链接交给 `phoenix_html.js` 造表单，服务端 `Plug.MethodOverride` 在 body 解析后、路由分发前改写 method。

商品能建能改了，但它们还是无主之物：任何人打开浏览器就能改任何拍品。给它加主人分两步，下一章先做前半：users 表、`pbkdf2` 密码哈希和用户注册；登录和守门 plug 再下一章接上。
