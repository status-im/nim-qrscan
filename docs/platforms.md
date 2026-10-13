# Platform matrix

Required platforms: **iOS, Android, Linux, Windows, macOS**. Checked on
2026-10-13 from a macOS arm64 host with Nim 2.2.10, zxing-cpp v3.1.1, Qt
6.11.0, Xcode (iOS 26.1 SDK) and Android NDK 27.2.

## nim-qrscan (core, worker, C ABI)

| Platform | How | Result |
|---|---|---|
| macOS arm64 | native: `make test && make ctest`; `scripts/cross-check.sh macos` | all suites + `tcapi: OK` |
| iOS simulator arm64 | `scripts/cross-check.sh ios-sim`, run with `xcrun simctl spawn booted` (iPhone 17 Pro) | `tcapi: OK` (ran in the simulator) |
| iOS device arm64 | `scripts/cross-check.sh ios` | builds and links (Mach-O arm64, platform iOS, minos 17.0); not run (no device attached) |
| Android arm64-v8a | `scripts/cross-check.sh android arm64-v8a`, run on the `Medium_Phone_API_36.1` emulator via `adb` | `tcapi: OK` (ran on the emulator) |
| Android x86_64 | `scripts/cross-check.sh android x86_64` | builds and links (ELF x86-64); not run (the emulator image is arm64) |
| Linux arm64 | Docker `nimlang/nim:2.2.10`: `make test-core && make ctest` | 20/20 core+worker tests, `tcapi: OK` |
| Linux x86_64 | same, `--platform linux/amd64` (emulated) | 20/20, `tcapi: OK` |
| Windows x86_64 | **pending**: no Windows toolchain on this host | build commands below; run on Windows CI or a Windows machine (Phase 5) |

The C test covers decoding, options, invalid arguments, UTF-8 and two threads
decoding at once. The QML layer (`tests/tqml.nim`) needs Qt and runs on macOS;
on mobile it is built as part of the app (Phase 4/5).

### Windows (pending)

Same flags desktop-app uses for the app (clang targeting MSVC):

```sh
scripts/build-zxing.sh windows      # cmake -G Ninja, clang/clang++ --target=x86_64-pc-windows-msvc, /MD runtime
nim c --app:staticlib --noMain -d:release --cc:clang --clang.exe=clang \
  --passC:--target=x86_64-pc-windows-msvc --passC:-fms-runtime-lib=dll \
  -d:qrscanZxingLib=build/zxing-windows/core/ZXing.lib qrscan/capi.nim
```

`qrscan/zxing.nim` adds no C++ runtime flag on Windows (the toolchain links
the MSVC runtime).

## nim-qtcamera (compile check for mobile)

`nim-qtcamera`'s core + QML layer compiled as a static library against Qt
6.11's mobile kits, using prl-to-pc's generated pkg-config trees (the same
mechanism desktop-app's mobile build uses):

| Target | Result |
|---|---|
| Android arm64-v8a | compiles (5.8 MB static library) |
| iOS simulator arm64 | compiles **with a workaround** (5.3 MB): see finding 1 |

Not run: camera behaviour on devices (texture-backed frames) is a Phase 5
on-device check.

## Findings

1. **prl-to-pc's generated iOS `Qt6Multimedia.pc` lacks `Requires: Qt6Gui
   Qt6Network`** (the macOS kit and the generated Android tree have them). seaqt's
   `gen_qvideoframe.cpp` then can't find QtGui headers (`QColor`). Workaround for
   the compile check: `--passC:-I<qt>/ios/lib/QtGui.framework/Headers`
   (+ QtNetwork). The proper fix belongs in prl-to-pc's iOS tree; it affects
   the Status iOS build in Phase 5, which compiles the same bindings.
2. **GNU ld needs `-lm` after `libZXing.a`** (zxing uses `lround`); macOS hides
   this because libm is part of libSystem. `qrscan/zxing.nim` now passes
   `-lstdc++ -lm` (Linux) and `-lc++ -lm` (Android) after the archive.
3. Android: zxing is built with `ANDROID_STL=c++_static` and test binaries
   link with `-static-libstdc++`, so no `libc++_shared.so` is needed at runtime.
4. On Apple Silicon the Android emulator is arm64, so arm64-v8a is the
   runtime-checked ABI and x86_64 is link-only.
