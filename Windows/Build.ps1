param([switch]$Check, [switch]$Package)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

if ($env:JUSTGIT_PYTHON) {
    # CI pins the exact interpreter so packages and the build never diverge.
    $Python = $env:JUSTGIT_PYTHON
    $Prefix = @()
    if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) {
        throw "JUSTGIT_PYTHON is set to '$Python', which is not runnable."
    }
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $Python = "py"
    $Prefix = @("-3")
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $Python = "python"
    $Prefix = @()
} else {
    throw "Install Python 3.11+ with Tcl/Tk and Git for Windows first."
}
& $Python @Prefix -c "import sys, tkinter; assert sys.version_info >= (3, 11), 'Python 3.11+ is required'"
if ($LASTEXITCODE -ne 0) { throw "Python prerequisites failed." }
& $Python @Prefix -m unittest discover -s Windows -p "test_*.py" -v
if ($LASTEXITCODE -ne 0) { throw "Git workflow tests failed. Nothing was packaged." }
& $Python @Prefix Windows/app.py --smoke-test
if ($LASTEXITCODE -ne 0) { throw "Desktop UI checks failed. Nothing was packaged." }
if ($Check) { exit 0 }

if ($Package) {
    & $Python @Prefix -m PyInstaller --version
    if ($LASTEXITCODE -ne 0) {
        throw "Packaging needs PyInstaller. Install it explicitly: $Python -m pip install pyinstaller"
    }
    $Stage = Join-Path ([IO.Path]::GetTempPath()) ("justgit-package-" + [guid]::NewGuid())
    New-Item -ItemType Directory $Stage | Out-Null
    try {
        & $Python @Prefix -m PyInstaller --noconfirm --clean --windowed --onedir --name JustGit `
            --distpath (Join-Path $Stage "dist") --workpath (Join-Path $Stage "work") `
            --specpath $Stage --add-data "LICENCE;." Windows/app.py
        if ($LASTEXITCODE -ne 0) { throw "Packaging failed." }
        $Release = Join-Path "Windows/releases" ("JustGit-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory $Release -Force | Out-Null
        Copy-Item (Join-Path $Stage "dist/JustGit/*") $Release -Recurse
        Copy-Item LICENCE (Join-Path $Release "LICENCE")
        Write-Host "Portable application: $Release/JustGit.exe"
    } finally {
        Remove-Item $Stage -Recurse -Force
    }
} else {
    & $Python @Prefix Windows/app.py
    if ($LASTEXITCODE -ne 0) { throw "JustGit exited with an error." }
}
