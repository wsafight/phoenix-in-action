---
title: 第6章 · Ecto Repo
description: 给 auction 应用接上 PostgreSQL：定义 Auction.Repo、用迁移建出 items 表、写 Auction.Item schema，把 context 里的 @repo 从 FakeRepo 切到 Repo。
sidebar:
  order: 6
---

上一章的领域层全靠 `Auction.FakeRepo` 撑着：三条 Item 写死在模块属性里，进程一重启数据归零，而且根本没有 `insert`、`delete` 这类写操作。它帮我们提前把 `Auction` context 的公开 API 定形了，但任务到此为止。本章把它换掉：给 `auction` 应用接上 Ecto 和 PostgreSQL，让 `list_items` 查的是一张真表，让 `insert_item` 写下的数据能扛过重启。

改动集中在 `auction` 一个应用里，`auction_web` 只多一个适配依赖。落地顺序是：加 `ecto_sql` 和 `postgrex` 依赖，定义 `Auction.Repo` 并把连接参数写进配置，挂进监督树；用 `mix ecto.create` 建库、迁移文件建 `items` 表；把 `Auction.Item` 从 `defstruct` 改写成 schema；最后把 context 里的 `@repo` 指到新模块，在 iex 和 psql 里验证数据真的落了盘。

## Ecto 只拆三件事：Repo、Schema、Migration

Ecto 是 Elixir 生态事实标准的数据库层。它不带 Web 语义，所以放的位置是 `auction` 子应用，不是 `auction_web`：`auction` 管领域和数据，`auction_web` 只管 HTTP，这条界限不变。

Ecto 的 API 面很大，但概念只有三个，本章会各碰一次：

- **Repo**：和数据库对话的入口。它是一个 OTP 进程，内部养着连接池，所有 SQL 都经由它发出。对应文件 `lib/auction/repo.ex`。
- **Migration**：用 Elixir 代码描述表结构的每次变更，可以重演、可以回滚。对应 `priv/repo/migrations/` 下的文件。
- **Schema**：把一张表映射成一个 struct。查询时行变成 `%Auction.Item{}`，写入时 struct 变成 `INSERT` 的参数。对应 `lib/auction/item.ex`。

先记住分工：Migration 管"表长什么样"的历史，Schema 管"行在代码里长什么样"，Repo 管两者之间的 SQL 往返。这三件东西和 ActiveRecord 那种"一个模型类包打天下"的风格不一样：Ecto 把数据库通信、表结构描述、数据映射拆成三个独立模块，哪一个都能单独换掉。

## 依赖：ecto_sql 提供抽象，postgrex 负责通信

Ecto 本体只定义行为，连 PostgreSQL 需要两个包配合。`auction` 的 deps 现在是：

```elixir
  defp deps do
    [
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"}
    ]
  end
```

`ch07/auction_umbrella/apps/auction/mix.exs`

`ecto_sql` 是 Ecto 的 SQL 适配层：`Ecto.Repo` 行为、查询语法到 SQL 的翻译、迁移机制、`mix ecto.*` 任务全在这里。`postgrex` 是 PostgreSQL 的驱动，管 TCP 连接和 wire protocol，ecto_sql 的 Postgres 适配器底层调的就是它。版本约束写成 `>= 0.0.0` 的意思是"交给 ecto_sql 的依赖约束去收敛"，这是 Phoenix 项目的惯例写法。

web 端的 deps 里也冒出一个 Ecto 相关的包：

```elixir
      {:phoenix_ecto, "~> 4.5"},
```

`ch07/auction_umbrella/apps/auction_web/mix.exs`

`phoenix_ecto` 是适配层，目前只用到一件事：让 Phoenix 的表单组件、错误展示能直接消费 `Ecto.Changeset`，具体说是给 changeset 实现了 `Phoenix.HTML.FormData` 协议，并给 `Ecto.NoResultsError` 等异常注册了 404 的 HTTP 状态映射。下一章表单接过 changeset 的 `errors` 字段时会看到它生效。Web 层依然不认识 `Auction.Repo`，它通过 `{:auction, in_umbrella: true}` 只调 `Auction` context。

