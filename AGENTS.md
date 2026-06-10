# CodeIsland Agent Rules

## Build And Run Modes

- Debug mode is for quick local development only:

  ```bash
  swift build
  ./.build/debug/CodeIsland
  ```

- Release mode is the default for installing, running, or validating the app as a user would use it:

  ```bash
  ./build.sh
  open .build/release/CodeIsland.app
  ```

- `./build.sh` creates the signed `.app` bundle at `.build/release/CodeIsland.app`. It builds universal macOS binaries and embeds the helper bridge in the app bundle.

## Default Behavior For Future Work

- When asked to install, run, rerun, launch, restart, or verify CodeIsland without an explicit build mode, use the release flow:

  ```bash
  ./build.sh
  open .build/release/CodeIsland.app
  ```

- Use debug mode only when the user explicitly asks for debug, fast iteration, or direct binary execution.
- Before opening a rebuilt release app, stop any already-running CodeIsland process so the newly built app owns the socket and refreshed hooks.
- After launching release, verify the important runtime state when relevant:
  - CodeIsland process is running from `.build/release/CodeIsland.app` or the symlinked `.build/x86_64-apple-macosx/release/CodeIsland.app`.
  - `/tmp/codeisland-<uid>.sock` exists.
  - `~/.codeisland/codeisland-bridge` has been refreshed by the app.

