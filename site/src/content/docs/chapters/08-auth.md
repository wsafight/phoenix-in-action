---
title: 第8章 · 用户和登录：pbkdf2、session 和守门 plug
description: 给用户体系补上第一块拼图：users 表、pbkdf2 密码哈希、注册登录的 SessionController、每个请求重建 current_user 的 Authenticator plug，以及 controller 里的守门 plug
sidebar:
  order: 8
---

上一章 Items 有了完整的增改查页面，但它们是"无主之物"：任何人打开浏览器都能新建、编辑、删除任何商品。要让拍卖站真正可用，得先回答一个问题：屏幕那头是谁。本章把用户体系立起来，代码都在 `ch10/auction_umbrella` 下，分五块：一张 `users` 表和 `Auction.User` schema（明文密码走虚拟字段，落库前经 `pbkdf2_elixir` 哈希成 `hashed_password`）；注册走 `UserController`；登录、登出走 `SessionController`，登录态只是签名 cookie 里的一个 `user_id`；一个 `AuctionWeb.Authenticator` plug 挂在 `:browser` pipeline 里，把每个请求的 `user_id` 还原成 `@current_user`；最后，`UserController` 里的守门 plug 按身份拦截越权访问，导航栏按登录状态切换显示。

## 认证全景：两条流水线

这一章的所有代码都在解决两个问题：

1. **注册/登录时**：拿到用户输入的明文密码，哈希后存库（注册），或与库里的哈希比对（登录）。比对通过就把 `user_id` 写进 session。
2. **之后每个请求**：session cookie 随请求自动带回，pipeline 里的 plug 读出 `user_id`，查出 `User` 结构体放进 `conn.assigns.current_user`，controller 和模板直接用。

第二条流水线决定了第一条的输出必须足够小：session 存什么、怎么存，不是这一章新配的东西，endpoint 早就声明好了。

```elixir
  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_auction_web_key",
    signing_salt: "jmVVQ88F",
    same_site: "Lax"
  ]
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/endpoint.ex`

`store: :cookie` 意味着 session 数据不存数据库、不存 Redis，整个序列化进一个 cookie 随请求往返。`signing_salt` 参与签名计算：浏览器能读到 cookie 内容（只是签名，没有加密），但任何篡改都会让签名校验失败，这份 cookie 会被服务端直接丢弃。所以把 `user_id` 放进 session 是安全的，伪造不了。代价是容量，浏览器对单个 cookie 有大约 4KB 的上限，session 里只能放个小整数，放不了整个 `%User{}`。

## users 表：只存哈希，不存密码

### migration

users 表只有三个业务字段：用户名、邮箱、哈希后的密码。注意库里根本没有 `password` 列，这是故意的：字段不存在，"忘了哈希就把明文塞进库里"这类事故连发生的机会都没有。

```elixir
defmodule Auction.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string
      add :email_address, :string
      add :hashed_password, :string
      timestamps()
    end

    create unique_index(:users, [:username])
  end
end
```

`ch10/auction_umbrella/apps/auction/priv/repo/migrations/20181213015711_create_users.exs`

迁移照旧放在 `auction` 子应用的 `priv/repo/migrations` 下，跑 `mix ecto.migrate` 时由 `Auction.Repo` 统一执行，和 items 表的迁移是同一个目录。

`unique_index` 给 username 加数据库层面的唯一约束。光靠 changeset 校验挡不住并发：两个同名注册同时走到 `Repo.insert`，校验时都还没看到对方，落库时就靠索引兜底，其中一个会拿到 `Ecto.ConstraintError` 转化成的 changeset 错误。

### schema：四个字段加一个约定俗成的参数名

```elixir
defmodule Auction.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field(:username, :string)
    field(:email_address, :string)
    field(:password, :string, virtual: true)
    field(:hashed_password, :string)
    timestamps()
  end

  def changeset(user, params \\ %{}) do
    user
    |> cast(params, [:username, :email_address])
    |> validate_required([:username, :email_address, :hashed_password])
    |> validate_length(:username, min: 3)
    |> unique_constraint(:username)
  end

  def changeset_with_password(user, params \\ %{}) do
    user
    |> cast(params, [:password])
    |> validate_required(:password)
    |> validate_length(:password, min: 5)
    |> validate_confirmation(:password, required: true)
    |> hash_password()
    |> changeset(params)
  end

  defp hash_password(%Ecto.Changeset{changes: %{password: password}} = changeset) do
    changeset
    |> put_change(:hashed_password, Auction.Password.hash(password))
  end

  defp hash_password(changeset), do: changeset
end
```

