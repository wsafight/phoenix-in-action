---
title: 第2章 · 领域层
description: 暂离 Phoenix，把拍卖应用的领域核心写成一个普通 .ex 文件：Item struct 钉死数据形状，FakeRepo 伪造存储层，context 用 @repo 解耦。
sidebar:
  order: 2
---

第 1 章的 Blog 应用骨架已经能跑：Endpoint、Router、Controller、模板一条链路齐全。但回头看 `Blog.App` context 有个不太舒服的地方：业务函数直接调 `Blog.Repo`，一个真连 PostgreSQL 的 Ecto Repo。数据库不通，什么业务都验不了；想单测业务逻辑，先得把数据库伺候好。

拍卖应用反着来。先把领域核心写成一份不依赖任何框架的普通 Elixir 代码，能独立运行、独立验证，再一层层往上套 OTP 应用、数据库和 Web。这个核心就三个模块，全在一个文件里：`Auction.Item` 是一个 struct，定义商品这种数据长什么样；`Auction.FakeRepo` 是一个假仓库，用模块属性存三条写死的 Item，实现 `all`/`get!`/`get_by` 三个读接口；`Auction` 是 context，对外的公共函数只调 `@repo`，不碰实现细节。

文件叫 `ch04/auction.ex`，总共 60 行，连 mix 项目都不是，用 `iex ch04/auction.ex` 一行就能跑起来。本章没有一行 Phoenix 代码，这是刻意的：领域层本来就该对 HTTP 一无所知，现在连数据库都先不认识。

要拆清楚的就是这三层怎么各管一摊：`defstruct` 给"数据长什么样"上了一道保险，模块属性 `@items` 把种子数据编译成常量，`@repo` 这一行怎么让 context 对存储实现无感。看完机制再上 iex 逐个函数验证。

## 一个 .ex 文件就是一个验证环境

第 1 章的顺序是"先有项目骨架，后填业务"：`mix phx.new` 先生成几十个文件，再把 Post、Comment 塞进现成的格子里。这章把顺序倒过来，从业务往回长骨架。用到的只是 `defmodule`、`defstruct`、`def` 这几个语言原语，Elixir 编译器本身就够了，Mix 的编译路径、依赖解析、应用启动一概缺席：

```elixir
defmodule Auction.Item do
  defstruct [:id, :title, :description, :ends_at]
end
```

`ch04/auction.ex`

连 Mix 都没有，编译从哪来？`iex ch04/auction.ex` 这条命令里，iex 把命令行参数当成源文件直接编译加载，三个模块进 BEAM 内存，产物不落盘。验证一下就知道：跑完 `iex ch04/auction.ex` 再去看 `ch04/` 目录，里面还是只有 `auction.ex` 一个文件，没有 `.beam` 残留。

顺带分清 `.ex` 和 `.exs` 的约定：`.ex` 表示"这份代码要被编译进项目产物"，mix 项目里 `lib/` 下全是它；`.exs` 表示"脚本"，`.formatter.exs`、`config.exs`、测试文件都是这种，即跑即弃不打算产出 `.beam`。iex 不挑扩展名，两种都加载进内存。这份文件用 `.ex` 是对的：它定义的是要长期存在的模块，不是跑完就扔的一次性代码。

这个"单文件先行"还有一个不太显眼的好处：注意力被迫只放在业务上。不用看 `mix.exs` 的 deps，不用配 `config.exs`，不用想 supervision tree 怎么摆，打开文件就是全部代码。等将来出了问题要排查，也是这样一个小文件最容易看全：三个模块 60 行，没有一行在隐藏行为。

省掉 mix 项目换来的是迭代成本极低：改一处代码，保存，`r` 一下（见动手验证），立刻重测。代价也明摆着：没有测试框架、没有依赖声明、没有自动编译路径、没有启动入口。这些都是后话，第 3 章的 umbrella 会一次性补回来。眼下阶段唯一的命题是"拍卖业务的核心长什么样"，单文件最贴合这个命题。

这个顺序还顺手回答了一个容易被框架遮住的问题：哪些代码离开 Phoenix 照样是合法的。`Auction.Item` 不用知道 HTTP 是什么，`Auction.FakeRepo` 不用知道数据库是什么，它们的输入输出都是纯数据结构。将来 framework 换一茬，这三个模块一行不用动。

## Auction.Item：用 struct 钉死数据形状

