#!/usr/bin/env bash
#
# SmartBook 客户端 —— 一键构建脚本
# 作用：在 Windows(Git Bash) 上构建 smartbook 客户端 APK / AAB，并把产物输出到本工作区 deploy/。
#
# 用法示例：
#   # 最简（构建 prod 版 APK,默认 arm64 —— 约 19-20MB;全 ABI 版用 --arch universal）：
#   bash deploy/build.sh
#
#   # 指定通用版(三 ABI)+ 版本与构建号：
#   bash deploy/build.sh --arch universal --app-version 0.0.1 --build-number 5
#
#   # 同时生成 APK 和 AAB：
#   bash deploy/build.sh --with-aab
#
#   # 调试 flavor + 只跑分析不打包：
#   bash deploy/build.sh --flavor dev --analyze-only
#
# 依赖（脚本会尽力自检，缺失即报错退出）：
#   - Flutter SDK  (默认 $HOME/devtools/flutter-3.27.3-sdk，可用 FLUTTER_HOME 覆盖)
#   - JDK 17      (默认 $HOME/devtools/jdk-17，可用 JAVA_HOME 覆盖)
#   - Android SDK (默认 %LOCALAPPDATA%/Android/Sdk，可用 ANDROID_HOME 覆盖)
#   - sdkmanager 已装 platforms;android-36 与 build-tools;35.0.0（脚本会校验）

set -euo pipefail

# ---------------------------------------------------------------- 定位脚本与根
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 工作区根（deploy/ 的上一级）
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Flutter 客户端源码目录（工作区内 client/）
CLIENT_DIR="$REPO_ROOT/client"
# 产物输出目录(与部署模板同放 deploy/,便于取用)
DEPLOY_DIR="$REPO_ROOT/deploy"

# ---------------------------------------------------------------- 颜色输出
if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; BLUE=""; NC=""
fi
log_info()  { echo -e "${BLUE}[i]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_err()   { echo -e "${RED}[x]${NC} $*" >&2; }

die() { log_err "$*"; exit 1; }

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  echo
  echo "参数："
  echo "  --app-version <v>   显式版本（写入 pubspec）；缺省时自动：首次 1.0.0，每次构建 +1（记录于根 .build-version-client）"
  echo "  --build-number <n>  构建号（写入 pubspec，默认 1）"
  echo "  --arch <a>          目标 ABI：universal|arm64|armv7|x86_64（默认 arm64）"
  echo "  --flavor <f>        prod|dev（默认 prod）"
  echo "  --with-aab          同时生成 Android App Bundle（.aab）"
  echo "  --analyze-only      仅 flutter analyze（不打包）"
  echo "  --tag <t>           打成 dart-define CI_VERSION（默认 dev-<version>）"
  echo "  --clean             先 clean 再构建（清 gradle/flutter 缓存）"
  echo "  -h|--help           显示本帮助"
}

# ---------------------------------------------------------------- 默认值
APP_VERSION=""
BUILD_NUMBER=1
# 默认 arm64:真实设备 99%+ 为 arm64,单 ABI 产物 ~19-20MB(三 ABI 通用版 ~46MB);
# 全设备兼容或模拟器场景用 --arch universal。
ARCH="arm64"
FLAVOR="prod"
WITH_AAB=0
ANALYZE_ONLY=0
TAG=""
DO_CLEAN=0

# ---------------------------------------------------------------- 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-version)   APP_VERSION="$2"; shift 2 ;;
    --build-number)  BUILD_NUMBER="$2"; shift 2 ;;
    --arch)          ARCH="$2"; shift 2 ;;
    --flavor)        FLAVOR="$2"; shift 2 ;;
    --with-aab)      WITH_AAB=1; shift ;;
    --analyze-only)  ANALYZE_ONLY=1; shift ;;
    --tag)           TAG="$2"; shift 2 ;;
    --clean)         DO_CLEAN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "未知参数: $1（用 -h 查看用法）" ;;
  esac
done

case "$ARCH" in
  universal|arm64|armv7|x86_64) ;;
  *) die "--arch 只支持 universal|arm64|armv7|x86_64，收到 '$ARCH'" ;;
esac
case "$FLAVOR" in
  prod|dev) ;;
  *) die "--flavor 只支持 prod|dev，收到 '$FLAVOR'" ;;
esac

