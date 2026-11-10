---
title: 第12章 · Channel
description: 用 Phoenix Channel 把新出价实时推送到所有正在浏览该商品页面的浏览器，不再依赖刷新
sidebar:
  order: 12
---

上一章出价已经能落库：表单提交、`Bid.changeset` 校验、`Auction.insert_bid` 写入
数据库，出价者重定向回商品页能看到自己的出价。但还有一个明显的体验问题：A 用户
出价之后，B 用户开着的商品页什么都不会发生，得手动刷新才能看到那条新出价。拍卖
场景要求的是"有人出价，所有人立刻看到"。

HTTP 的请求/响应模型做不到这一点，服务器没法主动找浏览器。本章用 Phoenix Channel
补上这一环：让浏览器和服务器之间保持一条 WebSocket 长连接，出价入库后由服务端把
渲染好的 HTML 片段推给所有正在看这件商品的浏览器。

要拆清楚的就是一条消息路径：Endpoint 上的 `socket "/socket"` 入口 → `UserSocket`
（连接建立和 channel 路由声明）→ `ItemChannel`（浏览器按 `item:{id}` 订阅单个商品）
→ `BidController.create` 出价入库后广播渲染好的 HTML 片段 → 前端 `app.js` 收到后
把它插进出价列表。

## 为什么需要 Channel

"别人出的价"要实时出现，只有两条路：轮询或长连接。轮询是浏览器定时发请求问"有新
出价吗"，空跑的请求占绝大多数，而且实时性取决于轮询间隔，调快了费服务器，调慢了
有延迟。长连接是浏览器先和服务器握一次手，之后这条 TCP 连接不断开，两边随时能互
发消息。Phoenix 选了长连接，在 WebSocket 之上再包一层 Channel 抽象。

裸 WebSocket 只提供一个双向字节流，消息格式、订阅关系、断线重连全要自己设计。
Channel 在这之上约定了一整套协议：消息长什么样、怎么订阅一个"话题"、服务端收到后
路由给谁。这套抽象分三层：

- **Socket（`Phoenix.Socket`）**：一条长连接。一个浏览器标签页通常一条，上面可以
  挂载多个 channel。服务端对应 `%Phoenix.Socket{}` 结构体，装着 transport、assigns
  和握手元数据。
- **Channel（`Phoenix.Channel`）**：连接里的"话题"。每个 channel 有独立的 topic
  字符串，比如 `item:1` 表示"商品 1 的出价更新"。浏览器端是一个 `Channel` 对象，
  服务端是一个独立的进程（OTP 语义上的 GenServer），两边靠 socket 上复用的消息帧
  通信。一条 socket 上挂多少个 channel 都行，互不干扰，这就是多路复用：一个标签页
  一条连接，订阅了哪几个话题就并发收哪几个话题的消息。
- **PubSub（`Phoenix.PubSub`）**：服务器内部的消息总线。任意进程（比如处理表单提
  交的 controller）向某个 topic 广播一条消息，所有订阅该 topic 的 channel 进程都
  会收到，再各自推给挂在自己身上的浏览器客户端。广播发起方完全不需要知道谁在听、
  有几个人在听。

WebSocket 上跑的不是 HTTP 语义，消息是一个个 JSON 编码的数组：

```text
[join_ref, ref, topic, event, payload]
```

`topic` 决定消息归哪个 channel，`event` 是事件名，`ref` 用来把请求和响应对上号，
`join_ref` 标识这次 join 产生的 channel 实例。这段格式定义在 vendored 的 `phoenix.js`
里（`Serializer.encode` 把对象序列化成数组，`decode` 再还原回来），服务端对应
`%Phoenix.Socket.Message{}` 结构体。v2 协议还支持二进制编码，payload 是 ArrayBuffer
时走另一条路，本章用不到。

一次出价的完整路径：

```text
浏览器 A 提交出价表单
  → POST /items/:id/bids → BidController.create
    → Auction.insert_bid 落库
    → Phoenix.Template.render_to_iodata 渲染 bid.html 片段
    → AuctionWeb.Endpoint.broadcast("item:1", "new_bid", %{body: html})
      → Phoenix.PubSub 分发给所有订阅 "item:1" 的 channel 进程
        → 每个 channel 进程沿自己的 WebSocket push 给浏览器 A、B、C……
          → app.js 收到 "new_bid"，insertAdjacentHTML 插到列表顶部
```

注意广播的发起方是 controller，不是某个 channel。订阅 channel 的浏览器在这条链路
里纯"听"，不需要"说"。这种"任意的服务端事件 → 推给订阅者"正是 PubSub 形态的典型
用法：出价的产生者是一次 HTTP 请求，广播只是请求处理的副产品。下面按这条流向逐个
看文件。

