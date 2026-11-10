# Phoenix 1.4 → Phoenix 1.7/1.8 迁移规范

本仓库所有章节代码统一迁移到现代 Phoenix 写法。以下规范适用于每个章节。

## 版本与依赖

- Elixir `~> 1.14`（本地验证环境：Elixir 1.20 / OTP 29）
- Phoenix `~> 1.7.0`，`phoenix_pubsub ~> 2.1`，`phoenix_ecto ~> 4.5`，
  `ecto_sql ~> 3.10`，`postgrex >= 0.0.0`，`phoenix_html ~> 4.1`，
  **`phoenix_live_view ~> 1.0`**（必须：Phoenix.Component、`~H` sigil、
  `attr`/`slot`、CoreComponents 都在这个包里，没有它 heex 组件无法编译），
  `phoenix_live_reload ~> 1.2`（仅 dev），`gettext ~> 0.26`，
  `jason ~> 1.2`，`bandit ~> 1.5`（替代 plug_cowboy），`dns_cluster ~> 0.1.1`，
  `pbkdf2_elixir ~> 2.0`（替换 comeonin + pbkdf2_elixir 0.12），`timex ~> 3.7`
- `mix.exs`：删除 `compilers: [:phoenix, :gettext] ++ Mix.compilers()` 整行；
  添加 `listeners: [Phoenix.CodeReloader]` 不适用——仅按 1.7 生成器模板即可。

## mix.exs aliases

```elixir
setup: ["deps.get", "ecto.setup"],
"ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
"ecto.reset": ["ecto.drop", "ecto.setup"],
test: ["ecto.create --quiet", "ecto.migrate", "test"]
```

## 配置文件

- `use Mix.Config` → `import Config`；`config/prod.secret.exs` → `config/runtime.exs`
- **Umbrella 必须注意**：`import_config` 不接受通配符路径，
  `import_config "../apps/*/config/config.exs"` 会直接抛 `File.Error`，
  连 `mix deps.get` 都跑不了。两种修法任选其一：
  a) 把 `apps/*/config/*.exs` 全部合并到 umbrella 根的 `config/`
  （config/dev/prod/test/runtime.exs），删掉各 app 自己的 config 目录——
  这正是 1.7 生成器的结构；
  b) 保留各 app 的 config，但在根 config 里用 `Path.wildcard` 显式展开：
  `for config <- "../apps/*/config/config.exs" |> Path.expand(__DIR__) |> Path.wildcard(), do: import_config config`
  （本仓库采用此方案，保留各应用独立的 dev/test 配置）
- Endpoint 中删除 `pubsub:` 选项；在 `application.ex` children 中加
  `{Phoenix.PubSub, name: AuctionWeb.PubSub}`（或对应 OTP app 名 + `.PubSub`）
- `dev.exs`：删除 webpack/node watchers
- `config :phoenix, :json_library, Jason` 保留
- endpoint 加 `adapter: Bandit` 可选；保留 `plug_cowboy` + `adapter: Phoenix.Endpoint.Cowboy2Adapter` 亦可。统一用 Bandit：`{:bandit, "~> 1.5"}`，endpoint 里 `adapter: Bandit.PhoenixAdapter`，可去掉 `plug_cowboy`。

## Web 层结构（Phoenix 1.7 风格）

- `lib/auction_web.ex`（或 `blog_web.ex`）按 Phoenix 1.7 生成器重写：`controller/0`、
  `html/0`、`router/0`、`channel/0`、`verified_routes/0`（`use Phoenix.VerifiedRoutes`，
  **Phoenix 1.7.x 中选项名是 `statics:`**：`statics: ~w(assets fonts images favicon.ico robots.txt)`；
  `static_paths:` 是 1.8 的名字，写错会导致所有 ~p 静态路径报警告）、`gettext/0`
- 视图层：`lib/auction_web/views/*_view.ex` → `lib/auction_web/controllers/*_html.ex`，
  `use AuctionWeb, :html` + `embed_templates "item_html/*"` 等；
  `error_view.ex` → `controllers/error_html.ex` + `controllers/error_json.ex`；
  `layout_view.ex` → `components/layouts.ex`（`embed_templates "layouts/*"`），
  模板移到 `components/layouts/app.html.heex`
- `templates/` 目录移到 `controllers/<name>_html/*.html.heex`，
  `.eex` → `.heex`。heex 语法要点：属性中的 `<%= expr %>` 改为 `{expr}`；
  `link_to` → `~p` sigil 配合 `<.link navigate={~p"..."}>` 或 `<a href={~p"..."}>`；
  `form_for` → `<.form :let={f} for={@changeset} action={...}>`；
  表单控件用 CoreComponents 的 `<.input field={f[:field]} type="text" />`；
  flash 用 `<.flash_group flash={@flash} />` 或 `<.flash kind={:info} flash={@flash} />`
