# Lift icon study

Native Icon Composer study of the Lift concept from
[the Paper concept board](https://app.paper.design/file/01M2RV00TMRMH6X2ASFQQHVGVG/1-0).

- `Lift.icon`: editable icon document with a yellow system gradient and a graphite foreground group.
- `Sources/01-lift.svg`: the original Paper silhouette on a 1024 by 1024 transparent canvas. No mask, shadow, or highlight is baked into the artwork.
- `Previews/`: native Default appearance renders extracted from the compiled icon at 256, 32, and 16 pixels.

The source palette is yellow `#FFD447` and graphite `#141414`. The initial material study uses a neutral shadow at 35% and translucency at 8%.

## Verification

Compiled successfully with Xcode 26.6 asset tools for macOS 26.0. The native Default render was inspected at 256 and small sizes. The concept is separate from the shipping `Momenta/AppIcon.icon` asset.

Icon Composer 2.0 is required to edit and preview the newer macOS 27 rendering controls. This study has not yet been reviewed using those controls, or in Dark and Mono appearances.

To regenerate the previews:

```sh
mkdir -p .build/lift-icon-review
xcrun actool Design/icon-concepts/Lift/Lift.icon \
  --compile .build/lift-icon-review \
  --platform macosx --minimum-deployment-target 26.0 \
  --app-icon Lift \
  --output-partial-info-plist .build/lift-icon-review/Info.plist \
  --output-format human-readable-text
iconutil --convert iconset .build/lift-icon-review/Lift.icns \
  --output .build/lift-icon-review/Lift.iconset
```
