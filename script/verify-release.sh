#!/bin/bash

set -euo pipefail

if [[ $# -ne 6 ]]; then
    echo "Usage: $0 <app-path> <dmg-path> <dsym-path> <version> <build-number> <team-id>" >&2
    exit 64
fi

app_path=$1
dmg_path=$2
dsym_path=$3
version=$4
build_number=$5
team_id=$6
info_plist="$app_path/Contents/Info.plist"

if [[ ! -d "$app_path" || ! -f "$dmg_path" || ! -d "$dsym_path" ]]; then
    echo "Release app, disk image, or dSYM is missing." >&2
    exit 66
fi

bundle_identifier=$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")
bundle_version=$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")
bundle_build_number=$(plutil -extract CFBundleVersion raw -o - "$info_plist")
if [[ "$bundle_identifier" != "dev.matcha.macos" ]]; then
    echo "Unexpected bundle identifier: $bundle_identifier" >&2
    exit 65
fi
if [[ "$bundle_version" != "$version" ]]; then
    echo "Unexpected bundle version: $bundle_version" >&2
    exit 65
fi
if [[ "$bundle_build_number" != "$build_number" ]]; then
    echo "Unexpected bundle build number: $bundle_build_number" >&2
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

binary_uuids=$(xcrun dwarfdump --uuid "$app_path/Contents/MacOS/$executable_name" \
    | awk '{ print $2, $3 }' \
    | sort)
dsym_binary="$dsym_path/Contents/Resources/DWARF/$executable_name"
dsym_uuids=$(xcrun dwarfdump --uuid "$dsym_binary" \
    | awk '{ print $2, $3 }' \
    | sort)
if [[ -z "$binary_uuids" || "$binary_uuids" != "$dsym_uuids" ]]; then
    echo "Application and dSYM UUIDs do not match." >&2
    exit 65
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
signature_details=$(codesign -dvvv "$app_path" 2>&1)
if ! grep -Fq "TeamIdentifier=$team_id" <<< "$signature_details"; then
    echo "App signature does not belong to team $team_id." >&2
    exit 65
fi
if ! grep -Eq '^Authority=Developer ID Application:' <<< "$signature_details"; then
    echo "App is not signed with a Developer ID Application certificate." >&2
    exit 65
fi
if ! grep -Eq '^flags=.*runtime' <<< "$signature_details"; then
    echo "App signature does not enable the hardened runtime." >&2
    exit 65
fi
if ! grep -Eq '^Timestamp=' <<< "$signature_details"; then
    echo "App signature does not contain a secure timestamp." >&2
    exit 65
fi

codesign --verify --strict --verbose=2 "$dmg_path"
xcrun stapler validate "$app_path"
xcrun stapler validate "$dmg_path"
syspolicy_check distribution "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
hdiutil verify "$dmg_path"
