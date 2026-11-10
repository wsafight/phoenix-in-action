---
title: 第3章 · 装进 umbrella：把领域代码变成 OTP 应用
description: "用 mix new --umbrella 把上一章的单文件拍卖代码改造成 umbrella 项目下的 auction OTP 应用，理清共享路径、mod 启动回调和 in_umbrella 依赖机制"
sidebar:
  order: 3
---

第 2 章的全部代码就是一个 `auction.ex` 文件：三个模块挤在里面，iex 里 `c "auction.ex"` 加载了才能用。能跑，但它不是一个应用：没有启动入口，没有依赖声明，没有测试，也没法被别的项目引用。本章把它改造成真正的 OTP 应用：用 `mix new --umbrella` 建一个 umbrella 项目，在 `apps/` 下生成 `auction` 应用，把三个模块拆成三个文件搬进去。

"OTP 应用"这个词值得先钉住：它不是"一堆代码"的意思，而是 OTP 的部署和生命周期单元。VM 里的每个应用有名字、有版本、有模块清单、有一棵以顶层 supervisor 为根的进程树，能单独启动、单独停止。`mix new` 出来的是源码仓库，编译后 `ebin/` 里的 `.app` 文件才是应用的身份证。

要拆清楚的东西：umbrella 的项目形态（根 `mix.exs` 只有 `apps_path`，子应用共享 `_build`、`deps`、`config`、`mix.lock`）；`mod: {Auction.Application, []}` 声明的启动回调，以及为什么它的 children 是空列表；deps 里已经写好但还没接线的 `ecto_sql`/`postgrex`；`in_umbrella` 依赖机制。数据层仍由 `FakeRepo` 顶着，接真数据库是第 5 章的事。

## `mix new --umbrella`：根目录不装代码，只装约定

umbrella 项目和普通项目用同一条命令生成，差别只有一个选项：

```sh
mix new auction_umbrella --umbrella
cd auction_umbrella
mix new apps/auction --sup
```

第二条命令在 `apps/` 目录里生成子应用，`--sup` 让它带上 Application 回调模块和监督树入口。子应用本身不需要知道自己在 umbrella 里：`apps/auction` 就是一个标准 `mix new --sup` 项目，把它拷出去单独开发也成立，umbrella 的差别全在根部和几个指回根目录的路径：

```
auction_umbrella/
  mix.exs                  # 只有 apps_path，不含任何代码
  mix.lock                 # 全项目共用一份（deps.get 后生成）
  config/
    config.exs             # 全项目共用一份
  deps/                    # 所有子应用的依赖都落在这里（deps.get 后出现）
  _build/                  # 所有子应用的编译产物都在这里（compile 后出现）
  .formatter.exs           # inputs 指向根文件，subdirectories: ["apps/*"]
  apps/
    auction/
      mix.exs              # 子应用自己的项目定义和 deps
      config/config.exs    # 应用自己的配置，经根文件 import_config 生效
      lib/
        auction.ex
        auction/item.ex
        auction/fake_repo.ex
        auction/application.ex
      test/
        auction_test.exs
        test_helper.exs
```

根 `mix.exs` 的内容值得看全：

```elixir
defmodule AuctionUmbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    []
  end
end
```

`ch05/auction_umbrella/mix.exs`

`apps_path: "apps"` 是 umbrella 的全部定义：Mix 看到这个键就把项目按 umbrella 处理，`apps/` 下的每个目录都是一个独立的 Mix 项目、一个独立的 OTP 应用。命令的语义也因此变了：在根目录跑 `mix compile`、`iex -S mix`、`mix test`，Mix 会对 `apps/` 下的每个应用逐个执行，编译输出前带 `==> auction` 这样的应用名前缀；`iex -S mix` 则把所有子应用连同它们的依赖一起启动，等于一条命令拉起整个系统。也可以直接 `cd apps/auction` 进去单独操作，效果和在一个普通项目里一样。

