# RoughTrack (SwiftUI)

A SwiftUI DAW for macOS over a C++ engine, forked from the JUCE RoughTrack (8track) at
826eb8c. It ships as RoughTrack.app and shares the JUCE app's bundle id, sessions folder
and settings (user decision 2026-11-12). README.md covers building and releasing.

## How it fits together

- `engine/` is RoughTrack's engine, copied. Changes here don't go back to RoughTrack.
- `core/` holds `roughtrack::Studio`: devices, sessions, plugins, undo and the
  transport, lifted from RoughTrack's MainComponent with the UI taken out.
- Swift sees only `core/bridge/RoughTrackCore.h` (namespace `rt`), which uses plain
  C++ types. Keep JUCE out of it. Swift polls `revision()` instead of taking callbacks.
- The app links the CMake-built static libraries; the Xcode pre-build script runs CMake.
- TONE3000 is RoughStomp's `rs::t3k` (fetched at a pinned commit, compiled as
  `roughtrack_t3k` against our JUCE) under `roughtrack::Tone3000` in the core. Its key is
  in `tone3000_client_id.local` (git-ignored; never commit it). The sign-in and downloads
  live in `~/Library/Application Support/TONE3000 Shared`, shared with RoughStomp
  (user decision 2026-11-13) and named for neither app.

## Rules of thumb

- Anything that moves every frame (playhead, meters, position display) updates Core
  Animation layers from `FrameClock`, never SwiftUI state: a SwiftUI counter and meter
  redrawn per frame cost about 19% of a core in the spike.
- Keep `ENABLE_DEBUG_DYLIB` off: with it, JUCE takes the .debug.dylib for the
  executable and plugin scans launch the dylib.
- The look is flat in Logic's style, in an original design, not Logic's artwork. Colours live in Theme.swift.

## Working here

- `cmake --build --preset release` then `build/release/tests/roughtrack_tests` before
  finishing a change; build the app with xcodebuild or Xcode.

- Apple Silicon only (user decision 2026-11-12): no Intel or universal builds.
- Quit the JUCE RoughTrack before running this one: they share settings and sessions.
- Bump the version in both `app/project.yml` (`MARKETING_VERSION`) and the top-level
  `CMakeLists.txt`.
