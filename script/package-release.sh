#!/bin/bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <app-path> <dsym-path> <version> <output-directory>" >&2
    exit 64
fi

app_path=$1
dsym_path=$2
version=$3
output_directory=$4

if [[ ! -d "$app_path" || "${app_path##*.}" != "app" ]]; then
    echo "App bundle does not exist: $app_path" >&2
    exit 66
fi
if [[ ! -d "$dsym_path" || "${dsym_path##*.}" != "dSYM" ]]; then
    echo "dSYM bundle does not exist: $dsym_path" >&2
    exit 66
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use MAJOR.MINOR.PATCH: $version" >&2
    exit 65
fi

info_plist="$app_path/Contents/Info.plist"
bundle_version=$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")
if [[ "$bundle_version" != "$version" ]]; then
    echo "App version $bundle_version does not match requested version $version." >&2
    exit 65
fi

executable_name=$(plutil -extract CFBundleExecutable raw -o - "$info_plist")
architectures=$(lipo -archs "$app_path/Contents/MacOS/$executable_name")
for required_architecture in arm64 x86_64; do
    if [[ " $architectures " != *" $required_architecture "* ]]; then
        echo "App executable is missing $required_architecture: $architectures" >&2
        exit 65
    fi
done

mkdir -p "$output_directory"
artifact_base="Rei-v$version"
zip_path="$output_directory/$artifact_base.zip"
dmg_path="$output_directory/$artifact_base.dmg"
dsym_zip_path="$output_directory/$artifact_base.dSYM.zip"

for output_path in "$zip_path" "$dmg_path" "$dsym_zip_path"; do
    if [[ -e "$output_path" ]]; then
        echo "Refusing to overwrite existing release artifact: $output_path" >&2
        exit 73
    fi
done

staging_root=$(mktemp -d "${TMPDIR:-/tmp}/rei-package.XXXXXX")
cleanup() {
    rm -rf -- "$staging_root"
}
trap cleanup EXIT

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
ditto -c -k --keepParent "$dsym_path" "$dsym_zip_path"

dmg_root="$staging_root/dmg"
mkdir -p "$dmg_root"
ditto "$app_path" "$dmg_root/Rei.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
    -volname "Rei $version" \
    -srcfolder "$dmg_root" \
    -format UDZO \
    "$dmg_path"
hdiutil verify "$dmg_path"

printf '%s\n' "$zip_path" "$dmg_path" "$dsym_zip_path"
