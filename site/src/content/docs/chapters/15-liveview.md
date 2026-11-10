---
title: 第15章 · LiveView 出价
description: 在 ch15 上给 item 详情页做一个 LiveView 版本：endpoint 挂 /live socket、UserAuthLive 注入 current_user、ItemLive.Show 用 phx-submit 出价、PubSub 消息驱动 handle_info 重渲染，把第 12 章手写的 socket.js 整段换掉
sidebar:
  order: 15
---

第 12 章的 Channel 是手工铺出来的实时链路：`app.js` 里 `new Phoenix.Socket`、
`channel.join()`、`on("new_bid")` 收到 payload 后
`insertAdjacentHTML` 往 DOM 里塞一段 HTML。能用，但前端那三十行 JS
全是重复 Phoenix 已经知道的事——表单提交、渲染、广播，每一步都在
服务端有对应的概念。

本章换一条路：LiveView。`{:phoenix_live_view, "~> 1.0"}` 从第 4 章起就躺在
`auction_web` 的 deps 里（heex、`~H`、function components 都来自它），
一直没被当 LiveView 用过。代码落在 `ch15/auction_umbrella`：上一章的
ch14 基础上，加一条 `/live` socket、一个 `ItemLive.Show` 模块、一条路由，
把 `app.js` 里那段手搓 channel 代码整段替换掉。

## LiveView 到底是什么

LiveView 是 Phoenix 1.7 的主流交互层。一个 LiveView 页面第一次进来是
普通的 HTML 请求（走 `:browser` pipeline，能拿到 session、能渲染成
完整页面）；页面加载完成后，客户端 JS 自动把这个页面升级成一条
WebSocket 长连接。之后发生的每件事——表单提交、点击、服务端推送——
都在这条连接上来回：浏览器发事件给 LiveView 进程，进程改 assigns，
LiveView 把 diff 算出来推回浏览器，浏览器局部更新 DOM。

和 Channel 的关系：LiveView 底层就是建在 Channel 上的，`/live` 那个
socket 和 `/socket` 是同族机制。差别是 LiveView 帮你把"事件进来→改
assigns→渲染→推回"这个循环做成了内置的 `handle_event`/`handle_info`/
`render` 三段式，你只管写状态变化，DOM 怎么同步不用管。

## 三处接线：endpoint、layout、路由

LiveView 需要一条自己的 socket。在 Endpoint 上加在 `/socket` 旁边：

```elixir
  # LiveView socket carries the same session as regular requests.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/endpoint.ex`

`websocket: [connect_info: [session: @session_options]]` 是 session 透传
的关键：LiveView 的握手 HTTP 请求本身也走 `Plug.Session`，`connect_info`
告诉 `Phoenix.LiveView.Socket` 把解出来的 session map 放进 WebSocket
连接，LiveView 进程 `mount` 时拿得到。

layout 那边补一行 script：

```heex
    <script defer phx-track-static type="text/javascript" src={~p"/assets/phoenix_live_view.js"}>
    </script>
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/components/layouts/app.html.heex`

`phoenix_live_view.js` 从 `deps/phoenix_live_view/priv/static/` 复制到
`priv/static/assets/`，顺序上排在 `phoenix.js` 之后、`app.js` 之前——
`LiveView.LiveSocket` 构造函数第二个参数要 `Phoenix.Socket`，前面的
`phoenix.js` 先把它挂上 `window`。

`app.js` 开头多出三行，负责把 LiveView 连上：

```javascript
// LiveView: connect on every page; pages without [data-phx-main] mounts stay inert.
let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: { _csrf_token: csrfToken }
})
liveSocket.connect()
```

`ch15/auction_umbrella/apps/auction_web/priv/static/assets/app.js`

`data-phx-main` 是 LiveView 在 DOM 里找到的锚点：有它，`liveSocket`
就把这个元素当成活的 LiveView 接进来；没有（比如 `/items` 列表页），
连接闲着，页面表现和一个普通 HTML 完全一样。

## 路由：live_session 管同一份登录态

```elixir
  # LiveView routes: same :browser pipeline for the initial HTML render,
  # then the socket upgrade picks the session up via connect_info.
  live_session :default,
    on_mount: [{AuctionWeb.UserAuthLive, :default}] do
    scope "/", AuctionWeb do
      pipe_through :browser

      live "/live/items/:id", ItemLive.Show, :show
    end
  end
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/router.ex`

