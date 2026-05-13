# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目目标

Docker 镜像同步代理。维护一份镜像清单 + 目标 Harbor 仓库地址，提交到 master 后由 GitHub Actions 自动 `pull → tag → push`，把公网镜像（Docker Hub 等）搬运到自建 Harbor。解决国内访问 Docker Hub 受限的场景。

## 架构

三件套，缺一不可：

- **`images.yaml`** — 唯一可变配置。`target.registry`（Harbor 域名）、`target.namespace`（Harbor 项目名）、`target.platforms`（多架构源的平台白名单，不配则保留全部）、`images[]`（源镜像列表，可选 `target` 字段覆盖目标命名，可选 `multiarch: true` 走 imagetools 多架构流程，默认 false 走 pull-tag-push）。**禁止写入用户名/密码**。
- **`scripts/sync.sh`** — 同步执行核心。流程：`yq` 解析 yaml → `imagetools inspect --raw` 抓取源 manifest → 判断单 / 多架构 → 多架构时按 `target.platforms` 用 `jq` 筛 digest → `imagetools create --tag <target> <src>@<digest>...` 重组并推送。跨 registry 直接复制 manifest 与 blob，不落盘。单镜像失败不中断整体，全部跑完后汇总；任一失败则脚本以非 0 退出。
- **`.github/workflows/sync.yml`** — 调度入口。`push` 到 master 且 `images.yaml` / `scripts/sync.sh` / workflow 自身变更时触发，附加 `workflow_dispatch` 手动重跑入口。`docker login` 凭据来自 Secrets。

## 多架构平台过滤

`target.platforms` 是白名单。**只对多架构源生效**——单架构源原样推（即便其平台不在白名单里）。

平台匹配规则（`find_digest_for_platform` 函数实现）：
- `linux/amd64` 精确匹配 os=linux, arch=amd64, variant 缺省或空
- `linux/arm64/v8` 匹配 os=linux, arch=arm64, **variant=v8 或缺省**（兼容很多官方镜像把 arm64 写成无 variant 的情况）
- 其他 `os/arch/variant` 走精确匹配

## 凭据

只走 GitHub Secrets，不走任何文件：

- `HARBOR_USERNAME`
- `HARBOR_PASSWORD`

变更凭据 → 改 Secrets，不改代码、不改配置。

## 镜像命名规则

最终目标地址 = `<target.registry>/<target.namespace>/<target_path>`

- 不指定 `target`：取 `source` 最后一段（`docker.io/library/alpine:3.19` → `alpine:3.19`）
- 指定 `target`：完全覆盖路径段（例：`base/alpine:3.19`）

## 常用命令

本地干跑（不真推送，校验配置）：

```bash
bash scripts/sync.sh --dry-run
```

本地真跑（需要本地 docker 已 `docker login`）：

```bash
bash scripts/sync.sh
```

## 添加镜像的标准流程

1. 编辑 `images.yaml`，在 `images:` 下追加一项
2. 本地 `--dry-run` 验证一遍
3. 提交到 master → workflow 自动跑

无需改代码。

## 红线

- 仓库内任何文件不得出现明文密码/token
- Workflow 触发 `paths` 不能扩展到全仓库（避免无关变更触发同步）
- 不为兼容旧用法保留废弃字段；改配置 schema 时统一升级 `images.yaml`
