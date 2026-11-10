---
title: 第7章 · changeset
description: 给 Item 写 changeset：cast 过滤外部参数、validate_* 逐条校验，Repo 只在 valid? 通过时才发 SQL
sidebar:
  order: 7
---

第 6 章把 `Auction.Repo` 接上了 PostgreSQL，`list_items`/`get_item` 已经开始查真表，`insert_item` 也能把数据写进库。但写入这条路还敞着口：`insert_item` 用 `struct/2` 拼出一个 struct 就直接交给 `Repo.insert`，参数是什么、合不合法，没人管。本章给 `Item` 加一个 `changeset/2`，把"过滤参数、转换类型、逐条校验"做成一条管线，`insert_item` 和 `update_item` 都改走它，校验失败统一返回 `{:error, changeset}`。

changeset 是理解 Ecto 的关键概念，但它名字起得有歧义：它不是一个"校验器"，而是一个把一次写入完整打包的数据结构，里面装着原始参数、生效的改动、累积的错误和一个 `valid?` 标记。`Repo` 只是照着这个结构决定要不要发 SQL。本章把它拆开看：先看裸 struct 写库到底缺了什么，再逐段读 `Item.changeset/2`，然后看 `Repo.insert` 拿到 changeset 之后的行为，最后看 context 层和测试怎么收尾。

## 裸 struct 写库：唯一的"校验"是列类型

第 6 章留下的 `insert_item` 长这样：

```elixir
  def insert_item(attrs) do
    Auction.Item
    |> struct(attrs)
    |> @repo.insert()
  end
```

`ch07/auction_umbrella/apps/auction/lib/auction.ex`

`Kernel.struct/2` 只做一件事：把 map 里的 key 塞进 `%Item{}` 结构体。它对内容没有任何判断。`title` 传空串、`ends_at` 传十年前的日期，都照样拼出 struct 交给 Repo。

数据库这边也不拦。回头看建表的迁移：

```elixir
    create table("items") do
      add :title, :string
      add :description, :string
      add :ends_at, :utc_datetime
      timestamps()
    end
```

`ch08/auction_umbrella/apps/auction/priv/repo/migrations/20181212023436_create_items.exs`

`title`、`description`、`ends_at` 三个列全是可空的，没有任何 `null: false`、`check`、唯一索引。一条 `title` 为 `NULL` 的记录，Postgres 会开开心心收下。也就是说，整条写入路径上唯一的"约束"是列类型本身：传个整数给 `title` 会被 Ecto 的编码层或 Postgres 拒掉，但拒的方式是异常，不是 `{:error, _}` 返回值。

把三件事摆在一起，这个 `insert_item` 对参数的要求隐式且自相矛盾：

- key 必须是 atom 且恰好对应字段名，多一个 `"hack"` 之类的未知 key，`struct/2` 直接抛 `KeyError`；
- key 对了，值却随便填，空标题、过期时间都能进库；
- 值填错了类型（比如 `ends_at: "tomorrow"`），不是返回错误而是当场崩。

真正要的是另一种语义：参数进来先过白名单、按字段类型转换、跑一组业务校验，全过才写库，不过就带一份"哪里错了"的报告回来。这正是 changeset 干的事。

## changeset 是把一次写入打包的数据结构

先看心智模型。`%Ecto.Changeset{}` 大致是这几个字段：

```elixir
%Ecto.Changeset{
  data: %Auction.Item{},        # 基准数据：新建时是空 struct，更新时是查出来的那条记录
  params: %{"title" => "...", ...},  # 原始提交参数，string key，cast 之后原样保留
  changes: %{title: "..."},     # 通过过滤和转换、真正要落库的字段，atom key
  errors: [title: {"can't be blank", [validation: :required]}],  # 逐条累积的错误
  required: [:title],
  valid?: false,                # 全部门检查完后的总判定
  action: nil                   # 准备拿这个 changeset 干什么：insert/update/delete/ignore
}
```