根项目的 `deps` 返回空列表，注释说得很直白：这里列的依赖对 apps 里的应用不可用。依赖归每个子应用自己管，根只负责把它们圈在一个项目里。`start_permanent: Mix.env() == :prod` 管的是另一件事：prod 环境下应用用 permanent 模式启动，顶层 supervisor 一死 VM 直接退出，崩溃止于监控而不是带病运行。

顺带说明一下边界：umbrella 不是把几个原本独立的项目硬捆在一起，也不是替代"一个应用内用命名空间分层"。它处在中间：比 namespace 强（每个应用有自己的 deps、自己的版本、自己的 supervision tree，OTP 眼里是两个单元），比分开的 Hex 包弱（同仓、同锁文件、同一次编译）。选择它的理由只有一个：这些子应用注定要在同一个 VM 里一起跑。

另一个小约定在 `.formatter.exs` 里：

```elixir
[
  inputs: ["mix.exs", "config/*.exs"],
  subdirectories: ["apps/*"]
]
```

`ch05/auction_umbrella/.formatter.exs`

`subdirectories: ["apps/*"]` 让根目录的 `mix format` 递归带上每个子应用自己的 `.formatter.exs` 和代码。格式化、编译、测试、依赖管理，所有命令都遵循同一个模式：在根部执行等于对所有子应用执行。

## 四个 `../../` 路径：全项目共用 `_build`、`deps`、`config`、`mix.lock`

子应用 `mix.exs` 的 `project/0` 和普通项目有一个明显不同：

```elixir
  def project do
    [
      app: :auction,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end
```

`ch05/auction_umbrella/apps/auction/mix.exs`

四个 `../../` 路径是 umbrella 的关键机制，各自的含义：

- `build_path`：编译产物输出目录。指向根的 `_build` 之后，`auction` 的 `.beam` 和 `.app` 落在 `_build/dev/lib/auction/ebin`，和将来其他子应用的产物并列。从根目录启动时所有应用的 ebin 都在同一套 code path 里，不用逐个配 `-pa`。
- `deps_path`：依赖源码目录。指向根的 `deps` 之后，`ecto_sql`、`postgrex` 及其间接依赖全落在根 `deps/`。一个包全项目只存一份、只编一次，哪个应用声明了它，编译时都能从同一处找到。
- `config_path`：本应用读取的配置文件。所有子应用都指向根的 `config/config.exs`，配置天然集中；根文件再用 `import_config` 把内容委托回各应用，后面有一节专门展开。
- `lockfile`：依赖解析结果。指向根的 `mix.lock`，全项目共用一份锁文件，一次求解对所有人生效。

`MIX_ENV` 只影响 `build_path` 里的子目录：dev 编到 `_build/dev/`、test 编到 `_build/test/`，其余三份路径不分环境。

共享这四个路径不是顺手省目录，是 umbrella 的立身之本：它的子应用注定跑在同一个 VM、同一个 release 里，版本必须严格一致。假如 `auction` 和将来的 `auction_web` 各持一份 `postgrex`，编译出两个版本，运行时 BEAM 只会加载先遇到的那份，另一个应用的行为就不可预期。共享 lockfile 把这种不一致消灭在依赖解析期：`mix deps.get` 对整个项目做一次求解，两个应用要同一个包的不兼容版本会直接报错，而不是各装各的。

## `mod:` 启动回调：`start/2` 必须交出一个顶层 supervisor

`mix.exs` 里第二个函数 `application/0` 决定这个应用被 OTP 怎么对待：

```elixir
  def application do
    [
      extra_applications: [:logger],
      mod: {Auction.Application, []}
    ]
  end
```

`ch05/auction_umbrella/apps/auction/mix.exs`

`application/0` 的产物是编译时生成的 `.app` 资源文件（`_build/dev/lib/auction/ebin/auction.app`），它告诉 OTP：这个应用叫什么、版本多少、由哪些模块组成、启动前要先跑哪些应用、入口在哪。`mix.exs` 的两个函数各管一块：`project/0` 面向构建工具 Mix，`application/0` 面向运行时 OTP。两个键的分工：