`ch10/auction_umbrella/apps/auction/lib/auction/user.ex`

五个"字段"其实是三种身份：

- `username`、`email_address`、`hashed_password` 是真实的列，有名字、有类型、会进 INSERT 语句。
- `password` 是 `virtual: true` 声明的虚拟字段。它在 `%User{}` 结构体里有个槽位，changeset 可以 cast 它、校验它，但 Ecto 写库时会忽略一切虚拟字段。表单里输入的明文只在这个槽位短暂停留。
- `password_confirmation` 连字段都不是。它纯粹是 `validate_confirmation(:password)` 这条校验约定的一个 params 键名：校验器去 params 里找 `password_confirmation`，要求和 `password` 的 change 一致，`required: true` 让缺了它直接报错。报错的 key 落在 `:password_confirmation` 上，所以表单里 `f[:password_confirmation]` 能照常显示"does not match confirmation"之类的错误。

### `changeset_with_password` 逐站拆解

这个管道是本章最值得逐行读的一段，它回答了一个问题：怎样让明文密码过了校验才变成哈希，又不越过 schema 边界。

```elixir
    user
    |> cast(params, [:password])
    |> validate_required(:password)
    |> validate_length(:password, min: 5)
    |> validate_confirmation(:password, required: true)
    |> hash_password()
    |> changeset(params)
```

1. `cast(params, [:password])`：只从外部参数里捞 `password`，username 和 email 这步先不管。cast 进来的值放在 changeset 的 `changes` map 里。
2. `validate_required(:password)`：没给密码就往 `errors` 里记一条。
3. `validate_length(:password, min: 5)`：太短拒掉。
4. `validate_confirmation(:password, required: true)`：比对 `password_confirmation` 参数。
5. `hash_password()`：上面任何一步出错，changeset 就已经是"invalid"了，但 `changes` 里的 `password` 并不会因为校验失败被摘掉（校验失败只记 error，不删 change）。所以 `hash_password` 用模式匹配区分两种情况：`changes` 里有 `:password` 这个键就 `put_change(:hashed_password, Auction.Password.hash(password))`；没有（比如压根没传密码）就原样放行，省一次哈希计算。这一步真正回答了"明文不进库"：落库的是 `hashed_password` 这个新 change，明文的那个 change 对应的是虚拟字段，`Repo.insert` 拼 SQL 时根本看不见它。
6. `changeset(params)`：最后才轮到普通字段。顺序不能反，`changeset` 里有 `validate_required([:username, :email_address, :hashed_password])`，`hashed_password` 必须已经躺在 `changes` 里，这一步的必填校验才过得了。

换句话说，前面五步只负责"把明文变成哈希并放进 changes"，最后一步才负责"检查其它字段外加确认哈希真的算出来了"。两个 changeset 函数拆开用也有道理：后台给已有用户改邮箱时走 `changeset` 就行，不用动密码。

还有一处值得注意的留白：两个 `cast` 的白名单里都没有 `hashed_password`。这不是疏忽。`cast` 是 params 进入 changeset 的唯一入口，把 `hashed_password` 排除在外意味着外部参数永远塞不进这一列，客户端就算在请求里伪造 `user[hashed_password]=$pbkdf2$...` 也没用，它会被 `cast` 直接丢弃。`hashed_password` 进入 `changes` 的通道只有服务端自己的 `put_change` 一条路。这是 Ecto 处理"不能让用户直接赋值"字段的标准姿势：不写进 cast 列表，由代码在服务器侧放进去。

## `Auction.Password`：给 Pbkdf2 套三个名字

为什么不能存明文？一句话：库一旦被拖走，所有用户的密码，连同他们在别的网站复用的同一串密码，全完了。哈希也不等于安全。MD5、SHA1 这类快哈希在 GPU 上每秒能试几十亿个候选，快恰恰是缺点。PBKDF2 这类算法的思路相反：故意把单次哈希做到几十上百毫秒，并且给每个密码加随机盐，让彩虹表和批量爆破都失去意义。这个成本对正常登录无感（一次请求多花零点几秒），对暴力破解是数量级的门槛。