它本质上是一份"变更提案"：`data` 是现状，`changes` 是提案内容，`errors` 是审查意见，`valid?` 是结论，`action` 是准备提交给谁审批。落库的实际内容就是 `data` 上叠加 `changes`：新建时 `data` 是空 struct，`changes` 即全部字段；更新时 `data` 是查出来的旧行，`changes` 只是差量。校验函数不改 `data` 也不直接写库，它们只在这张提案上批注。最终 `Repo` 扮演审批人：`valid?` 为真就执行 SQL，为假就原样退回。

这个模型解释了后面所有行为的动机：

- `params` 和 `changes` 分开存，所以你能看到"用户提交了什么"和"我们接受了什么"的差别，比如被 `cast` 丢弃的多余 key 在 `params` 里还留着；
- `errors` 是累积式的，一条记录可以同时背着"标题太短"和"时间过期"两条错误，一次性报全；
- `action` 存在结构体里，所以调用方拿到 `{:error, changeset}` 就知道这份提案是哪一步被拒的，表单也靠它决定要不要显示红字。

还有几个字段平时不太露面，但迟早用到。`required` 记录 `validate_required` 标记过哪些字段，Phoenix 的表单组件靠它给 label 加星号；`types` 是从 schema 推出来的字段类型表，`cast` 就靠它做转换；`filters`/`prepare`/`constraints` 服务于写库阶段的兜底逻辑，本章用不到，先跳过。

changeset 也不绑定 schema。Ecto 允许拿 `{data, types}` 这样的二元组做 changeset，不需要先定义 `use Ecto.Schema` 的模块，临时校验一份 map 或一段表单参数时用得上。`Item` 有自己的 schema，所以本章用标准形态。

## `Item.changeset/2`：cast 过滤，validate 检查

本章给 `Item` schema 加了 `import Ecto.Changeset` 和一个 `changeset/2` 函数：

```elixir
defmodule Auction.Item do
  import Ecto.Changeset
  use Ecto.Schema

  schema "items" do
    field :title, :string
    field :description, :string
    field :ends_at, :utc_datetime
    timestamps()
  end

  def changeset(item, params \\ %{}) do
    item
    |> cast(params, [:title, :description, :ends_at])
    |> validate_required(:title)
    |> validate_length(:title, min: 3)
    |> validate_length(:description, max: 200)
    |> validate_change(:ends_at, &validate/2)
  end

  defp validate(:ends_at, ends_at_date) do
    case DateTime.compare(ends_at_date, DateTime.utc_now()) do
      :lt -> [ends_at: "ends_at cannot be in the past"]
      _ -> []
    end
  end
end
```

`ch08/auction_umbrella/apps/auction/lib/auction/item.ex`

整条管线就是一个 `|>` 链：每一步都接收一个 changeset、返回一个 changeset。`cast` 负责决定"哪些参数算数、它们是什么类型"，后面四个 `validate_*` 负责决定"这些算数的参数合不合规"。顺序不是随便排的：`cast` 必须第一个，因为它才是把外部 params 翻译进 `changes` 的那一步，`validate_*` 检的正是 `changes` 里的值。

`params \\ %{}` 这个默认参数也值得留意：不传 params 就得到一个"什么改动都没有"的 changeset，`valid?` 为真、`changes` 为空。下一章的"新建"表单就是拿它渲染空白表单用的。

### `cast`：白名单过滤，顺手做类型转换

`cast(item, params, [:title, :description, :ends_at])` 是入口，做三件事：