`live "/live/items/:id"` 路由到 LiveView 模块而不是 controller，`use
AuctionWeb, :router` 里新加的 `import Phoenix.LiveView.Router` 让 `live`
宏在路由文件里能用。

`live_session :default` 把一组 LiveView 路由圈在一起：`on_mount` 列表
里的每个 `{模块, :default}` 在 mount 之前先执行，返回值 `{:cont, socket}`
放行、`{:halt, socket}` 截断。这正是浏览器侧 `Authenticator` plug 的
LiveView 版等价物，只是作用于 socket 生命周期而不是请求管线：

```elixir
defmodule AuctionWeb.UserAuthLive do
  @moduledoc """
  on_mount hook shared by LiveViews that need `current_user`.

  `live_session` copies the Plug session into the WebSocket `session` map, so
  the `user_id` written by `SessionController.create/2` arrives here verbatim.
  """

  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    user =
      case session["user_id"] do
        nil -> nil
        id -> Auction.get_user(id)
      end

    {:cont, assign(socket, :current_user, user)}
  end
end
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/live/user_auth_live.ex`

`session` 参数拿到的就是 `connect_info` 里解出来的那份 Plug session，
`session["user_id"]` 和 `get_session(:user_id)` 读到的是同一个值。
`Authenticator` 管请求方向的"你是谁"，`UserAuthLive` 管 WebSocket
方向的"你是谁"——两份代码做的是一件事，落在两个不同的插口上。

## ItemLive.Show：mount、render、handle_event

```elixir
defmodule AuctionWeb.ItemLive.Show do
  use AuctionWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AuctionWeb.PubSub, "item:#{id}")
    end

    socket =
      socket
      |> assign(:page_title, "Item #{id}")
      |> assign(:item, Auction.get_item_with_bids(id))
      |> assign(:form, to_form(Auction.new_bid()))

    {:ok, socket}
  end
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/live/item_live/show.ex`

`mount` 会跑两次：第一次是无状态的 HTML 渲染（`connected?` 是
`false`，不订阅 PubSub），第二次是 WebSocket 连接建立后的挂载（
`connected?` 为 `true`，订阅 `item:#{id}`）。这个 if 是"只有活着
的页面才需要收推送"的标准写法，没有它的订阅会让首屏渲染空跑一次。

`render/1` 是把 `item_html/show.html.heex` 抄成 `~H`：

```elixir
      <div style="flex: 1">
        <h2>Current bids</h2>
        <p :for={bid <- @item.bids} id={"bid-#{bid.id}"}>
          {integer_to_currency(bid.amount)} <em>from {bid.user.username}</em>
        </p>
      </div>

      <div style="flex: 1">
        <%= if @current_user do %>
          <h2>Place your bid!</h2>
          <.form :let={f} for={@form} phx-submit="save">
            <div class="form-group">
              <.input field={f[:amount]} type="number" label="Bid amount" />
            </div>
            <.button type="submit" phx-disable-with="Placing...">Submit</.button>
          </.form>
        <% else %>
          <p>
            <.link navigate={~p"/login"}>Log in</.link> to place a bid.
          </p>
        <% end %>
      </div>
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/live/item_live/show.ex`

和 heex 版相比改动只有两行：`phx-submit="save"` 代替
`action={~p"/items/#{@item}/bids"}`，`phx-disable-with` 让按钮提交
后变灰防重复点。`@form` 是 `to_form(Auction.new_bid())` 转出来的
`%Phoenix.HTML.Form{}`，`f[:amount]` 和 `<.input>` 的用法和 heex 版
完全一样——`new_bid()` 那个空 changeset 在这里照样是表单的骨架。

`handle_event` 替代了 `BidController.create` 的"成功/失败"分派：

```elixir
  @impl true
  def handle_event("save", %{"bid" => %{"amount" => amount}}, socket) do
    item = socket.assigns.item

    case Auction.insert_bid(%{
           amount: amount,
           item_id: item.id,
           user_id: socket.assigns.current_user.id
         }) do
      {:ok, _bid} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Auction.new_bid()))
         |> reload_item()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/live/item_live/show.ex`

