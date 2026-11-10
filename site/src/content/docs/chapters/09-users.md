---
title: 第9章 · 用户注册
description: users 表只存 hashed_password，明文经 virtual 字段进 changeset、落库前算成哈希；Auction.Password 薄封装 pbkdf2_elixir；UserController 只开 show、new、create 三个 action
sidebar:
  order: 9
---

上一章 Items 有了完整的增改查页面，但它们是"无主之物"：任何人打开浏览器都能新建、编辑、删除任何商品。要让拍卖站真正可用，得先回答一个问题：屏幕那头是谁。回答它分两步，先把人登记进来（注册），再让系统每次认出他（登录）。本章只做第一步，代码都在 `ch10/auction_umbrella` 下，分三块：一张 `users` 表和 `Auction.User` schema（明文密码走虚拟字段，落库前经 `pbkdf2_elixir` 哈希成 `hashed_password`）；一层 `Auction.Password` 薄封装；一个只开 `show`、`new`、`create` 的 `UserController`。登录、登出、每个请求识别身份的那一套，留给下一章。

## 认证全景：两条流水线

先一次把"认证"的全貌摆出来，后面两章各走一半。这一章加下一章的所有代码，都在解决两个问题：

1. **注册/登录时**：拿到用户输入的明文密码，哈希后存库（注册），或与库里的哈希比对（登录）。比对通过就把 `user_id` 写进 session。
2. **之后每个请求**：session cookie 随请求自动带回，pipeline 里的 plug 读出 `user_id`，查出 `User` 结构体放进 `conn.assigns.current_user`，controller 和模板直接用。

本章完成第一条流水线的注册半边：users 表、密码哈希、注册表单。登录那半边、session 具体怎么存、第二条流水线的 plug，全部在下一章落地。这里只需要先记住一件事：session 存在浏览器读得到、但改不了的签名 cookie 里，容量只有约 4KB，所以登录态能放进去的东西必须足够小——一个 `user_id` 整数，而不是整个 `%User{}`。

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

这段管道回答了一个问题：怎样让明文密码过了校验才变成哈希，又不越过 schema 边界。

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

前面五步只负责"把明文变成哈希并放进 changes"，最后一步才负责"检查其它字段外加确认哈希真的算出来了"。两个 changeset 函数拆开用也有道理：后台给已有用户改邮箱时走 `changeset` 就行，不用动密码。

还有一处刻意的留白：两个 `cast` 的白名单里都没有 `hashed_password`。`cast` 是 params 进入 changeset 的唯一入口，把 `hashed_password` 排除在外意味着外部参数永远塞不进这一列，客户端就算在请求里伪造 `user[hashed_password]=$pbkdf2$...` 也没用，它会被 `cast` 直接丢弃。`hashed_password` 进入 `changes` 的通道只有服务端自己的 `put_change` 一条路。这是 Ecto 处理"不能让用户直接赋值"字段的标准姿势：不写进 cast 列表，由代码在服务器侧放进去。

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
- `verify_with_hash/2` 调用 `verify_pass`：从哈希串里读出算法、迭代次数和盐，对输入的明文重算一遍，再做常量时间比对，返回 `true` 或 `false`。常量时间比对是为了让"对了几个字符"这种信息不通过响应时间泄露出去。本章还用不到它，下一章登录比对密码时才出场。
- `dummy_verify/0` 调用 `no_user_verify`：对一个不存在的用户也完整跑一遍哈希校验，然后返回 `false`。注意返回的是 `false` 不是 `nil`。

`dummy_verify` 解决的是一个时序侧信道问题。如果代码写成"用户名查不到就直接返回失败"，那么"用户名不存在"的请求几十微秒就回来，"用户名存在但密码错"的请求要等一次完整的哈希。攻击者拿这个毫秒级的时间差就能枚举出哪些用户名已注册，再针对真实存在的账号慢慢猜密码。让每个失败路径都付出同样的哈希成本，这个信号就消失了。返回值 `false` 也让调用方对两种失败一视同仁。和 `verify_with_hash` 一样，它是为登录准备的，这里先和 `hash` 一起介绍完。

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

（`prevent_unauthorized_access` 是下一章的守门 plug，文件里它就定义在同一个 controller 内，先记住 `when action in [:show]` 这一行：只有看用户主页需要身份。）

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

失败分支返回的 `{:error, user}` 里，那个 `user` 其实是带错误信息的 changeset，重渲染 `new` 模板时每个 `<.input>` 会把自己的错误显示在输入框下方。这是 changeset 一贯的用法，和第 8 章 Item 表单的错误回显是同一个机制。

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

注册成功后看到的 `show.html.heex` 只展示 `username` 和 `email_address` 两个非敏感字段，密码哈希不出现在任何页面上。不过这里有个"反直觉"的体验：注册完重定向到 `/users/:id`，你会立刻被一行 flash 弹回 `/items`。原因正是前面埋下的那行 `plug :prevent_unauthorized_access when action in [:show]`——它的完整规则和实现都在下一章。

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

然后走浏览器流程，再回 iex 里看落库的结果：

1. 打开 `http://localhost:4000/users/new` 注册。先故意填错：两次密码不一致，看 `validate_confirmation` 的报错（落在 Password confirmation 输入框下）；密码少于 5 位，看 `validate_length`；username 少于 3 位或留空也有对应错误。错误全部回显在各自输入框下方，顶部出现那条 "Unfortunately, there are errors..."。
2. 填对再提交，注册成功、重定向 `/users/:id`——然后被那句 "Nice try, friend." 弹回 `/items`。这是守门 plug 在拦人，细节下章解释；眼下先记住"注册成功不等于登录"。
3. 回 iex 里查刚注册的用户，看 `users` 表真正落了什么：

```elixir
iex> Auction.get_user(1)
%Auction.User{username: "neo", hashed_password: "$pbkdf2-sha512$160000$...", ...}
```

`hashed_password` 是带盐带参数的完整哈希串，`password` 虚拟字段读出来是 `nil`——明文从头到尾没进过库。

最后跑测试，umbrella 根目录一条命令：

```bash
mix test
```

`auction` 里的 `auction_test.exs` 和 `auction_web` 里的 `page_controller_test.exs` 都还是脚手架级别的测试，本章没有为注册流程补充测试，跑通只是为了确认迁移和依赖没出岔子。

## 小结

- `users` 表只存 `hashed_password`。明文经 `virtual: true` 的 `password` 字段进 changeset，校验过后被 `hash_password` 算成哈希放进 `changes`，虚拟字段在落库时被自动忽略。`password_confirmation` 连字段都不是，只是 `validate_confirmation` 约定的参数名。
- `Auction.Password` 薄封装 `pbkdf2_elixir`：`hash_pwd_salt` 加盐哈希，`verify_pass` 常量时间校验，`no_user_verify` 抹平"用户不存在"的时间差，返回 `false`。后两个函数下一章登录时才真正上场。
- 注册走 `UserController` 的 `new`/`create`：空 changeset 喂表单，`insert_user` 成功重定向、失败带错误重渲染，和 Item 表单是同一套机制。`show` 门口已经挂了一行 `plug :prevent_unauthorized_access`，规则下章揭晓。

下一章补全"你是谁"的另一半：`SessionController` 的登录、登出三个 action 把 `user_id` 写进签名 cookie 里的 session，`AuctionWeb.Authenticator` plug 在每个请求里把 `user_id` 还原成 `@current_user`，最后 `UserController` 里那个守门 plug 会亮出全部规则——包括它刚才把你拦下时的那句 "Nice try, friend."。