1. **按白名单收参数**。第三个参数列出允许接受的字段，`params` 里其他所有 key 直接丢弃。表单里多塞一个 `"admin": true`，根本走不到 `changes` 里。这是挡 mass-assignment 的第一道门。
2. **按 schema 类型转换**。外部参数几乎都是字符串，比如表单传来的 `"ends_at" => "2030-05-01T12:00:00Z"`。`cast` 看 schema 声明的类型是 `:utc_datetime`，就尝试转成 `DateTime`；转不了就在 `errors` 里记一条 `is invalid`，该字段不进 `changes`。
3. **算出 `changes`**。转换成功的、且和 `data` 里现值不同的字段才进 `changes`。提交的 `title` 和库里一样时，`changes` 里根本不会出现它，`update` 也就不会白跑一遍校验。

params 的 key 既可以是 string 也可以是 atom，混用会报错。表单传来的统一是 string key，内部代码传 atom key 也行，反正 `cast` 都认。

`cast` 还有两个边界行为，写代码时迟早会撞见。`params` 传 `nil` 会得到一个 `valid?` 为假的 changeset，连"提交了什么"都没法成立，所以整体判非法。另外 `cast` 允许字段缺省：表单没提交的字段就是"不改"，进不了 `changes`，也就不会被后面的 `validate_*` 检查到。这就是为什么 `validate_required` 是特殊的那一个：它管的是"必须提交"，其他校验只管"提交了的必须合法"。

类型转换失败的字段会被标记为 `errors` 里的 `is invalid`，且该字段不会进入 `changes`。后面的 `validate_*` 看到 `changes` 里没有它，就当作没提交，不会重复报错。所以一条 `ends_at` 传乱码字符串的参数，errors 里只有一条 `is invalid`，不会再叠一条"不能是过去"。

### `cast` 和 `change` 的分界：外部输入还是可信参数

`Ecto.Changeset` 里还有另一个入口 `change/2`，样子很像：`change(item, title: "x")` 也产出一个 changeset，也会把 `title` 放进 `changes`。差别在它对参数的处理方式完全不同：

- `cast` 收外部 params（map），按白名单挑字段，值类型不合适就在 errors 里记 `is invalid`，changeset 继续活着；
- `change` 收 map 或 keyword list，**没有白名单，给什么收什么**，传了 schema 里不存在的 key 直接抛 `ArgumentError: unknown field`，值类型 cast 不动也当场抛异常，而不是记进 errors。

一句话：`cast` 是"把不可信输入翻译进来"，错误是它的产出物；`change` 是"我明确声明这些改动"，错误是你的 bug。

什么时候用哪个，看数据从哪来：

- **数据来自用户、表单、API 请求：一律 `cast`**。白名单是你的安全边界，`is invalid` 是你要回给用户的反馈。
- **数据是代码自己造的、字段和值都可控：可以 `change`**。比如在 seed 或测试里给 struct 改两个字段再 `Repo.update`。

一个容易踩的坑：拿 `change` 去处理外部 params，等于把白名单绕过了，未知字段和非法值还会以异常的形式炸出来，而不是可控的 `{:error, changeset}`。`Item.changeset/2` 是 context 对外的唯一入口，入口就该按最严格的假设写，所以用 `cast`。

### `validate_*`：只查不改，errors 逐条累积

`cast` 之后的一串 `validate_*` 函数遵守同一个约定：**只检查 `changes` 里的值，发现违规就往 `errors` 追加一条并把 `valid?` 置 `false`，绝不修改数据本身**。

```elixir
    |> validate_required(:title)
    |> validate_length(:title, min: 3)
    |> validate_length(:description, max: 200)
    |> validate_change(:ends_at, &validate/2)
```

`ch08/auction_umbrella/apps/auction/lib/auction/item.ex`

逐个看：