## 在 Endpoint 挂载 socket

WebSocket 请求不经过 Router 和 pipeline，它由 Endpoint 直接接管，所以第一步是在
`endpoint.ex` 里声明挂载点：

```elixir
  socket "/socket", AuctionWeb.UserSocket,
    websocket: true,
    longpoll: false
```

`ch12/auction_umbrella/apps/auction_web/lib/auction_web/endpoint.ex`

`socket` 宏把路径 `/socket` 绑定到 `AuctionWeb.UserSocket` 模块。浏览器里写的
`new window.Phoenix.Socket("/socket")` 必须和这里的路径完全一致，否则握手 404。
实际建连时客户端会在这个路径后拼上 transport 名，真正打过来的 URL 是
`/socket/websocket?token=...&vsn=2.0.0`（拼法见 phoenix.js 的 `endPointURL()`），
这些细节 phoenix.js 帮你处理了，不用手写。

`websocket: true, longpoll: false` 表示只接受 WebSocket transport，不接受
long-polling 降级。phoenix.js 本身是支持 longpoll 的（Socket 构造器里
`transport: opts.transport || global.WebSocket || LongPoll`，还能用
`longPollFallbackMs` 配置 WebSocket 连不上时自动切换），服务端关掉降级后，不支持
WebSocket 的环境就直接连不上。本地开发和现代浏览器场景够用。

这个文件里还藏着第二个 socket：

```elixir
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end
```

`ch12/auction_umbrella/apps/auction_web/lib/auction_web/endpoint.ex`

`Phoenix.LiveReloader.Socket` 是开发环境"改完代码浏览器自动刷新"的实现，用的就是
同一套 Channel 机制，只是挂在另一个路径、另一个 socket 模块上。所以 Channel 不是新
东西，从生成项目那天起它就在 Endpoint 里占了一行，只是之前没有业务代码用到它。

还有一个容易漏掉的点：WebSocket 握手不流经 `plug AuctionWeb.Router`，自然也就不经过
`:browser` pipeline。`fetch_session`、`protect_from_forgery` 这些 plug 管不到它，
登录态、CSRF 这些"HTTP 请求"层面的机制要在 socket 层重新考虑。本章的 channel 只做
公开的出价订阅，不涉及认证；真要认证（比如只允许商品发布者订阅管理话题），入口是
`UserSocket.connect/3`，新版本 Phoenix 还能用
`websocket: [connect_info: [:session]]` 把 session cookie 递给它校验。

## UserSocket：连接层

一个 socket 模块对应一种连接。生成器给的骨架里我们真正用到的只有三处：channel
声明、`connect/3` 和 `id/1`：

```elixir
defmodule AuctionWeb.UserSocket do
  use Phoenix.Socket

  ## Channels
  channel "item:*", AuctionWeb.ItemChannel

  # Socket params are passed from the client and can
  # be used to verify and authenticate a user. After
  # verification, you can put default assigns into
  # the socket that will be set for all channels, ie
  #
  #     {:ok, assign(socket, :user_id, verified_user_id)}
  #
  # To deny connection, return `:error`.
  #
  # See `Phoenix.Token` documentation for examples in
  # performing token verification on connect.
  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  # Socket id's are topics that allow you to identify all sockets for a given user:
  #
  #     def id(socket), do: "user_socket:#{socket.assigns.user_id}"
  #
  # Would allow you to broadcast a "disconnect" event and terminate
  # all active sockets and channels for a given user:
  #
  #     AuctionWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  # Returning `nil` makes this socket anonymous.
  @impl true
  def id(_socket), do: nil
end
```

`ch12/auction_umbrella/apps/auction_web/lib/auction_web/channels/user_socket.ex`

三个角色分别干什么：

- **`channel "item:*", AuctionWeb.ItemChannel`**：声明式路由，相当于 socket 世界里
  的 `scope`。topic 以 `item:` 开头的 channel 请求都交给 `ItemChannel` 处理；`*`
  是通配符，匹配任意后缀，所以 `item:1`、`item:42`、`item:probe` 都进同一个模块。
  通配符只能出现在末尾，`item:*:bids` 这种写法不支持。一个 socket 模块里可以有多条
  `channel` 声明，按声明顺序匹配，先中先赢；浏览器如果 join 了一个没有任何规则匹配
  的 topic（比如 `socket.channel("foo:1")`），服务端会直接拒绝，客户端走
  `.receive("error", ...)` 分支。

