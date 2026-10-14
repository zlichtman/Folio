# Folio engineering guide

Folio is a native macOS visual library: macOS 14 or later, Apple silicon and Intel, MIT
licensed. It is built with AppKit, Core Animation, system SQLite (FTS5), ImageIO,
AVFoundation and Vision, as a Swift 5.9 package with no third-party dependencies.

## Architecture

- `Sources/ShelfCore` (library, unit tested): `LibraryDatabase` (SQLite in WAL mode on a
  serialized queue; FTS5 over names, tags, notes, OCR text and source URLs, kept current by
  triggers), `Models` (`ShelfItem`, `MasonryLayout`, `GridGeometry`, `Distribution`),
  `Media` (`MediaFiles` import, `ThumbnailCache`: ImageIO downsampling into size buckets with a
  PNG disk cache, AVFoundation poster frames) and `ImageClassifier` (Vision classification,
  dominant colours, OCR).
- `Sources/CSQLite`: module map for the system `libsqlite3`.
- `Sources/Folio` (app): `main.swift` (`AppController`: menus, library, imports, the single
  indexing worker, development flags), `DesignedWindow.swift` (window layout, inspector, tag
  editor, preview panel), `GridView.swift` (`ShelfGridView`: reused CALayer tiles),
  `CaptureServer.swift` (browser capture on 127.0.0.1:53187 with a per-library key) and
  `Theme.swift` (`AppIdentity`, colours, shared views).
- `Sources/ShelfBench`: the `shelf-bench` tool (fixtures, core benchmarks, classification, demo studies).
- `Extensions/`: the browser extensions. `shared/` holds the code; `Firefox/`, `Chrome/` and `Safari/` hold
  each manifest. Safari's also has a small native handler, its Info.plist and sandbox entitlements:
  `scripts/build-safari-extension.sh` builds `Save to Folio.appex` (universal) into `Folio.app/Contents/PlugIns`, and
  `build-app.sh` signs it with those entitlements before the app. `scripts/build-extensions.sh` combines them into `folio-firefox.zip` and
  `folio-chrome.zip`, which ship in `Folio.app/Contents/Resources/Extensions/` and are copied to `dist/`.
- `dist/` holds only archives (`Folio.dmg`, zips, `SHA256SUMS.txt`). The unpacked app, `shelf-bench`
  and unpacked extensions stay in the build stage, `/private/tmp/folio-build/stage`, so Spotlight
  never indexes stray copies of Folio.app.
- `Design/`: `folio-mark.svg` and the 1024 px icon master `folio-app-icon.png`.
- `docs/`: architecture and performance notes with their raw reports.

The library lives in `~/Library/Application Support/Folio` (`LibraryLocation`): the database, `media/`
(copies of files Folio had to keep), `snapshots/` and `capture-key`. Libraries made before 1.8 sat in
`LumaShelf`; the first launch of 1.8 renames that folder, rebases stored paths with `rebasePaths`, and
drops the old `previews/` cache. Thumbnails live in `~/Library/Caches/<bundle id>/Previews`.
`--support-folder <folder>` stands in for Application Support when testing the move; never test it
against the real one. Other libraries (File ▸ Library) are folders anywhere: the defaults `library.current` (the
one to open; none means the main one) and `library.others` list them, switching relaunches Folio, the capture key
stays in the main folder so extensions keep their pairing, and the `folio` command reads `library.current` too. Compatibility identifiers stay so preferences and browser pairing survive:
bundle identifier `org.lumashelf.app`, the Firefox extension ID and the `org.lumashelf.*` queue names.
Nothing may delete or zap the library folder.

## Build and test

```sh
export CLANG_MODULE_CACHE_PATH=/private/tmp/folio-<name>/clang
swift build --disable-sandbox --scratch-path /private/tmp/folio-<name>/build -debug-info-format none
swift test --disable-sandbox --scratch-path /private/tmp/folio-<name>/build -debug-info-format none
```

`make build`, `make test`, `make app`, `make dmg`, `make release-check` and `make clean` wrap the
same steps (scratch in `/private/tmp/folio-build`, or `SCRATCH=`). Builds stage outside the
project because iCloud Drive adds FinderInfo that breaks signatures; `xattr -cr` and
`ditto --norsrc --noextattr` keep copies clean. `Run Folio.command` opens an installed
`/Applications/Folio.app`, or builds the checkout when it changed (ad-hoc allowed) and opens the staged app;
`FOLIO_FROM_SOURCE=1` forces the checkout.

Development flags: `--library <folder>`, `--no-capture`, `--no-autotag`, `--no-folders`, `--appearance light|dark`,
`--grid-style rows|columns`, `--select-first`, `--select-count <n>`, `--open-first`, `--import-folder <folder>`,
`--watch-folder <folder>`, `--settings <pane>`, `--show <sidebar place>`, `--search <text>`, `--board`, `--select-title <name>`, `--edit-smart-folder <name>` (stage a
scene for a capture; an open sheet is saved beside the snapshot as `-sheet.png`), `--qa <folder>` (see below), `--background-check`, `--snapshot <png> --quit-after-snapshot` (renders the window, toolbar
included, without screen recording), `--benchmark-json <file>`, `--headless-capture`.

SwiftPM's default build system records the deployment target (14.0) as the SDK version, so a plain
`swift build` draws AppKit's pre-macOS 26 appearance. `scripts/build-app.sh` records the real SDK
with `vtool` so shipped builds use the current controls, matching MacSpaces; `FOLIO_CURRENT_SDK=0`
keeps the old appearance. To preview a debug build the same way, run `vtool -set-build-version macos
14.0 "$(xcrun --sdk macosx --show-sdk-version)" -replace` on the binary and re-sign it ad hoc.