- `validate_required(:title)` 检查 `title` 有没有被提交且不是 `nil`、不是空串。纯空格的字符串也会被 `trim: true`（默认）视作缺失。注意它检的是"在不在"，不是"对不对"：`title: "Hi"` 能过这一关，然后被下一关 `min: 3` 拦下。这一关也是唯一一个"字段没改也会报错"的校验：它检的恰恰是缺失。
- `validate_length(:title, min: 3)` 和 `validate_length(:description, max: 200)` 是字符串长度检查，支持 `min:`、`max:`、`is:`。一个细节：`description` 压根没提交时，`changes` 里没有这个字段，长度校验直接跳过，不报"太短"也不报"太长"。除了 `validate_required` 之外，绝大多数校验都是"没改就当合法"。这带来一个后果：**校验的是增量，不是整条记录**。一条 `ends_at` 已经过期的老数据，只要更新时不动 `ends_at`，就能通过校验。
- `validate_change(:ends_at, &validate/2)` 是自定义入口。内置校验表达不了的规则，就写一个 `(field, value) -> errors` 的函数给它：返回空列表表示通过，返回 `[ends_at: "message"]` 这样的 keyword list 表示报错。这里检查截止时间不能早于当前时刻。

校验的执行顺序就是管线里的声明顺序，所有校验都会跑完，不会因为第一条失败就短路。一个字段被多条校验命中，errors 里就挂多条，提交一次表单能把所有问题一次看全。

还有一类 `*_constraint` 函数（`unique_constraint`、`foreign_key_constraint` 等）容易和 `validate_*` 混淆。区别在时机：`validate_*` 在应用层跑、不发 SQL、校验先于写库；`*_constraint` 不预检，而是照常发 INSERT，把数据库约束的报错翻译回 changeset 错误。本章的表没有任何数据库级约束，用不上它，但思路要知道：**能提前判的用 `validate_*` 在应用层判，必须靠数据库判的（唯一索引、外键）用 `*_constraint` 兜底**。

`validate_number`、`validate_format`、`validate_inclusion`、`validate_subset`、`validate_confirmation` 这些内置校验本章没用上，但写法和 `validate_length` 一样：往管线上再插一步。规则多了之后 `changeset/2` 容易长成一屏的管道，Ecto 的习惯是把它拆成多个小函数再 `|>` 串起来，`Item` 现在的规模还不需要。

## `Repo.insert` 先看 `valid?`，invalid 不发 SQL

changeset 构造完，把它交给 `Repo.insert`，行为分两条路：

```text
params（string key 的 map）
  │ cast/3       白名单过滤 + 类型转换 → changeset.changes
  │ validate_*   逐条检查 → changeset.errors，valid? = false（若有失败）
  ▼
%Ecto.Changeset{data, params, changes, errors, valid?}
  │ Repo.insert
  ├─ valid? == true   → 生成并执行 INSERT → {:ok, %Item{}}
  └─ valid? == false  → 不发任何 SQL     → {:error, %Ecto.Changeset{action: :insert}}
```

三个细节：

- **校验失败的写入是零数据库开销的**。`Repo.insert` 看到 `valid? == false` 直接返回 `{:error, changeset}`，一条 SQL 都没发。开发模式下连 `[debug] QUERY` 日志都不会出现，这是验证校验生效最直观的信号。
- **失败返回的 changeset 上 `action` 被设成 `:insert`**。`Repo.update` 失败则是 `:update`。这个字段后面接表单时有大用：Phoenix 把 changeset 转成 `Phoenix.HTML.Form` 时，只有 `action` 非 `nil` 的 changeset 才会把 `errors` 渲染成红字。原因很实际：一个刚生成的空 changeset 上也挂着 `can't be blank` 之类的错误（`validate_required` 已经在管线上跑过了），要是见到错误就显示，"新建"表单一打开就满屏红。`action` 相当于一个"这是真被拒过的"盖章。
- **`Repo.insert` 也接受裸 struct**，就像第 6 章那样。区别在于裸 struct 没有校验管线可走，永远进不了"退回"这条路。所以"走不走校验"是 context 层的决定，不是 Repo 强制的。测试 setup 里 `Repo.insert(%Item{title: "Item 1"})` 就是裸 struct 直写，fixture 要的就是绕过业务规则的快捷通道。

