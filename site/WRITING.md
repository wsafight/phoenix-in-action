# 章节写作规范

本目录 `src/content/docs/chapters/` 下每章一个 `.md` 文件，文件名即 slug。

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
| ch03.md | ch03/blog | 第一个 Phoenix 应用：生成器、MVC、Post/Comment |
| ch04-05.md | ch04 + ch05 | Umbrella 项目、auction 上下文、FakeRepo |
| ch06.md | ch06 | auction_web：Endpoint、Router、Controller、模板渲染 |
| ch07.md | ch07 | 接入 Ecto Repo、Item schema、迁移 |
| ch08.md | ch08 | Ecto changeset、校验、list/get/insert |
| ch09.md | ch09 | Items CRUD：form、heex 模板、redirect |
| ch10.md | ch10 | 用户注册、Pbkdf2 密码哈希、登录 Session、plug 认证 |
| ch11.md | ch11 | Bid 出价：belongs_to 关联、嵌套表单、校验金额 |
| ch12.md | ch12 | Phoenix Channel：ItemChannel、广播 new_bid、前端 socket.js |
| ch13.md | ch13 | JSON API：Api.ItemController、render json、视图 |
| ch14.md | ch14 | 收尾：测试、API 完善、项目结构回顾 |
