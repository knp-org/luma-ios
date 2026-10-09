# Documentation screenshots

Current documentation captures:

| File | Screen |
| --- | --- |
| [listen.png](listen.png) | Listen home screen and recent tracks |
| [readme-library.png](readme-library.png) | Songs, covers, favorites, and filters |
| [readme-now-playing.png](readme-now-playing.png), [now-playing.png](now-playing.png), [album-color-warm.png](album-color-warm.png) | Artwork, visualizer strip, and playback controls (identical captures) |
| [readme-playlist.png](readme-playlist.png), [playlist.png](playlist.png) | Playlist details (identical captures) |
| [readme-insights.png](readme-insights.png), [insights.png](insights.png) | Listening totals and daily activity (identical captures) |
| [visualizer.png](visualizer.png) | Visualizer paused at its baseline |
| [queue.png](queue.png) | Current track and upcoming songs |
| [album-color-cool.png](album-color-cool.png) | Player with a cool album tint |
| [album-color-library.png](album-color-library.png) | Library with a cool album tint |
| [online-lyrics.png](online-lyrics.png), [lyrics-preview.png](lyrics-preview.png) | Lyrics search and preview using a local API stub |
| [app-icons.png](app-icons.png) | Generated preview of current light, dark, and tinted icons |

They were captured at 1206 × 2622 on an iPhone 17 Pro simulator running iOS 26.2. All names are fictional. Covers come from Luma's procedural artwork renderer, tracks use generated silent 48-second WAV files, and listening statistics are synthetic. No external music, artwork, or lyrics were downloaded for these captures.

`testReadmeScreenshots` launches with `--ui-testing --reset-ui-state --readme-screenshots --mock-lyrics-api`. The fixture uses separate test preferences and a `UITesting` documents directory. Its generation code is guarded by `#if DEBUG`, requires explicit launch arguments, and is absent from Release builds. Normal launches start with the user's library or an empty library. Lyrics text is original fixture text supplied by the local API stub; the captures do not contact LRCLIB.

## Capture again

Run these commands from the project directory. Select an installed iOS 26+ simulator with `xcrun simctl list devices available`, boot it in Simulator, then set its identifier:

```sh
LUMA_SIMULATOR_ID='<simulator UUID>'
LUMA_CAPTURE_DIR="$(mktemp -d /tmp/luma-screenshots.XXXXXX)"

xcrun simctl status_bar "$LUMA_SIMULATOR_ID" override \
  --time '9:41' --batteryState charged --batteryLevel 100 \
  --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4

xcodebuild -project Luma.xcodeproj -scheme Luma -configuration Debug \
  -destination "platform=iOS Simulator,id=$LUMA_SIMULATOR_ID" \
  -resultBundlePath "$LUMA_CAPTURE_DIR/Screenshots.xcresult" \
  -parallel-testing-enabled NO \
  -only-testing:LumaUITests/LumaUITests/testReadmeScreenshots \
  test CODE_SIGNING_ALLOWED=NO

xcrun simctl status_bar "$LUMA_SIMULATOR_ID" clear

xcrun xcresulttool export attachments \
  --path "$LUMA_CAPTURE_DIR/Screenshots.xcresult" \
  --output-path "$LUMA_CAPTURE_DIR/attachments"

python3 Scripts/export_screenshots.py "$LUMA_CAPTURE_DIR/attachments"
```

The export script reads `manifest.json` and updates every app screenshot listed above, including the existing filename aliases. It requires all eleven named captures before copying any files. Inspect the resulting images before updating the README. The chart dates follow the capture date; playback progress may vary slightly.

The icon preview is generated separately by `swift Scripts/generate_logo_assets.swift`. It uses the current icon assets and does not contain app-screen content.