依赖声明在 `auction` 子应用里，密码哈希是领域逻辑，跟 HTTP 无关，不该进 `auction_web` 的 deps：

```elixir
  defp deps do
    [
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:pbkdf2_elixir, "~> 2.0"}
    ]
  end
```

`ch10/auction_umbrella/apps/auction/mix.exs`

`pbkdf2_elixir` 提供的 `Pbkdf2` 模块本身就能用，这里给它套了一层薄薄的封装：

```elixir
defmodule Auction.Password do
  import Pbkdf2

  def hash(password), do: hash_pwd_salt(password)

  def verify_with_hash(password, hash), do: verify_pass(password, hash)

  def dummy_verify, do: no_user_verify()
end
```

`ch10/auction_umbrella/apps/auction/lib/auction/password.ex`

三个函数，三种职责：

- `hash/1` 调用 `hash_pwd_salt`：随机生成一份盐，跑满迭代次数，把算法、参数、盐、结果打包成一个字符串返回，形如 `$pbkdf2-sha512$160000$<盐>$<哈希>`。存进 `hashed_password` 一列的就是这一整行。因为盐是随机的，同一个密码每次哈希出的字符串都不一样，后面 iex 验证时会看到。
- `verify_with_hash/2` 调用 `verify_pass`：从哈希串里读出算法、迭代次数和盐，对输入的明文重算一遍，再做常量时间比对，返回 `true` 或 `false`。常量时间比对是为了让"对了几个字符"这种信息不通过响应时间泄露出去。
- `dummy_verify/0` 调用 `no_user_verify`：对一个不存在的用户也完整跑一遍哈希校验，然后返回 `false`。注意返回的是 `false` 不是 `nil`。

`dummy_verify` 解决的是一个时序侧信道问题。如果代码写成"用户名查不到就直接返回失败"，那么"用户名不存在"的请求几十微秒就回来，"用户名存在但密码错"的请求要等一次完整的哈希。攻击者拿这个毫秒级的时间差就能枚举出哪些用户名已注册，再针对真实存在的账号慢慢猜密码。让每个失败路径都付出同样的哈希成本，这个信号就消失了。返回值 `false` 也让调用方对两种失败一视同仁。

给这套函数起名"薄封装"而不是直接用 `Pbkdf2`，也有个实际好处：登录查询、注册、未来改密码的地方都只依赖 `Auction.Password` 这一个模块，哪天要换成 `bcrypt_elixir` 或 `argon2_elixir`，改的也只是这三个函数的实现，调用点一行不动。

## 注册：UserController

路由只开放了三个 action，`edit`、`update`、`delete` 都没放出来：

```elixir
    resources "/users", UserController, only: [:show, :new, :create]
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/router.ex`

controller 本身平铺直叙，复杂逻辑全部下沉到了 `Auction` context 和 `User` schema：

```elixir
defmodule AuctionWeb.UserController do
  use AuctionWeb, :controller

  plug :prevent_unauthorized_access when action in [:show]

  def show(conn, %{"id" => id}) do
    user = Auction.get_user(id)
    render(conn, :show, user: user)
  end

  def new(conn, _params) do
    user = Auction.new_user()
    render(conn, :new, user: user)
  end

  def create(conn, %{"user" => user_params}) do
    case Auction.insert_user(user_params) do
      {:ok, user} -> redirect(conn, to: ~p"/users/#{user}")
      {:error, user} -> render(conn, :new, user: user)
    end
  end
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/controllers/user_controller.ex`

（`prevent_unauthorized_access` 是后面的守门 plug，文件里它就定义在同一个 controller 内，先记住 `when action in [:show]` 这一行：只有看用户主页需要身份。）

`new` 拿到的 `Auction.new_user()` 是 `User.changeset_with_password(%User{})`，一个还没校验过的空 changeset，正好喂给表单。`create` 走 `Auction.insert_user/1`，context 侧就三行：

```elixir
  def get_user(id), do: @repo.get!(User, id)

  def new_user, do: User.changeset_with_password(%User{})

  def insert_user(params) do
    %User{}
    |> User.changeset_with_password(params)
    |> @repo.insert()
  end
```