- **`connect/3`**：整条 socket 建立时被调用一次，之后这条连接上所有 channel 的 join
  都不会再过它。三个参数里，`_params` 是浏览器 `new Socket(url, {params: ...})` 传
  进来的参数（跟着握手 URL 的 query string 上来），`_connect_info` 是连接信息
  （`:peer_data`、`:x_headers`，以及声明过的 `:session`）。认证就做在这里：校验
  `Phoenix.Token` 之类的凭证，通过后 `{:ok, assign(socket, :user_id, …)}`，assigns
  会传进这条 socket 上每个 channel 的 socket；不通过就返回 `:error`，握手被拒。我们
  的实现无条件 `{:ok, socket}`：出价列表本来就是公开的，谁都可以订阅。

- **`id/1` 返回 `nil`**：socket 是匿名的。注释里给的例子已经说明了它的用途：返回
  `"user_socket:#{user_id}"` 之后，同一个用户的所有连接（可能多个标签页、多台设备）
  共享一个 topic，可以用 `Endpoint.broadcast("user_socket:#{id}", "disconnect", %{})`
  把它们定向踢下线。`nil` 意味着这个应用不做这种定向操作。

这里的 `socket` 是服务端的 `%Phoenix.Socket{}` 结构体，不是浏览器那个 `Socket` 对象
的镜像。浏览器端 `channel()`/`on()` 操作的是客户端状态，服务端 `join`/`handle_in`
看到的是这个结构体和它上面的 assigns，两边只通过消息帧同步，不存在"读浏览器 socket
的字段"这种操作。

## ItemChannel：一个方向收，一个方向发

```elixir
defmodule AuctionWeb.ItemChannel do
  use AuctionWeb, :channel

  @impl true
  def join("item:" <> _item_id, _params, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_in("new_bid", params, socket) do
    broadcast!(socket, "new_bid", params)
    {:noreply, socket}
  end
end
```

`ch12/auction_umbrella/apps/auction_web/lib/auction_web/channels/item_channel.ex`

`use AuctionWeb, :channel` 展开后就是 `use Phoenix.Channel`（见 `auction_web.ex` 里的
`channel` quote，只有一行）。每个 join 成功的 channel 是服务端一个独立进程，挂着它
自己的 socket（里面记着 topic、join_ref、assigns 和底层 transport），崩溃只影响自己，
这是 channel 能放心用 OTP 语义写的原因。同一个客户端 join 多个 topic 就是多个进程，
同一 topic 被多个客户端订阅也是多个进程，一一对应。

**`join/3`：建立订阅。** 浏览器 `socket.channel("item:1", {}).join()` 发出的
`phx_join` 消息落到这个回调。三个参数是匹配到的 topic、客户端构造 channel 时给的参数
（这里是 `{}`）、channel 的 socket。模式 `"item:" <> _item_id` 用二进制前缀匹配兜住
所有商品 topic；返回值决定客户端 `.receive(...)` 链拿到什么：

- `{:ok, socket}`：放行，join 成功，客户端走 `"ok"` 分支；
- `{:ok, assigns_map, socket}`：放行并把 map 作为 join 响应发回客户端
  （`.receive("ok", resp)` 里能拿到，适合顺手下发当前状态，比如已有的成员列表）；
- `{:error, map}`：拒绝，客户端走 `"error"` 分支拿到 `{reason: "..."}`。

想按商品做权限控制（比如未上架的商品不许订阅），把 `_item_id` 用起来查库后返回
`{:error, %{reason: "item not found"}}` 即可。我们现在对 `_item_id` 不校验，直接放行。

**`handle_in/3`：处理浏览器推上来的消息。** 浏览器 `channel.push("new_bid", payload)`
发来的消息进这里，事件名做模式匹配，`params` 是浏览器给的原始 payload。这个实现把
payload 原样 `broadcast!` 给所有订阅者（包括发起者自己），相当于一个 echo 中继。
返回值约定和 GenServer 一样：`{:reply, {:ok, resp}, socket}` 给这次 push 回一个响应
（客户端 `.receive("ok", ...)` 拿到），`{:noreply, socket}` 不回。

和 `handle_in`（收）对应的方向是 `handle_out/3`（发）：广播消息离开 channel 进程、
写给浏览器之前可以拦截改写。默认它不拦截任何事件，消息原样下发；在模块顶部写
`intercept ["new_bid"]` 之后，这个事件的每次下发都会先过你的
`handle_out("new_bid", payload, socket)`，可以按订阅者改 payload（比如给管理员多
几个字段），也可以决定不发。没被 intercept 的事件走快路径，不经过这个回调。

**四个"发"的入口，语义各不相同：**

| 调用 | 作用范围 |
| --- | --- |
| `push(socket, event, payload)` | 只发给当前这一个客户端（点对点回包） |
| `broadcast!(socket, event, payload)` | 发给该 topic 的所有订阅者，包括发起者自己 |
| `broadcast_from!(socket, event, payload)` | 同上，但排除发起者（自己的客户端收不到） |
| `Endpoint.broadcast(topic, event, payload)` | 从任何进程发，给该 topic 的所有订阅者，不要求发起方持有某个 socket |

