# MasterWater

Local-first 知乎文章仓库。本地 Markdown 是唯一真源。

## 同步命令

在仓库根目录运行：

```powershell
.\sync --dry-run
.\sync
```

也可以指定 Git commit 信息：

```powershell
.\sync.ps1 -Message "Update article notes"
```

`sync` 只检查相对当前 `HEAD` 新增或修改的 Markdown。frontmatter 中含有 `zhihu_article_id`、`zhihu_token` 或 `article_id` 时，该文件归入知乎同步；没有这些字段时只提交到 GitHub。

同步顺序固定为：

1. 列出修改的 Markdown；
2. 逐篇更新带知乎文章 ID 的文件；
3. 知乎全部成功后执行 `git add --all`、`git commit`；
4. 推送到 `origin/main`。

任何知乎更新失败都会立即停止，不创建 Git commit，也不推送。已经成功更新的文章不会回滚；本地文件仍保持未提交状态，再次运行 `sync` 会重新处理这些文件。

## 当前知乎能力限制

已安装的知乎 Skill 0.7.1 / CLI 0.6.0 只提供本人文章读取、评论和统计，没有文章创建、发布或更新命令。官方开放平台文档也没有公开文章写入 API。

因此当前 `sync --dry-run`、Git 增量识别和 GitHub-only 同步路径可用；只要修改项中包含带知乎文章 ID 的文件，正式 `sync` 会在知乎预检阶段安全失败，并保证不 commit、不 push。

知乎发布适配层位于 `scripts/publish-zhihu-article.ps1`。当知乎提供官方更新命令后，只需按其文档补齐这个适配层，不需要改动同步事务和 Git 流程。

`export_zhihu_articles.py` 是一次性导入/补档工具。它默认跳过已存在的 Markdown，防止远端内容覆盖本地真源；只有显式传入 `--overwrite` 才会覆盖本地文件。

## 文章元数据

当前文章使用：

```yaml
---
title: "文章标题"
date: 2026-09-26
source: https://zhuanlan.zhihu.com/p/123456
zhihu_token: 123456
---
```

`zhihu_token` 即原知乎文章 ID。同步命令从元数据读取 ID，不会创建新的知乎文章。