`ch10/auction_umbrella/apps/auction/lib/auction.ex`

失败分支返回的 `{:error, user}` 里，那个 `user` 其实是带错误信息的 changeset，重渲染 `new` 模板时每个 `<.input>` 会把自己的错误显示在输入框下方。这是 changeset 一贯的用法，和第 7 章 Item 表单的错误回显是同一个机制。

注册表单四个输入框，其中 `password_confirmation` 对应的正是 `validate_confirmation` 期待的那个参数名：

```heex
<h1>User Registration</h1>

<.form :let={f} for={@user} action={~p"/users"}>
  <div :if={@user.action} class="alert alert-danger">
    Unfortunately, there are errors in your submission. Please correct them below.
  </div>

  <.input field={f[:username]} label="Username" />
  <.input field={f[:email_address]} label="Email address" />
  <.input field={f[:password]} type="password" label="Password" />
  <.input field={f[:password_confirmation]} type="password" label="Password confirmation" />

  <div>
    <.button type="submit">Submit</.button>
  </div>
</.form>
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/controllers/user_html/new.html.heex`

`:if={@user.action}` 的意思是：changeset 只在被 `Repo.insert` 实际用过之后才有 `action` 字段值（比如 `:insert`），首次渲染 `new` 时它为空，顶部提示条不显示。`<.input>` 会自动读取字段错误、画出 label 和错误文案，模板里一行一个输入框。

注册成功后看到的 `show.html.heex` 只展示 `username` 和 `email_address` 两个非敏感字段，密码哈希不出现在任何页面上。

## 登录：SessionController 的三个 action

路由三条，注意登出是 `DELETE` 不是 `GET`：

```elixir
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/router.ex`

用 `DELETE` 有个实际理由：`GET` 会被浏览器预取、爬虫、链接预览当成"读操作"随便触发，把"登出"这种改变状态的动作放在 `DELETE` 后面，误触的门就关上了。HTML 表单和链接默认只会发 `GET`/`POST`，DELETE 怎么发出来，后面讲导航栏时交代。

controller 全貌：

```elixir
defmodule AuctionWeb.SessionController do
  use AuctionWeb, :controller

  def new(conn, _params) do
    render(conn, :new, form: login_form(%{}))
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password} = user_params}) do
    case Auction.get_user_by_username_and_password(username, password) do
      %Auction.User{} = user ->
        conn
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Successfully logged in")
        |> redirect(to: ~p"/users/#{user}")

      _ ->
        conn
        |> put_flash(:error, "That username and password combination cannot be found")
        |> render(:new, form: login_form(user_params))
    end
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> redirect(to: ~p"/items")
  end

  defp login_form(params), do: Phoenix.Component.to_form(params, as: :user)
end
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/controllers/session_controller.ex`

三个 action 各看一处：

**`new`**：登录表单没有可用的 changeset，`User.changeset` 会要求一堆注册时该有的字段，拿它渲染登录框会带出"can't be blank"的错觉。所以用 `Phoenix.Component.to_form(params, as: :user)` 把普通 map 包成表单对象，`as: :user` 让生成的参数名仍是 `user[username]`、`user[password]`，和 `create` 的 `%{"user" => ...}` 模式匹配对得上。

**`create`**：成功分支只做三件事。`put_session(:user_id, user.id)` 把 `user_id` 写进 session，响应返回时它被打包进那个签名 cookie；放一条 flash；重定向到用户主页。注意 `put_session` 的效果体现在下一个请求上：当前这个响应只是让浏览器存下 cookie，真正"登录了"要等到浏览器带着新 cookie 发出下一个请求、Authenticator 读到 `user_id` 的那一刻。session 里只存 id 不存整个结构体，除了 cookie 容量限制，还保证每个请求拿到的 `current_user` 都是库里查出来的最新状态，用户名改了立刻生效。

失败分支用 `render` 不用 `redirect`。重定向会丢掉 `conn` 上的一切临时状态，render 则把错误 flash 和用户已填的 `user_params` 一起带回表单，登录失败刷新后用户名输入框还留着原值，密码框清空。错误信息故意写得含糊（"cannot be found"），不区分"用户不存在"和"密码错"，和 `dummy_verify` 是同一个思路：不给攻击者任何可以分辨两种失败的信息。

