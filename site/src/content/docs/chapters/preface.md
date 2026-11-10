---
title: 序章 · 这本书要构建什么
description: 从一个内存里的假仓库，到一个有实时竞价、LiveView 页面和 JSON API 的拍卖系统——跟着 13 个代码快照，把一个 Phoenix 应用从零养大
sidebar:
  order: 0
---

这本书只讲一件事：怎么用 Phoenix 1.7 把一个真实应用从零搭起来。

用的不是 Hello World 示例，也不是生成器默认页面——是一个**拍卖网站**。它能列出商品、新建/编辑商品、注册用户、登录登出、给商品出价，出价会实时推到所有正在看这件商品的浏览器，还有一套供外部程序调用的 JSON API。到最后一章，它是长这样的：

- **领域层**住在 `auction` 应用里：Item、Bid、User 三张表，changeset 校验，context 收敛所有公开 API；
- **Web 层**住在 `auction_web` 应用里：Bandit 起 HTTP 服务，Endpoint 串 plug 链，Router 分 pipeline，heex 模板渲染页面，Channel 推 WebSocket；
- **两个应用装在一个 umbrella 里**，共享一份 `_build`/`deps`/`config`，`auction_web` 通过 `in_umbrella` 依赖调用 `auction` 的公共函数——业务代码对 HTTP 一无所知。

## 跟着代码走，不跟书走

仓库里每个章节目录是一个**可运行的代码快照**，不是"示例片段"：`ch04/auction.ex` 能直接 `iex` 加载，`ch07/auction_umbrella` 能 `mix phx.server` 起服务，`ch15/auction_umbrella` 的 `mix test` 全绿。每一章的讲法都是：**先打开代码，再解释它为什么长这样**。

顺序按应用的"成长"排，不按技术主题排：

1. 先用一个 `mix phx.new` 生成的 Blog 看懂 Phoenix 应用的骨架长什么样（第 1 章）；
2. 再换到拍卖项目，把领域核心先写成三个不依赖框架的普通模块（第 2 章），然后才装进 umbrella、接 Web、接数据库（第 3–6 章）；
3. 之后每一章补一块真实需求：写入校验、CRUD 页面、用户认证、出价、实时推送、JSON API（第 7–13 章）；
4. 再往后是 Phoenix 1.7 的主战场：API 写接口、LiveView 详情页、GenServer 出价缓存（第 14–16 章）；
5. 收尾两章回到全景：目录结构、整条请求链路、测试体系（第 17–18 章）。

这个顺序是故意的。直接上 Phoenix 容易学成"路由怎么写、模板怎么写"，先写没有框架的领域层能让你看清一件事：**Phoenix 只是给 context 包了一层壳，应用的本体从来不在 Web 层**。

## 代码和书的关系

所有代码快照都已经迁到 **Phoenix 1.7 / Elixir 1.20** 的现代写法：heex 模板、`embed_templates`、function components、`~p` 路由验证、Bandit、CoreComponents。不是"老代码凑活能跑"，是按 1.7 的惯用法重写的——正文里引的每一段都能在仓库里原样找到。

如果手里有 1.4 时代的老项目，附录里有一份完整的迁移对照表（依赖、config、视图层、模板语法、静态资源），可以单独当工具用。

## 跑起来需要什么

- Elixir 1.14+、Erlang/OTP 25+（本仓库在 Elixir 1.20 / OTP 29 上验过）；
- PostgreSQL 跑在本地 5432，账号 `postgres`/`postgres`（第 6 章起用得到；前几章不需要数据库）；
- 一个能开 `http://localhost:4000` 的浏览器。

每章末尾都有"动手验证"：命令能复制就跑，预期输出是实测过的，不是猜的。

准备好了，从第 1 章开始——`mix phx.new blog`。
