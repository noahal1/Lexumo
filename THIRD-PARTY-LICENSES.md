# Third-Party Licenses

Lexumo is built on open-source components, each distributed under its own
license. This file acknowledges them. The list reflects the project's declared
dependencies; for the exact terms and versions, consult each package directly
and the project's homepage.

All licenses below are compatible with the project's GNU Affero General Public
License v3.0.

## Tauri / React app (`package.json`)

| Component | Purpose | License |
| --- | --- | --- |
| react | UI library | MIT |
| react-dom | DOM renderer | MIT |
| @tauri-apps/api | Native bridge from the webview | Apache-2.0 / MIT |
| tauri-plugin-tts-api | Text-to-speech | MIT |

### Build and test only

| Component | Purpose | License |
| --- | --- | --- |
| vite | Dev server and bundler | MIT |
| @vitejs/plugin-react | React plugin for Vite | MIT |
| typescript | Type checker and compiler | Apache-2.0 |
| vitest | Test runner | MIT |
| jsdom | DOM implementation for tests | MIT |
| @tauri-apps/cli | Tauri build tooling | Apache-2.0 / MIT |

## Flutter app (`flutter/pubspec.yaml`)

| Component | Purpose | License |
| --- | --- | --- |
| flutter | UI framework | BSD-3-Clause |
| flutter_localizations | Localization delegates | BSD-3-Clause |
| crypto | SHA-256 hashing for sync | BSD-3-Clause |
| file_selector | Native open/save dialogs | BSD-3-Clause |
| flutter_tts | Text-to-speech | MIT |
| flutter_lints | Lint rule set (dev only) | BSD-3-Clause |

`flutter_tts` is vendored under `flutter/third_party/flutter_tts` so the Windows
and Android platform channels can be patched; its upstream license is preserved
in that directory.

## Bundled assets

| Component | Purpose | License |
| --- | --- | --- |
| IBM Plex Sans / Serif / Mono | Interface and reading typography | SIL Open Font License 1.1 |

## Notes

- License identifiers follow the [SPDX](https://spdx.org/licenses/) convention.
- If a dependency's license differs for the version you install, the version you
  install governs.
