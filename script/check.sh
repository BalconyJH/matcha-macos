#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

xcodebuild -version

swift format lint \
    --configuration .swift-format \
    --strict \
    --parallel \
    --recursive \
    Package.swift App Sources Tests

swift test -Xswiftc -warnings-as-errors

xcodebuild \
    -project Matcha.xcodeproj \
    -scheme "Matcha App" \
    -configuration Debug \
    -destination "generic/platform=macOS" \
    -derivedDataPath .build/xcode \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    build