`defstruct` 一行声明了商品的四个字段：自增的 `id`、标题 `title`、描述 `description`，还有 `ends_at` 拍卖截止时间。它展开成 `%Auction.Item{}`，本质上是一个带 `__struct__` 键的 map，字段默认全是 `nil`：

```elixir
iex(1)> struct(Auction.Item)
%Auction.Item{id: nil, title: nil, description: nil, ends_at: nil}
iex(2)> Map.keys(struct(Auction.Item))
[:id, :description, :title, :__struct__, :ends_at]
```

`iex ch04/auction.ex`

`Map.keys` 的结果把构造底细露出来了：struct 就是 map 加一枚 `__struct__` 标记。那为什么不直接用普通 map 表示商品？struct 多出三样东西。

第一样是键名白名单。`%Item{titel: "x"}` 在编译好的代码里是编译错误，在 iex 里手敲会当场收到 `KeyError: key :titel not found`。字段名拼错这种事，用 map 时编译器一个字都不会说，到查询返回 `nil` 才发现不对；用 struct 时错误发生的点被挪到了出错的那一行。

第二样是模式匹配。`%Item{id: id} = item` 一条语句做了两件事：断言"这是个 Item struct"，同时取出 `id` 字段。函数签名里写 `%Item{}` 做参数头，把传错类型的调用当场挡下，不用进函数体再检查。挡得多严可以试：`%Item{} = %{}` 直接 `MatchError`，而 `%{} = item` 能过，因为裸 `%{}` 模式匹配任意 map，不管 `__struct__` 是谁。struct 模式比 map 模式多查的就是这枚类型标记。

第三样是类型归属。`__struct__` 这个键标明了数据的"种类"，inspect 输出、`Phoenix.Param` 协议分发、将来 changeset 的 `cast`，都靠这枚标记认型。

构造时字段不必给全，没给的回落到 `nil`：

```elixir
iex(3)> %Auction.Item{title: "x", ends_at: ~N[2030-01-01 00:00:00]}
%Auction.Item{id: nil, title: "x", description: nil, ends_at: ~N[2030-01-01 00:00:00]}
```

`iex ch04/auction.ex`

想让某字段必填，可以在 `defstruct` 前面加一行 `@enforce_keys [:title]`，构造时缺了就直接报错。这章的数据全由 FakeRepo 写死，用不上这个约束。

同时也得说清 struct 不管什么。`%Auction.Item{id: "abc"}` 能构造出来，`defstruct` 不查类型也不查必填，它只管键名白名单。值是否合法（标题是不是字符串、`ends_at` 是不是时间、哪些字段非空）是另一层的事：第 7 章引入 changeset 后才有校验。shape 和 content 是两种约束，`defstruct` 只覆盖前一种。

`ends_at` 存的是 `NaiveDateTime`，源码里用 `~N` sigil 写字面量，比如 `~N[2020-01-01 00:00:00]`。"Naive"的意思是不带时区信息，就是"某年某月某日某时"这几个数字本身。带时区的 `DateTime` 等到需要跨时区展示时再引入。三条种子数据的 `ends_at` 都在 2018–2020 年之间，在当年写这段代码时是"未来截止"的拍品；现在看都过期了，但读接口并不关心过期与否，按时间过滤是以后 `where` 子句的事。

## Auction.FakeRepo：模块属性当数据库

数据层分工完整，先看数据本身：

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
```

`ch04/auction.ex`

`@items` 是模块属性，在编译期求值并内嵌进编译产物：这三个 `%Item{}` 从此是代码的一部分，任何函数读到的都是同一份常量，不产生拷贝。里面的 `%Item{...}` 字面量能写全靠 `alias Auction.Item`，否则得写全 `%Auction.Item{...}`。

模块属性本意是存元数据，`@moduledoc` 用的就是同一套机制；拿来当"数据表"是借力打力，数据写在模块最顶上，形状一眼可见，不需要进程、不需要文件、不需要数据库服务。这正是 fake 的含义，重启 iex，数据就回到起点。

把数据放模块属性而不是写进 `all` 的函数体，是顺手但合理的选择：常量提到模块顶部，"表"的形状一眼可见，要加数据只改一处。它带来的限制也摆在明面上：编译期常量不可变，所以 FakeRepo 天生没有写接口，这点后面细说。

接口只有三个读函数：

```elixir
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

`ch04/auction.ex`

三个函数对应三种真实查询，逐行拆开看。

### `all/1`：返回整张"表"