- `extra_applications: [:logger]` 往依赖应用列表里加 `:logger`。它是 OTP 自带的应用，不在 deps 里，所以显式列。deps 里的 OTP 应用（`ecto_sql`、`postgrex` 那串）由 Mix 自动推断加入列表，不用写，后面 `Application.started_applications()` 的输出能验证这一点。
- `mod: {Auction.Application, []}` 是入口声明：启动 `:auction` 时 OTP 调用 `Auction.Application.start(:normal, [])`，它必须返回 `{:ok, pid}`，这个 pid 就是该应用的顶层 supervisor。从这棵树的根往下，所有进程都算这个应用的；顶层 supervisor 一死，OTP 认为应用整体停了。

回调模块本身是生成器模板：

```elixir
defmodule Auction.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      # Starts a worker by calling: Auction.Worker.start_link(arg)
      # {Auction.Worker, arg},
    ]

    opts = [strategy: :one_for_one, name: Auction.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

`ch05/auction_umbrella/apps/auction/lib/auction/application.ex`

`children` 是空列表，这不是忘了填，是确实没有进程可填。看 `start/2` 的职责就知道什么时候会有东西进来：监督树托管的是应用运行期间必须活着的进程，比如连接池、缓存、HTTP 服务器、定时任务。判据只有一条：它是个进程吗，挂了需不需要被拉起来？第 5 章的 `Auction.Repo`（Ecto 连接池进程）会是这个列表里的第一个真 child，第 4 章 `auction_web` 的 Endpoint 是隔壁应用里的同类角色。

两个 supervisor 选项也顺手看一眼。`strategy: :one_for_one` 表示某个子进程崩溃时只重启它自己，兄弟进程不受影响；`name: Auction.Supervisor` 把 supervisor 注册成本地名字，之后才能用 `Supervisor.which_children(Auction.Supervisor)` 直接点名查看它。

`use Application` 本身只是把这个模块标记为 Application 回调模块，并注入 `start/2`、`stop/1` 的默认实现供覆写；`stop/1` 在应用停掉时被调，通常用不上默认实现。如果 `application/0` 里不写 `mod:`，编译出来的是一个纯库应用：代码能被别人依赖，但启动时不跑任何进程。`deps/` 里的 `decimal` 就是这种形态。

换句话说，"是不是 OTP 应用"和"有没有跑进程"是两回事：`decimal` 是应用但没进程，`FakeRepo` 是模块连应用都不是，而 `auction` 两者都是。`mod:` 就是这三类形态的分水岭。

## 领域代码原样搬进来，`@repo` 留出接缝

`Auction` 的公开 API 和上一章一字不差：

```elixir
defmodule Auction do
  alias Auction.{FakeRepo, Item}

  @repo FakeRepo

  def list_items do
    @repo.all(Item)
  end

  def get_item(id) do
    @repo.get!(Item, id)
  end

  def get_item_by(attrs) do
    @repo.get_by(Item, attrs)
  end
