# FillTube

YouTube-only LiveContainer tweak (`FillTube.dylib`, source `src/FillTube.m`). Loads only when the host app is YouTube.

## Features

- **Stretch video to fill (landscape)**: widens the picture to the full screen width. Height is untouched, nothing is cropped (the picture is stretched horizontally).
- **Disable all captions**: hides the caption renderer, greys out the subtitle button, and forces the caption-enabled state to off so YouTube can't auto-enable it (muted / no audio device).
- **Settings**: YouTube Settings → **FillTube** has a switch for each, with icons. Both default to ON. Values live in `FillTube.stretch` / `FillTube.noCaptions`.

## Install

Enable `FillTube.dylib` only for the YouTube app in LiveContainer (not `LiveAspect8.dylib`).

## If something doesn't work

Every YouTube class and selector is looked up by name at runtime and skipped when missing. On launch the tweak logs one summary line and, on the first landscape player, the player view hierarchy:

```
[FillTube] loaded ... playerView=1 buttons=1 settingsHooks=4/4 captionViews=N captionStateHooks=N
[FillTube] player view YTPlayerView bounds=... videoView=...
```

Send those lines from the LiveContainer log. `settingsHooks` below 4/4 means the Settings entry or its icons are missing. `videoView=NOT FOUND` means stretch can't find the picture view. `captionViews=0` and `captionStateHooks=0` mean the caption kill is limited to greying the button.

The subtitle button is matched by its accessibility id/label containing "caption" or "subtitle", so it can miss in non-English UI.