在 umbrella 根目录跑 `mix deps.get`，Mix 会对 `apps/` 下每个应用各拉一次依赖，产物进共享的 `deps/` 目录。

## Auction.Repo：一个模块，两种身份

Repo 的全部定义只有五行：

```elixir
defmodule Auction.Repo do
  use Ecto.Repo,
    otp_app: :auction,
    adapter: Ecto.Adapters.Postgres
end
```

`ch07/auction_umbrella/apps/auction/lib/auction/repo.ex`

`use Ecto.Repo` 展开后往模块里灌了两批东西。第一批是 API：`all/2`、`get/3`、`get!/3`、`get_by/3`、`one/2`、`insert/2`、`update/2`、`delete/2`、`exists?/2`、`aggregate/3`、`transaction/2` 等几十个函数，外加 `checked_out?/0`、`checkout/0` 这类给测试沙箱用的连接管理函数。第二批是 OTP 部件：`child_spec/1` 和 `start_link/1`，这让 `Auction.Repo` 可以直接写进监督树的 children 列表，稍后就用到。同时模块拿到了 `Ecto.Queryable` 协议实现，`Repo.all(Auction.Item)` 里的 `Item` 能被翻译成 `SELECT * FROM "items"` 的查询。

调用 Repo 函数和 Repo 进程是两件事。`Auction.Repo.all(Item)` 在你自己的进程里执行：函数负责拼查询、encode 参数、decode 结果；只有借连接、发 SQL 这一步会穿过启动时拉起的连接池进程。所以 Repo 模块写在监督树里，但调用它不会引入"消息发给另一个进程"的延迟语义，用法上和一个普通函数没区别。

两个选项各管一件事：

- `otp_app: :auction` 声明配置归属：连接参数去 `:auction` 这个 OTP 应用的 env 里找，也就是 `config :auction, Auction.Repo` 那一段。迁移文件默认的存放目录 `priv/repo/migrations` 也是按这个 app 的 priv 目录解析的。
- `adapter: Ecto.Adapters.Postgres` 选方言适配器：它负责把 Ecto 查询翻成 PostgreSQL 语法、把返回的行 decode 成 schema 字段类型，传输走 postgrex。想换 MySQL 的话改这一项加换依赖即可，本章用不到。

### 连接配置分层放

开发用的连接参数写在 `auction` 子应用自己的 config 里：

```elixir
config :auction, ecto_repos: [Auction.Repo]

config :auction, Auction.Repo,
  database: "auction",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: "5432"
```

`ch07/auction_umbrella/apps/auction/config/config.exs`

第一行 `ecto_repos: [Auction.Repo]` 是这个应用的 Repo 清单。`mix ecto.create`、`mix ecto.migrate` 这些任务执行时不知道项目里有几个 Repo，就靠遍历各应用的 `ecto_repos` 配置枚举；漏写它，任务打印一条 warning 然后什么都不做，除非命令行用 `-r Auction.Repo` 显式点名。

下面一段是标准 PostgreSQL 连接参数，对的是本地默认安装的 `postgres` 超级用户和 `auction` 库。`port` 写的是字符串 `"5432"`，Postgrex 原样接受。这套参数没有按环境分文件：config.exs 末尾的 `import_config "#{config_env()}.exs"` 是注释掉的，所以 dev 和 test 共用同一个 `auction` 库。

这份配置能被读到，靠的是 umbrella 根 config 的显式导入：

```elixir
import Config

# By default, the umbrella project as well as each child
# application will require this configuration file, ensuring
# they all use the same configuration. While one could
# configure all applications here, we prefer to delegate
# back to each application for organization purposes.
import_config "../apps/auction/config/config.exs"
import_config "../apps/auction_web/config/config.exs"

config :phoenix, :json_library, Jason
```

`ch07/auction_umbrella/config/config.exs`

