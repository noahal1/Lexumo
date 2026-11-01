IBM Plex Sans, Serif and Mono are bundled with the app: the eight `.ttf`
files in this directory are registered under `flutter: fonts:` in
`pubspec.yaml`, and `lib/design/tokens.dart` (`Fonts.ui` / `Fonts.display` /
`Fonts.mono`) names those three families.

Only the eight weights below are shipped. Adding another weight means
dropping the `.ttf` here **and** adding a matching `asset:` + `weight:` entry
in `pubspec.yaml` — an unregistered file is simply ignored, it does not fall
through to the system face.

| Family         | Files                                          |
| -------------- | ---------------------------------------------- |
| IBM Plex Sans  | `plex-sans-400.ttf`, `-500`, `-600`            |
| IBM Plex Serif | `plex-serif-400.ttf`, `-500`, `-600`           |
| IBM Plex Mono  | `plex-mono-400.ttf`, `-500`                    |

Plex carries no CJK glyphs, so Chinese still renders through the platform face
listed in `Fonts.cjkFallback` (PingFang SC / Microsoft YaHei / Noto Sans CJK).

The files are fetched by `scripts/fetch-plex-ttf.cjs` at the repo root.
