#!/bin/zsh
set -eu
root="${0:A:h:h:h}"
scratch=$(mktemp -d /tmp/mangar-brush-check.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
cd "$root"
xcrun swiftc -parse-as-library -swift-version 5 \
  Mangar/Localization/AppLanguage.swift Mangar/Localization/L10n.swift Mangar/Storage/ProjectStore.swift Mangar/Storage/TileCodec.swift Mangar/Storage/CanvasTileArchive.swift Mangar/Editor/CanvasBoundary.swift Mangar/Editor/PageSurface.swift Mangar/Editor/DocumentModel.swift Mangar/Editor/LayerShape.swift Mangar/Editor/LayerCurveEffect.swift Mangar/Editor/BucketFill.swift \
  Mangar/Editor/PageConversion.swift Mangar/Editor/PageArrangement.swift Mangar/Editor/PressureCurve.swift Mangar/Editor/ModifierKeyHoldState.swift Mangar/Editor/BrushSizeDrag.swift \
  Mangar/Editor/AppToolPreferences.swift Mangar/Rendering/CanvasViewportGeometry.swift Mangar/Rendering/CanvasTileIndex.swift Mangar/Rendering/CanvasTileLOD.swift Mangar/Rendering/PolygonMaskRasterizer.swift Mangar/Rendering/SelectionSnapshot.swift Mangar/Rendering/TileContentTracker.swift \
  Mangar/Brushes/Model/*.swift Mangar/Brushes/Presets/*.swift \
  Mangar/Brushes/Resources/*.swift Mangar/Brushes/GPU/*.swift Mangar/Brushes/Runtime/MetalBrushEngine.swift Mangar/Brushes/Runtime/BrushChangeTracker.swift \
  Mangar/Preview3D/Model/*.swift Mangar/Preview3D/Rendering/BookSpineMesh.swift Mangar/Preview3D/Rendering/BookShaders.swift Mangar/Preview3D/Rendering/MetalBookRenderer.swift Mangar/Preview3D/Rendering/MetalSphereRenderer.swift Tests/BrushEngine/BookPreviewChecks.swift Tests/BrushEngine/SpherePreviewChecks.swift \
  Tests/BrushEngine/main.swift -o "$scratch/check"
"$scratch/check" "$root"