和 `action` 配套的一个函数是 `Ecto.Changeset.apply_action/2`：不碰数据库，纯在内存里"假设执行"，校验通过返回 `{:ok, item}`，失败返回 `{:error, changeset}` 并把 `action` 标上。写测试或者想在 `Repo` 之外演练校验时用它，行为和 `Repo.insert` 的失败分支一致，只是没有 INSERT。`apply_changes/1` 是它的姊妹函数：不看 `valid?`，硬把 `changes` 套回 `data` 上拿到一个 struct，想预览"改完之后长什么样"而不关心合不合法时用。

写库成功返回的 `{:ok, item}` 里，`item` 已经是数据库回填后的完整 struct：`id` 由 sequence 生成，`inserted_at`/`updated_at` 由 `timestamps()` 宏声明的 autogenerate 填上，`__meta__.state` 是 `:loaded`。`Repo.insert` 发的是一条参数化 INSERT，日志里 `[debug] QUERY` 能看到实际 SQL 和绑定值，这是排查"字段为什么没写进去"的第一手信息。

Ecto 的写函数一律返回 tagged tuple：`Repo.insert(changeset)`、`Repo.update(changeset)`、`Repo.delete(struct)` 都是 `{:ok, struct}` 或 `{:error, changeset}`。对应的 bang 变体 `insert!`/`update!`/`delete!` 失败时抛 `Ecto.InvalidChangesetError`/`Ecto.StaleEntryError`。惯例是：**预期可能失败、需要把错误带回给用户的路径用非 bang 版本；seed、测试、"不成就是 bug"的脚本里用 bang 版本**。`priv/repo/seeds.exs` 顶部注释推荐的就是 bang 写法。

## `insert_item` 和 `update_item`：一条管线，两个起点

`Auction` context 现在的写入侧是成对出现的：

```elixir
  def insert_item(attrs) do
    %Auction.Item{}
    |> Item.changeset(attrs)
    |> @repo.insert()
  end

  def delete_item(%Auction.Item{} = item), do: @repo.delete(item)

  def update_item(%Auction.Item{} = item, updates) do
    item
    |> Item.changeset(updates)
    |> @repo.update()
  end
```

`ch08/auction_umbrella/apps/auction/lib/auction.ex`

`insert_item` 和 `update_item` 的结构完全对称，唯一差别是**管线的起点不同**：insert 从一个空的 `%Auction.Item{}` 出发，`changes` 就是全部字段；update 从一条已加载的 `%Item{}` 出发，`changes` 只装本次改动的字段。同一个 `changeset/2` 函数服务两种场景，这就是为什么它的第一个参数是 `item` 而不是参数写死。

`delete_item` 不走 changeset，直接传 struct 给 `Repo.delete`。删除没有字段要校验，包一层 changeset 没有意义。真要给删除加规则（比如"有外键引用时不许删"），也是用 `foreign_key_constraint` 挂在 changeset 上做，现在没这个需求。

读路径维持原样：`list_items`/`get_item`/`get_item_by` 还是薄封装，返回 struct 或 `nil`，查询没有"校验失败"可言。整个 context 对外的契约现在很整齐：**读返回 struct 或 `nil`，写返回 `{:ok, struct}` 或 `{:error, changeset}`**。调用方不需要知道底下有几条校验规则，拿到 `{:error, changeset}` 就往表单里一传，剩下的交给模板。

`@repo` 依然指向 `Auction.Repo`。`Auction.FakeRepo` 文件还在仓库里留着，但它只有 `all`/`get!`/`get_by` 三个读函数，从没实现过写入接口，第 6 章之后就已经是历史遗留了。真正的 `Repo` 是一个 `use Ecto.Repo` 的空壳模块：

```elixir
defmodule Auction.Repo do
  use Ecto.Repo,
    otp_app: :auction,
    adapter: Ecto.Adapters.Postgres
end
```