`def all(Item), do: @items` 的参数 `Item` 是个模式匹配用的哨兵。函数头里写大写开头的名字会被展开成模块别名（借助上面的 `alias Auction.Item`），所以这个子句只匹配 `all(Auction.Item)` 这一种调用。传别的进来，比如 `Auction.FakeRepo.all(String)`，直接 `FunctionClauseError`。

注意 `Item` 在函数头里是模式不是变量：它匹配 `Auction.Item` 这个原子本身，不会像普通参数那样把传进来的值绑到名字上。写成小写 `def all(item)` 就变成"收任何东西并命名为 item"，哨兵语义就没了。

哨兵还留了扩展口：将来有了 `Auction.User` 这类新 struct，补一个 `def all(User), do: @users` 函数头就行，老代码不用动。Ecto 的 `Repo.all/1` 收的同样是 schema 模块，参数形状从这里就开始对齐了。

### `get!/2`：按 id 精确查找

```elixir
    Enum.find(@items, fn item -> item.id === id end)
```

`Enum.find/2` 遍历列表，返回第一个让匿名函数为真的元素，找不到返回 `nil`。匿名函数里 `item.id === id` 是唯一的判定条件。

为什么用 `===` 不用 `==`？两者对数字的处理不同：`==` 做数值宽松比较，`2 == 2.0` 为真；`===` 是严格相等，`2 === 2.0` 为假。`id` 将来是数据库主键，主键比较本来就该是精确匹配，宽松语义在这里只会引入模糊地带。顺带一提，`get_item("2")` 传字符串在 `==` 下也返回 `nil`（字符串和整数比本来为假），`===` 真正拉开差距的是 `2` 对 `2.0` 这种场景。

这层严格性的实际价值会在 Web 层接上时显现：HTTP 传进来的 `id` 是字符串，repo 不替你做类型转换，就逼你在参数解析的边界上显式 `String.to_integer/1`。转换发生的位置清清楚楚，不会漏进业务层。

### `get_by/2`：按任意属性组合过滤

```elixir
    Enum.find(@items, fn item ->
      Enum.all?(Map.keys(attrs), fn key ->
        Map.get(item, key) === attrs[key]
      end)
    end)
```

外层还是 `Enum.find`，内层把判定逻辑做成了"所有键都相等"：`Map.keys(attrs)` 取出查询条件的键名列表，`%{id: 1}` 得到 `[:id]`，`%{id: 1, title: "x"}` 得到 `[:id, :title]`；`Enum.all?` 对列表里每个键要求 `Map.get(item, key) === attrs[key]` 成立，有一个不成立这个 item 就被跳过。两层枚举都带短路：`Enum.all?` 撞到第一个假值就停，`Enum.find` 命中第一个就返回，不会把三条数据全扫完。

`Map.get/2` 用变量当键查 struct：`item.title` 那种点号语法要求键名写死在代码里，这里键名来自运行时传入的 attrs，只能用 `Map.get`。`attrs[key]` 则取查询条件里同名字段的期望值。

拿 `%{id: 1, description: "wrong"}` 走一遍：键列表 `[:id, :description]`（map 的键序不保证，这里不影响结果），对 item 1 来说 `id` 匹配但 `description` 不成立，`Enum.all?` 返回假，这个 item 出局；剩下两条的 `id` 第一关就挂。三个都筛完没有命中，返回 `nil`。返回值是"第一个命中的 item"而不是列表，和 `Repo.get_by` 一样只回一条；想要全部匹配项得换 `Enum.filter`，Ecto 那边对应的是 `Repo.all` 加 where。

这个实现里有三个语义细节，都和 Ecto 的 `Repo.get_by/2` 对得上：

- **条件之间是与关系**。`%{id: 1, description: "wrong"}` 要求两个字段同时匹配，一个不符就落空。`Enum.all?` 就是这个"与"的机械实现。
- **空 map 命中第一条**。`get_item_by(%{})` 时 `Map.keys` 返回空列表，`Enum.all?([], ...)` 恒真，第一个 item 直接入选。Ecto 的 `Repo.get_by(Schema, [])` 也是这个行为。
- **attrs 必须是 map**。`Map.keys` 不接收关键字列表，`get_item_by(title: "x")` 会抛 `BadMapError`，得写成 `%{title: "x"}`。这算 FakeRepo 和真 Repo 的一个分歧点：Ecto 那边关键字列表是合法的。写顺手容易漏掉 `%{...}` 这层壳：keyword list 是"键值对的列表"，map 才是"键到值的映射"，`Map.keys` 要的是后者。

