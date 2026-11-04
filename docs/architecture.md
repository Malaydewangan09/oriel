# How Sill works

One process, one SQLite file, no server. Three things put rows in the store, and the shelf reads them back.

```
ClipboardWatcher --+
FolderIndexer -----+--> Store (SQLite + FTS5) --> .sillCaught --> NotchShelf (peek)
Notch drops -------+          |
                              +--> ShelfModel.reload --> ShelfView / ClassicShelfView
```

## Capture

- `Capture/ClipboardWatcher` checks `NSPasteboard.changeCount` every 0.25s on the main thread. A change with plain text is saved, unless the pasteboard carries a concealed or transient type, comes from an excluded app, or was written by Sill itself (`markOwn`).
- `Capture/FolderIndexer` watches Downloads and the screenshot folder with a `DispatchSource`, and rescans every 15s as a fallback. Text in images and PDFs is read with Vision and PDFKit on a utility queue. Files older than 14 days are ignored.
- `Notch/HoverView` takes files and text dropped on the notch. Dropped items are pinned.
- `Capture/Secrets` decides whether copied text is a secret. Secrets are stored with an `expires` time, and their text is kept out of the FTS index.

Each item has a `fingerprint`, so the same copy or file is stored once. Copying the same text again moves its row to the top.

## Store

`Store/Store.swift` owns one SQLite connection behind a lock. It is `@unchecked Sendable`, so it can be called from any queue.

| Table | Holds |
| --- | --- |
| `items` | Every caught thing: kind, time, title, body, path, source, secret, expiry, pinned. |
| `items_fts` | FTS5 index over title and body, kept in sync by triggers. |
| `stacks`, `stack_items` | Stacks you made yourself. Auto stacks are computed, not stored. |
| `forgotten` | Fingerprints of deleted files, so a rescan doesn't bring them back. |

`Store.search(Query, limit:)` is the only read path. `Store/Query.swift` turns plain words like "links from slack yesterday" into a `Query`: kinds, a date range, the app it came from, and the remaining words for FTS.

`Store.purge` runs every 20s. It drops expired secrets and anything older than the history length in Settings, except pinned items.

## Stacks

`Stacks/Stacks.swift` groups items from the last week that share an identifier: a GitHub PR or issue link, a ticket key like `ENG-142`, or a Figma file. Two or more matches make a stack. *Collect here* puts every new copy into one stack you made, until you turn it off.

## The shelf

- `Notch/NotchShelf` owns the notch window and the hover target. It shows the peek when something is caught and opens the full shelf on hover or ⌃⌥Space.
- `Shelf/ShelfModel` holds what the shelf shows. `reload()` runs the query on a background queue and applies only the latest result, so typing never waits on SQLite.
- `Shelf/ShelfView` is the Glass and Next design. `Shelf/ClassicShelfView` is Classic. Both read colours from `UI/Theme.swift` only.

## Hand to Claude

`Claude/ClaudeAgent` builds a Markdown prompt from a stack, with `Secrets.redact` applied to every item, and runs `claude --bg --permission-mode plan` in the folder you picked for that repo. The session id is parsed from Claude's output so the shelf can offer `claude attach`.

## Self-test

`App/SelfTest.swift` runs with `--selftest`. It checks the pure logic: secret detection, link cleaning, query parsing, transforms, stack keys and store invariants against a throwaway database. It exits non-zero on any failure, and CI runs it on every push.