`ch08/auction_umbrella/apps/auction/lib/auction/repo.ex`

配置在 `apps/auction/config/config.exs`（`database: "auction"`）和 `config/test.exs`（`database: "auction_test"`、连接池换成 `Ecto.Adapters.SQL.Sandbox`）。context 只认 `@repo`，下面接真库还是假仓对业务代码透明。

## errors 是 `{msg, opts}` 模板，不是最终文案

校验失败拿到的 `changeset.errors` 长这样：

```elixir
[
  title: {"should be at least %{count} character(s)",
   count: 3, validation: :length, kind: :min, type: :string}
]
```

每条错误是 `{field, {message_template, opts}}`：消息是带 `%{count}` 插值的模板，`opts` 里除了插值参数还有 `validation: :length`、`kind: :min` 这类元数据。这是 Ecto 故意的：最终文案可能要走 gettext 翻译、要处理单复数，校验层只负责把"哪错了、参数是什么"记清楚，渲染层再决定怎么写给人看。

把这个结构展开成人话，通用工具是 `Ecto.Changeset.traverse_errors/2`，它把 keyword list 转成 `%{field => [msg]}` 的普通 map。测试文件里已经有一个现成的实现：

```elixir
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
```

`ch08/auction_umbrella/apps/auction/test/auction_test.exs`

这个 helper 几乎是 Ecto 文档里的标准写法：回调拿到 `{msg, opts}`，用正则把 `%{key}` 逐个替换成 `opts[key]` 的值，返回 `%{title: ["should be at least 3 character(s)"]}` 这样的 map。这种形态比 keyword list 好断言、好序列化，后面做 JSON API 的章节往外吐校验错误就靠它。

渲染到 HTML 上走另一条路。`auction_web` 的 `core_components.ex` 里预置了 `translate_error/1` 和 `translate_errors/2`：

```elixir
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(AuctionWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AuctionWeb.Gettext, "errors", msg, opts)
    end
  end

  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
```

`ch08/auction_umbrella/apps/auction_web/lib/auction_web/components/core_components.ex`（注释从略）

`translate_error` 把 `{msg, opts}` 丢给 Gettext：没配翻译就返回英文原文，`opts[:count]` 存在时走 `dngettext` 处理单复数。同一个文件里的 `<.error>` 组件负责把每条文案包进 `<p class="help-block">`。

从 `{:error, changeset}` 到页面红字的完整链路是：controller 原样把 changeset 传给模板，模板里 `Phoenix.Component.to_form(changeset)` 把它转成 `Phoenix.HTML.Form`，因为 `action` 已经被标成 `:insert`，`form.errors` 才携带错误；逐条经 `translate_error` 展开，`<.error>` 输出。下一章做表单时会走完这条路，现在只需要知道：**context 返回的 changeset 原封不动就是表单要的输入，中间不需要任何转接代码**。

## 测试把校验规则钉住

`auction_test.exs` 把写入路径的两端都钉住了。`insert_item` 的用例验证成功路径：行数确实加一，返回的 struct 带着提交上去的属性：

```elixir
  describe "insert_item/1" do
    test "adds an Item to the database" do
      count_query = from(i in Item, select: count(i.id))
      before_count = Repo.one(count_query)
      {:ok, _item} = Auction.insert_item(%{title: "test item"})
      assert Repo.one(count_query) == before_count + 1
    end

    test "the Item in the database has the attributes provided" do
      attrs = %{title: "test item", description: "test description"}
      {:ok, item} = Auction.insert_item(attrs)
      assert item.title == attrs.title
      assert item.description == attrs.description
    end
  end
```

`ch08/auction_umbrella/apps/auction/test/auction_test.exs`

`update_item` 是本章新增的，两个用例刚好覆盖 `{:ok, _}` / `{:error, _}` 两条分支：

