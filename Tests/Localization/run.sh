#!/bin/zsh
set -eu
root="${0:A:h:h:h}"
app="${1:-/tmp/mangar-device-derived/Build/Products/Debug-iphoneos/Mangar.app}"
scratch=$(mktemp -d /tmp/mangar-localization-check.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
python3 "$root/Tests/Localization/check.py"
xcrun swiftc -parse-as-library -swift-version 5 "$root/Mangar/Localization/AppLanguage.swift" "$root/Mangar/Localization/L10n.swift" "$root/Tests/Localization/main.swift" -o "$scratch/check"
"$scratch/check" "$app" "$root/Mangar/Localization/Localizable.xcstrings"
