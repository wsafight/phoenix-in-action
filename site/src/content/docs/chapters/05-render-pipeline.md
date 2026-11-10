---
title: 第5章 · 渲染管线
description: 从 *_html 模块与 embed_templates 讲到 heex 模板函数、Layouts 外壳、flash 组件、错误页和 priv/static 静态资源组织
sidebar:
  order: 5
---

上一章走完了请求方向的管道：Bandit 监听、Endpoint 的 plug 链、Router 分发，最后 `PageController.index/2` 调 `render(conn, "index.html", items: items)` 交出 conn。本章把 `render/3` 的出口端拆开：模板怎么被编译成函数、外壳怎么套、错误页怎么按格式分发、静态资源在没有打包器之后怎么服务。这一段没有新的概念类型，渲染同样是函数：输入 assigns、输出 iodata。

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

`@flash` 是 `fetch_flash` plug 放进 `conn.private.phoenix_flash` 的 flash map，渲染时被复制进 assigns。目前还没有代码写过 flash，两个组件渲染出来是空的；等第 8 章 `put_flash` 出现，这里才会真的显示提示。

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

留占位而不是删掉，是因为这个文件同时回答两个问题：JS 资源以后放哪（`priv/static/assets`，直接当静态文件发），和 Channel 的客户端代码长什么样（注释里的 `new Phoenix.Socket("/socket", ...)`，正是 Endpoint 里 `socket "/socket"` 声明对应的客户端）。第 12 章把它取消注释就能用。

CSS 那头简单得多：`app.css` 是一份 Milligram 骨架样式加几条项目自定义规则（`alert-info`、`phx-logo`、header 布局），layout 里的 `.container` 和导航条靠的就是它。没有打包器也没有 import 链，一个文件就是全部样式，对这本书的页面量够用了。

## 动手验证

在 umbrella 根目录启动：

```sh
cd ch06/auction_umbrella
mix deps.get
mix phx.server
```

请求首页：

```sh
curl -i http://localhost:4000/
```

响应 HTML 里能搜到三条商品，比如：

```html
<strong>My first item</strong>: A tasty item sure to please
```

这三条数据来自 `auction` 应用的 `FakeRepo`：`PageController.index/2` 读出来放进 assigns，`index.html.heex` 用 `:for` 渲染成 `<li>`，再由 `app.html.heex` 套成完整的 HTML 文档——就是这一章走完的那条路。

再试一个静态文件：

```sh
curl -i http://localhost:4000/assets/app.css
```

`Plug.Static` 在链的最前面就返回了，`x-request-id` 这类 header 都没有，它没走到链的下半截。

再触发一个 404：

```sh
curl -i http://localhost:4000/nope
```

开发模式下拿到的不是 `ErrorHTML` 渲染的 "Not Found"，而是 Phoenix 的调试错误页——`dev.exs` 里 `debug_errors: true` 把异常拦截下来给你看堆栈和路由表，`render_errors` 在生产环境才接管。`ErrorHTML` 自己的行为由测试保证：

```elixir
  test "renders 404.html" do
    assert render_to_string(AuctionWeb.ErrorHTML, "404", "html", []) == "Not Found"
  end
```

`ch06/auction_umbrella/apps/auction_web/test/auction_web/controllers/error_html_test.exs`

`render_to_string` 不走 HTTP，直接调渲染模块的模板函数，正好印证了"模板就是函数"——测试绕开整个 plug 链也能拿到渲染结果。

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

`render/3` 之后的出口端：

```
render(conn, "index.html", items: items)
    → phoenix_format 协商出 :html
    → PageHTML "index.html" 模板函数（assigns → Rendered 树）
    → Layouts "app" 模板函数（{@inner_content} 注入外壳）
    → send_resp → iodata 流给 Bandit
```

模板不是运行时读的文件，是编译进模块的函数；layout 不是包裹语法，是第二次函数调用；错误页只是另一组按 format 分发的渲染模块；静态资源连函数都不经过，`Plug.Static` 在链头直接读盘。整条渲染管线没有一个"框架在背后做的事"：assigns 进、iodata 出，中间全是可以在仓库里指到具体行的函数。

`auction_web` 的分工图到这里补齐了：Endpoint 管所有请求都要做的事，Router 管按路径和客户端形态分流，Controller 管 HTTP 和领域之间的翻译，`*_html`、`Layouts`、错误模块管把 assigns 变成响应体。

下一章离开 Web 层回到领域侧：第 6 章把 `FakeRepo` 换成真的 Ecto Repo，`Auction.list_items()` 开始查 PostgreSQL，商品数据从内存列表变成数据库表。