还有一个更隐蔽的坑：`Map.get(item, key)` 对 struct 里不存在的键返回 `nil`，所以 `get_item_by(%{nonsense: nil})` 会命中第一条记录，`nil === nil` 为真。同理 `%{__struct__: Auction.Item}` 会匹配每一条，因为 `__struct__` 是真的存在的键。真 Ecto 在编译期就按 schema 字段校验查询，这种 attrs 根本进不了 SQL。FakeRepo 没有这层把关，写 attrs 时只能靠自己别乱敲。

:::note[这个 get! 并不真"!"]
Elixir 命名惯例里 `!` 表示"找不到就抛异常"，比如 `Repo.get!/2` 查无此行会 raise `Ecto.NoResultsError`。`FakeRepo.get!` 只是借了函数名对齐接口形状，内部 `Enum.find` 找不到照样返回 `nil`，不会抛。这个差异现在无害，等第 6 章换 `Auction.Repo` 时 `get!` 会恢复成真正会抛的版本，调用方 `get_item/1` 的行为也会从"返回 `nil`"变成"抛异常"。
:::

FakeRepo 缺什么也很说明问题：没有 `insert`、`update`、`delete`。`@items` 是编译期常量，写操作对它没有意义，硬要写就得把数据搬进 Agent 或 ETS，为了一个 fake 不值得。它顶住的边界是：能读，不能写；能验证接口形状，不能验证持久化。写操作要等第 6 章 `Ecto.Repo` 进场才有真正的落点。

## Auction：context 用 @repo 换实现自由

前面两个模块一个管"数据长什么样"，一个管"数据从哪来"。`Auction` 模块把两者粘成对外边界：

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

`ch04/auction.ex`

每个公共函数都是一行：委托给 `@repo`，参数是 `Item` 模块名加业务参数。`alias Auction.{FakeRepo, Item}` 一句用大括号展开成两行 alias，`@repo FakeRepo` 把仓库模块记进模块属性。属性里存的不是字符串，是 `alias` 展开后的模块名 `Auction.FakeRepo` 这个原子，`@repo` 每次出现的位置在编译期被替换成它。

和第 1 章的 `Blog.App` 对照着看更有意思：

```elixir
  def list_posts do
    Repo.all(Post)
  end
```

`ch03/blog/lib/blog/app/app.ex`

那边 `list_posts` 就是 `Repo.all(Post)`，`get_post!(id)` 就是 `Repo.get!(Post, id)`：函数形状一模一样，连参数顺序都对得上，区别只在仓库写成 `Repo` 还是 `@repo`。context 的职责边界两边相同：收敛公开 API、屏蔽存储细节。不同在于 `Blog.App` 从第一天起就和 PostgreSQL 绑定，`Auction` 先拿 FakeRepo 顶班。

`get_item_by(attrs)` 的参数 `attrs` 没写类型约束，签名上收任何值。约束其实藏在 FakeRepo 那层：`Map.keys` 只收 map，关键字列表走到那里才抛 `BadMapError`。这种"上游签名松、下游自然报错"的写法在这份代码里没问题，因为出错位置和出错原因对得上；将来 Ecto 接手后，attrs 的形状约束还是由 repo 层（`Repo.get_by` 的参数校验）兜着。

`@repo` 是编译期替换，不是运行时可配置的依赖注入，改个环境变量换 repo 那一套在这里不存在。想要可配置也有现成路子，`Application.compile_env` 就能从配置读模块名；对一个马上要被一行替换掉的属性，没必要。它的价值在源代码层：整份文件里只有 `@repo FakeRepo` 这一处写着具体实现，三个公共函数对实现完全无感。第 6 章把这行改成 `@repo Repo`，`list_items`/`get_item`/`get_item_by` 一个字不动，行为就从读内存列表变成查 PostgreSQL。

假仓库的接口形状照抄 `Repo.all`/`Repo.get!`/`Repo.get_by`，就是为这一刻准备的：调用方写法和将来换真库时一模一样，差别只有 `@repo` 指向谁。

context 这个名字来自 Phoenix 的约定：应用对外暴露的一组相关函数收在同一个模块里，模块本身就是业务边界。`Auction` 现在只有三个函数，但它已经占好了"拍卖领域唯一入口"的位置。后面章节往里加 `insert_item`、`update_item`、`new_bid`、`list_bids_for_item`，全都从这个模块进；Web 层从头到尾只认 `Auction.xxx()`，不直接碰 Repo。

三个模块的调用关系：