end
```

`ch05/auction_umbrella/apps/auction/lib/auction.ex`

变化只有组织方式：原来三个模块挤在一个文件里，现在一文件一模块，目录映射命名空间，`Auction.X` 就住 `lib/auction/x.ex`。`Auction.Item` 仍是个普通 struct，`defstruct [:id, :title, :description, :ends_at]`（`ch05/auction_umbrella/apps/auction/lib/auction/item.ex`），没有 schema、没有表，纯数据容器。单文件时代挤在一起只是因为当时只有三个模块，按文件拆开后每个模块才有自己的演化空间。

`@repo` 这个模块属性是刻意留的接缝。三个公开函数都不直接点名 `FakeRepo`，第 5 章把它换成 `Repo` 只动这一行，调用方无感。context 模块面向"一个能 `all/get!/get_by` 的仓库"编程，不关心背后是常量列表还是 PostgreSQL。

## `FakeRepo` 是纯函数模块，所以监督树里没有它

上一节的空 `children` 在这里找到答案：

```elixir
defmodule Auction.FakeRepo do
  alias Auction.Item

  @items [
    %Item{
      id: 1,
      title: "My first item",
      description: "A tasty item sure to please",
      ends_at: ~N[2020-01-01 00:00:00]
    },
    %Item{
      id: 2,
      title: "WarGames BluRay",
      description: "The best computer movie of all time, now on BluRay!",
      ends_at: ~N[2018-10-15 13:39:35]
    },
    %Item{
      id: 3,
      title: "U2 - Achtung Baby on CD",
      description: "The sound of 4 men chopping down The Joshua Tree",
      ends_at: ~N[2018-11-05 03:12:29]
    }
  ]

  def all(Item), do: @items

  def get!(Item, id) do
    Enum.find(@items, fn item -> item.id === id end)
  end

  def get_by(Item, attrs) do
    Enum.find(@items, fn item ->
      Enum.all?(Map.keys(attrs), fn key ->
        Map.get(item, key) === attrs[key]
      end)
    end)
  end
end
```

`ch05/auction_umbrella/apps/auction/lib/auction/fake_repo.ex`

没有 `use GenServer`，没有 `start_link`，它就不是进程。`@items` 是模块属性，编译时连同三条 `%Item{}` 一起算好、烧进 BEAM 文件；`all`、`get!`、`get_by` 只是对这个常量做 `Enum` 运算，谁调用就在谁的进程里执行，和调一个数学函数没有区别。不占进程，谈不上崩溃重启，监督树的边界根本不沾它。

反过来想"什么该进监督树"也有参照：如果 `FakeRepo` 被写成一个 `Agent` 或一张 ETS 表，持有可变状态，它就必须作为一个进程挂在 `children` 里，挂了才有 supervisor 拉起来。假仓库的价值恰恰是零生命周期：不需要启动、不需要关、不存在失败模式，换真实现时连"先停旧进程"这一步都不存在。

两个细节。`ends_at` 的 `~N[...]` 是 `NaiveDateTime` 的字面量 sigil，编译期求值，写在模块属性里正合适。`get!` 名字带感叹号，实现却是 `Enum.find`，找不到返回 `nil` 不抛异常。这个名字是冲着将来的 `Ecto.Repo.get!/2` 起的，那里的 `!` 才真会抛 `Ecto.NoResultsError`：接口形状先对齐，语义等换真仓库时自然补上。

## `ecto_sql` 已在 deps 里，数据库却还没接

子应用 `deps` 的完整内容是：

```elixir
  defp deps do
    [
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
      # {:sibling_app_in_umbrella, in_umbrella: true},
    ]
  end
```

`ch05/auction_umbrella/apps/auction/mix.exs`

本章一行数据库代码都没有，但 `ecto_sql` 和 `postgrex` 已经躺在 deps 里。两个版本约束各说一句话：`~> 3.10` 表示 `>= 3.10.0 and < 4.0.0`，锁死主版本放开次版本；`postgrex` 的 `>= 0.0.0` 等于不约束，实际版本交给 `ecto_sql` 自己的 `postgrex` 要求去决定。`mix deps.get` 会把它们连同间接依赖一起拉回根 `deps/` 编译：`ecto`、`db_connection`、`decimal`、`telemetry`，打开 `mix.lock` 能看到七个包的完整解析记录。启动应用时这一串也都作为依赖应用先跑起来，尽管还没有任何代码调用它们。

提前放进来是在声明归属，不是浪费：数据库依赖属于领域应用 `auction`，不属于将来的 Web 层。第 4 章 `auction_web` 进来时，它的 deps 里只会出现 `phoenix`、`bandit` 这些 HTTP 相关的包，对 `ecto_sql` 一行不提；第 5 章 `Auction.Repo` 定义时，依赖也已经就位，只需写 `use Ecto.Repo` 和配置。依赖边界从第一天就是对的，后面不用重画。

## `in_umbrella`：子应用之间的依赖通道

deps 末尾还有一行被注释的占位：

```elixir
      # {:sibling_app_in_umbrella, in_umbrella: true},
