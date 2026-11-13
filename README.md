# RoughTrack (SwiftUI)

A simplified multitrack DAW for macOS, with a SwiftUI front end in a flat style. It
ships as RoughTrack.app (bundle id `com.danmullins.roughtrack`), starting at 0.1.1,
and replaces the JUCE RoughTrack on the Mac.

It was forked from the JUCE [RoughTrack](https://github.com/dantaipan/roughtrack) at
826eb8c (0.11.0). The engine was copied, not shared, so the two can drift. The JUCE
project keeps its interface, ready for a possible Windows port.

## Layout

- `engine/`: the audio engine, sessions and plugin hosting (C++, JUCE), as copied
- `core/`: the app's logic without any UI (`Studio`), and `core/bridge/RoughTrackCore.h`,
  the plain-C++ API that Swift imports
- `app/`: the SwiftUI app; `app/project.yml` generates the Xcode project
- `tests/`: Catch2 tests for the engine and the core (`roughtrack_tests`)
- `tools/`: `roughtrack_bench`, which some tests use, and `make_release.sh`

## Building

You need Xcode, CMake, Ninja and XcodeGen (`brew install cmake ninja xcodegen`).

```sh
cmake --preset release && cmake --build --preset release   # engine, core, tests
build/release/tests/roughtrack_tests

cd app && xcodegen generate && open RoughTrackSwift.xcodeproj
```

The Xcode build runs the CMake build first, so after the first configure you can
just build in Xcode. The `.xcodeproj` is generated; edit `app/project.yml`, not the project.

Sessions live in `~/Music/RoughTrack`, and settings and the plugin list in
`~/Library/Application Support/RoughTrack.*`, the same places the JUCE RoughTrack uses,
so it opens the same sessions and keeps the same audio device, latency and plugins.

## Releasing

`tools/make_release.sh` archives a Release build signed with Developer ID, notarizes
and staples it, and makes `dist/RoughTrack-<version>.dmg`, also signed, notarized and
stapled. It needs the `roughtrack-notary` notarytool profile. The version is
`MARKETING_VERSION` in `app/project.yml` (and the CMake project version, which the
About box and update checker use).

The update checker is built but off: `updates::latestReleaseUrl` in
`core/include/roughtrack/Updates.h` is empty until releases have a GitHub home.

## Licence

GNU AGPL 3.0 or later (see LICENSE). JUCE is used under the AGPL.