`broadcast!` 和 `broadcast_from!` 的差别在聊天室类场景很常用：别人发的消息用
`broadcast_from!`（自己这边已经本地回显了），系统公告用 `broadcast!`（所有人一视同仁）。
非 bang 版本（`broadcast`/`broadcast_from`）失败时返回 `{:error, reason}` 而不是
raise。`Endpoint.broadcast` 底层走 PubSub，不要求调用方是 channel 进程，controller、
iex、以后写的后台任务（比如"拍卖到点自动结束"的定时器）都能用。

channel 进程本质上还是个 OTP 进程，所以还有第五个入口 `handle_info/2`：任何
`send(channel_pid, msg)` 或者 OTP 系统消息（monitor 的 `:DOWN`、定时器的 `:tick`）
都进这里，在里面可以 `push` 或 `broadcast!` 给客户端。PubSub 的广播其实也是以消息
形式送达 channel 进程的，只是这层被 `Phoenix.Channel` 内部消化了，代码里看不到。

:::note
真实的出价流程里 `handle_in` 不会被走到：新出价由 controller 通过 `Endpoint.broadcast`
发出，不经过浏览器的 `push`。保留它有两个用处：浏览器端能模拟一次"出价"广播（后面动
手环节演示），也顺便演示了 channel 双向通信的写法。
:::

## BidController：入库后渲染并广播

出价的表单提交仍然走普通 HTTP POST，嵌套路由、changeset 校验都是上一章配好的。变化
发生在 `{:ok, bid}` 分支里：

```elixir
  def create(conn, %{"bid" => %{"amount" => amount}, "item_id" => item_id}) do
    case Auction.insert_bid(%{
           amount: amount,
           item_id: item_id,
           user_id: conn.assigns.current_user.id
         }) do
      {:ok, bid} ->
        html =
          Phoenix.Template.render_to_iodata(AuctionWeb.BidHTML, "bid", "html",
            bid: bid,
            username: conn.assigns.current_user.username
          )
          |> IO.iodata_to_binary()

        AuctionWeb.Endpoint.broadcast("item:#{item_id}", "new_bid", %{body: html})
        redirect(conn, to: ~p"/items/#{bid.item_id}")
```

`ch12/auction_umbrella/apps/auction_web/lib/auction_web/controllers/bid_controller.ex`

三步拆开看：

1. **`Phoenix.Template.render_to_iodata/4`**：在请求流程之外"手动"渲染一个模板。正常
   `render(conn, ...)` 里模板渲染是 Phoenix 帮你调好的，这里要在 controller 里主动
   触发一次，参数要传全：渲染模块（`AuctionWeb.BidHTML`）、模板名（`"bid"`）、格式
   （`"html"`）和 assigns。返回值是 iodata，一种嵌套的字符串/二进制列表，渲染引擎天然
   产生这种结构，比每层拼接字符串高效。
2. **`IO.iodata_to_binary/1`**：把 iodata 拍平成一个二进制字符串。channel 的 payload
   最终要由 `Jason` 编码成 JSON 发到浏览器，JSON 里没有 iodata 这种类型，必须先转成
   普通字符串。
3. **`AuctionWeb.Endpoint.broadcast/3`**：向 topic `"item:#{item_id}"` 广播事件
   `"new_bid"`，payload 是 `%{body: html}`。所有正在看这件商品的浏览器都会收到，其他
   商品的订阅者收不到。广播完成后照常 `redirect`，出价者自己的页面靠这次重定向刷新，
   他其实不依赖 channel 推送。

为什么广播写在 controller 而不是 channel 里？因为事件的源头是一次 HTTP 请求，
`{:ok, bid}` 这个结果只有 `create` 知道，商品 id、出价者用户名这些上下文也都在它手
里。Channel 订阅者在这条链路里的角色是纯接收方，它们 join 之后不再发任何消息。这也
说明了 `Endpoint.broadcast` 的价值：广播不需要"找一个 channel 进程来发"，任何进程
都能发起，PubSub 负责扇出。

:::tip
也可以直接广播 `%{amount: bid.amount, username: …}` 让前端自己拼 DOM，但服务端渲染能
保证出价条目在任何页面、任何客户端上长得一样：展示逻辑只有 `bid.html.heex` 一处，前
端只做"插入"这一件傻事。这是 Phoenix 应用里很常用的取舍：能在服务端渲染的，就不在
客户端重复一份模板。附带的好处是 heex 对插值自动转义，广播出去的 HTML 里的用户输入已
经处理过，不会产生 XSS——前提是 payload 由服务端渲染，这一点后面还会回来讲。
:::

