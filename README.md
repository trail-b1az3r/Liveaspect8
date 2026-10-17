# LiveAspect8

LiveContainer tweak. The guest app sees an **iPhone 8 aspect ratio (16:9)** at the phone's **own pixel density**. The 16:9 area is centered on the real screen; the rest is empty (letterbox/pillarbox).

- Output: `LiveAspect8.dylib` — arm64, min iOS 14, ad-hoc signed
- Target device: iPhone 17 Pro. Target app: Life is Strange (2.01.1 and newer)
- Hooks only public UIKit API (`UIScreen.bounds`, `nativeBounds`, `UIScreenMode.size`, `UIWindow` frame/layout). No per-app offsets, so it is not tied to a game version
- Status: built by CI; not yet verified on device — open an issue with LiveContainer logs if something is off

## Get the dylib

- Actions tab → **Build** → latest run → artifact **LiveAspect8-dylib** (unzip it), or
- push a tag like `v1.0` and the dylib is attached to the Release

## Install

Import `LiveAspect8.dylib` into LiveContainer's Tweaks, enable it for Life is Strange, launch.

## Retarget the aspect

Edit `kAspectLong` / `kAspectShort` at the top of `src/Tweak.m`.

## Build locally (macOS + Xcode)

```
bash build.sh
```

## `.github` vs `GitHub`

Actions only reads `.github/workflows/`. `GitHub/` is a visible mirror — see `GitHub/README.md`.
