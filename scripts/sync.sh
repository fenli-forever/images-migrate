#!/usr/bin/env bash
#
# 读取 images.yaml，把每个 source 镜像复制到目标 Harbor。
# 用 docker buildx imagetools：
#   - 自动保留多架构 manifest（不会因为 runner 是 amd64 就丢掉 arm64/arm/v7 等变体）
#   - 跨 registry 直接复制 manifest 与 blob，不落盘镜像层
# 单条失败不中断整体，结束时汇总；任一失败则脚本以 1 退出。

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-images.yaml}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--dry-run]

环境变量:
  CONFIG_FILE   配置文件路径，默认 images.yaml
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

command -v yq     >/dev/null || { echo "yq not found in PATH" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker not found in PATH" >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "docker buildx not available" >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "Config file not found: $CONFIG_FILE" >&2; exit 1; }

REGISTRY=$(yq -r '.target.registry' "$CONFIG_FILE")
NAMESPACE=$(yq -r '.target.namespace' "$CONFIG_FILE")
COUNT=$(yq -r '.images | length' "$CONFIG_FILE")

[[ -n "$REGISTRY"  && "$REGISTRY"  != "null" ]] || { echo "target.registry missing"  >&2; exit 1; }
[[ -n "$NAMESPACE" && "$NAMESPACE" != "null" ]] || { echo "target.namespace missing" >&2; exit 1; }
[[ "${COUNT:-0}" -gt 0 ]] || { echo "images list is empty" >&2; exit 1; }

declare -a SUCCESS=()
declare -a FAILED=()

# 列出源镜像支持的平台（一行一个，已去重）。失败时输出为空。
inspect_platforms() {
  local image="$1"
  docker buildx imagetools inspect "$image" 2>/dev/null \
    | awk '/^Platform:/ {print $2}' \
    | sort -u
}

for ((i=0; i<COUNT; i++)); do
  SOURCE=$(yq -r ".images[$i].source" "$CONFIG_FILE")
  TARGET_OVERRIDE=$(yq -r ".images[$i].target // \"\"" "$CONFIG_FILE")

  if [[ -z "$SOURCE" || "$SOURCE" == "null" ]]; then
    echo "images[$i].source missing, skipped" >&2
    FAILED+=("images[$i]: source missing")
    continue
  fi

  if [[ -n "$TARGET_OVERRIDE" ]]; then
    TARGET_PATH="$TARGET_OVERRIDE"
  else
    TARGET_PATH="${SOURCE##*/}"
  fi

  FULL_TARGET="${REGISTRY}/${NAMESPACE}/${TARGET_PATH}"

  echo "===== [$((i+1))/$COUNT] $SOURCE  ->  $FULL_TARGET ====="

  PLATFORMS=$(inspect_platforms "$SOURCE" || true)
  PLATFORM_COUNT=$(printf '%s\n' "$PLATFORMS" | grep -c . || true)

  if [[ "$PLATFORM_COUNT" -eq 0 ]]; then
    echo "  WARN: 探测平台失败（源镜像不存在或无访问权限），仍尝试复制"
  elif [[ "$PLATFORM_COUNT" -eq 1 ]]; then
    echo "  单架构: $PLATFORMS"
  else
    echo "  多架构: $PLATFORM_COUNT 个平台"
    printf '%s\n' "$PLATFORMS" | sed 's/^/    - /'
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    SUCCESS+=("$SOURCE -> $FULL_TARGET (dry-run, ${PLATFORM_COUNT}p)")
    continue
  fi

  # 单条命令同时处理单架构 / 多架构，原样保留 manifest 类型
  if docker buildx imagetools create --tag "$FULL_TARGET" "$SOURCE"; then
    SUCCESS+=("$SOURCE -> $FULL_TARGET (${PLATFORM_COUNT}p)")
  else
    FAILED+=("$SOURCE -> $FULL_TARGET")
  fi
done

echo
echo "===== Summary ====="
echo "Success: ${#SUCCESS[@]}"
for x in "${SUCCESS[@]}"; do echo "  [OK]   $x"; done
echo "Failed:  ${#FAILED[@]}"
for x in "${FAILED[@]}";  do echo "  [FAIL] $x"; done

[[ "${#FAILED[@]}" -eq 0 ]] || exit 1
