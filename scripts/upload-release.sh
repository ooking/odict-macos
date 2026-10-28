#!/bin/sh
# Upload an existing development build; never build, re-sign, or push code.
set -eu
umask 077
cd "$(dirname "$0")/.."

repo=ooking/odict-macos
app=build/Build/Products/Release/ODict.app
work_dir=
remote_attempted=no
completed=no

fail() {
    echo "错误：$*" >&2
    exit 1
}

usage() {
    echo '用法：sh scripts/upload-release.sh v<应用版本号>'
    echo '将已有 Release 产物打包并直接发布为 GitHub Pre-release（未经 Apple 公证）。'
}

cleanup() {
    result=$?
    trap - EXIT
    if [ -n "$work_dir" ]; then
        rm -rf "$work_dir"
    fi
    if [ "$remote_attempted" = yes ] && [ "$completed" != yes ]; then
        echo "发布未确认完成。请查看 https://github.com/$repo/releases，确认是否已有草稿或已发布的预览版。" >&2
        echo '不会自动删除 Release、附件或标签。若有草稿，可在网页补齐附件后发布；详细恢复步骤见 docs/building.md。' >&2
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
    usage
    exit 0
fi
[ "$#" -eq 1 ] || { usage >&2; exit 1; }
tag=$1
case "$tag" in
    v[0-9]*) ;;
    *) fail '标签应为 v<应用版本号>，例如 v1.0.1。' ;;
esac
case "${tag#v}" in
    *[!0-9.]*|*..*|*.) fail '版本号仅允许由点分隔的数字。' ;;
esac

command -v gh >/dev/null 2>&1 || fail '请先安装 GitHub CLI（gh），并运行 gh auth login --hostname github.com。'
gh auth status --hostname github.com >/dev/null 2>&1 || fail 'GitHub 尚未登录或凭据不可用，请运行 gh auth login --hostname github.com。'
[ -d "$app" ] && [ -f "$app/Contents/Info.plist" ] || fail "缺少编译产物：$app。请先单独编译。"

output_dir="$(pwd)/build/releases/$tag"
mkdir -p "$output_dir"
work_dir=$(mktemp -d "$output_dir/.upload.XXXXXX")
# Validate and package the same snapshot, independent of subsequent local builds.
/usr/bin/ditto "$app" "$work_dir/ODict.app"
snapshot="$work_dir/ODict.app"
plist="$snapshot/Contents/Info.plist"
plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist"
}
version=$(plist_value CFBundleShortVersionString) || fail '无法读取应用版本号。'
build_number=$(plist_value CFBundleVersion) || fail '无法读取 Build 号。'
executable=$(plist_value CFBundleExecutable) || fail '无法读取应用可执行文件名。'
minimum_os=$(plist_value LSMinimumSystemVersion) || fail '无法读取最低系统版本。'
[ "$tag" = "v$version" ] || fail "标签 $tag 与编译产物版本 v$version 不一致。"
case "$build_number" in
    ''|*[!0-9.]*) fail '编译产物 Build 号无效。' ;;
