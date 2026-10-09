#!/bin/zsh
set -eu
root="${0:A:h:h:h}"
scratch=$(mktemp -d /tmp/mangar-brush-check.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
cd "$root"
xcrun swiftc -parse-as-library -swift-version 5 \
  Mangar/Editor/DocumentModel.swift Mangar/Editor/LayerShape.swift \
  Mangar/Editor/PageArrangement.swift Mangar/Editor/PressureCurve.swift \
  Mangar/Editor/AppToolPreferences.swift Mangar/Rendering/SelectionSnapshot.swift \
  Mangar/Brushes/Model/*.swift Mangar/Brushes/Presets/*.swift \
  Mangar/Brushes/Resources/*.swift Mangar/Brushes/GPU/*.swift Mangar/Brushes/Runtime/MetalBrushEngine.swift Mangar/Brushes/Runtime/BrushChangeTracker.swift \
  Tests/BrushEngine/main.swift -o "$scratch/check"
"$scratch/check" "$root"