```elixir
  describe "update_item/2" do
    test "updates the Item with the attributes provided" do
      {:ok, item} = Repo.insert(%Item{title: "Item 1"})
      {:ok, updated} = Auction.update_item(item, %{title: "Updated Item"})
      assert updated.title == "Updated Item"
      assert Auction.get_item(item.id).title == "Updated Item"
    end

    test "returns an error changeset for invalid attributes" do
      {:ok, item} = Repo.insert(%Item{title: "Item 1"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Auction.update_item(item, %{title: "ab"})

      assert "should be at least 3 character(s)" in errors_on(changeset).title
    end
  end
```

`ch08/auction_umbrella/apps/auction/test/auction_test.exs`

第二条断言的就是前面说的形状：`update_item` 返回 `%Ecto.Changeset{}`，`errors_on` 展开后 `title` 下挂着 `"should be at least 3 character(s)"`。

测试数据的准备方式也在传达约定：`setup` 和用例开头都是 `Repo.insert(%Item{title: "Item 1"})` 裸 struct 直写，跳过 `changeset/2`。fixture 的作用是"把已知数据摆进库里"，不是"模拟用户提交"，绕过校验管线是合理且更便宜的选择。`Ecto.Adapters.SQL.Sandbox` 让每个用例跑在事务里，结束回滚，`test_helper.exs` 里 `Ecto.Adapters.SQL.Sandbox.mode(Auction.Repo, :manual)` 配合用例顶部的 `Ecto.Adapters.SQL.Sandbox.checkout(Repo)` 完成这个机制。

跑起来就一句：

```sh
cd ch08/auction_umbrella
mix test apps/auction
```

5 个用例全绿，其中新加的两条把"`title` 长度小于 3 会被拒、错误信息能展开成可读文案"钉死在回归里。

## 动手验证

在 umbrella 根目录起一个带项目代码的 iex：

```sh
cd ch08/auction_umbrella
iex -S mix
```

先看 `cast` 的类型转换和白名单。`ends_at` 传 ISO8601 字符串，再混进一个不在白名单里的 `"hack"`：

```elixir
iex> params = %{"title" => "Vintage Camera", "ends_at" => "2030-05-01T12:00:00Z", "hack" => true}
iex> cs = Auction.Item.changeset(%Auction.Item{}, params)
iex> cs.valid?
true
iex> cs.changes
%{ends_at: ~U[2030-05-01 12:00:00Z], title: "Vintage Camera"}
iex> cs.params
%{"ends_at" => "2030-05-01T12:00:00Z", "hack" => true, "title" => "Vintage Camera"}
```

字符串 `ends_at` 被转成了 `~U[...]` 的 `DateTime`；`"hack"` 在 `params` 里原样留着，但没进 `changes`，白名单生效。

再走一遍非法参数，看校验在哪关失败：

```elixir
iex> bad = Auction.Item.changeset(%Auction.Item{}, %{"title" => "Hi"})
iex> bad.valid?
false
iex> bad.errors
[title: {"should be at least %{count} character(s)",
  count: 3, validation: :length, kind: :min, type: :string}]
```

`"Hi"` 通过了 `validate_required`（它确实提交了、非空），被 `min: 3` 拦下。`count: 3` 就是 `traverse_errors` 展开时插进 `%{count}` 的值。

现在把校验失败直接带到 context 层。`insert_item` 已经改走 changeset，`title` 太短会直接被退回：

```elixir
iex> Auction.insert_item(%{title: "x"})
{:error,
 %Ecto.Changeset{
   action: :insert,
   changes: %{title: "x"},
   errors: [
     title: {"should be at least %{count} character(s)",
      count: 3, validation: :length, kind: :min, type: :string}
   ],
   data: %Auction.Item<>,
   valid?: false
 }}
```