**`delete`**：`clear_session()` 清掉 conn 里已加载的 session 数据，`configure_session(drop: true)` 告诉 session plug 在响应里删掉那份 cookie。两步一起用是稳妥做法：数据清了，容器也撤了。之后浏览器再发请求就是无 session 的匿名状态。

### 按用户名和密码查用户

context 侧的查询用 `with` 把"用户存在"和"密码匹配"串成一道关卡：

```elixir
  def get_user_by_username_and_password(username, password) do
    with user when not is_nil(user) <- @repo.get_by(User, %{username: username}),
         true <- Password.verify_with_hash(password, user.hashed_password) do
      user
    else
      _ -> Password.dummy_verify()
    end
  end
```

`ch10/auction_umbrella/apps/auction/lib/auction.ex`

第一步 `@repo.get_by` 返回 `nil` 时守卫 `when not is_nil(user)` 让它匹配失败；第二步 `verify_with_hash` 返回 `false` 时也匹配不上 `true`。两种失败都落入 `else`，统一调 `Password.dummy_verify()` 跑一遍耗时相当的哈希再返回 `false`。所以 `SessionController.create` 里 `case` 只需要两个分支：匹配到 `%Auction.User{}` 就是成功，其它一律按失败渲染。这个函数的返回值类型因此是 `%Auction.User{} | false`，没有 `nil` 的情况。

### 登录表单

```heex
<h1>Log In</h1>

<.form :let={f} for={@form} action={~p"/login"}>
  <.input field={f[:username]} label="Username" />
  <.input field={f[:password]} type="password" label="Password" />

  <div>
    <.button type="submit">Submit</.button>
  </div>
</.form>
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/controllers/session_html/new.html.heex`

表单 `for={@form}` 吃的是 `to_form` 包出来的 `Phoenix.HTML.Form` 对象，不是 changeset，用法上没有区别。

## Authenticator：每个请求重建 current_user

登录成功只是把 `user_id` 写进了 cookie，后续请求带着它回来，但 `conn` 里并没有一个现成的"当前用户"。把"session 里的整数"变成"`conn.assigns` 里的 `%User{}`"这一步，由一个模块 plug 在 pipeline 里统一完成：

```elixir
defmodule AuctionWeb.Authenticator do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    user =
      conn
      |> get_session(:user_id)
      |> case do
        nil -> nil
        id -> Auction.get_user(id)
      end

    assign(conn, :current_user, user)
  end
end
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/authenticator.ex`

模块 plug 的约定就是这两个函数：`init/1` 在启动时（编译期）跑一次，把选项整理好；`call/2` 每个请求执行，拿 conn 进来、返回 conn 出去。`call` 的实现也很直白：`get_session(:user_id)` 读出 id（session 已经由 pipeline 前面的 plug fetch 好，这里只是取值），有 id 就 `Auction.get_user(id)` 查库，没有就给 `nil`，最后 `assign` 进 `conn.assigns`。

这里也顺带把 plug 的两种形态分清楚。`Authenticator` 是模块 plug，一个有 `init/1` 和 `call/2` 的模块，挂在 pipeline 里对所有走这条管道的请求生效，可以跨 controller 复用。马上要在 `UserController` 里看到的 `prevent_unauthorized_access` 是函数 plug，controller 内的一个私有函数，只对它声明的 action 生效。全局共享的拦截用模块挂 pipeline，单个 controller 私有的前置检查用函数写在本地，本章两种形态各见了一个。

无论登录与否都会 `assign`，这个细节让下游省事：controller 和模板可以无条件地读 `conn.assigns.current_user`，值要么是 `%Auction.User{}` 要么是 `nil`，不存在"key 不存在"的第三种情况。

每个请求都查一次库看起来浪费，但这是拿一次廉价的主键查询换两个保证：用户信息永远新鲜（改名、封号立即生效），session cookie 里那份旧数据没有任何发言权，它只起一个"钥匙"的作用。

挂载位置在 `:browser` pipeline 的末尾：

```elixir
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug AuctionWeb.Authenticator
  end
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/router.ex`

