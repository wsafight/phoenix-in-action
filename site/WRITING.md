# 章节写作规范

本目录 `src/content/docs/chapters/` 下每章一个 `.md` 文件，文件名即 slug
（`NN-slug` 命名，`NN` 为章节序号）。

## 文件格式

```markdown
---
title: 第X章 · 标题
description: 一句话概括本章内容
sidebar:
  order: N
---

正文……
```

- 语言：简体中文，技术术语保留英文（context、changeset、heex、Channel 等）
- 写作风格：教程式，先讲"为什么"再讲"怎么做"；直接、具体，不堆砌形容词
- 引用代码：**逐字**取自仓库迁移后的代码文件（Phoenix 1.7 写法），代码块标注语言 `elixir`/`heex`/`bash`
- 每段代码引用后用一行注明路径，格式：`` `ch14/auction_umbrella/apps/auction/lib/auction.ex` ``
- 每章结构建议：本章目标 → 概念讲解（穿插代码）→ 动手验证（iex/mix 命令）→ 小结 + 下章预告
- 篇幅：200–450 行，重点文件可整段引用但要有解释，不要变成代码清单
- 不得复制 Manning《Phoenix in Action》原书文字；所有讲解文字为原创
- heex 模板代码块用 ```` ```heex ```` 标注
- 可在章节末尾加 `:::note`/`:::tip` 星标提示（Starlight aside 语法）

## 章节 ↔ 仓库目录

| 站点文件 | 仓库代码 | 主题 |
| --- | --- | --- |
| 01-blog-skeleton.md | ch03/blog | Blog 骨架：生成器、Endpoint/Router/模板 |
| 02-domain-core.md | ch04 | 无框架领域层：Auction、Item、FakeRepo |
| 03-umbrella.md | ch05 | umbrella 化：apps/ 拆分、application.ex |
| 04-request-pipeline.md | ch06 | 请求管道：Endpoint plug 链、Router、pipeline |
| 05-render-pipeline.md | ch06 | 渲染管线：*_html + embed_templates、Layouts、Plug.Static |
| 06-ecto-repo.md | ch07 | Ecto Repo、Item schema、迁移 |
| 07-changeset.md | ch08 | changeset、校验、insert/update |
| 08-crud.md | ch09 | Items CRUD：form、heex、redirect、_method |
| 09-users.md | ch10 | 用户注册：users 表、Pbkdf2、changeset_with_password |
| 10-login.md | ch10 | 登录与守门：session、Authenticator、函数 plug |
| 11-bids.md | ch11 | 出价：belongs_to、嵌套路由、preload |
| 12-channel.md | ch12 | Channel：ItemChannel、广播 new_bid、app.js |
| 13-json-api.md | ch13 | JSON API：/api scope、*_json 渲染模块 |
| 14-api-write.md | ch14 | API 写接口：Api.Authenticate、POST items/bids、ChangesetJSON |
| 15-liveview.md | ch15 | LiveView：ItemLive.Show、live_session、handle_info |
| 16-otp-cache.md | ch15 | OTP：BidCache GenServer、cache-aside、let it crash |
| 17-architecture.md | ch15 | 项目全貌：目录树、应用边界、链路总览 |
| 18-testing.md | ch14 | 测试体系：ConnCase/ChannelCase、Sandbox、mix test |