被渲染的片段就是一条出价记录：

```heex
<p>
  {integer_to_currency(@bid.amount)}
  <em>from {Map.get(@bid.user, :username) || @username}</em>
</p>
```

`ch12/auction_umbrella/apps/auction_web/lib/auction_web/controllers/bid_html/bid.html.heex`

`integer_to_currency/1` 是上一章写过的 helper，把分转成美元字符串（定义在
`global_helpers.ex`，由 `html` quote 统一 import 进所有 HTML 模块）。
`Map.get(@bid.user, :username) || @username` 这个回退对应两种数据形状：

- **页面初次渲染**时，`@item.bids` 经过 `Auction.get_item_with_bids/1` 预加载了
  `bids: [:user]`（`auction.ex` 里连着两次 `preload`，第一次排 `inserted_at` 倒序，
  第二次带上 user），`@bid.user.username` 能取到值，`@username` 传 `nil` 无所谓。
- **Channel 广播**时，`insert_bid` 返回的 `bid` 没有预加载 `user`，`@bid.user` 是
  `Ecto.Association.NotLoaded`，`Map.get` 取不到 `:username`，所以 controller 把
  `username: conn.assigns.current_user.username` 显式传进来兜底。

这个片段能被 `render_to_iodata` 找到，靠的是 `BidHTML` 模块的 `embed_templates`：

```elixir
defmodule AuctionWeb.BidHTML do
  use AuctionWeb, :html

  embed_templates "bid_html/*"
end
```

`ch12/auction_umbrella/apps/auction_web/lib/auction_web/controllers/bid_html.ex`

`embed_templates "bid_html/*"` 把目录下每个 heex 文件编译成一个同名 function
component，`bid.html.heex` 变成 `bid/1` 组件函数。所以商品详情页能以组件形式复用它，
和广播走的是同一份模板：

```heex
<div style="display: flex; flex-direction: row;">
  <div style="flex: 1">
    <h2>Current bids</h2>
    <div id="bids">
      <BidHTML.bid :for={bid <- @item.bids} bid={bid} username={nil} />
    </div>
  </div>
```

`ch12/auction_umbrella/apps/auction_web/lib/auction_web/controllers/item_html/show.html.heex`

几处细节：`<BidHTML.bid>` 前缀的 `BidHTML` 来自 `item_html.ex` 里的
`alias AuctionWeb.BidHTML`，没有 alias 就得写全 `<AuctionWeb.BidHTML.bid ...>`；
`username={nil}` 对应上面说的初次渲染场景，fallback 用不到但 assigns 不能缺；外层的
`<div id="bids">` 就是前端插入新出价的锚点；`:for` 按 `@item.bids` 逐条渲染，列表是
`inserted_at` 倒序，最新的在最上面，和前端 `insertAdjacentHTML("afterbegin", ...)`
插到顶部的行为刚好对齐，两边对"最新在哪头"的约定是一致的。

## 前端 app.js：订阅并插入

服务端备齐了，最后一块是浏览器侧。`app.js` 是一个不经打包、直接由 `Plug.Static`
服务的文件：

```javascript
// The vendored phoenix.js (copied from deps/phoenix/priv/static)
// is loaded before this file and exposes window.Phoenix.
// phoenix_html.js is also loaded for link method support (e.g. "Log out").

let socket = new window.Phoenix.Socket("/socket", {
  params: { token: window.userToken },
});

socket.connect();

let match = document.location.pathname.match(/\/items\/(\d+)$/);
if (match) {
  let itemId = match[1];
  let channel = socket.channel(`item:${itemId}`, {});

  channel.on("new_bid", (data) => {
    console.log("new_bid message received", data);
    const elem = document.getElementById("bids");
    elem.insertAdjacentHTML("afterbegin", data.body);
  });

  channel
    .join()
    .receive("ok", (resp) => {
      console.log("Joined successfully", resp);
    })
    .receive("error", (resp) => {
      console.log("Unable to join", resp);
    });
}
```

`ch12/auction_umbrella/apps/auction_web/priv/static/assets/app.js`

逐段读：

- **`new window.Phoenix.Socket("/socket", …)`**：`phoenix.js` 是从
  `deps/phoenix/priv/static` 原样拷来的 vendored 文件（1593 行的打包产物，里面除了
  `Socket`/`Channel` 还有 `Push`、Ajax、LongPoll、JSON 和二进制两套序列化器），加载
  后挂在 `window.Phoenix` 上，所以没有 `import`，直接用全局对象。`params` 里的
  `window.userToken` 目前没有任何地方赋值（`connect/3` 也没读它），是给将来 token
  认证留的钩子。

