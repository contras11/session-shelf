#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
bundle_root="$project_root/dist/Session Shelf.app"
contents="$bundle_root/Contents"
macos_dir="$contents/MacOS"
resources_dir="$contents/Resources"
iconset_dir="$project_root/.build/SessionShelf.iconset"
master_icon="$project_root/.build/AppIcon-1024.png"

if [[ "$bundle_root" != "$project_root/dist/Session Shelf.app" ]]; then
    print -u2 "予期しないバンドル出力先です"
    exit 2
fi

swift build -c release --product SessionShelf

rm -rf "$bundle_root" "$iconset_dir"
mkdir -p "$macos_dir" "$resources_dir" "$iconset_dir"

cp "$project_root/.build/release/SessionShelf" "$macos_dir/SessionShelf"
chmod 755 "$macos_dir/SessionShelf"
cp "$project_root/Resources/Info.plist" "$contents/Info.plist"

swift "$project_root/scripts/generate_icon.swift" "$master_icon"

for specification in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"; do
    pixels="${specification%% *}"
    filename="${specification#* }"
    sips -z "$pixels" "$pixels" "$master_icon" --out "$iconset_dir/$filename" >/dev/null
done

iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"
codesign --force --deep --sign - "$bundle_root"
plutil -lint "$contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$bundle_root"

print "$bundle_root"