- `templates/layout/app.html.eex` → `components/layouts/app.html.heex`，
  `<%= @inner_content %>` → `{@inner_content}`；若原模板用 `get_flash`，
  改用 `<.flash_group flash={@flash} />`（需在 conn_case/测试中注意 flash 结构），
  或简化：`Phoenix.Flash.get(@flash, :info)` 渲染 `<p>`
- 新增 `components/core_components.ex`：采用 Phoenix 1.7 生成器版本的
  精简 CoreComponents（保留 `flash/1`、`flash_group/1`、`header/1`、
  `input/1`、`form/1`、`button/1`、`error/1`、`label/1`、`table/1`、`list/1`、`back/1`、`icon/1` 中实际用到的），
  `use Phoenix.Component`，`use Gettext, backend: AuctionWeb.Gettext`
- `error_helpers.ex` 删除；错误标签用 CoreComponents `error/1`
- `gettext.ex` 后端模块本身：`use Gettext.Backend, otp_app: :auction_web`；
  各模块引用处：`use Gettext, backend: AuctionWeb.Gettext`
  （`import AuctionWeb.Gettext` 旧写法删除）
- `router.ex`：`use AuctionWeb, :router`；`pipe_through` 不变；
  `forward`/`resources` 不变。controller 里 `Routes.item_path(@conn, ...)` → `~p"/items/#{id}"`；
  保留 controller 中 `redirect(to: ~p"/")` 写法
- `endpoint.ex`：live reload socket 写法改为
  `socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket`（仅 dev，
  包在 `if code_reloading?` 或 env 判断之外直接放也行，生成器是在 endpoint 模块顶层
  `if Application.compile_env(:auction_web, :code_reloading?)` 包裹）；
  按 1.7 生成器 endpoint 模板重写，`socket "/live", Phoenix.LiveView.Socket` 不需要
- `user_socket.ex`：保留，`use Phoenix.Socket`；`transport` 不变
- `application.ex`：children 顺序 `{Phoenix.PubSub, ...}`、`AuctionWeb.Endpoint`

## 密码哈希

- `comeonin` + `pbkdf2_elixir ~> 0.12` → `pbkdf2_elixir ~> 2.0`；
  `Comeonin.Pbkdf2.hashpwsalt(p)` → `Pbkdf2.hash_pwd_salt(p)`；
  `Comeonin.Pbkdf2.checkpass(p, h)` → `Pbkdf2.verify_pass(p, h)`；
  `Comeonin.Pbkdf2.dummy_checkpw()` → `Pbkdf2.no_user_verify()`

## 资产（去掉 webpack/npm）

- 删除 `assets/` 目录及 `package.json`、`webpack.config.js`、`yarn.lock`、`package-lock.json`
- `assets/css/phoenix.css` + `app.css` 合并为 `priv/static/assets/app.css`
- `assets/js/app.js` + `socket.js` 合并为 `priv/static/assets/app.js`，去掉 ES import：
  `import { Socket } from "phoenix"` → 用 `window.Phoenix.Socket`；
  在布局中 `<script defer src=".../phoenix.js">` 之前引入
  `deps/phoenix/priv/static/phoenix.js`——不能引 deps 路径，
  改为把 `deps/phoenix/priv/static/phoenix.js` 复制到 `priv/static/assets/phoenix.js`，
  布局模板中按顺序 `<script defer phx-track-static src={~p"/assets/phoenix.js"}>`、
  `<script defer phx-track-static src={~p"/assets/app.js"}>`
- `assets/static/*` → `priv/static/`（favicon、images、robots.txt）

## 测试支持文件

- `conn_case.ex`、`channel_case.ex`：按 1.7 风格，`use AuctionWeb, :verified_routes` 不需要；
  保留 `import Phoenix.ConnTest`、`import Plug.Conn`；`using` 块中
  `import Phoenix.ConnTest` 等不变，`@endpoint AuctionWeb.Endpoint` 不变
- `data_case.ex` 基本不变

## 验证

- 在 umbrella 根目录（或应用根目录）执行：`mix deps.get` → `mix compile`，
  要求 0 错误。警告尽量修复（deprecation warnings 必须修）。
- 运行 `mix format`（各 app 目录及 umbrella 根）。
- 不改公共 API 语义；不 git commit。

## 已知陷阱

- Phoenix 1.7 中 `Phoenix.View` 不存在 → 必须转 component/html 写法
- `Phoenix.Controller.get_flash/1` 在 1.7 仍存在但返回 map；模板里建议 `<.flash_group>`
- `render/3` in controller + `embed_templates` 的函数模板：controller `render(conn, "show.html", item: item)` 仍然工作
- `layout: false`/`put_layout` 用法：`put_layout(html: {AuctionWeb.Layouts, :app})`
- heex 里 `<script>` 块中不能有未转义的 `{`
- `Phoenix.HTML.Link.link/2` 在 phoenix_html 4 中存在但建议用 `<.link>` 组件或 `<a href={~p"..."}>`