- **`socket.connect()`**：发起 WebSocket 握手，命中 Endpoint 的 `socket "/socket"` →
  `UserSocket.connect/3`。握手成功前 socket 上 `push` 的消息先进 `sendBuffer`，连接
  建立后统一发出去，所以代码顺序上 `connect` 之后立刻 `channel.join()` 是安全的，不
  用等 `onOpen`。

- **路径正则 `/\/items\/(\d+)$/`**：这份脚本在每个页面都会执行，但 channel 只对商品
  详情页有意义。用 `document.location.pathname` 判断当前页是不是 `/items/:id`，不是
  就什么都不订阅，`socket` 连接本身还是会建立。这比"每个页面一个 JS 入口"朴素，但对
  单一用途的脚本足够；项目没有打包器，做多入口反而要动 layout 的条件渲染。

- **`socket.channel(`item:${itemId}`, {})`**：在已建立的连接上申请一个 topic 为
  `item:{id}` 的 channel。这一步只是本地构造一个 `Channel` 对象记进 `socket.channels`，
  还没有任何网络消息发出去，真正的 join 请求在后面的 `.join()`。这里拼的字符串和服务
  端 `channel "item:*"` 的匹配规则、`broadcast("item:#{item_id}")` 的 topic 三处必须
  严丝合缝，错一个字母就变成"永远收不到"。

- **`channel.on("new_bid", …)`**：注册事件回调，服务端该 topic 的每一次 `new_bid`
  广播都会调到它。`data.body` 是服务端渲染好的 HTML，
  `insertAdjacentHTML("afterbegin", …)` 把它插到 `#bids` 容器内部的最前面。
  `insertAdjacentHTML` 比 `innerHTML +=` 合适的地方在于它解析片段后只做局部插入，
  不会重序列化已有子树、毁掉里面挂好的状态。

- **`channel.join().receive(…)`**：真正发出 `phx_join` 请求（对应服务端
  `ItemChannel.join/3`）。`join()` 返回一个 `Push` 对象，`receive` 链处理这次请求的
  异步结果：`"ok"` 是成功，`"error"` 是服务端返回 `{:error, …}` 或 topic 不匹配，
  `"timeout"` 是 10 秒内没等到响应（默认 `DEFAULT_TIMEOUT`，phoenix.js 这时还会自动
  发 `phx_leave` 再 rejoin）。join 失败只会打到 console，页面其余功能不受影响，而且
  客户端会自己重试。

phoenix.js 对 channel 实例有两条硬规矩，写错了会直接抛异常：`push` 必须 `join()`
先调，没 join 过的 channel 实例上直接 `push` 抛
`tried to push '...' to '...' before joining`；`join` 每个 channel 实例只能调一次，
第二次抛 `tried to join multiple times`，想重试要 `socket.channel(...)` 新建实例。

脚本能跑起来的前提是加载顺序，看 layout 的 `<head>`：

```heex
    <meta name="csrf-token" content={get_csrf_token()} />
    <title>AuctionWeb · Phoenix Framework</title>
    <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
    <script defer phx-track-static src={~p"/assets/phoenix_html.js"}>
    </script>
    <script defer phx-track-static src={~p"/assets/phoenix.js"}>
    </script>
    <script defer phx-track-static src={~p"/assets/app.js"}>
    </script>
```

`ch12/auction_umbrella/apps/auction_web/lib/auction_web/components/layouts/app.html.heex`

三个 `<script>` 都带 `defer`：`defer` 脚本严格按文档顺序在 HTML 解析完成后依次执行，
所以 `phoenix.js` 一定先于 `app.js` 跑，`window.Phoenix` 必然已就位。`phoenix_html.js`
提供 `<.link method="delete">` 这类非 GET 链接的支持（导航栏的 "Log out" 靠它把点击
改成 POST + `_method=delete`）。

## phoenix.js 内部：Socket、Channel、Push

vendored 的 `phoenix.js` 不是黑盒，它的三个类对应协议的三个层面，读一遍能解释很多
"它为什么自己重连了"的疑问。文件是打包产物，但类结构很清楚：

- **`Socket`**：管连接。构造器里 `endPoint` 末尾拼上 `/websocket`，`params` 和
  `vsn`（默认 `"2.0.0"`）拼进 query string。`connect()` 建连后每 30 秒向 `phoenix`
  这个保留 topic 发一次 heartbeat（`heartbeatIntervalMs` 默认 `3e4`），断线时
  `reconnectTimer` 按 `[10, 50, 100, 150, 200, 250, 500, 1000, 2000]` 毫秒、之后
  固定 5000 毫秒的回退序列自动重连。它还维护 `channels` 数组和 `sendBuffer`，连接没
  建立时消息先攒着。