浏览器发 `phx-submit="save"`，LiveView 进程收到事件调
`handle_event("save", params, socket)`。`params` 形状和表单 POST
body 一样：`%{"bid" => %{"amount" => "1200"}}`。两条分支对应
`BidController` 的两条：成功就重置表单（`to_form(new_bid())`）
再 `reload_item`（把新出价拉进 `@item.bids`，LiveView 算出 diff
把新的 `<p>` 推给浏览器）；失败就把 `{:error, changeset}` 直接
`to_form` 进 `@form`，`<.input>` 照常渲错误——没有 redirect、
没有第二次 render，状态就长在进程里。

## handle_info：PubSub 到 LiveView 的最后一公里

出价可能来自另一个浏览器、同一个 LiveView 在别处的调用、HTML
表单、或者上一章的 JSON API——`Endpoint.broadcast` 广播到哪，消息
就到哪。LiveView 进程自己也是 `Phoenix.PubSub` 的订阅者，广播
落到 `handle_info`：

```elixir
  # Another bid landed — either in this LiveView, in another browser tab, over
  # the HTML form, or through the JSON API. Refetch so `bids` keeps its
  # server-side ordering.
  @impl true
  def handle_info(%{event: "new_bid"}, socket) do
    {:noreply, reload_item(socket)}
  end
```

`ch15/auction_umbrella/apps/auction_web/lib/auction_web/live/item_live/show.ex`

`Endpoint.broadcast` 发出来的消息是 `%{event: "new_bid", payload:
%{body: "<p>...</p>"}}`；LiveView 这边不读 `body`，直接按 item id
重新 `get_item_with_bids`，让服务端排序和 preload 重新说了算。
代价是一次额外的查询，换来的是渲染路径唯一：首屏、表单提交、
外部推送，三条路都落到同一份 `render/1` 上，没有"服务端渲一份
HTML、前端再拼一份"的错位。

## 动手验证

```sh
cd ch15/auction_umbrella
mix setup
mix phx.server
```

**第一步：路由里多出一条 live。**

```text
  GET     /live/items/:id           AuctionWeb.ItemLive.Show :show
```

**第二步：浏览器打开 `http://localhost:4000/live/items/1`。** 页面
看起来和 `/items/1` 一样，但地址栏多了 `/live` 前缀。登录后再
看，表单出现（`@current_user` 由 `UserAuthLive` 注入）；不登录
就只有"Log in to place a bid"。

**第三步：出一个价。** 表单 `phx-submit` 触发 `handle_event("save")`，
提交后列表立刻多一条，输入框重置回空。这个"立刻"发生在
WebSocket 帧里：Network 面板里找不到 POST 请求。

**第四步：跨界面推送。** 另一个浏览器窗口停在 HTML 版的 `/items/1`
（Channel 那条路也在工作），在 LiveView 这边出一个价，HTML 那边
的 `insertAdjacentHTML` 照常把新出价插到顶部。反过来也成立：
HTML 或 API 出价，LiveView 这边的 `handle_info` 接到广播，重拉
`@item.bids` 把新条目插进列表——不用写一行 `channel.on`。

## 小结

- `use AuctionWeb, :live_view` 展开成 `use Phoenix.LiveView, layout:
  {AuctionWeb.Layouts, :app}` 加全套 `html_helpers`：LiveView 和
  `*_html` 共用同一批组件、同一份 `~p`、同一份 layout。
- `live "/live/items/:id"` 走 `:browser` 管线完成首屏，握手升级时
  `connect_info` 把 Plug session 带进 WebSocket，`live_session` 的
  `on_mount` 把 `user_id` 译成 `@current_user`。
- `handle_event`/`handle_info`/`render` 三段式把"事件→改 assigns→
  算 diff→推 DOM"做成了框架内建：`phx-submit` 不用写 fetch，
  `Endpoint.broadcast` 不用写 `channel.on`，`app.js` 那段手搓
  channel 代码整段删除。
- LiveView 没有换掉任何领域代码：`Auction.insert_bid`、
  `get_item_with_bids`、`new_bid` 一个参数没动，界面层换了一套
  交互协议，业务层完全无感。

下一章留在 `auction` 应用里加最后一块 OTP 部件：`BidCache`，一个
被监督树托管的 GenServer 缓存，看"让它崩"在真正的监督树里是怎么
兑现的。
