#!/usr/bin/env bash
#
# 读取 images.yaml，把每个 source 镜像复制到目标 Harbor。
# 用 docker buildx imagetools：
#   - 多架构源：按 target.platforms 过滤（用 source@digest 形式重组 manifest list）
#   - 单架构源：原样复制
#   - 未配置 target.platforms：原样保留源的所有平台
# 跨 registry 直接复制 manifest 与 blob，不在 runner 上落盘镜像层。
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
command -v jq     >/dev/null || { echo "jq not found in PATH" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker not found in PATH" >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "docker buildx not available" >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "Config file not found: $CONFIG_FILE" >&2; exit 1; }

REGISTRY=$(yq -r '.target.registry' "$CONFIG_FILE")
NAMESPACE=$(yq -r '.target.namespace' "$CONFIG_FILE")
COUNT=$(yq -r '.images | length' "$CONFIG_FILE")

[[ -n "$REGISTRY"  && "$REGISTRY"  != "null" ]] || { echo "target.registry missing"  >&2; exit 1; }
[[ -n "$NAMESPACE" && "$NAMESPACE" != "null" ]] || { echo "target.namespace missing" >&2; exit 1; }
[[ "${COUNT:-0}" -gt 0 ]] || { echo "images list is empty" >&2; exit 1; }

mapfile -t DESIRED_PLATFORMS < <(yq -r '.target.platforms[]?' "$CONFIG_FILE")

if [[ ${#DESIRED_PLATFORMS[@]} -eq 0 ]]; then
  echo "target.platforms 未配置，多架构源将原样保留所有平台"
else
  echo "目标平台过滤: ${DESIRED_PLATFORMS[*]}"
fi

declare -a SUCCESS=()
declare -a FAILED=()

# 在 manifest list JSON 中找匹配平台的 digest。
# 兼容 arm64/v8 在源镜像里 variant 缺省的情况（很多官方镜像就这么写）。
find_digest_for_platform() {
  local raw="$1"
  local desired="$2"
  local os arch variant
  os=$(echo "$desired" | cut -d/ -f1)
  arch=$(echo "$desired" | cut -d/ -f2)
  variant=$(echo "$desired" | cut -d/ -f3-)

  printf '%s' "$raw" | jq -r --arg os "$os" --arg arch "$arch" --arg variant "$variant" '
    .manifests[]?
    | select(.platform.os == $os and .platform.architecture == $arch)
    | select(
        ($variant == "" and (.platform.variant == null or .platform.variant == ""))
        or ($variant != "" and .platform.variant == $variant)
        or ($arch == "arm64" and ($variant == "v8" or $variant == "")
            and (.platform.variant == "v8" or .platform.variant == null or .platform.variant == ""))
      )
    | .digest
  ' | head -1
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

  RAW=$(docker buildx imagetools inspect --raw "$SOURCE" 2>/dev/null || true)

  declare -a SOURCES_FOR_CREATE=()

  if [[ -z "$RAW" ]]; then
    # imagetools inspect 失败，回退到 pull → tag → push
    echo "  imagetools inspect 无结果，尝试 pull → tag → push"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      SUCCESS+=("$SOURCE -> $FULL_TARGET (dry-run, pull-tag-push)")
      continue
    fi

    if ! docker pull "$SOURCE"; then
      echo "  FAIL: 镜像不存在或无访问权限"
      FAILED+=("$SOURCE -> $FULL_TARGET (pull failed)")
      continue
    fi

    docker tag "$SOURCE" "$FULL_TARGET"
    if docker push "$FULL_TARGET"; then
      SUCCESS+=("$SOURCE -> $FULL_TARGET (pull-tag-push)")
    else
      FAILED+=("$SOURCE -> $FULL_TARGET (push failed)")
    fi
    docker rmi "$SOURCE" "$FULL_TARGET" 2>/dev/null || true
    continue
  fi

  IS_MANIFEST_LIST=$(printf '%s' "$RAW" | jq -r 'if has("manifests") then "yes" else "no" end')

  if [[ "$IS_MANIFEST_LIST" == "no" ]]; then
    echo "  单架构源，原样复制（平台过滤不适用）"
    SOURCES_FOR_CREATE=("$SOURCE")
  elif [[ ${#DESIRED_PLATFORMS[@]} -eq 0 ]]; then
    PLATFORM_COUNT=$(printf '%s' "$RAW" | jq '.manifests | length')
    echo "  多架构源，未配置过滤，原样复制全部 $PLATFORM_COUNT 个平台"
    SOURCES_FOR_CREATE=("$SOURCE")
  else
    echo "  多架构源，按 target.platforms 过滤:"
    for plat in "${DESIRED_PLATFORMS[@]}"; do
      digest=$(find_digest_for_platform "$RAW" "$plat")
      if [[ -n "$digest" && "$digest" != "null" ]]; then
        echo "    [OK]   $plat  -> ${digest:0:19}..."
        SOURCES_FOR_CREATE+=("${SOURCE}@${digest}")
      else
        echo "    [SKIP] $plat  (源镜像无此平台)"
      fi
    done

    if [[ ${#SOURCES_FOR_CREATE[@]} -eq 0 ]]; then
      echo "  FAIL: 源镜像不含任何配置的目标平台"
      FAILED+=("$SOURCE -> $FULL_TARGET (no matching platforms)")
      continue
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    SUCCESS+=("$SOURCE -> $FULL_TARGET (dry-run, ${#SOURCES_FOR_CREATE[@]} ref)")
    continue
  fi

  if docker buildx imagetools create --tag "$FULL_TARGET" "${SOURCES_FOR_CREATE[@]}"; then
    SUCCESS+=("$SOURCE -> $FULL_TARGET (${#SOURCES_FOR_CREATE[@]} ref)")
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