- **`Channel`**：管一个 topic 的订阅。内部有状态机（`closed` → `joining` → `joined`
  → `leaving`/`errored`），`join()` 发出 `phx_join`，`push()` 发出带 `ref` 的事件
  消息，`leave()` 发 `phx_leave` 并清理。join 或 channel 出错时 `rejoinTimer` 按
  `[1000, 2000, 5000]` 毫秒、之后固定 10000 毫秒自动重试 join，所以服务端短暂重启不
  会让页面丢订阅。
- **`Push`**：管一次"需要响应"的请求。`join()` 和 `push()` 返回的都是它，上面挂着
  `ref` 和 `receive` 注册的回调；服务端回 `phx_reply` 时按 `ref` 找到对应的 Push，
  把 `{status, response}` 交给 `matchReceive` 分发。10 秒没回就触发 `"timeout"`。

Channel 上还有两个有用的方法：`channel.onMessage(callback)` 可以拦截所有到达的
消息，回调返回加工后的 payload 才交给 `on` 注册的监听器，适合打日志或统一改数据；
`channel.leave()` 主动退订，服务端进程收到 `phx_leave` 后正常退出。`app.js` 只用到
最基本的三件套（`channel`、`on`、`join`），其余都是协议白送的。

## PubSub 是从哪冒出来的

`Endpoint.broadcast` 能跨进程投递，依赖的是应用监督树里的 PubSub 进程：

```elixir
    children = [
      {DNSCluster, query: Application.get_env(:auction_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AuctionWeb.PubSub},
      # Start the Endpoint (http/https)
      AuctionWeb.Endpoint
      # Start a worker by calling: AuctionWeb.Worker.start_link(arg)
      # {AuctionWeb.Worker, arg}
    ]
```

`ch12/auction_umbrella/apps/auction_web/lib/auction_web/application.ex`

`{Phoenix.PubSub, name: AuctionWeb.PubSub}` 排在 `Endpoint` 之前启动，顺序不是随便写
的：Endpoint 一起来就可能接受连接、join channel，那时候 PubSub 必须已经在了。Endpoint
侧靠 `apps/auction_web/config/config.exs` 里一行配置找到它：

```elixir
config :auction_web, AuctionWeb.Endpoint,
  ...
  pubsub_server: AuctionWeb.PubSub
```

`ch12/auction_umbrella/apps/auction_web/config/config.exs`

整条链是这样合起来的：channel 进程 `join` 成功时，`Phoenix.Channel` 内部用它的 topic
向 `pubsub_server` 指定的 PubSub 订阅（订阅动作在代码里看不到，`use Phoenix.Channel`
帮你做了）；`Endpoint.broadcast(topic, event, payload)` 实际上是把消息包成
`%Phoenix.Socket.Broadcast{}` 交给 `Phoenix.PubSub.broadcast/3`；PubSub 查 topic 的
订阅者列表，给每个 channel 进程发一条消息；channel 进程收到后（没被 intercept 的话走
默认路径）把事件编码成 `[join_ref, ref, topic, event, payload]` 数组，经自己的
WebSocket 发给浏览器。

整条链上没有共享状态，`Endpoint.broadcast` 的调用方也不需要持有任何 channel 上下文，
这就是它能从 controller、iex、后台进程随手发起的原因。PubSub 默认实现基于 `:pg`
（process groups），本身就支持跨节点分发：多个 BEAM 节点连成集群后，A 节点上的
broadcast 能送达 B 节点上订阅同 topic 的 channel，业务代码一行不动。

## 动手验证

在 umbrella 根目录启动服务：

```bash
cd ch12/auction_umbrella
mix deps.get
mix ecto.create   # 第一次跑这个项目才需要，已有库可跳过
mix ecto.migrate
mix phx.server
```

**实验一：双窗口实时同步**

1. 用两个浏览器（或一个正常窗口加一个隐身窗口）同时打开 `http://localhost:4000/items/1`。
2. 在任一窗口登录并提交一个出价。
3. 出价的窗口重定向回详情页，新条目出现在顶部；**另一个窗口不刷新也会同时多出同一条**。
4. 打开 DevTools Console，能看到 `Joined successfully` 和 `new_bid message received`
   两条日志。

想看得更细可以开 DevTools 的 Network 面板，过滤 WS，找
`localhost/socket/websocket?token=...&vsn=2.0.0` 那条连接，Messages 标签页里能看到实际
的帧：浏览器发出的 `phx_join` 是 `["3","3","item:1","phx_join",{}]` 这样
`join_ref` 和 `ref` 相同的数组，服务端回的 `phx_reply` 用同一个 `ref` 对上；广播帧则是
`[null,null,"item:1","new_bid",{"body":"<p>..."}]`，`ref` 和 `join_ref` 都是 `null`，
因为它不是任何一次请求的回复。