# ---------------------------------------------------------------- 版本号(自动递增)
# 缺省时：首次从 1.0.0 开始，每次构建末位 +1（1.0.0 → 1.0.1 → …），记录于工作区根
# .build-version-client；显式 --app-version 覆盖且不写记录。
VERSION_FILE="$REPO_ROOT/.build-version-client"
if [[ -z "$APP_VERSION" ]]; then
  if [[ -f "$VERSION_FILE" ]]; then
    PREV="$(cat "$VERSION_FILE")"
    if [[ ! "$PREV" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      die "版本记录文件无效: $VERSION_FILE ($PREV)；删除后自动回到 1.0.0"
    fi
    IFS='.' read -r VMAJ VMIN VPAT <<< "$PREV"
    APP_VERSION="$VMAJ.$VMIN.$((VPAT + 1))"
  else
    APP_VERSION="1.0.0"
  fi
  echo "$APP_VERSION" > "$VERSION_FILE"
  log_info "版本自动递增: $APP_VERSION（记录 $VERSION_FILE；BUILD_NUMBER=$BUILD_NUMBER）"
else
  log_info "版本(显式): $APP_VERSION（--app-version，未写版本记录）"
fi

if [[ -z "$TAG" ]]; then TAG="dev-$APP_VERSION"; fi

# ---------------------------------------------------------------- 工具链探测
# 允许用户通过环境变量覆盖，否则回退到本机默认安装位置。
FLUTTER_HOME="${FLUTTER_HOME:-$HOME/devtools/flutter-3.27.3-sdk}"
JAVA_HOME="${JAVA_HOME_OVERRIDE:-$HOME/devtools/jdk-17}"
ANDROID_HOME="${ANDROID_HOME:-$LOCALAPPDATA/Android/Sdk}"

FLUTTER_BIN="$FLUTTER_HOME/bin/flutter"
export JAVA_HOME="$JAVA_HOME"
export ANDROID_HOME="$ANDROID_HOME"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$FLUTTER_HOME/bin:$PATH"

log_info "工作区根     : $REPO_ROOT"
log_info "客户端源码   : $CLIENT_DIR"
log_info "Flutter      : $FLUTTER_BIN"
log_info "JDK          : $JAVA_HOME"
log_info "Android SDK  : $ANDROID_HOME"

[[ -x "$FLUTTER_BIN" ]] || die "找不到 Flutter：$FLUTTER_BIN（可用 FLUTTER_HOME 覆盖，或先装 Flutter SDK）"
[[ -x "$JAVA_HOME/bin/java.exe" || -x "$JAVA_HOME/bin/java" ]] || die "找不到 JDK17：$JAVA_HOME（可用 JAVA_HOME 覆盖）"
[[ -d "$ANDROID_HOME/platforms/android-36" ]] || die "Android SDK 缺 android-36：请先 sdkmanager --install 'platforms;android-36' 'build-tools;35.0.0'"
[[ -d "$CLIENT_DIR/lib" ]] || die "客户端源码不完整：无 $CLIENT_DIR/lib（请确认 client/ 已就位）"

# 编译期需要 JDK17，检查当前 java 是否够版本
JAVA_VER="$("$JAVA_HOME/bin/java.exe" -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')"
if (( JAVA_VER < 17 )); then
  die "JDK 需 17+，当前主版本为 $JAVA_VER（请设置 JAVA_HOME 指向 JDK17）"
fi
log_ok "工具链校验通过（JDK $JAVA_VER）"

# ---------------------------------------------------------------- 进入客户端
cd "$CLIENT_DIR"
log_info "pubspec 当前版本：$(grep '^version:' pubspec.yaml)"

# ---------------------------------------------------------------- 可选：clean
if (( DO_CLEAN )); then
  log_warn "执行 flutter clean（会删除 build/ 与 .dart_tool/，下次构建从零开始）"
  flutter clean >/dev/null 2>&1 || true
fi

# 跨盘符 Kotlin 增量编译坑：本项目在 D:，Pub 缓存在 C:，二者不同盘符。
# Kotlin 增量缓存会报 "base files have different roots"，虽非致命但会导致回退
# 非增量重编译、拖慢构建。这里主动清掉 Kotlin 增量缓存目录，避免该问题。
KOTLIN_CACHE_DIRS=$(find "$CLIENT_DIR/build" -type d -path '*compileReleaseKotlin*' -o -type d -path '*compileDebugKotlin*' 2>/dev/null || true)
if [[ -n "$KOTLIN_CACHE_DIRS" ]]; then
  log_info "清理 Kotlin 增量编译缓存（避免跨盘符 different-roots 问题）"
  rm -rf "$KOTLIN_CACHE_DIRS" 2>/dev/null || true
fi

# ---------------------------------------------------------------- flutter pub get
log_info "flutter pub get ..."
flutter pub get >/dev/null 2>&1 || { flutter pub get; die "flutter pub get 失败"; }
log_ok "依赖解析完成"

# ---------------------------------------------------------------- 写入版本号
log_info "设置版本 $APP_VERSION+$BUILD_NUMBER ..."
sed -i.bak "s/^version: .*/version: ${APP_VERSION}+${BUILD_NUMBER}/" pubspec.yaml
rm -f pubspec.yaml.bak
log_ok "pubspec 已更新：$(grep '^version:' pubspec.yaml)"

# ---------------------------------------------------------------- analyze
if (( ANALYZE_ONLY )); then
  log_info "仅分析模式：flutter analyze ..."
  flutter analyze
  log_ok "分析完成"
  exit 0
fi

# ---------------------------------------------------------------- 构建 APK
# arch 决定 flutter build 的目标：
#   universal -> 单个 app-prod-release.apk（三 ABI 全含）
#   arm64     -> app-arm64-v8a-<flavor>-release.apk
#   armv7     -> app-armeabi-v7a-<flavor>-release.apk
#   x86_64    -> app-x86_64-<flavor>-release.apk
case "$ARCH" in
  universal) APK_SUFFIX="" ;;
  arm64)     APK_SUFFIX="--target-platform android-arm64" ;;
  armv7)     APK_SUFFIX="--target-platform android-arm" ;;
  x86_64)    APK_SUFFIX="--target-platform android-x64" ;;
