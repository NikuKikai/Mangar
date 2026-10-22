# Spectral pigment mixing

- Source: https://github.com/rvanwijnen/spectral.js/tree/3.0.0
- Original: shader/spectral.glsl
- Copyright (c) 2025 Ronald van Wijnen
- License: MIT, included in [spectral-mixing-LICENSE.txt](spectral-mixing-LICENSE.txt) and the shader header.
- Mangar port: [PigmentMixing.txt](../../Mangar/Brushes/GPU/PigmentMixing.txt), two-color functions only; Metal syntax, float-safe epsilon, stable reciprocal KM reflectance, exact endpoint handling.

The spectral basis is an RGB-to-reflectance approximation, not a measurement of arbitrary real pigments. It is evaluated for brush reservoir colors, separate from alpha compositing.
