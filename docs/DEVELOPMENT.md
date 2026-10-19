# Build, test & release

## macOS

Requires Swift 5.7+ and a macOS SDK supporting a deployment target of 11.0.
Running the app requires Apple’s Git command-line tools.

```sh
./Build.command --check                         # Build and test, no install
./Build.command --package /tmp/JustGit-package   # Universal arm64 + x86_64 app
bash Tests/BuildTests.sh                        # Inert installer/packaging rollback tests
bash Tests/CompatibilityTests.sh /tmp/JustGit-package/JustGit.app
```

Double-clicking `Build.command` without options tests, installs into
`~/Applications/JustGit.app`, and launches it. Quit the app before installing.
Package mode preserves the previous output if assembling or replacing it fails.

The build compiles against the newest macOS SDK the installed Swift toolchain
can use: after a Command Line Tools update the default SDK can be newer than the
compiler, so each architecture is probed and an older compatible SDK is selected
automatically. Set `JUSTGIT_SDK=/path/to/MacOSX.sdk` to force a specific SDK.

## Windows

Install Python 3.11+ with Tcl/Tk and Git for Windows on PATH.

```powershell
powershell -File Windows/Build.ps1 -Check
python -m pip install -r Windows/requirements-build.txt
powershell -File Windows/Build.ps1 -Package
```

Packages are written under `Windows/releases/`. Keep all files in the portable
folder together. Packaging tests both the source UI and the frozen executable.
Release configuration uses Python 3.12 x64; `JUSTGIT_PYTHON` can select an explicit
interpreter. `Run-Windows.cmd` accepts an optional repository folder argument.

## Compatibility

`CompatibilityTests.sh` validates both Mach-O architectures, the macOS 11.0
minimum in the executable and bundle metadata, and the ad-hoc signature. It runs
self-tests under each architecture the host can execute; Intel runs via Rosetta
on Apple silicon when Rosetta is already installed. The script does not install it.

CI is configured for Apple silicon (`macos-15`) and Intel (`macos-15-intel`)
Macs and Windows Server 2022/2025, with Python 3.11/3.12. These checks run on
every pull request and every push to `main`, and upload a built app to the
workflow run's **Artifacts** section. The macOS check builds a universal binary
with both Intel and Apple silicon slices. A configured or passing job is not
evidence of a verified release on the older desktop OSes:
Big Sur and Windows 10 desktop verification remains outstanding. On each target:

1. Open a disposable repository, commit, and restart the app.
2. Push, pull, and sync against a local bare remote.
3. Create a conflict, resolve/continue, then repeat and abort.
4. Check Settings, Appearance, keyboard navigation, and window sizing.
5. Verify live SSH/Keychain separately using a test account.

Big Sur uses Apple’s older `ssh-add -K` flag. Newer macOS uses
`--apple-use-keychain`. Multi-commit Squash honors signing but does not run commit
hooks. Windows offers protected Force Push; Mac also offers a hard-force option.

## Refresh the README screenshots

```sh
JUSTGIT_DOC_SCREENSHOTS="$PWD/docs/screenshots" ./Build.command --check
```

The self-test builds a disposable Fieldnotes repository with real commits and a
merge conflict, then captures the native Changes, History, and Recovery panels.
It does not restore recent repositories, save settings, or contact a remote.
Inspect all PNGs before committing them. Do not substitute mockups for screenshots.

## Releases

Releases are cut from a pushed semantic tag; nothing is published on ordinary
commits. The workflow is `.github/workflows/release-tag.yml`.

```sh
git tag v1.2.3
git push origin v1.2.3
```

Tags look like `vMAJOR.MINOR.PATCH` (a two-component `v1.2` or a
`v1.2.3-rc1` suffix is also accepted). On a tag push, GitHub Actions:

1. Derives the bundle version from the tag (without the `v`).
2. Builds, self-tests and packages the macOS universal app (`macos-15`),
   including `CompatibilityTests.sh` and `BuildTests.sh`.
3. Builds, unit-tests, UI-smoke-tests and packages the Windows portable folder.
4. Produces the `git archive` source zip.
5. Only if every platform job succeeds, creates the GitHub Release and attaches
   the three archives plus `SHA256SUMS.txt`.

A failed build leaves no release behind (the publish job only runs once all
builds pass). Re-running a tag's workflow updates the same release. A tag with a
prerelease suffix is published as a GitHub pre-release.

The publish job is the only job granted `contents: write`; check jobs and
pull-request runs keep read-only permissions. GitHub Actions must be enabled and
repository policy must allow that permission. `JUSTGIT_VERSION` and
`JUSTGIT_BUILD` override local bundle metadata (the CI sets both from the tag and
run number); a local version must have two or three numeric components and the
build number must be a nonnegative integer.

Mac bundles are ad-hoc signed, without Developer ID signing or notarization.
Windows executables are unsigned. Do not describe them as notarized or signed by
a verified publisher.

## Icons

The application and menu-bar mark share vector geometry in `Sources/AppIcon.swift`.
Regenerate the Mac and Windows assets on macOS:

```sh
xcrun swiftc Sources/AppIcon.swift Tools/GenerateIcons.swift -o /tmp/justgit-icons
/tmp/justgit-icons
```

Generated assets are committed in `Assets/`; ordinary builds need no image tools.
