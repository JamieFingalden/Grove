#!/bin/zsh

# 把 dist/Grove.app 打成 dist/Grove-<版本>.dmg。先跑 scripts/build.sh。
#
# 用 hdiutil 而不是 create-dmg 之类的第三方工具：不多一个依赖，而且我们要的
# 只是「一个能拖进 Applications 的压缩只读镜像」，没有背景图和图标排版的需求。

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${PROJECT_DIR}/dist/Grove.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_DIR}/Support/Info.plist")"
DMG_PATH="${PROJECT_DIR}/dist/Grove-${VERSION}.dmg"

if [[ ! -d "${APP_DIR}" ]]; then
    echo "找不到 ${APP_DIR}，先运行 zsh scripts/build.sh" >&2
    exit 1
fi

# 版本号来自 Info.plist；同名 dmg 已经存在说明这个版本发过了，
# 静默覆盖会把已经分发出去的那份换掉，让人对不上号。
if [[ -e "${DMG_PATH}" ]]; then
    echo "${DMG_PATH} 已存在。先在 Support/Info.plist 里升版本号，或者手动删掉旧文件。" >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/grove-dmg.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT

# ditto 保留签名需要的扩展属性和资源分叉；cp -R 在某些卷上会丢。
ditto "${APP_DIR}" "${STAGING_DIR}/Grove.app"
# 指向 /Applications 的链接：打开镜像后直接拖过去就装好了。
ln -s /Applications "${STAGING_DIR}/Applications"

echo "正在生成 ${DMG_PATH}…"
hdiutil create \
    -volname "Grove ${VERSION}" \
    -srcfolder "${STAGING_DIR}" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -quiet \
    "${DMG_PATH}"

hdiutil verify -quiet "${DMG_PATH}"
echo "DMG 构建完成：${DMG_PATH}"
