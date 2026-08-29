#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${PROJECT_DIR}/dist/Grove.app"
CONTENTS_DIR="${APP_DIR}/Contents"
ICON_SOURCE_PATH="${PROJECT_DIR}/Support/GroveIcon.png"
ICONSET_DIR="${PROJECT_DIR}/.build/Grove.iconset"
ASSET_CATALOG_DIR="${PROJECT_DIR}/.build/GroveAssets.xcassets"
ASSET_ICONSET_DIR="${ASSET_CATALOG_DIR}/AppIcon.appiconset"
ASSET_OUTPUT_DIR="${PROJECT_DIR}/.build/GroveAssetOutput"
ASSET_INFO_PATH="${PROJECT_DIR}/.build/GroveAssetInfo.plist"

echo "正在构建 Grove Release 版本…"

# 图标母图是脚本画出来的，不进版本库也能随时重建。
if [[ ! -f "${ICON_SOURCE_PATH}" ]]; then
    swift "${PROJECT_DIR}/scripts/draw-icon.swift" "${ICON_SOURCE_PATH}"
fi

swift "${PROJECT_DIR}/scripts/generate-icon.swift" "${ICON_SOURCE_PATH}" "${ICONSET_DIR}"

rm -rf "${ASSET_CATALOG_DIR}" "${ASSET_OUTPUT_DIR}"
mkdir -p "${ASSET_ICONSET_DIR}" "${ASSET_OUTPUT_DIR}"
ditto "${ICONSET_DIR}" "${ASSET_ICONSET_DIR}"
install -m 644 \
    "${PROJECT_DIR}/Support/Assets.xcassets/AppIcon.appiconset/Contents.json" \
    "${ASSET_ICONSET_DIR}/Contents.json"

# 编译成 Assets.car。Dock 和 Finder 认的是这个，
# 光把 PNG 丢进 Resources 只能让「关于」窗口有图标。
xcrun actool "${ASSET_CATALOG_DIR}" \
    --compile "${ASSET_OUTPUT_DIR}" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "${ASSET_INFO_PATH}" \
    --warnings \
    --notices > /dev/null

swift build --package-path "${PROJECT_DIR}" -c release
BIN_DIR="$(swift build --package-path "${PROJECT_DIR}" -c release --show-bin-path)"

rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources"
install -m 755 "${BIN_DIR}/Grove" "${CONTENTS_DIR}/MacOS/Grove"
install -m 644 "${PROJECT_DIR}/Support/Info.plist" "${CONTENTS_DIR}/Info.plist"
install -m 644 "${ICON_SOURCE_PATH}" "${CONTENTS_DIR}/Resources/GroveIcon.png"
ditto "${ASSET_OUTPUT_DIR}/" "${CONTENTS_DIR}/Resources/"

SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | head -n 1
)"
if [[ -n "${SIGNING_IDENTITY}" ]]; then
    codesign --force --deep --options runtime --timestamp=none --sign "${SIGNING_IDENTITY}" "${APP_DIR}"
    echo "已使用 Apple Development 签名：${SIGNING_IDENTITY}"
else
    # 临时签名（ad-hoc）足够本机运行。没有签名的话 Gatekeeper 会直接拒绝启动。
    codesign --force --deep --sign - "${APP_DIR}"
    echo "未找到 Apple Development 证书，已使用临时签名。"
fi

echo "App 构建完成：${APP_DIR}"