顺序有一个硬约束：`plug AuctionWeb.Authenticator` 必须在 `plug :fetch_session` 之后。session cookie 到达服务端时只是一串加密签名的文本，`fetch_session` 负责验签、反序列化并把数据挂到 conn 上；没跑过它，`get_session` 调用会直接抛错。把 Authenticator 放在 pipeline 末尾，等于声明"先让基础设施把请求收拾干净，再做业务层面的身份识别"。

挂上之后，所有走 `:browser` 的请求（本应用目前全部页面请求）的 `conn.assigns` 里都有 `current_user`，模板里的 `@current_user` 就是从这里来的。

这里顺带理清三个容易混淆的"存东西的地方"：

- **session**：跨请求持久，存在签名 cookie 里，登录时写入、登出时删除。本章只往里面放 `user_id` 一个整数。
- **`conn.assigns`**：只在当前请求内有效，请求处理完就没了。`current_user` 住在这里，每个请求由 Authenticator 重新填充。
- **`conn.params`**：本次请求带的参数，登录表单提交的 `user[username]`、`user[password]` 在这里。密码明文只在 params 和 changeset 里短暂存活，从不落库、从不进 session。

session 是慢变量（写一次管一串请求），assigns 是快变量（每个请求重建）。Authenticator 干的就是把慢变量在每个请求开头翻译成快变量。

## 守门：controller 里的函数 plug

`Authenticator` 的职责到"识别"为止，它从不拒绝请求。真正的访问控制在 `UserController` 里，用函数 plug 加 `when` 守卫声明：

```elixir
  plug :prevent_unauthorized_access when action in [:show]
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/controllers/user_controller.ex`

controller 里的函数 plug 在对应 action 之前执行，`when action in [:show]` 让它只管 `show` 这一个 action。`new` 和 `create` 当然要放匿名用户进来，不然永远没人能注册。实现：

```elixir
  defp prevent_unauthorized_access(conn, _opts) do
    current_user = Map.get(conn.assigns, :current_user)

    requested_user_id =
      conn.params
      |> Map.get("id")
      |> String.to_integer()

    if current_user == nil || current_user.id != requested_user_id do
      conn
      |> put_flash(:error, "Nice try, friend. That's not a page for you.")
      |> redirect(to: ~p"/items")
      |> halt()
    else
      conn
    end
  end
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/controllers/user_controller.ex`

规则一句话：没登录，或者登录用户的 id 和 URL 里的 `:id` 对不上，就 flash 一句"Nice try, friend."重定向到 `/items`。登录用户只能看自己的主页。

`halt()` 不能省。Plug 管道的语义是"每个 plug 返回 conn，给下一个 plug 用"，`redirect` 只是在 conn 上写好响应内容，并没有终止管道；不 `halt`，这个 conn 会继续流进 `show` action，`render` 会把刚写好的重定向覆盖掉（或者撞上重复响应的异常），守卫形同虚设。`halt()` 把 `conn.halted` 置为 `true`，Phoenix 的 plug 分发看到它就不再往后走了。

另一个细节是 `String.to_integer()`：URL 参数 `id` 永远是字符串，和 `current_user.id` 的整数比较前必须转换，不然 `1 != "1"` 会让任何人连自己的主页都进不去。

至此认证的两层分工也清楚了。pipeline 里的 `Authenticator` 管 authentication：你是谁，答案是 `@current_user`。controller 里的 `prevent_unauthorized_access` 管 authorization：你能不能干这件事，规则写在具体的 action 门口。前者全局统一，后者按需分散，需要保护的 action 各自声明自己的门槛。这个应用目前只有 `UserController.show` 设了卡，下一章加出价时还会看到同一模式的复用。

为什么把判断写成 plug 而不是塞进 `show` 开头的 `if`？功能上等价，但 plug 形式有两点好处。一是 `when action in [...]` 的声明式范围控制，加 `edit`、`update` 这类新 action 时只改一行声明；二是把"预处理"和"业务"分开，`show` 里就只剩查用户、渲染两行，守卫的存在一眼可见。

:::note
这套代码里注册和登录是两条独立的路径。`UserController.create` 注册成功后 `redirect` 到 `/users/:id`，但那一刻 session 里还没有 `user_id`，守门 plug 会直接把这个"新用户"拦回 `/items`。也就是说注册完得老老实实再走一遍 `/login` 才能看到自己的主页。这个看起来不体贴的行为，恰好是最好的演示：守门 plug 真的在拦人。
:::

