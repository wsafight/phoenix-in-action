---
title: 附录：Phoenix 1.4 → 1.7 迁移要点
description: 本仓库代码从 Phoenix 1.4 迁移到 1.7/1.8 时所做的全部改动
sidebar:
  order: 99
---

仓库中所有章节代码原本写于 Phoenix 1.4 时代，现已统一迁移到 Phoenix 1.7/1.8 的现代写法。
这份清单可以作为你自己迁移老 Phoenix 项目时的对照表。

## 依赖

| 旧 | 新 |
| --- | --- |
| `{:phoenix, "~> 1.4.0"}` | `{:phoenix, "~> 1.7.0"}` |
| `{:phoenix_pubsub, "~> 1.1"}` | `{:phoenix_pubsub, "~> 2.1"}` |
| `{:phoenix_ecto, "~> 4.0"}` | `{:phoenix_ecto, "~> 4.5"}` |
| `{:ecto_sql, "~> 3.0"}` | `{:ecto_sql, "~> 3.10"}` |
| `{:phoenix_html, "~> 2.11"}` | `{:phoenix_html, "~> 4.1"}` |
| `{:gettext, "~> 0.11"}` | `{:gettext, "~> 0.26"}` |
| `{:plug_cowboy, "~> 2.0"}` | `{:bandit, "~> 1.5"}` |
| `{:comeonin}` + `{:pbkdf2_elixir, "~> 0.12"}` | `{:pbkdf2_elixir, "~> 2.0"}` |

## mix.exs

```elixir
# 删除这一整行 —— Phoenix 1.7 不再需要专用编译器，Elixir 新版本也会报错
compilers: [:phoenix, :gettext] ++ Mix.compilers()
```

## 配置文件

- `use Mix.Config` → `import Config`
- `config/prod.secret.exs` → `config/runtime.exs`
- Endpoint 的 `pubsub:` 选项删除；在 `application.ex` 的 children 中加入：

```elixir
children = [
  {Phoenix.PubSub, name: AuctionWeb.PubSub},
  AuctionWeb.Endpoint
]
```

- `dev.exs` 中删除 webpack/node 的 watchers
- Endpoint 加 `adapter: Bandit.PhoenixAdapter`

## Web 层结构

```
旧（Phoenix 1.4）                          新（Phoenix 1.7）
lib/auction_web/views/item_view.ex     →  lib/auction_web/controllers/item_html.ex
lib/auction_web/views/error_view.ex    →  controllers/error_html.ex + error_json.ex
lib/auction_web/views/layout_view.ex   →  components/layouts.ex
templates/item/*.html.eex              →  controllers/item_html/*.html.heex
templates/layout/app.html.eex          →  components/layouts/app.html.heex
helpers/error_helpers.ex               →  components/core_components.ex
```

`*_html.ex` 模块形如：

```elixir
defmodule AuctionWeb.ItemHTML do
  use AuctionWeb, :html

  embed_templates "item_html/*"
end
```

## 模板语法

```heex
<%# eex %>                          <%# heex %>
<%= link "Edit", to: Routes.item_path(@conn, :edit, @item) %>
                                   <.link navigate={~p"/items/#{@item}/edit"}>Edit</.link>

<%= form_for @changeset, @action, fn f -> %>
                                   <.form :let={f} for={@changeset} action={@action}>

<%= error_tag f, :title %>         <.error :for={msg <- translate_errors(f.errors, :title)}>{msg}</.error>
                                   （或直接用 <.input field={f[:title]} />）

<%= @inner_content %>              {@inner_content}
```

注意 heex 中 HTML 属性里写 `{expr}` 而不是 `<%= expr %>`。

## 密码哈希

```elixir
# 旧
Comeonin.Pbkdf2.hashpwsalt(password)
Comeonin.Pbkdf2.checkpass(password, hash)
# 新（pbkdf2_elixir 2.x 内置了 comeonin 的功能）
Pbkdf2.hash_pwd_salt(password)
Pbkdf2.verify_pass(password, hash)
Pbkdf2.no_user_verify()   # 替代 dummy_checkpw
```

## Gettext

```elixir
# 旧
use Gettext, otp_app: :auction_web
# 新
use Gettext.Backend, otp_app: :auction_web
# 引用处
use Gettext, backend: AuctionWeb.Gettext
```

## 静态资源（去 webpack/npm）

- 删除 `assets/`、`package.json`、`webpack.config.js`、`yarn.lock`
- CSS 合并后放入 `priv/static/assets/app.css`
- JS 合并后放入 `priv/static/assets/app.js`；`import { Socket } from "phoenix"` 改为 `window.Phoenix.Socket`
- 把 `deps/phoenix/priv/static/phoenix.js` 复制到 `priv/static/assets/phoenix.js`，
  在布局中先于 `app.js` 引入：

```heex
<script defer phx-track-static src={~p"/assets/phoenix.js"}>
</script>
<script defer phx-track-static src={~p"/assets/app.js"}>
</script>
```

## 路由

```elixir
# 旧
Routes.item_path(@conn, :show, item)
Routes.item_path(@conn, :edit, item)
# 新（verified routes，编译期检查）
~p"/items/#{item}"
~p"/items/#{item}/edit"
```

完整的逐条规范见仓库根目录的 `MIGRATION.md`。