**实验二：在 iex 里伪造一次广播**

另开一个终端，`iex -S mix`（或 `iex -S mix phx.server`）后在商品页开着的状况下执行：

```elixir
AuctionWeb.Endpoint.broadcast("item:1", "new_bid", %{body: "<p><strong>$9.99</strong> <em>from iex</em></p>"})
```

页面顶部的出价列表会立刻多出这一条。广播可以从任何进程发起，controller、iex、以后的
后台任务都行，发起方不需要持有 socket。换个没人订阅的 topic（比如 `"item:999"`）再发
一次，什么都不会发生：PubSub 查不到订阅者就直接丢弃。

**实验三：从浏览器 push 走 `handle_in` 分支**

在商品详情页的 Console 里执行（`socket` 是 `app.js` 顶层的 `let`，在 console 里能访问
到）：

```javascript
ch = socket.channel("item:probe", {});
ch.join();
ch.on("new_bid", (d) => console.log("echo back:", d));
ch.push("new_bid", { body: "<p><strong>$0.01</strong> <em>from console</em></p>" });
```

依次是：新建一个 channel 实例（`item:*` 通配符匹配任何 `item:` 开头的 topic，这里故
意用 `item:probe` 不和页面已 join 的 `item:1` 冲突）、发 join、注册回调、push 一条
`new_bid`。这条 push 命中 `ItemChannel.handle_in("new_bid", …)`，`broadcast!` 把
payload 原样转给 `item:probe` 的所有订阅者，目前只有 console 里这一个，所以
`echo back:` 日志会立刻打出来，而页面的 `item:1` 频道不受影响。

两个坑提前说清楚。第一，`push` 必须 `join()` 先调，顺序颠倒会抛
`tried to push 'new_bid' to 'item:probe' before joining. Use channel.join() before pushing events`。
第二，不要图省事也用 `item:1` 做实验：phoenix.js 在同一个 socket 上发现同 topic 的
channel 已 join 或 joining，会主动 leave 掉旧的那个，页面里 `app.js` 建立的那个
channel 会被踢掉，真实的出价广播就收不到了。channel 实例是一次性的，leave 之后想再
订阅要新建实例。

:::caution
`insertAdjacentHTML` 插入的是原始 HTML，不做转义（虽然它不会执行片段里的 `<script>`，
`<img onerror="...">` 这类属性注入照样有效）。现在 payload 里的 `body` 是服务端 heex
模板渲染的，动态内容已经被转义过，所以安全；但 `handle_in` 那条路意味着任何浏览器都能
push 任意 HTML 给同 topic 的所有订阅者，如果订阅的是 `item:1` 就等于给所有看这件商品
的人塞了段未转义的 markup，这在生产环境是个 XSS 入口。本章按进度先不堵它，正确的做法
是让 `handle_in` 拒绝这类事件、做内容校验，或者干脆删掉这个分支，只留服务端的
`Endpoint.broadcast`。
:::

## 小结

本章把出价从"刷新才可见"变成了"实时推送"：

- Endpoint 用 `socket "/socket", AuctionWeb.UserSocket` 把 WebSocket 接进应用，不经过
  Router 和 pipeline，握手、channel 路由、认证全在 socket 层解决；
- `UserSocket` 用 `channel "item:*"` 做 topic 路由，`connect`/`id` 两个回调分别管
  连接认证和 socket 身份；
- `ItemChannel` 的 `join` 建立订阅、`handle_in` 收上行消息；下行的四个入口
  `push`/`broadcast!`/`broadcast_from!`/`Endpoint.broadcast` 各管一种范围，出去之前
  还能用 `intercept` + `handle_out` 按订阅者改写；
- 广播由 `AuctionWeb.Endpoint.broadcast(topic, event, payload)` 发起，底层走
  `Phoenix.PubSub`，订阅者是谁、有几个、挂在哪个进程上，发起方都不用关心；
- `render_to_iodata` 让 HTML 片段在请求流程之外复用同一个 heex 模板，前端只做
  `insertAdjacentHTML`；
- 前端 `app.js` 用 vendored `window.Phoenix` 建连、按 URL 订阅 `item:{id}`，
  `channel.on` 接事件、`join().receive` 处理 join 结果，断线和 join 失败都由
  phoenix.js 自动重试。

Channel 是双向的，本章只用到了"服务端 → 浏览器"这一个方向（`handle_in` 留了个口子做
演示）。实时性的另一半——让不打开页面的外部程序也能读到商品和出价——要靠下一章的
JSON API：在 `/api` scope 下加一组返回 JSON 的路由，让 `curl` 和脚本也能用上这个拍卖
系统。