## 导航栏按登录态切换

`conn.assigns` 会原样透传给模板，`current_user` 变成 `@current_user`，布局文件直接拿它做条件渲染：

```heex
<div
  class="container"
  style="border-bottom: 1px solid #777777; margin-bottom: 2rem; padding-bottom: 1rem;"
>
  <.link navigate={~p"/items"}>Items</.link>
  |
  <%= if @current_user do %>
    Logged in as <.link navigate={~p"/users/#{@current_user.id}"}>{@current_user.username}</.link>
    | <.link href={~p"/logout"} method="delete">Log out</.link>
  <% else %>
    <.link navigate={~p"/login"}>login</.link>
  <% end %>
</div>
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/components/layouts/app.html.heex`

登录后导航栏显示"Logged in as 用户名"（链到本人主页）和 Log out；未登录只有一个 login 链接。状态切换的全部依据就是 `@current_user` 是不是 `nil`，而这个值由 Authenticator 每个请求重新查库得出，所以登出后刷新任何一个页面，导航栏立刻变回去。

### `method="delete"` 是怎么变成 DELETE 请求的

`Log out` 这一行值得追到底。`<.link href={~p"/logout"} method="delete">` 渲染出的不是普通链接，而是一个带 `data-method="delete"`、`data-to`、`data-csrf` 属性的 `<a>` 标签。`data-csrf` 里嵌着当次的 CSRF token（root layout 头部也有 `<meta name="csrf-token">`，两处来源一致）。

root layout 加载的 `phoenix_html.js` 负责接管点击：

```html
    <script defer phx-track-static src={~p"/assets/phoenix.js"}>
    </script>
    <script defer phx-track-static src={~p"/assets/phoenix_html.js"}>
    </script>
```

`ch10/auction_umbrella/apps/auction_web/lib/auction_web/components/layouts/root.html.heex`

链路完整走一遍：用户点击链接，JS 拦截事件，动态创建一个隐藏表单，`action` 指向 `/logout`，内含 `_method=delete` 和 CSRF token 两个隐藏字段，以 `POST` 提交；请求到 endpoint 后，`Plug.MethodOverride`（就在 `Plug.Session` 上面一行）读到 `_method` 参数，把请求方法改写成 `DELETE` 交给 Router；`delete "/logout"` 路由命中，`SessionController.delete` 执行。CSRF token 同时通过 `protect_from_forgery` 的校验，登出动作没法被第三方网站伪造。

从"一个链接"到"一条带 CSRF 保护的 DELETE"，中间隔着三层东西：模板层的 `method` 属性、前端 JS 的表单拼装、服务端的 method override。少了哪一层都断：去掉 `phoenix_html.js`，点击就退化成普通 `GET /logout`，路由表里没有这条，404。

## 动手验证

在 umbrella 根目录准备依赖、数据库并起服务：

```bash
cd ch10/auction_umbrella
mix deps.get
mix ecto.setup   # 建库 + 迁移 + seeds
mix phx.server
```

先看哈希本身。另开终端进 `iex -S mix`，注意每次输出：

```elixir
iex> Auction.Password.hash("secret")
"$pbkdf2-sha512$160000$Jd5z..."   # 每次都不一样，盐是随机的

iex> Auction.Password.verify_with_hash("secret", "$pbkdf2-sha512$160000$Jd5z...")
true
iex> Auction.Password.verify_with_hash("wrong", "$pbkdf2-sha512$160000$Jd5z...")
false
iex> Auction.Password.dummy_verify()
false   # 注意：不是 nil，而且耗时和真校验相当
```

`hash/1` 的返回值可以直接粘进 `verify_with_hash/2` 的第二个参数，因为算法、迭代数、盐全编码在字符串里。

想亲眼看"时间差被抹平"，用 `:timer.tc` 量一下两种失败（返回的是微秒）：

```elixir
iex> :timer.tc(fn -> Auction.get_user_by_username_and_password("neo", "wrong") end)
{184_231, false}   # 约 0.18 秒
iex> :timer.tc(fn -> Auction.get_user_by_username_and_password("nobody", "x") end)
{187_950, false}   # 几乎一样，dummy_verify 真跑了一遍哈希
```