注意两点：一是返回的是 `{:error, changeset}`，`action` 被标成 `:insert`；二是终端里**没有 `[debug] QUERY` 日志**，INSERT 根本没发出去。这和第 6 章 `struct/2` 写库的行为形成对照，那边无论什么参数都照着发 SQL。

补一个成功路径，再把错误展开成人话：

```elixir
iex> {:ok, item} = Auction.insert_item(%{title: "Road Bike", description: "Single speed, city commuter"})
[debug] QUERY OK db=3.1ms
INSERT INTO "items" ("title","description","inserted_at","updated_at") VALUES ($1,$2,$3,$4) [...]
{:ok, %Auction.Item{id: 1, title: "Road Bike", ...}}

iex> {:error, cs} = Auction.update_item(item, %{title: "ab"})
iex> Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
...>   Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
...>     opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
...>   end)
...> end)
%{title: ["should be at least 3 character(s)"]}
```

这就是测试文件里 `errors_on/1` 的那套代码，在 iex 里原样跑一遍：`{msg, opts}` 被展成 `%{title: [最终文案]}`。

自定义校验也顺手验一下。`ends_at` 传过去的时间，`validate_change` 应当拦下：

```elixir
iex> Auction.insert_item(%{title: "Expired Auction", ends_at: ~U[2020-01-01 00:00:00Z]})
{:error, %Ecto.Changeset{errors: [ends_at: {"ends_at cannot be in the past", _}], ...}}
```

`update_item` 的行为和 `insert_item` 是同一条管线，只换一个起点。把刚才的 `item` 拿来改：

```elixir
iex> {:ok, item} = Auction.update_item(item, %{title: "Vintage Road Bike"})
{:ok, %Auction.Item{title: "Vintage Road Bike", ...}}
iex> Auction.update_item(item, %{title: "x"})
{:error, %Ecto.Changeset{action: :update, ...}}
```

`action` 这次标的是 `:update`，`Repo` 照同样一套规则区分两条写入路径。

最后看一眼 `apply_action` 的用途。拿一个没经过任何 Repo 的 changeset 试：

```elixir
iex> Auction.Item.changeset(%Auction.Item{}, %{title: "x"}) |> Ecto.Changeset.apply_action(:insert)
{:error, %Ecto.Changeset{action: :insert, ...}}
```

行为跟 `Repo.insert` 的失败分支一致，差别是内存里完成的、没碰数据库。表单那边正好相反：一个 `action` 为 `nil` 的 changeset 就算带着 `can't be blank`，`to_form` 渲染时也不会显示错误，这就是"新建"表单首次打开干干净净的原因。

## 小结

本章给写入路径装上了闸门，`Item` 的每一条写库数据都必须先过 `changeset/2`：

- `cast` 是入口，做白名单过滤和类型转换，把外部 params 翻译成 `changes` 里干净的改动；`change` 留给可信的内部调用。
- `validate_required`/`validate_length`/`validate_change` 只查不改，错误逐条累积到 `errors`，除了"缺失"本身以外，校验的都是增量不是整条记录。
- `Repo.insert`/`update` 把 `valid?` 当开关：通过了发 SQL 返回 `{:ok, item}`，不通过零开销返回 `{:error, changeset}` 并把 `action` 标上。
- `insert_item` 和 `update_item` 共用同一条管线，差别只在起点是空 struct 还是已加载记录；`delete_item` 没有字段可校验，直接走裸 struct。
- `errors` 存的是 `{msg, opts}` 模板，`traverse_errors` 展开成 `%{field => [msg]}`，`translate_error` 接 Gettext 渲染成页面文案。

下一章把这条管线接到用户面前：`resources` 路由配出 `/items/new` 和 `/items/:id/edit`，`ItemController` 的 `new`/`create`/`edit`/`update` 走"失败 render、成功 redirect"的三段式，heex 里的 `<.form>` 把 `{:error, changeset}` 渲染成字段下的红字。本章攒下的 `{:error, changeset}` 到那时候才第一次被用户看见。
