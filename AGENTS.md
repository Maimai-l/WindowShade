# 项目约定

WindowShade 是一个 macOS 窗口工具：双击标题栏，窗口收起成一条留在原处的卷帘条。
源码在 `prototype/`，构建、测试、签名和发布见 [`DEVELOPMENT.md`](DEVELOPMENT.md)。
整体设计、功能需求和改写计划见 [`docs/design.md`](docs/design.md)；改代码前先对上它。
测试的内容和方法见 [`docs/testing.md`](docs/testing.md)。修复缺陷时先写能复现它的测试，再改代码；新增需求时同时补测试。修复缺陷的顺序、等待和什么时候问用户，见 [`docs/fix-process.md`](docs/fix-process.md)。
面向用户的说明见 [`README_CN.md`](README_CN.md) / [`README.md`](README.md)。

## 文案（产品与官网共用）

面向用户的每一句文案都按 [`docs/copy-guide.md`](docs/copy-guide.md) 写：照 macOS 自带 App 和“系统设置”的写法，
一个东西只有一个名字。拿不准时在 `docs/apple-zh-strings.tsv.gz` 里找系统的同类说法。

用词表也在那份文件里（收起/展开、卷帘条、卷帘条置顶、按编号展开……），菜单、设置、面板、官网必须一致。

## 设计

书面令牌在 [`docs/design-system.md`](docs/design-system.md)，画面稿在 [`docs/design-drafts/`](docs/design-drafts/README.md)。
改界面之前先对上稿；稿和令牌对不上时，画面照稿，差异记进 [`docs/design-grammar.md`](docs/design-grammar.md)。
稿是画面，不是源码，不嵌进工程。

## 提交

- 提交信息第一行写这次改了什么，一句话，不加句号，不超过 72 列；需要解释原因时空一行写正文。
- 不写交付批次、工单号或流程用语，写清楚改动本身。
- 推送前跑 `prototype/build.sh --check` 和相关的 `tests/run-*.sh`；CI 会在 macOS 上再跑一遍。
- 改了用户可见的文字、代码注释或文档时，提交前交给独立的语言审查者（`.claude/agents/language-review.md`）审一遍，写的人按审查结果改，不自己审自己。