esac

# CI 环境下可能提供 GIT_COMMIT，否则回退到 git 或 dev
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo 'dev')}"
BUILD_TIME="${BUILD_TIME:-$(date +%s)}"

log_info "构建 ${FLAVOR}/${ARCH} APK（tag=$TAG, commit=$GIT_COMMIT）……这可能耗时较久（首次约 5-15 分钟，视网络与缓存）"
# shellcheck disable=SC2086
flutter build apk --release --flavor "$FLAVOR" \
  --dart-define=CI_VERSION="$TAG" \
  --dart-define=GIT_COMMIT="$GIT_COMMIT" \
  --dart-define=BUILD_TIME="$BUILD_TIME" \
  $APK_SUFFIX
log_ok "APK 构建完成"
BUILD_APK_DIR="$CLIENT_DIR/build/app/outputs/flutter-apk"

# ---------------------------------------------------------------- 构建 AAB（可选）
if (( WITH_AAB )); then
  log_info "构建 AAB ..."
  flutter build appbundle --release --flavor "$FLAVOR" \
    --dart-define=CI_VERSION="$TAG" \
    --dart-define=GIT_COMMIT="$GIT_COMMIT" \
    --dart-define=BUILD_TIME="$BUILD_TIME" \
    >/dev/null 2>&1 || { log_warn "flutter build appbundle 失败（可能因 PLAY 权限裁剪，可忽略）"; }
  log_ok "AAB 构建完成（如有）"
fi

# ---------------------------------------------------------------- 收拢产物
mkdir -p "$DEPLOY_DIR"
rm -f "$DEPLOY_DIR"/smartbook-*.apk "$DEPLOY_DIR"/smartbook-*.aab "$DEPLOY_DIR"/smartbook-*.sha256 2>/dev/null || true

copy_apk() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || { log_warn "未找到产物：$src"; return 1; }
  cp "$src" "$dst"
  log_ok "已生成：$dst（$(du -h "$dst" | cut -f1)）"
  # 生成校验和
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$dst" > "$dst.sha256"
    log_info "  校验和：$(cat "$dst.sha256" | cut -c1-16)…"
  fi
}

SRC_UNIVERSAL="$BUILD_APK_DIR/app-$FLAVOR-release.apk"
SRC_ARM64="$BUILD_APK_DIR/app-arm64-v8a-$FLAVOR-release.apk"
SRC_ARMV7="$BUILD_APK_DIR/app-armeabi-v7a-$FLAVOR-release.apk"
SRC_X86="$BUILD_APK_DIR/app-x86_64-$FLAVOR-release.apk"

case "$ARCH" in
  universal) copy_apk "$SRC_UNIVERSAL" "$DEPLOY_DIR/smartbook-$FLAVOR-${TAG}.apk" ;;
  arm64)     copy_apk "$SRC_ARM64"     "$DEPLOY_DIR/smartbook-$FLAVOR-arm64-${TAG}.apk" ;;
  armv7)     copy_apk "$SRC_ARMV7"     "$DEPLOY_DIR/smartbook-$FLAVOR-armv7-${TAG}.apk" ;;
  x86_64)    copy_apk "$SRC_X86"       "$DEPLOY_DIR/smartbook-$FLAVOR-x86_64-${TAG}.apk" ;;
esac

if (( WITH_AAB )); then
  SRC_AAB="$CLIENT_DIR/build/app/outputs/bundle/$FLAVORRelease/app-$FLAVOR-release.aab"
  [[ -f "$SRC_AAB" ]] && copy_apk "$SRC_AAB" "$DEPLOY_DIR/smartbook-$FLAVOR-${TAG}.aab"
fi

# ---------------------------------------------------------------- 汇总
echo
log_ok "构建完成！产物位于：$DEPLOY_DIR"
echo
echo "=========================================================="
echo " 版本      : $APP_VERSION+$BUILD_NUMBER"
echo " flavor    : $FLAVOR"
echo " arch      : $ARCH"
echo " tag       : $TAG"
echo " Git commit: $GIT_COMMIT"
echo "=========================================================="
echo " 若需安装到设备：adb install -r \"$DEPLOY_DIR/smartbook-$FLAVOR-${TAG}.apk\""
