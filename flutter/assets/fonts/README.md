IBM Plex Sans, Serif and Mono are referenced by `lib/design/tokens.dart`
but are not bundled yet. Drop the .ttf files here and register them under
`flutter: fonts:` in pubspec.yaml to switch every text style from the system
fallback to Plex. Until then the app renders with the platform face at the
same metrics (the tokens name family + fallback list).