不存在的用户也付出了同样的成本，从响应时间上分辨不出"neo 存在、nobody 不存在"。

再看查询函数的返回值形状：

```elixir
iex> Auction.insert_user(%{username: "neo", email_address: "neo@matrix.io",
...>   password: "trinity", password_confirmation: "trinity"})
{:ok, %Auction.User{username: "neo", hashed_password: "$pbkdf2-sha512$...", ...}}

iex> Auction.get_user_by_username_and_password("neo", "trinity")
%Auction.User{username: "neo", ...}
iex> Auction.get_user_by_username_and_password("neo", "wrong")
false
iex> Auction.get_user_by_username_and_password("nobody", "whatever")
false   # 返回一样，耗时也一样，dummy_verify 在抹平时间差
```

然后走浏览器流程：

1. 打开 `http://localhost:4000/users/new` 注册。试试两次密码不一致看 `validate_confirmation` 的报错（落在 Password confirmation 输入框下），或者密码少于 5 位看 `validate_length`。
2. 注册完会被守门 plug 拦回 `/items`，flash 是那句 "Nice try, friend."：此刻 session 里还没有 `user_id`。去 `/login` 用刚注册的账号登录，跳转 `/users/:id`，导航栏变成 "Logged in as ..."。
3. 打开 DevTools 的 Application 面板看 `_auction_web_key` cookie。内容是一串签名后的文本，能在网上找个 base64 解码工具看出里面包着 `user_id`，但手动改一个字符再发请求，服务端直接当它不存在，Authenticator 给到 `nil`，又回到匿名状态。
4. 注册第二个用户、登录，然后手动访问第一个用户的 `/users/1`，被同样的 "Nice try, friend." 弹回 `/items`。守门 plug 拦住的是"登录了但身份不对"，和第 2 步"压根没登录"走的是同一个 `if`。
5. 点 Log out，导航栏恢复成 login，再访问 `/users/1` 也进不去了，`_auction_web_key` cookie 在 DevTools 里也看不到了。

还可以在登录前后对比一下 cookie 的体积：登录前没有 `_auction_web_key`，登录后多出一个几百字节的 cookie，里面只有一个 `user_id` 和签名。4KB 的上限就是这么省出来的。

最后跑测试，umbrella 根目录一条命令：

```bash
mix test
```

`auction` 里的 `auction_test.exs` 和 `auction_web` 里的 `page_controller_test.exs` 都还是脚手架级别的测试，本章没有为认证流程补充测试，跑通只是为了确认迁移和依赖没出岔子。给 `SessionController` 补一个"登录成功后 session 里有 user_id"的 conn test，是不错的练手。

## 小结

- `users` 表只存 `hashed_password`。明文经 `virtual: true` 的 `password` 字段进 changeset，校验过后被 `hash_password` 算成哈希放进 `changes`，虚拟字段在落库时被自动忽略。`password_confirmation` 连字段都不是，只是 `validate_confirmation` 约定的参数名。
- `Auction.Password` 薄封装 `pbkdf2_elixir`：`hash_pwd_salt` 加盐哈希，`verify_pass` 常量时间校验，`no_user_verify` 抹平"用户不存在"的时间差，返回 `false`。
- 登录 = `put_session(:user_id, user.id)` 写进签名 cookie；登出 = `clear_session` + `configure_session(drop: true)`。cookie 内容浏览器读得到但改不了。
- `AuctionWeb.Authenticator` 挂在 `:browser` pipeline 的 `fetch_session` 之后，每个请求把 `user_id` 查成 `@current_user`，未登录时是 `nil`。
- 访问控制是 controller 里的函数 plug：`when action in [:show]` 限定作用范围，身份不符就 `redirect` 加 `halt()`，少调 `halt()` 拦截等于没拦。
- `method="delete"` 的登出链接靠 `phoenix_html.js` 拼隐藏表单、`Plug.MethodOverride` 改写请求方法，才把 `<a>` 变成一条受 CSRF 保护的 DELETE。

现在"谁"的问题解决了，"干什么"还差最后一块。下一章给 Item 加上 `Bid`：一个出价同时 `belongs_to` 一个用户和一个商品，`current_user` 会第一次真正进入业务逻辑，用来标出价的主人。
