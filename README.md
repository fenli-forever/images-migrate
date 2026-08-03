# images-migrate

Docker 镜像同步代理：通过 GitHub Actions 自动把公网镜像（Docker Hub 等）搬运到自建 Harbor，解决国内 Docker Hub 访问受限的场景。

## 工作原理

```
push to master
      |
      v
GitHub Actions  -->  docker login harbor  -->  for each image in images.yaml:
                                                  multiarch: false -> skopeo copy（流式复制）
                                                  multiarch: true  -> buildx imagetools（筛选平台）
                                              汇总成功/失败
```

两条路径都不会执行 `docker pull`，因此镜像层不会解压到 GitHub Runner 的 Docker `overlay2`，可同步体积远大于 Runner 剩余磁盘的单架构镜像。

- **单架构源（默认）**：用 `skopeo copy` 在两个 registry 之间流式复制压缩层，不保留本地镜像；平台白名单不适用。
- **多架构源**：用 `docker buildx imagetools` 跨 registry 复制，并按 `target.platforms` 白名单筛选 digest、重组 manifest list。当前默认只保留 `linux/amd64` 和 `linux/arm64/v8`。
- **未配置 `target.platforms`**：源的所有平台全部保留。

## 一次性准备

在 GitHub 仓库 `Settings -> Secrets and variables -> Actions` 添加：

| Name | 说明 |
|---|---|
| `HARBOR_USERNAME` | Harbor 用户名 |
| `HARBOR_PASSWORD` | Harbor 密码 |

**密码绝不写进任何文件**。

## 日常使用：加一个新镜像

1. 编辑 `images.yaml`：

   ```yaml
   target:
     registry: harbor.example.com   # 你的 Harbor 域名
     namespace: library             # Harbor 项目名
     platforms:                     # 多架构源仅保留这些平台；不写则保留全部
       - linux/amd64
       - linux/arm64/v8

   images:
     - source: nginx:1.25                  # 自动 -> harbor.example.com/library/nginx:1.25
     - source: redis:7-alpine              # 自动 -> harbor.example.com/library/redis:7-alpine
     - source: alpine:3.19
       target: base/alpine:3.19            # 显式 -> harbor.example.com/library/base/alpine:3.19
   ```

2. 提交到 master：

   ```bash
   git add images.yaml
   git commit -m "add nginx:1.25"
   git push origin master
   ```

3. 去 `Actions` 标签页看进度。完成后即可拉取：

   ```bash
   docker pull harbor.example.com/library/nginx:1.25
   ```

## 命名规则

最终地址 = `<registry>/<namespace>/<target_path>`

- 不写 `target`：取 `source` 最后一段（`docker.io/library/alpine:3.19` -> `alpine:3.19`）
- 写 `target`：完全覆盖路径段

## 本地测试

```bash
# 仅校验配置，不真推送
bash scripts/sync.sh --dry-run

# 本地完整同步（需要先 docker login）
bash scripts/sync.sh
```

依赖：`docker`（含 buildx）、[`skopeo`](https://github.com/containers/skopeo)、[`yq`](https://github.com/mikefarah/yq)、`jq`。工作流会自动安装 `skopeo` 和 `yq`。

## 手动触发

`Actions -> sync images to harbor -> Run workflow`。

## 触发条件

只有以下文件变更才会触发同步（避免改 README 也跑一遍）：

- `images.yaml`
- `scripts/sync.sh`
- `.github/workflows/sync.yml`