```

`ch05/auction_umbrella/apps/auction/mix.exs`

`in_umbrella: true` 告诉 Mix：这个依赖不去 Hex 拉，到本项目 `apps_path` 指向的目录下找同名子应用，当成 path 依赖直接编译它的源码。它还参与排序：声明方排在被依赖方之后编译、之后启动。后一条不是 Mix 的礼貌，是硬约束：umbrella 依赖会写进 `.app` 文件的依赖应用列表，OTP 启动 `:auction_web` 前先保证 `:auction` 已经在跑，否则 controller 第一次调 `Auction.list_items()` 就是对一个不存在的模块发消息。

目前只有一个应用，这行只是生成器留的占位。第 4 章 `auction_web` 的 deps 里会真的写上 `{:auction, in_umbrella: true}`，两个应用用起来像同一个项目，但依赖方向被显式钉死：Web 依赖领域，反过来不行。领域层哪天想回到单应用部署，把 `auction` 摘出 `apps/` 发成 Hex 包，`auction_web` 改一行 deps 就行，业务代码一行不动。

## 配置回收：根 `config.exs` 用 `import_config` 委托回各应用

根目录的 `config/config.exs` 实质内容只有一行：

```elixir
import Config

# By default, the umbrella project as well as each child
# application will require this configuration file, ensuring
# they all use the same configuration. While one could
# configure all applications here, we prefer to delegate
# back to each application for organization purposes.
import_config "../apps/auction/config/config.exs"
```

`ch05/auction_umbrella/config/config.exs`

机制串起来是这样的：每个子应用的 `config_path` 都指向根这份文件，所以不管从哪个应用触发，读到的都是它；根文件再反过来用 `import_config` 载入每个应用自己的 `config/config.exs`。效果等于"各写各的配置，集中生效"：`auction` 想配置自己，写 `apps/auction/config/config.exs`，通过根文件被递归载入。现在那份子配置全是注释模板（`ch05/auction_umbrella/apps/auction/config/config.exs`），没有任何实际配置，但注释里已经埋了按环境分文件的钩子：解开 `import_config "#{Mix.env()}.exs"` 那行就能分 `dev.exs`/`test.exs`，后面章节给 `Repo` 配数据库连接用的就是这个机制。

注意这里是显式列文件，不是通配。每加一个子应用，根文件就添一行 `import_config`；仓库后面的快照里能看到它长成两行：`auction` 一行、`auction_web` 一行。用显式列表而不是 `apps/*/config/config.exs` 通配，是为了让加载顺序一目了然，行序就是生效顺序，后 import 的覆盖先 import 的。

## 测试住在各自的应用里，根 `mix test` 逐个执行

`mix new --sup` 顺手生成了 `test/` 目录：`test_helper.exs` 只有一句 `ExUnit.start()`，`auction_test.exs` 是改造后的模板测试：

```elixir
defmodule AuctionTest do
  use ExUnit.Case
  doctest Auction

  test "list_items/0 returns the fake items" do
    assert [%Auction.Item{} | _] = Auction.list_items()
  end
end
```

`ch05/auction_umbrella/apps/auction/test/auction_test.exs`

生成器原装的断言是 `assert Auction.hello() == :world`，对应一个不存在的 `hello/0`，跑起来必然失败。这里把它换成了对 `list_items/0` 的冒烟断言：能返回一个非空列表，元素是 `%Auction.Item{}`。`doctest Auction` 是模板自带的那行，`Auction` 还没有 `@doc` 示例，所以实际不产生用例。

在根目录跑 `mix test`，Mix 会对 `apps/` 下每个应用逐个执行，输出按应用分段：

```text
==> auction
Running ExUnit with seed: 535032, max_cases: 24

.
Finished in 0.01 seconds (0.00s async, 0.01s sync)

Result: 1 passed
```

跑测试时 `MIX_ENV` 是 `test`，编译产物落在共享的 `_build/test/` 而不是 `_build/dev/`，所以测试和开发各自编译，互不覆盖。只想跑 `auction` 一个应用的测试，`cd apps/auction && mix test` 就行，子应用始终是一个独立 Mix 项目。

## 动手验证

在 umbrella 根目录操作：

```sh
cd ch05/auction_umbrella
mix deps.get
iex -S mix
```

`deps.get` 对整个项目做一次依赖求解，拉回来的包落在根 `deps/`。`iex -S mix` 先编译 `apps/` 下每个应用（输出带 `==> auction` 前缀），再把它们连同依赖一起作为 OTP 应用启动。进 iex 后直接调：

```elixir
iex> Auction.list_items() |> length()
3
iex> Auction.get_item(2)
%Auction.Item{id: 2, title: "WarGames BluRay", ...}
iex> Auction.get_item_by(%{title: "WarGames BluRay"})
%Auction.Item{id: 2, title: "WarGames BluRay", ...}
```

应用已经自己跑起来了，不用手动 start：

```elixir
iex> Application.started_applications() |> Enum.map(&elem(&1, 0))
[:auction, :ecto_sql, :postgrex, :db_connection, :ecto, :decimal,
 :telemetry, :eex, :logger, ...]
```

`:auction` 排最前，这个列表按启动顺序倒着排，它最后启动。跟在它后面的 `:ecto_sql`、`:postgrex`、`:db_connection`、`:ecto`、`:decimal`、`:telemetry` 全是 deps 带进来的依赖应用，被 Mix 自动写进启动列表，先跑起来了。再看那棵监督树：

```elixir
iex> Supervisor.which_children(Auction.Supervisor)
[]
```

一个 supervisor，零个子进程。树现在只有骨架，等 `Repo`、Endpoint 这类真进程进来才会长肉。

想确认 `.app` 文件长什么样，不用去 `_build` 里翻，`Application.spec/1` 直接读出来：

```elixir
iex> Application.spec(:auction)
[
  applications: [:kernel, :stdlib, :elixir, :logger, :ecto_sql, :postgrex],
  mod: {Auction.Application, []},
  ...
]
```

`applications` 列表就是 `extra_applications` 和 deps 推断的合流：手写了一个 `:logger`，Mix 从 deps 推断出 `:ecto_sql`、`:postgrex`，再加三个 OTP 自带的。`mod` 的值和 `mix.exs` 里写的一字不差。

退出 iex，根目录跑 `mix test`，输出如上一节：`==> auction` 段里一条断言通过。

## 小结

- umbrella 是个容器：根 `mix.exs` 只声明 `apps_path`，代码全部住在 `apps/` 下，每个子目录是一个完整 Mix 项目；
- 子应用 `mix.exs` 里四个 `../../` 路径让全项目共用 `_build`、`deps`、`config`、`mix.lock`，依赖只解析一次，版本天然一致；
- `mod: {Mod, args}` 把应用接到 OTP 启动机制上：`start/2` 必须返回顶层 supervisor，children 为空说明系统里还没有需要保活的进程；
- `FakeRepo` 是无状态纯函数模块，不进监督树；`Auction` 的 `@repo` 属性留好了换真 Repo 的接缝；
- `ecto_sql`/`postgrex` 提前进 deps 是在声明数据库依赖归领域层；`in_umbrella: true` 是子应用互相依赖的通道，下一章马上用到。

代码已经从"能跑"变成"是个应用"，但用户还是碰不到它：中间差一层把 HTTP 请求翻译成 `Auction.list_items()` 调用的东西。第 4 章在 `apps/` 里加第二个应用 `auction_web`，用 `in_umbrella` 拿到 `auction` 的 API，把商品列表挂到 `http://localhost:4000` 上。
