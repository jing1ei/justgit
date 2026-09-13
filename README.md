# JustGit

A desktop Git front-end for macOS 12+ and Windows 10/11.

## Build

When authorized under [LICENCE](LICENCE), on macOS double-click `Build.command` to test,
install into `~/Applications/JustGit.app`, and launch. Quit JustGit before installing.
Requires Apple's Git and Swift command-line tools.
Run `./Build.command --check` to build and test without installing.
`bash Tests/BuildTests.sh` checks installer rollback with an inert binary.

On Windows, install Python 3.11+ (including Tcl/Tk) and Git for Windows on PATH,
then double-click `Run-Windows.cmd`. It can also accept a repository folder.
Setup and Skin are in the menu bar on both platforms, not the main panel.

Windows checks: `powershell -File Windows/Build.ps1 -Check`.
Optional portable EXE: install PyInstaller, then run
`powershell -File Windows/Build.ps1 -Package`. Output goes to `Windows/releases/`.
Git is still required; packaged copies do not require Python.
The Windows CI workflow runs tests and creates a downloadable build artifact.

## Releases

Tag a commit and push the tag; GitHub Actions builds both platforms and publishes
the release with the two archives attached.

    git tag v2.2
    git push origin v2.2

The tag sets the version: `v2.2` becomes `CFBundleShortVersionString` 2.2. Running
the Release workflow manually builds and uploads artifacts but publishes nothing.
`./Build.command --package <dir>` produces `JustGit.app` locally the same way CI
does — a universal arm64 + x86_64 binary, installing and launching nothing.

Released builds are not signed with an Apple Developer ID or notarised, and the
Windows executable is unsigned. macOS Gatekeeper therefore blocks the downloaded
app until the user right-clicks it and chooses Open (or clears the quarantine
attribute), and Windows SmartScreen warns on first run.

## Use

Open or drop a folder. Commit stages all changes; an empty message uses the date.
Push and Pull target the current branch on `origin`. Sync commits, pulls, then
pushes, stopping on failure. Remote converts entered HTTPS URLs to SSH and also
accepts SSH URLs or local paths. Refresh does not change repository configuration.
Changes, History and Activity have separate views. Recovery controls appear only
when needed; Squash and force operations are under Advanced.
Setup saves your Git identity and manages SSH keys. Skin edits colours and fonts
on macOS; Windows provides Light/Dark themes.

## Recovery

- Resolve conflicts in your editor, mark each file with **Resolve files**, then
  **Continue** or **Abort** an active operation. Stash conflicts without an active
  operation are resolved and committed normally.
- **New branch** preserves detached commits on a branch.
- **Squash** requires a clean tree, complete history and a backup branch.
  Multi-commit squash honors signing but does not run commit hooks.
- **Force Push** previews lost commits; its protected option pins the lease.
- **Force Pull** requires a fetch, backup and stash, including ignored files.
  Recovery references appear in the log. Backup branches and stashes are retained.

Avoid concurrent external Git changes while an action runs. Tests use disposable
local repositories; live SSH/Keychain and Windows packaging require on-device
verification. Windows uses protected force push only; macOS also offers hard force.
Windows supports Open/recent folders and launcher folder arguments, not drag/drop.

## Licence

All rights reserved. Use, modification and redistribution require prior written
permission from the applicable copyright holder(s). See [LICENCE](LICENCE).