子应用 `mix.exs` 里的 `config_path: "../../config/config.exs"` 把所有应用的 config 入口都指向根目录这一份，根 config 再 import 回各子应用自己的文件。绕一圈的效果是：在 umbrella 根目录和 `apps/auction` 里执行 mix 命令，读到的是同一份合并后的配置。这跟 `auction_web` 那种"config.exs 里 `import_config "#{config_env()}.exs"` 再引 dev.exs/test.exs"的结构不是一回事，`auction` 目前只有一层。

生产环境的连接参数不在这份文件里。密码不该进版本库，所以生产配置放在 `config/runtime.exs`，它在应用启动时才求值，可以直接读环境变量：

```elixir
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :auction, Auction.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
```

`ch07/auction_umbrella/config/runtime.exs`

两处写法是同一份配置的不同入口：开发期散字段 `database`/`username`/`hostname`，生产期一个 `url`（`ecto://USER:PASS@HOST/DATABASE` 的完整 URI）加 `pool_size`。`if config_env() == :prod` 保证开发时这段不执行，缺 `DATABASE_URL` 也只会在生产启动时炸。

### Repo 是监督树里的子进程

前面说 `use Ecto.Repo` 给模块补了 `child_spec`，这里就用上了。`Auction.Application` 的 children 从空列表变成：

```elixir
  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      # Starts a worker by calling: Auction.Worker.start_link(arg)
      # {Auction.Worker, arg},
      {Auction.Repo, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Auction.Supervisor]
    Supervisor.start_link(children, opts)
  end
```

`ch07/auction_umbrella/apps/auction/lib/auction/application.ex`

Repo 启动时读上面那套连接配置，拉起一个连接池（默认池大小 10，每条连接是一个 Postgrex 进程）。应用 `mod: {Auction.Application, []}` 一启动，监督树就把池子建好，之后 `Auction.Repo.all` 这类调用从池里借连接、发 SQL、归还。连接池崩溃会被 `one_for_one` 策略拉起，单个查询出错不影响其他连接。

FakeRepo 不进监督树，因为它是无状态纯函数模块；Repo 必须进，因为它有活着的状态要保。顺序上也有讲究：监督树按列表顺序拉起子进程，`auction` 目前只有 Repo 一个 child，但将来加了别的依赖数据库的进程，排它后面就能保证池子先就绪。

## mix ecto.create：只建库，不建表

先确认本机 PostgreSQL 已启动，然后在 umbrella 根目录执行：

```sh
mix ecto.create
```

成功时输出 `The database for Auction.Repo has been created`。任务读的就是上面 `config :auction, Auction.Repo` 那段参数，在本地 PostgreSQL 里建出一个名为 `auction` 的空库。再跑一遍会提示 `has already been created`，幂等，不会删数据。

在根目录能直接跑 `mix ecto.create`，靠的是 `mix.exs` 里那四个 `../../` 路径：子应用的 `config_path` 全指向根 config，所以 mix 任务在任何一层执行，加载到的应用配置完全一致。ecto 任务又靠各子应用 env 里的 `ecto_repos` 找到 `Auction.Repo`，两条机制合起来，根目录和 `apps/auction` 下执行的效果一样。只有 `ecto.gen.migration` 这类要写文件的任务讲究目录：它往 `priv/repo/migrations/` 落盘，得在 `apps/auction` 里跑。

报 `connection refused` 多半是 PostgreSQL 没在跑，macOS 上 Homebrew 安装的话用 `brew services start postgresql`；报认证错误就检查 `username`/`password` 和本机实际账号对不对得上。

## 迁移：表结构变更也是代码

`ecto.create` 建的是空库，`items` 表要靠迁移文件来建。迁移的颗粒度是"一次变更"：建一张表、加一列、改个索引，各是一份文件。生成器在 `apps/auction` 目录下跑：

```sh
cd apps/auction
mix ecto.gen.migration create_items
```

它在 `priv/repo/migrations/` 下生成一个文件名以时间戳开头的文件，时间戳就是版本号，保证迁移按顺序执行。`priv` 是 OTP 应用存放"非代码资源"的约定目录，`repo/` 下面都是数据库相关的附属文件：migrations 目录、一个让 `mix format` 也格式化迁移的 `.formatter.exs`、以及稍后说到的 `seeds.exs`。把生成的 `change/0` 填成：