esac
case "$executable" in
    ''|.|..|*/*) fail '编译产物的可执行文件名无效。' ;;
esac
[ "$(plist_value CFBundleIdentifier)" = com.touchany.odict.mac ] || fail '产物不是预期的 ODict 应用。'
[ "$(plist_value CFBundlePackageType)" = APPL ] || fail '产物不是应用程序包。'
case "$minimum_os" in
    12.0|12.0.0) ;;
    *) fail "产物最低系统版本为 $minimum_os，与发布说明要求的 macOS 12 不一致。" ;;
esac
binary="$snapshot/Contents/MacOS/$executable"
[ -f "$binary" ] && [ -x "$binary" ] || fail '应用可执行文件缺失或不可执行。'
for resource in LICENSE THIRD_PARTY_NOTICES.md; do
    [ -f "$snapshot/Contents/Resources/$resource" ] || fail "应用缺少资源：$resource。"
done
/usr/bin/codesign --verify --deep --strict --all-architectures "$snapshot" || fail '应用签名验证失败，不会上传或修改签名。'
signature=$(/usr/bin/codesign --display --verbose=4 "$snapshot" 2>&1) || fail '无法读取签名信息。'
case "$signature" in
    *'Authority=Apple Development:'*) ;;
    *) fail '此脚本仅发布现有 Apple Development 开发签名产物。' ;;
esac
architectures=$(/usr/bin/lipo -archs "$binary") || fail '无法读取应用架构。'
for required_arch in arm64 x86_64; do
    case " $architectures " in
        *" $required_arch "*) ;;
        *) fail '产物必须同时包含 arm64 和 x86_64 架构。' ;;
    esac
done

# Use an explicit GitHub host, regardless of the current checkout or GH_HOST.
gh_repo="github.com/$repo"
gh api --hostname github.com "repos/$repo/git/ref/tags/$tag" >/dev/null || fail "无法确认远程标签 $tag；请先将对应版本标签推送到 GitHub。"
# Listing also finds drafts; API errors must never be mistaken for an absent release.
existing=$(gh api --hostname github.com --paginate "repos/$repo/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$tag\") | .id") || fail '无法检查已有 Release，已停止。'
[ -z "$existing" ] || fail "$tag 已有 Release（可能是草稿），请在 GitHub 查看；不会覆盖已有附件。"

zip_name="ODict-$version-macOS-universal.zip"
checksum_name="$zip_name.sha256"
notes_name=release-notes.md
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$snapshot" "$work_dir/$zip_name"
(
    cd "$work_dir"
    /usr/bin/shasum -a 256 "$zip_name" > "$checksum_name"
)
cat > "$work_dir/$notes_name" <<EOF
## ODict $version 预览版

- Build：$build_number
- 系统要求：macOS 12 或更高版本
- 架构：Apple 芯片（arm64）与 Intel（x86_64）
- 签名：Apple Development 开发签名，未经 Apple 公证

### 安装

1. 下载附件 $zip_name，解压后将 ODict.app 拖入“应用程序”。升级前请完全退出旧版。
2. 首次打开若被系统拦截，仅在确认下载来源可信后，进入“系统设置 → 隐私与安全性 → 仍要打开”；macOS 12 对应“系统偏好设置 → 安全性与隐私 → 通用”。受管理设备可能不允许手动放行。
3. 按需授予应用请求的系统权限。

此版本供预览试用；开发签名不等同于 Developer ID 发行签名或 Apple 公证。

### 校验下载

将 ZIP 与 $checksum_name 放在同一目录，运行：

    shasum -a 256 -c $checksum_name

首次打开说明：https://support.apple.com/102445
EOF
# Keep completed artifacts for manual recovery; only temporary snapshots are removed.
for filename in "$zip_name" "$checksum_name" "$notes_name"; do
    mv "$work_dir/$filename" "$output_dir/$filename"
done
echo "已打包 ODict $version（Build $build_number）：$output_dir/$zip_name"
echo "即将发布至 $repo，标签 $tag，类型 Pre-release。"

# A failed response can still mean the server created a draft, so warn from here on.
remote_attempted=yes
gh release create "$tag" --repo "$gh_repo" --verify-tag --draft --prerelease \
    --title "ODict $version Preview" --notes-file "$output_dir/$notes_name" || fail '创建草稿失败。'
gh release upload "$tag" "$output_dir/$zip_name" "$output_dir/$checksum_name" \
    --repo "$gh_repo" || fail '附件上传失败，草稿已保留。'
gh release edit "$tag" --repo "$gh_repo" --verify-tag --draft=false \
    --prerelease --latest=false || fail '发布请求失败，请先到 GitHub 确认状态。'
completed=yes
echo "预览版已发布：https://github.com/$repo/releases/tag/$tag"
