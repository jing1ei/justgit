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

CI is configured for Apple silicon and Intel Macs and Windows Server 2022/2025,
with Python 3.11/3.12. Successful macOS and Windows checks upload downloadable
apps to the workflow run's **Artifacts** section. Each macOS artifact contains
`JustGit-macOS-universal.zip`, with both Intel and Apple silicon binaries; the
artifact name identifies the runner that built and tested it. Extract the inner
ZIP to preserve the app bundle's executable permissions.
A configured job is not evidence of a successful run.
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

Push a new numeric tag such as `v1.0.0` to trigger the release workflow. Both
platform builds must succeed before publishing the archives. Use a version that
does not already exist. Manual branch runs use `0.0.0`; manual tag runs use the tag version.
Both upload artifacts without publishing a release. `JUSTGIT_VERSION` and `JUSTGIT_BUILD` override local
bundle metadata; the version must have two or three numeric components and the
build number must be a nonnegative integer.

Release publication checks: `bash Tests/ReleaseTests.sh` (uses a mock GitHub CLI;
never publishes). Tag pushes build all archives from one commit, verify them,
then upload to a draft and publish it. Failed draft uploads can be retried; an
already published release is never overwritten. Manual runs never publish, even
when selecting a tag. GitHub Actions must be enabled and repository policy must
allow the publish job's `contents: write` permission.

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