```elixir
defmodule Auction.Repo.Migrations.CreateItems do
  use Ecto.Migration

  def change do
    create table("items") do
      add :title, :string
      add :description, :string
      add :ends_at, :utc_datetime
      timestamps()
    end
  end
end
```

`ch07/auction_umbrella/apps/auction/priv/repo/migrations/20181212023436_create_items.exs`

`use Ecto.Migration` 引入 `create`、`add`、`table` 这套 DSL。逐条看：

- **`change/0` 是可逆写法。** Ecto 知道 `create table` 的反操作是 `drop table`、`add` 的反操作是 `remove`，所以升级（`ecto.migrate`）和回滚（`ecto.rollback`）共用这一段代码。遇到推导不出反操作的写法（裸 `execute` SQL、某些数据迁移），要改成 `up/0` 和 `down/0` 分开写。
- **`add :title, :string` 对应 PostgreSQL 的 `varchar(255)`。** `:utc_datetime` 对应 `timestamp`，语义是"按 UTC 存"，读出来是 `DateTime`。Ecto 类型和数据库类型的对应表在 `Ecto.Migration` 文档里，常见的 `:string`/`:integer`/`:text`/`:utc_datetime`/`:naive_datetime` 覆盖大部分需求。
- **`timestamps()` 是宏，展开成 `inserted_at` 和 `updated_at` 两列**，类型默认 `:naive_datetime`，都带 `NOT NULL` 约束。值不用你管，Repo 在 insert 和 update 时自动填、自动刷新。
- 表里还会出现一个 `id` 列：Ecto 建表默认加自增主键，类型在 PostgreSQL 上是 `bigserial`。

执行迁移回到 umbrella 根目录：

```sh
mix ecto.migrate
```

输出里能看到执行过程和生成的 SQL：

```
[info] == Running 20181212023436 Auction.Repo.Migrations.CreateItems.change/0 forward
[info] create table items
[info] == Migrated 20181212023436 in 0.0s
```

同时数据库里多了一张 `schema_migrations` 表，里面就一行 `20181212023436`。Ecto 用它记录哪些迁移版本已经跑过：再执行 `mix ecto.migrate` 发现没有新版本就直接跳过，所以这条命令可以随便重复跑。`mix ecto.rollback` 则按相反顺序回滚最近一批。这张表也是迁移能进版本库的前提：团队里每个人的库各自记着自己跑到哪个版本，拉到新迁移文件后跑一次 `ecto.migrate` 就补齐差距，不需要手工对账。

想看每个迁移的执行状态，还有一条只读命令 `mix ecto.migrations`，输出里 `up`/`down` 标记每份文件的当前状态：

```
Repo: Auction.Repo

  Status    Migration ID    Migration Name
--------------------------------------------------
  up        20181212023436  create_items
```

为什么 `ends_at` 选 `:utc_datetime` 而不是 `:naive_datetime`：两者在 PostgreSQL 上都是 `timestamp`，差别在语义。`:naive_datetime` 存 `NaiveDateTime`，只是"某个时刻的数字"，不带时区立场；`:utc_datetime` 强制存 `DateTime` 且按 UTC 解读，跨时区展示、和"现在"比较都有明确依据。拍卖截止时间天然是个绝对时刻，选后者，代价是写入端必须构造 `DateTime` 而不是 `NaiveDateTime`。

`mix.exs` 里的别名把这套流程串成了两条命令：

```elixir
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end
```

`ch07/auction_umbrella/apps/auction/mix.exs`

`mix ecto.setup` 等于建库加迁移加跑 `priv/repo/seeds.exs`；seeds 文件现在还是生成器给的注释模板（`ch07/auction_umbrella/apps/auction/priv/repo/seeds.exs`），往里写 `Auction.Repo.insert!(%Auction.Item{...})` 就能播种。`mix ecto.reset` 是推倒重来：`drop` 掉库再 setup。`test` 别名在跑测试前自动 `ecto.create --quiet` 和 `ecto.migrate`，所以 `mix test` 永远对着最新表结构执行；因为配置没分环境，测的是和开发同一个 `auction` 库。