```
调用方（iex、将来的 controller）
        │
        ▼
   Auction                 公共 API：list_items / get_item / get_item_by
        │ @repo
        ▼
   Auction.FakeRepo         存储接口：all / get! / get_by
        │
        ▼
   @items（模块属性）        数据本体：三个 %Auction.Item{}
```

依赖只往下指：FakeRepo 不知道谁在调它，Item 不知道谁在用它的字段，`Auction` 不知道调用方是 iex 还是浏览器。单向依赖让这个文件可以独立存在，它没有引用 `Auction` 命名空间以外的任何东西。

注意模块在文件里的排列顺序和依赖方向相反：`Auction` 定义在第 5 行，`Auction.FakeRepo` 要到第 23 行才出现。能编译过是因为远程调用 `@repo.all(Item)` 是运行时派发，编译期只要求模块名是个合法原子，不要求被调模块已经加载。哪天把 FakeRepo 从文件里删掉，`Auction` 照样编译，调用时才炸 `UndefinedFunctionError`。

为什么是三层而不是两层？把 `FakeRepo` 内联进 `Auction`，三个函数各自 `Enum.find` 也能跑，还省一个模块。多这一层的理由前面已经埋了：存储实现要整个换掉。换实现意味着"有一整块东西会被替掉"，那一整块最好是一个独立的模块、有独立的职责边界。`Auction` 存的是"调什么"，`FakeRepo` 存的是"怎么存"，分开之后替换才是一行 `@repo` 的事，不是逐函数重写。

## 这份代码还缺什么

把缺口列出来，等于把后面几章的目录列出来：

- **没有写路径**。`insert_item`、`update_item` 还不存在，因为内存常量没法写。第 6 章接 Ecto 之后才有 `Repo.insert` 的落点，写入还会带上 changeset 校验（第 7 章）。
- **没有校验**。`%Item{title: nil}` 能构造，`Auction` 层不做任何检查。同样得等 changeset。
- **没有进程**。没有 Application、没有监督树，`@items` 是数据不是状态机。第 3 章补上 OTP 外壳。
- **没有测试**。没有 `test/` 目录和 ExUnit 用例，验证全靠手动调 iex。第 3 章变成 mix 项目后才有 `mix test` 的落点，测试体系到收尾章统一盘。
- **没有边界守卫**。`Auction.FakeRepo` 可以被任何代码直接调，"调用只走 context"目前靠自觉。这层约束要到 Web 层进来才会真正受力。

每个缺口都是后面某一章的主题。现在缺着不是疏忽，是验证顺序的一部分：先确认接口形状成立，再逐个补真实现。

## 动手验证

`auction.ex` 是普通 `.ex` 文件，不需要 mix 项目。在仓库根目录喂给 iex：

```sh
iex ch04/auction.ex
```

启动时文件被编译加载，三个模块立即可用。先看 context 的对外面：

```elixir
iex(1)> exports(Auction)
get_item/1        get_item_by/1     list_items/0
```

就这三个函数，和文件里的 `def` 一一对应。逐个调：

```elixir
iex(2)> Auction.list_items()
[
  %Auction.Item{
    id: 1,
    title: "My first item",
    description: "A tasty item sure to please",
    ends_at: ~N[2020-01-01 00:00:00]
  },
  %Auction.Item{
    id: 2,
    title: "WarGames BluRay",
    description: "The best computer movie of all time, now on BluRay!",
    ends_at: ~N[2018-10-15 13:39:35]
  },
  %Auction.Item{
    id: 3,
    title: "U2 - Achtung Baby on CD",
    description: "The sound of 4 men chopping down The Joshua Tree",
    ends_at: ~N[2018-11-05 03:12:29]
  }
]
```

inspect 输出里 `~N[...]` 就是 `NaiveDateTime` 的写法，和源码里的字面量对应。三条数据全部来自 `@items` 写死的 struct。

```elixir
iex(3)> Auction.get_item(1)
%Auction.Item{
  id: 1,
  title: "My first item",
  description: "A tasty item sure to please",
  ends_at: ~N[2020-01-01 00:00:00]
}
iex(4)> Auction.get_item(99)
nil
iex(5)> Auction.get_item("2")
nil
```

`99` 查无此物返回 `nil`，`"2"` 也是 `nil`：字符串和整型在 `===` 下不等。这里没有异常，这个行为和 `!` 的命名惯例不符，前面那个 note 说的就是它。

