# FillTube

YouTube-only LiveContainer tweak (`FillTube.dylib`, source `src/FillTube.m`). Loads only when the host app is YouTube.

## Features

- **Stretch video to fill (landscape)**: widens the picture to the full screen width. Height is untouched, nothing is cropped (the picture is stretched horizontally).
- **Disable all captions**: hides the caption renderer, greys out the subtitle button, and forces the caption-enabled state to off so YouTube can't auto-enable it (muted / no audio device).
- **Settings**: YouTube Settings → **FillTube** has a switch for each, with icons. Both default to ON. Values live in `FillTube.stretch` / `FillTube.noCaptions`.

## Install

Enable `FillTube.dylib` only for the YouTube app in LiveContainer (not `LiveAspect8.dylib`).

## If something doesn't work

Every YouTube class and selector is looked up by name at runtime and skipped when missing. Installation is retried for ~15 s after launch because LiveContainer can load tweaks before YouTube's classes exist.

Each launch writes `Documents/FillTube.log` inside YouTube's LiveContainer data (Files app → On My iPhone → LiveContainer → Data → Application → YouTube's folder → Documents). Lines look like:

```
[FillTube] constructor ran
[FillTube] state (...): YTPlayerView=1 buttons=1 settingsHooks=4/4 captionViews=N captionStateHooks=N | classes: PresentationData=1 ItemManager=1 ...
[FillTube] player view YTPlayerView bounds=... videoView=...
```

No file at all means the dylib isn't loading. `settingsHooks` below 4/4 means the Settings entry or its icons are missing; the `classes:` flags show which class wasn't found. `videoView=NOT FOUND` means stretch can't find the picture. `captionViews=0` and `captionStateHooks=0` mean the caption kill is limited to greying the button.

The subtitle button is matched by its accessibility id/label containing "caption" or "subtitle", so it can miss in non-English UI.