`--qa <folder>` runs the interaction checks in `QAScenarios.swift` against the real window while it stays
off-screen: synthetic clicks, drags and keys, each followed by an assertion, with snapshots and `report.json`
in the folder. It edits the library, so point `--library` at a copy. The owner checks changes by building and
looking at the real window (`--snapshot`), not by growing this suite:

```sh
Folio --library /tmp/qa-library --background-check --no-capture --no-autotag --no-folders --qa /tmp/qa
```

CI (`.github/workflows/ci.yml`, macos-latest, no signing) lints Info.plist and the scripts, runs
`scripts/check-release.sh --metadata`, then `swift build` and `swift test`.

## Release policy

- `Info.plist` is the source of truth. Versions follow MacSpaces and Tape: `CFBundleVersion` is an
  integer build that grows by one for every published installer and must exceed every published
  build, and `CFBundleShortVersionString` is `<major>.<build>` (build 5 is `1.5`; also the tag
  `v1.5`). Never show the build separately. 1.0.0 (build 4) predates this. `scripts/bump-version.sh`
  advances the build and sets both (`scripts/bump-version.sh 2` starts major 2). Swift reads them from
  `Bundle.main` (`CFBundleShortVersionString`, `CFBundleVersion`).
- `RELEASE_NOTES.md` describes the current version only: `**X.Y**`, then `## New`,
  `## Improvements` and `## Fixes` as needed, in plain sentence case for people, not developers.
  Never add the build marker yourself.
- Signing: Developer ID Application, team `28LJG7MXT3`, hardened runtime, secure timestamp,
  `Folio.entitlements` (empty: Folio is not sandboxed and needs no runtime exceptions; add a key
  only with the reason in the commit). Notarization uses the notarytool keychain profile in
  `FOLIO_NOTARY_PROFILE` (default `MacSpaces`, same team) and runs twice, app then disk image,
  so both are stapled and pass Gatekeeper offline.

Steps:

1. `scripts/bump-version.sh`, update `RELEASE_NOTES.md`, commit, push `main` and wait for CI to pass
   on that commit.
2. `make dmg`: universal build, signing, notarization, stapling, the branded disk image
   (`scripts/make-dmg.sh`, background from `scripts/render-dmg-background.swift`, Finder layout
   from `scripts/dmg-layout.swift`; MacSpaces and Tape ship identical copies of all three, so
   change them together), then checks of the mounted app (signature, architectures,
   version, `stapler validate`, `spctl`). Output: `dist/Folio.dmg`, `dist/Folio-X.Y.zip`,
   `dist/SHA256SUMS.txt`. It refuses a dirty tree. `FOLIO_NOTARIZE=0` is a dry run that cannot
   be published.
3. `make release-check` verifies `dist/` again: checksums, team, hardened runtime, universal
   binary, stapled tickets and Gatekeeper for the disk image, its app and the ZIP, and that the
   app's `FolioSourceCommit` (written by `build-app.sh`; `-dirty` with uncommitted changes)
   is the current `HEAD`.
4. `scripts/publish-release.sh X.Y` refuses a dirty tree, an existing tag or release, a commit
   that is not `origin/main`, missing CI success, unstapled artifacts or a build not above every
   published `folio-build` marker. It tags `vX.Y`, pushes the tag, creates the Latest release
   "Folio X.Y" on `zlichtman/Folio` with the notes plus one hidden line
   `<!-- folio-build:N -->`, uploads `Folio.dmg` and `Folio-X.Y.zip`, checks the uploaded
   digest and prints the cask. If it fails after pushing the tag, delete the tag
   (`git push origin :refs/tags/vX.Y`, `git tag -d vX.Y`) before retrying.
5. `scripts/update-tap.sh X.Y` updates `Casks/folio.rb` in `zlichtman/homebrew-tap` only after the
   release's `Folio.dmg` downloads and matches `dist/Folio.dmg` (template: `packaging/folio.rb`). Never
   push the cask in the same command line as `make dmg`: a failed build must not leave the cask pointing
   at a missing installer. The cask never zaps the library.

Updater contract: read `https://api.github.com/repos/zlichtman/Folio/releases/latest`; take
the public version from the tag (`vX.Y`) and the build from the single body line matching
`^<!-- folio-build:([0-9]+) -->$` (strip `\r` first; zero or several markers mean no update).
Offer the update only when that build exceeds the installed `CFBundleVersion`. Download the
`Folio.dmg` asset (or `Folio-X.Y.zip`) and verify bundle identifier, version, build, team
`28LJG7MXT3`, minimum macOS and architecture before relaunching. `LSFileQuarantineEnabled`
quarantines every file Folio writes, including the download and the app copied out of it, so
after those checks pass remove `com.apple.quarantine` from the staged app recursively before
moving it into place; otherwise macOS translocates the relaunched app to a random read-only
path and asks again whether to open it.

Never commit `dist/`, credentials, notary logs or downloaded installers.

## Conventions

- Compact Swift that matches the existing code: terse names, few comments (only for a
  non-obvious why), no third-party packages.
- UI copy is plain and in sentence case, with no jargon or developer metrics.
- Never name or reference competing products in code, UI, docs, commits or release notes.
  Study them only through public material. In `work/`, only `release-notes-current.html` and
  `releases-current.json` may be opened.
