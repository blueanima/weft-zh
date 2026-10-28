#!/bin/bash
# Packages build/Weft.app into build/release/Weft-<version>.dmg.
#
# This is the "no paid developer account" path: the app is signed with whatever local
# identity you have (or ad-hoc), and the DMG ships with an install note explaining how to
# get past Gatekeeper's first-launch warning.
#
# Once you have a "Developer ID Application" certificate, use scripts/release.sh instead —
# it signs, notarizes and staples, so the DMG opens with no warning at all.
#
# Environment:
#   VERSION   version string to stamp into the bundle (default: 0.2.0)
#   IDENTITY  signing identity (default: first "Apple Development" in the keychain, else ad-hoc)
#   APP_SRC   app bundle to package (default: build/Weft.app)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION=${VERSION:-0.2.0}
APP_SRC=${APP_SRC:-$ROOT/build/Weft.app}
OUT=$ROOT/build/release

step() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

[[ -d $APP_SRC ]] || die "$APP_SRC not found. Build the app first."

if [[ -z ${IDENTITY:-} ]]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)
fi
[[ -n ${IDENTITY:-} ]] || IDENTITY="-"
if [[ $IDENTITY == "-" ]]; then
    echo "note: no signing identity found, falling back to ad-hoc signing."
fi

rm -rf "$OUT"
mkdir -p "$OUT/staging"

step "Copying $APP_SRC"
ditto "$APP_SRC" "$OUT/staging/Weft.app"
APP=$OUT/staging/Weft.app

step "Stamping version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

step "Signing with $IDENTITY"
if ! codesign --force --options runtime --entitlements "$ROOT/App/Weft.entitlements" \
        --sign "$IDENTITY" --timestamp "$APP" 2>/dev/null; then
    echo "note: timestamp server unreachable, signing without it."
    codesign --force --options runtime --entitlements "$ROOT/App/Weft.entitlements" \
        --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --deep "$APP"

step "Writing install note"
cat > "$OUT/staging/安装说明.txt" <<'NOTE'
Weft 中文版 —— 安装说明
======================

一、安装
  把左边的 Weft.app 拖进右边的「应用程序」文件夹。

二、首次打开被系统拦下时
  这个版本没有使用 Apple 付费开发者证书（99 美元/年）签名，所以 macOS 的
  门禁（Gatekeeper）在第一次启动时会拦一下。放行一次以后就不会再问。

  方法一（推荐，最简单）
    在「应用程序」里找到 Weft，按住 Control 键点它（或右键），
    选择「打开」，在弹出的窗口里再点一次「打开」。

  方法二（方法一无效时）
    「系统设置」→「隐私与安全性」→ 往下翻到「安全性」区域，
    会看到一条关于 Weft 被阻止的提示，点「仍要打开」。

  方法三（终端，最干脆）
    打开「终端」，粘贴下面这行，输入密码回车：

      sudo xattr -dr com.apple.quarantine /Applications/Weft.app

    然后正常双击即可。

三、启动之后
  Weft 常驻菜单栏，不占 Dock，顶部会出现一个圆环图标。
  第一次运行会请求两项权限：
    · 辅助功能（读取前台窗口标题）—— 用于判断你在做什么
    · 自动化（读取浏览器当前标签页网址）—— 用于给网页细分归类
  两项都可以稍后在「系统设置 → 隐私与安全性」里调整。

四、配置 DeepSeek 后端
  点菜单栏图标 →「设置」→「AI」页签：
    1. 模型提供方选「DeepSeek」
    2. 填入 API Key（在 platform.deepseek.com 创建，sk- 开头）
    3. 点「测试连接」，成功后关闭窗口

  API Key 只保存在本机钥匙串里，网络请求只发往 api.deepseek.com。
  不配置也能用：内置规则和自定义规则仍然会归类，只是没有语义分析。

五、系统要求
  macOS 26 或更新版本，Apple Silicon 或 Intel 均可。

源码与问题反馈：https://github.com/blueanima/weft-zh
NOTE

ln -s /Applications "$OUT/staging/Applications"

DMG=$OUT/Weft-$VERSION-zh.dmg
step "Creating $(basename "$DMG")"
hdiutil create -quiet -volname "Weft" -srcfolder "$OUT/staging" -format UDZO -fs HFS+ "$DMG"

if [[ $IDENTITY != "-" ]]; then
    codesign --force --sign "$IDENTITY" "$DMG" 2>/dev/null || true
fi

rm -rf "$OUT/staging"

step "Result"
ls -lh "$DMG" | sed 's/^/    /'
echo
echo "    Gatekeeper verdict for the app inside (expected: rejected, it isn't notarized):"
spctl --assess --type execute --verbose=2 "$APP_SRC" 2>&1 | sed 's/^/      /' || true
echo
echo "    Publish with: gh release create v$VERSION \"$DMG\" --title \"Weft $VERSION 中文版\""
