# Contributing

Bug reports and small pull requests are welcome. For anything bigger, open an issue first so we can agree on the shape before you write it.

## Before you open a pull request

1. Read [AGENTS.md](AGENTS.md). The privacy rules are hard rules. A feature that reads other apps' windows, tracks the frontmost app or sends data off the Mac will not be merged.
2. Build and test:
   ```sh
   swift build
   .build/debug/Oriel --selftest
   swift format format --in-place --recursive --configuration .swift-format Sources
   ```
3. Bundle the app with `./scripts/bundle.sh`, open it, and use the feature you changed.
4. Keep the change to one thing. Don't reformat or rename code you didn't otherwise touch.

## Pull request

- Title and commits: [Conventional Commits](https://www.conventionalcommits.org), like `fix(capture): skip partial downloads`.
- Body: why, and how you checked it. A screenshot or short recording for anything visible.
- Add a self-test check if you fixed a bug in pure logic (a detector, parser or transform) and the check would have failed before.

## Reporting a bug

Include your macOS version, your Mac model (notch or not), what you did, and what happened. If it crashed, attach the crash report from Console.app.