## schema 块是表结构在代码侧的镜像

表建好了，但 `Repo.all` 返回的行总得有个代码侧的落点。第 2 章的 `Auction.Item` 是 `defstruct`，现在它升级成 Ecto schema：

```elixir
defmodule Auction.Item do
  use Ecto.Schema

  schema "items" do
    field :title, :string
    field :description, :string
    field :ends_at, :utc_datetime
    timestamps()
  end
end
```

`ch07/auction_umbrella/apps/auction/lib/auction/item.ex`

`use Ecto.Schema` 做的是当年 `defstruct` 做的事再加一倍：`schema` 块里的 `field` 既定义 `%Auction.Item{}` struct 的成员，又登记每个字段的 Ecto 类型，类型信息走 `__schema__/1,2` 和 `__changeset__/0` 这些反射函数暴露给 Ecto，查询结果 decode、`Repo.insert` 编码参数都靠它。`Item` 还实现了 `Ecto.Queryable` 协议，所以可以直接写 `Repo.all(Item)` 或 `Repo.get(Item, 1)`，Ecto 把它转成 `from i in "items"` 形式的查询。

和迁移文件对着看，字段是一一对应的：

| schema 声明 | 数据库列 |
|---|---|
| `field :title, :string` | `title varchar(255)` |
| `field :description, :string` | `description varchar(255)` |
| `field :ends_at, :utc_datetime` | `ends_at timestamp` |
| `timestamps()` | `inserted_at`、`updated_at` 两个 `timestamp` |
| （默认）`field :id, :id` | `id bigserial` 主键 |

`schema "items"` 的字符串是表名，Ecto 不从模块名推导。`id` 不用声明，`use Ecto.Schema` 默认按整型自增主键注入。两侧类型必须对得上：schema 写 `:utc_datetime`，读出来的行 decode 成 `DateTime`；类型和数据库实际列对不上，会在写入 dump 或读取 load 阶段抛错。

schema 还比 `defstruct` 多一个隐藏字段 `__meta__`，类型是 `Ecto.Schema.Metadata`，记着这行数据从哪张表来（`"items"`）、当前状态是 `:built`（新建未落库）还是 `:loaded`（库里查出来的）。后面做 update/delete 时 Ecto 靠它拼 `WHERE id = ...`。

两个现在用不到的留白：`schema` 块里没有 `has_many`，因为 `bids` 表要到第 11 章才出现，关联声明到时候和外键迁移一起补；校验也还没有，schema 只描述形状，"什么样的数据合法"是下一章 changeset 的事。

`ends_at` 的类型顺带变了：FakeRepo 里三条数据写的是 `~N[...]` NaiveDateTime，schema 现在声明 `:utc_datetime`，写入端传进来的必须是 `DateTime`，传 `NaiveDateTime` 会在 insert 时抛类型错误。这在 `insert_item` 的验证环节会看到。

## 换 @repo 只改一行

表和 schema 都齐了，context 这边只剩收尾。回到 `Auction` context：

```elixir
defmodule Auction do
  alias Auction.{Item}

  @repo Auction.Repo

  def list_items do
    @repo.all(Item)
  end

  def get_item(id) do
    @repo.get!(Item, id)
  end

  def get_item_by(attrs) do
    @repo.get_by(Item, attrs)
  end

  def insert_item(attrs) do
    Auction.Item
    |> struct(attrs)
    |> @repo.insert()
  end

  def delete_item(%Auction.Item{} = item), do: @repo.delete(item)
end
```

`ch07/auction_umbrella/apps/auction/lib/auction.ex`

