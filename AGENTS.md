# Coding agent guidelines for Oriel

Oriel is a native macOS notch app. It keeps what you copy, screenshot and download, groups it by task, and hands a task to Claude Code. Read this file before changing anything.

## Read first

- **KISS.** No abstraction until a second caller exists. No protocols with one conformer, no managers of managers.
- **DRY.** Find the closest existing pattern and follow it. A second way to do the same thing will not be merged.
- **Surgical changes.** Touch only what the goal needs. Do not reformat or rename code you did not otherwise change.
- **Define success first.** Know what you will check before you write the first line.
- **Build and self-test before calling anything done** (see [Build and test](#build-and-test)).

## Privacy rules

These are product rules, not preferences. A change that breaks one will not be merged.

- Oriel only acts on what the user hands it: copies, drops, screenshots and downloads. It never reads other apps' windows, window titles, browser tabs or screen content, and never records which app is in front.
- Nothing leaves the Mac except a stack the user explicitly hands to Claude Code. That text goes through `Secrets.redact` first.
- Secrets (`Secrets.kind`) are stored masked, never enter the full-text index, and expire after `Secrets.lifetime`.
- No network code, analytics or crash reporting.
- No new always-on permission. Accessibility is optional and only used by Quick paste.

## Project layout

Swift Package, one executable target, macOS 14+, Swift 6 toolchain in Swift 5 language mode. No third-party dependencies.

```
Sources/Oriel/
  App/       entry point, AppDelegate, preferences, global hotkeys, the self-test
  Store/     Item, Kind and Look, the SQLite store, natural-language Query
  Capture/   clipboard watcher, Downloads and screenshot indexer, Grab, Secrets, Transform
  Stacks/    auto and manual stacks, Collect here
  Claude/    Hand to Claude: background session and its view
  Features/  Noticed (act on text), Share safely, Mark up
  Notch/     the notch window, hover target, peek and drop handling
  Shelf/     ShelfModel and the shelf views (Glass/Next grid and list, Tile, ActionBar, Classic)
  UI/        Theme tokens, shared components, Settings, Quick paste, search panel
scripts/     bundle.sh (app bundle), dmg.sh (disk image)
brand/       icon and DMG background
docs/        architecture.md and README images
.github/     CI: build with warnings as errors, self-test, format lint
```

[docs/architecture.md](docs/architecture.md) explains how capture, the store and the shelf fit together. Read it before changing more than one folder.

Data lives in `~/Library/Application Support/Desk/desk.sqlite`. The folder keeps the app's working title so existing history carries over. Do not rename it.

## Code rules

### Comments

The default is no comment. Write one only when a reader would otherwise ask **why**: a non-obvious constraint, an OS quirk being worked around, an ordering or threading requirement, a deliberate omission. One line. Never restate the code, never add section banners or a `TODO` without an issue link. When code is deleted, delete its comment.

### Colour and design

Every colour comes from `UI/Theme.swift`:

- `Palette.make(design, dark:)` for anything that follows the design (Glass, Next, Classic) and appearance.
- `Swatch` for fixed colours (code background, secret gradient, highlighter, link gradients).

No `Color(red:…)`, `Color(white:…)` or `NSColor(red:…)` in a view. If a colour is missing, add a token to `Theme.swift`. Reuse `Chip`, `ChipLabel`, `BackRow`, `Flow` and `LookPickers` from `UI/Components.swift` before building a new control.

### Swift

- UI types and anything touching AppKit are `@MainActor`. `Store` is `@unchecked Sendable` and guards SQLite with its lock. Keep that pattern.
- Blocking work (OCR, file reads, SQLite queries, `Process`) runs off the main thread and hops back with `DispatchQueue.main.async` or `await`. Follow `ShelfModel.reload`: capture the inputs on the main thread, query on a queue, apply only the latest result.
- Bind every SQL value that can hold user text. Only integers we produced ourselves may be interpolated.
- Use enums for closed sets (`Kind`, `Design`, `Tab`). Never compare against raw strings.
- `UserDefaults` keys live in `Pref`. Do not add a key anywhere else.
- Format with `swift format format --in-place --recursive --configuration .swift-format Sources`.

### Errors

No silent failures on paths the user sees. If an action cannot complete, say so through `ShelfModel.flash` or the view's own message. `try?` is fine where a missing result is the expected outcome (a file that was deleted, an image without text).

## Build and test

```sh
swift build                         # debug build
.build/debug/Oriel --selftest       # pure-logic checks, exits non-zero on failure
./scripts/bundle.sh                 # universal dist/Oriel.app, ad-hoc signed
./scripts/dmg.sh                    # dist/Oriel.dmg
ORIEL_DEMO=1 open dist/Oriel.app    # demo mode: ignores files that existed before launch
ORIEL_DB=/tmp/x.sqlite              # run against a throwaway database
```

CI runs the same build with `-warnings-as-errors`, the self-test, and `swift format lint --strict`. A change is done when `swift build` shows no warnings, the self-test passes, and you have opened the bundled app and used the feature you touched.

### When a check earns its place

Add a self-test check when you add behaviour or fix a bug, and the check would have failed before your change: a detector pattern, a parser, a transform, a store invariant. Do not add checks for SwiftUI layout or for what Apple's APIs already guarantee. When a feature is removed, remove its checks in the same change.

## Writing

Plain and factual, in UI text, comments, commits and docs. Say what it does. No hype words, no exclamation marks, no em dashes. Commit messages follow [Conventional Commits](https://www.conventionalcommits.org): `type(scope): summary`, with type one of `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `ci` or `chore`. One short line saying what changed and why. Never add an AI tool as author or co-author.

## Keeping this file current

Update this file in the same change whenever you add a folder, a token family, a privacy rule or a build step.
