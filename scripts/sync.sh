#!/usr/bin/env bash
#
# 读取 images.yaml，把每个 source 镜像 pull → tag → push 到目标 Harbor。
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
[[ -f "$CONFIG_FILE" ]] || { echo "Config file not found: $CONFIG_FILE" >&2; exit 1; }

REGISTRY=$(yq -r '.target.registry' "$CONFIG_FILE")
NAMESPACE=$(yq -r '.target.namespace' "$CONFIG_FILE")
COUNT=$(yq -r '.images | length' "$CONFIG_FILE")

[[ -n "$REGISTRY"  && "$REGISTRY"  != "null" ]] || { echo "target.registry missing"  >&2; exit 1; }
[[ -n "$NAMESPACE" && "$NAMESPACE" != "null" ]] || { echo "target.namespace missing" >&2; exit 1; }
[[ "${COUNT:-0}" -gt 0 ]] || { echo "images list is empty" >&2; exit 1; }

declare -a SUCCESS=()
declare -a FAILED=()

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
    # source 形如 docker.io/library/alpine:3.19 或 nginx:1.25，取最后一段
    TARGET_PATH="${SOURCE##*/}"
  fi

  FULL_TARGET="${REGISTRY}/${NAMESPACE}/${TARGET_PATH}"

  echo "===== [$((i+1))/$COUNT] $SOURCE  ->  $FULL_TARGET ====="

  if [[ "$DRY_RUN" -eq 1 ]]; then
    SUCCESS+=("$SOURCE -> $FULL_TARGET (dry-run)")
    continue
  fi

  if docker pull "$SOURCE" \
     && docker tag  "$SOURCE" "$FULL_TARGET" \
     && docker push "$FULL_TARGET"; then
    SUCCESS+=("$SOURCE -> $FULL_TARGET")
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