为什么只改 `@repo` 那一行？第 2 章写 FakeRepo 时，三个函数 `all/1`、`get!/2`、`get_by/2` 就是照着 `Ecto.Repo` 的公开签名仿的，context 里的调用点一个参数都不用动。换实现不换接口，接缝当初就留好了。`@repo` 是模块属性，编译期就定死，所以 `@repo.all(Item)` 展开成 `Auction.Repo.all(Item)` 是一次普通远程调用，没有任何运行时动态分发；想做成运行时换实现的话，把 `@repo` 换成从 `Application.get_env` 里读就行，这里用不上。

`insert_item/1` 是新能力，FakeRepo 根本没这个函数。它分两步：`struct(Auction.Item, attrs)` 把属性 map 装进 `%Item{}`，`@repo.insert/1` 生成 `INSERT` 执行。insert 内部先看 `__meta__` 确认这是个没落库的 `:built` 状态结构（对 `:loaded` 的调 `insert` 会直接报错），然后按 schema 的字段映射拼参数化 SQL、从池里借连接发出，成功后把数据库回填的 `id`、`inserted_at`、`updated_at` 装进新 struct 返回。返回值是 `{:ok, item}` 或 `{:error, changeset}` 的 tuple，写操作一律用这种形态把成败分开，调用方模式匹配处理两个分支。目前 `items` 表上没有 unique 约束，出错分支基本只有类型不匹配才会触发。

顺带一提，`Repo.insert` 接受的参数分两种：裸 struct 和 changeset。传裸 struct 时它内部先包一层空 changeset，不做任何校验直接执行；传 changeset 时才检查 `valid?` 标志。现在代码走的是前一条路，这正是不校验的根源，下一章会换成后者。

`delete_item/1` 接的是 struct 不是 id。Ecto 需要 `__meta__` 和主键来判断"删哪一行、这行是否已落库"，所以流程是先 `get_item` 查出来再删。

换真 Repo 之后，有几个调用点行为跟着变了：

- `get_item/1` 现在真的会抛。FakeRepo 的 `get!` 用 `Enum.find` 实现，查不到返回 `nil`，配不上函数名里的 `!`；`Repo.get!` 查不到时抛 `Ecto.NoResultsError`，这个 bang 是真的。
- `get_by` 的语义变了。FakeRepo 是逐字段 `===` 比较，真 Repo 是生成 `WHERE` 子句交给 PostgreSQL 匹配，传 `%{title: "x"}` 就是 `WHERE title = 'x'`。
- 读路径现在每次都过 SQL。FakeRepo 返回的是编译进代码的常量列表，`Repo.all(Item)` 每次调用都真发 `SELECT`，数据改动立刻可见，也真的落盘。

`fake_repo.ex` 文件还留在 `lib/auction/` 里，能编译，但已经没有任何调用方了。留着它无害，本章就当对照样本放着。想彻底删掉也只是一次 `rm` 的事，不影响任何调用。

## 动手验证

确保本机 PostgreSQL 在跑，然后从依赖到数据走一遍完整流程。在仓库根目录：

```sh
cd ch07/auction_umbrella
mix deps.get
mix ecto.create
mix ecto.migrate
```

三条命令依次对应拉依赖、建 `auction` 库、跑迁移建 `items` 表。用 psql 直接看表结构，确认迁移落了实地：

```sh
psql -U postgres -d auction -c '\d items'
```

```
                                      Table "public.items"
    Column    |            Type             | Collation | Nullable |              Default
--------------+-----------------------------+-----------+----------+-----------------------------------
 id           | bigint                      |           | not null | nextval('items_id_seq'::regclass)
 title        | character varying(255)      |           |          |
 description  | character varying(255)      |           |          |
 ends_at      | timestamp without time zone |           |          |
 inserted_at  | timestamp without time zone |           | not null |
 updated_at   | timestamp without time zone |           | not null |
Indexes:
    "items_pkey" PRIMARY KEY, btree (id)
```

顺手看一眼 `select * from schema_migrations`，里面应该是 `20181212023436` 这一个版本号。

然后进 iex 做第一次真实写入。`:utc_datetime` 要求传 `DateTime`，这里用"一周后"当截止时间：

```sh
iex -S mix
```