```elixir
iex(6)> Auction.get_item_by(%{title: "U2 - Achtung Baby on CD"})
%Auction.Item{
  id: 3,
  title: "U2 - Achtung Baby on CD",
  description: "The sound of 4 men chopping down The Joshua Tree",
  ends_at: ~N[2018-11-05 03:12:29]
}
iex(7)> Auction.get_item_by(%{id: 1, description: "wrong"})
nil
iex(8)> Auction.get_item_by(%{id: 1, title: "My first item"})
%Auction.Item{id: 1, title: "My first item", ...}
iex(9)> Auction.get_item_by(%{})
%Auction.Item{id: 1, title: "My first item", ...}
iex(10)> Auction.get_item_by(title: "My first item")
** (BadMapError) expected a map, got:

    [title: "My first item"]
```

第 7、8 行验证了条件是"与"关系：全部匹配才命中，一个不匹配就落空。第 9 行是空 attrs 的边界行为，`Enum.all?` 对空列表恒真，返回第一条。第 10 行的 `BadMapError` 是参数形态问题：`title: "..."` 是关键字列表不是 map，`Map.keys` 不收，要套 `%{...}`。

再试 struct 的键名白名单和 repo 的哨兵参数：

```elixir
iex(11)> %Auction.Item{titel: "typo"}
** (KeyError) key :titel not found
    expanding struct: Auction.Item.__struct__/1
iex(12)> %Auction.Item{} = %{}
** (MatchError) no match of right hand side value: %{}
iex(13)> Auction.FakeRepo.all(String)
** (FunctionClauseError) no function clause matching in Auction.FakeRepo.all/1
```

第 11 行是键名白名单在抓拼写错误，第 12 行是 struct 模式拒绝了裸 map，第 13 行验证了 repo 的哨兵参数：没有匹配 `String` 的函数头。绕过 context 直接调 `Auction.FakeRepo` 当然可行，Elixir 没有私有模块，"只走 `Auction` 层"是约定不是机制。

struct 本身也值得在 iex 里把玩一下：

```elixir
iex(14)> i %Auction.Item{}
Term
  %Auction.Item{id: nil, title: nil, description: nil, ends_at: nil}
Data type
  Auction.Item
Description
  This is a struct. Structs are maps with a __struct__ key.
Implemented protocols
  IEx.Info, Inspect
```

`defstruct` 顺手还给模块生成了 `__struct__/0` 和 `__struct__/1` 两个函数：前者返回全 `nil` 的默认实例，`%Auction.Item{title: "x"}` 这种字面量在底层走的其实是 `Auction.Item.__struct__/1`。前面 `KeyError` 的报错栈里那行 `expanding struct: Auction.Item.__struct__/1` 就是这么来的。

改代码不用退出 iex。把 `@items` 里加一条 `id: 4` 的 `%Item{}` 保存，回 iex 跑：

```elixir
iex(15)> r Auction.FakeRepo
{:reloaded, [Auction, Auction.FakeRepo, Auction.Item]}
iex(16)> length(Auction.list_items())
4
```

`r/1` 按模块找到它所在的源文件重新编译，三个模块定义在同一个文件里，所以一次重载全部刷新，新数据立刻生效。编译失败也不会动旧版本：文件改出语法错误时 `r` 会抛 `MatchError`（它内部对编译结果做 `{:ok, ...} =` 匹配），已经加载的三个模块保持原样，改回正确代码再 `r` 一次就行。单 `.ex` 文件的迭代就是这么便宜。

## 小结

这个文件做的事不多，但把后面几章的骨架全钉好了：

```
Auction（context）           对外三函数：list_items / get_item / get_item_by
   │  @repo
Auction.FakeRepo             存储接口：all / get! / get_by，数据编译进模块
   │
Auction.Item                 数据形状：id / title / description / ends_at
```

`@repo` 一行是整章的支点：context 只写接口，实现可以换。`defstruct` 钉死了数据的形状，`FakeRepo` 照 `Ecto.Repo` 的读侧形状模仿接口、写侧留白。先立边界再填实现，让领域层在没有数据库、没有 Web 框架的前提下跑通了全部读路径。

这个形态也到头了：没有项目结构，就没有依赖声明、测试目录和启动入口。下一章用 `mix new --umbrella` 建一个 umbrella 项目，在 `apps/` 下生成 `auction` 应用，把这三个模块拆成 `item.ex`、`fake_repo.ex`、`auction.ex` 三个文件搬进去，`Auction` 变成带 `Application` 回调和监督树的 OTP 应用。为第 4 章在它旁边加 `auction_web`、第 6 章把 `@repo` 指向 `Auction.Repo` 腾好位置。