```elixir
iex> Auction.insert_item(%{
...>   title: "Vintage camera",
...>   description: "A fully working film camera from the 70s",
...>   ends_at: DateTime.utc_now() |> DateTime.add(7 * 24 * 3600, :second)
...> })
[debug] QUERY OK db=4.2ms
INSERT INTO "items" ("title","description","ends_at","inserted_at","updated_at") VALUES ($1,$2,$3,$4,$5) [...]
{:ok,
 %Auction.Item{
   __meta__: #Ecto.Schema.Metadata<:loaded, "items">,
   id: 1,
   title: "Vintage camera",
   description: "A fully working film camera from the 70s",
   ends_at: ~U[2026-11-17 10:00:00Z],
   inserted_at: ~N[2026-11-10 10:00:00],
   updated_at: ~N[2026-11-10 10:00:00]
 }}
```

`[debug] QUERY` 那行是开发模式下 Repo 的 SQL 日志，能看到参数化的 `INSERT` 和实际绑定值，调问题时第一手信息在这。返回的 struct 里 `__meta__` 已经是 `:loaded`，`id`、`inserted_at`、`updated_at` 全是数据库回填的值。

其余几个接口跟着验一遍：

```elixir
iex> Auction.list_items()
[%Auction.Item{id: 1, title: "Vintage camera", ...}]

iex> Auction.get_item(1)
%Auction.Item{id: 1, ...}

iex> Auction.get_item(2)
** (Ecto.NoResultsError) expected at least one result but got none in query:

iex> Auction.get_item_by(%{title: "Vintage camera"})
%Auction.Item{id: 1, ...}

iex> Auction.delete_item(Auction.get_item(1))
{:ok, %Auction.Item{...}}
```

退出 iex 再进，`list_items` 还在，这次数据躺在磁盘上。用 psql 也能直接看到同一行：

```sh
psql -U postgres -d auction -c 'select id, title, ends_at from items'
```

想把库推倒重来，在 `apps/auction` 下跑 `mix ecto.reset`：drop 掉 `auction` 库，重新 create、migrate、跑 seeds。开发中调乱数据时这是最快的一键复位。

测试方面，`apps/auction` 的 `mix test` 别名会先自动 `ecto.create --quiet` 和 `ecto.migrate`，再跑用例；`auction_test.exs` 里 `assert is_list(Auction.list_items())` 现在断言的是真表查询。`mix phx.server` 起服务后访问 `http://localhost:4000`，首页渲染出来的就是数据库里的条目：`PageController.index/2` 一行没改，HTTP 层感知不到底下从内存换成了 PostgreSQL。

## 小结

本章把 `auction` 从 FakeRepo 迁到了真数据库，动过的文件拢共七个：

1. `apps/auction/mix.exs` 加 `ecto_sql` + `postgrex` 依赖和 ecto 别名；`apps/auction_web/mix.exs` 加 `phoenix_ecto`；
2. `lib/auction/repo.ex` 定义 `Auction.Repo`，`otp_app` 指向配置归属，`adapter` 选定 PostgreSQL；
3. `apps/auction/config/config.exs` 写开发连接参数和 `ecto_repos` 清单，生产参数走根 `config/runtime.exs` 的 `DATABASE_URL`；
4. `application.ex` 把 `{Auction.Repo, []}` 放进监督树，连接池随应用启动；
5. 迁移文件 `create_items` 建表，`schema_migrations` 记版本；
6. `lib/auction/item.ex` 从 `defstruct` 升级为 `Ecto.Schema`；
7. `lib/auction.ex` 改一行 `@repo`，解锁 `insert_item` 和 `delete_item`。

接口没动，实现换了：这是当初用 `@repo` 模块属性把 context 和存储解耦的回报。

现在的写入路径还有一个洞没堵上：`insert_item` 用 `struct/2` 直接构造，`title` 传空串、`ends_at` 传过去的日期都照样入库，表上唯一的防线是列类型本身。下一章引入 `Ecto.Changeset`，在 `Item` 上加 `changeset/2` 校验管线，把"什么样的数据合法"这件事从数据库手里收回到代码里。
