#Requires -Version 5.1
<#
.SYNOPSIS
    Hermes Agent installer for mainland China (Windows).

.DESCRIPTION
    The official install.ps1 is structurally sound - it pins exact artifacts,
    verifies every download with sha256, and falls back between two URLs. Its
    only problem is that ALL of those URLs point at hosts that are slow or
    blocked from mainland China:

        github.com       repo (1.35 GB of history), uv, PortableGit
        api.github.com   release lookup
        hermes-assets.nousresearch.com   the sha256 fallback mirror
        pypi.org         the ~78 Python dependencies

    This script downloads the official installer, rewrites ONLY the download
    layer against domestic mirrors, verifies the result parses, and runs it.
    The installer's own logic - pinning, sha256 verification, fallback
    ordering, clone/checkout handling - is left untouched.

    What gets rewritten, and why (all speeds measured 2026-10-31):
      * Repo clone  -> cnb.cool (Tencent). 91.6 MB shallow clone in <1 min at
        28 MB/s. GitHub direct: 36 KB/s. gh-proxy: 5-48 KB/s then early EOF.
        origin is rewritten back to GitHub afterwards so `hermes update`
        still follows upstream.
      * PortableGit 55.6 MB -> registry.npmmirror.com at 1.18 MB/s (47 s).
        Via a GitHub proxy the same file takes 55 minutes.
      * uv 2.8 MB -> ghproxy.net, which completes in <40 s. The official
        astral.sh host answers 200 but resets the connection mid-transfer.
      * Extra fallback candidates are inserted BEFORE the blocked
        hermes-assets host, so one flaky mirror does not fail the install.

    No download loses its sha256 check. A bad mirror fails loudly instead of
    installing tampered bytes.

.PARAMETER Channel
    Pass through: 'stable' (default) or 'main'.

.PARAMETER SkipSetup
    Pass through: skip the interactive setup wizard (run `hermes setup` later).

.PARAMETER PatchOnly
    Download and patch the installer, save it, and stop. Useful for inspecting
    exactly what would run.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install-cn.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install-cn.ps1 -SkipSetup
#>
[CmdletBinding()]
param(
    [string]$Channel = '',
    [switch]$SkipSetup,
    [switch]$PatchOnly,
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar makes IRM ~10x slower

$UvProxy     = if ($env:HERMES_CN_GH_PROXY) { $env:HERMES_CN_GH_PROXY } else { 'https://ghproxy.net/' }
$NpmGit      = 'https://registry.npmmirror.com/-/binary/git-for-windows'
$RepoMirror  = 'https://cnb.cool/hermesagent-cn/hermes-agent-cn-mirror.git'
$RepoUpstream = 'https://github.com/NousResearch/hermes-agent.git'

function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    OK   $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "    WARN $m" -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host "    FAIL $m" -ForegroundColor Red }
function Write-Info($m) { Write-Host "    $m" -ForegroundColor DarkGray }

Write-Host @'

  ============================================================
    Hermes Agent - China installer (official + mirror patch)
  ============================================================
    Official installer logic, domestic download sources.

'@ -ForegroundColor White

# ---------------------------------------------------------------- 0. preflight
Write-Step 'Checking PowerShell and TLS'
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Fail "PowerShell 5.1+ required (found $($PSVersionTable.PSVersion))"
    exit 1
}
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Ok "PowerShell $($PSVersionTable.PSVersion) / TLS 1.2"
} catch {
    Write-Fail "cannot enable TLS 1.2: $_"
    exit 1
}

# ---------------------------------------------------------------- 1. fetch official
Write-Step 'Fetching the official installer'
$sources = @(
    'https://hermes-agent.nousresearch.com/install.ps1'
    "$UvProxy`https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1"
    'https://gh-proxy.com/https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1'
)
$text = $null
foreach ($u in $sources) {
    try {
        Write-Info "trying $u"
        $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 45
        if ($r.Content -and $r.Content.Length -gt 50000) {
            $text = $r.Content
            Write-Ok ("{0:N0} bytes" -f $text.Length)
            break
        }
    } catch {
        Write-Warn2 "failed: $($_.Exception.Message)"
    }
}
if (-not $text) {
    Write-Fail 'could not download the official installer from any source'
    Write-Info 'check the network and re-run'
    exit 1
}

# ---------------------------------------------------------------- 2. patch
Write-Step 'Rewriting download sources'

# Anchors must match exactly once. If upstream restructures the script, a
# silent no-op here would leave blocked URLs in place and the install would
# hang on github.com - so abort instead.
$swaps = @(
    @{
        Label = 'uv x64'
        From  = 'Url    = "https://github.com/astral-sh/uv/releases/download/0.13.5/uv-x86_64-pc-windows-msvc.zip"'
        To    = 'Url    = "' + $UvProxy + 'https://github.com/astral-sh/uv/releases/download/0.13.5/uv-x86_64-pc-windows-msvc.zip"'
    }
    @{
        Label = 'uv arm64'
        From  = 'Url    = "https://github.com/astral-sh/uv/releases/download/0.13.5/uv-aarch64-pc-windows-msvc.zip"'
        To    = 'Url    = "' + $UvProxy + 'https://github.com/astral-sh/uv/releases/download/0.13.5/uv-aarch64-pc-windows-msvc.zip"'
    }
    @{
        Label = 'git x64'
        From  = 'Url    = "https://github.com/git-for-windows/git/releases/download/v2.53.0.windows.3/PortableGit-2.53.0.3-64-bit.7z.exe"'
        To    = 'Url    = "' + $NpmGit + '/v2.53.0.windows.3/PortableGit-2.53.0.3-64-bit.7z.exe"'
    }
    @{
        Label = 'git arm64'
        From  = 'Url    = "https://github.com/git-for-windows/git/releases/download/v2.53.0.windows.3/PortableGit-2.53.0.3-arm64.7z.exe"'
        To    = 'Url    = "' + $NpmGit + '/v2.53.0.windows.3/PortableGit-2.53.0.3-arm64.7z.exe"'
    }
)

$bad = @()
foreach ($s in $swaps) {
    $n = ([regex]::Matches($text, [regex]::Escape($s.From))).Count
    if ($n -ne 1) {
        $bad += "$($s.Label): expected 1 match, found $n"
    } else {
        $text = $text.Replace($s.From, $s.To)
        Write-Ok "$($s.Label) -> domestic mirror"
    }
}

# Repo: clone from the mirror, but leave origin pointing at upstream.
$oldRepo = '$RepoUrl = if ($env:HERMES_REPO_URL) { $env:HERMES_REPO_URL } else { "https://github.com/NousResearch/hermes-agent.git" }'
$newRepo = @"
# China build: github.com serves 1.35 GB of history and is unreachable here.
# Clone from the cnb.cool mirror, then rewrite origin to GitHub so
# ``hermes update`` still follows upstream. Set HERMES_REPO_URL to override.
`$RepoUpstream = "$RepoUpstream"
`$RepoMirror   = "$RepoMirror"
`$RepoUrl   = if (`$env:HERMES_REPO_URL) { `$env:HERMES_REPO_URL } else { `$RepoMirror }
`$CloneUrl  = `$RepoUrl
if (`$RepoUrl -eq `$RepoMirror) { `$RepoOriginTarget = `$RepoUpstream } else { `$RepoOriginTarget = "" }
"@
if (([regex]::Matches($text, [regex]::Escape($oldRepo))).Count -ne 1) {
    $bad += 'repo url: anchor not found'
} else {
    $text = $text.Replace($oldRepo, $newRepo)
    Write-Ok "repo clone -> cnb.cool (origin restored to GitHub)"
}

# Extra fallback candidates ahead of the blocked hermes-assets host.
$oldUrls = @'
    $urls = @($Url)
    if ($MirrorUrl -and $MirrorUrl -ne $Url) { $urls += $MirrorUrl }
'@
$newUrls = @'
    $urls = @($Url)
    # China build: extra candidates ahead of the stock fallback, which points at
    # hermes-assets.nousresearch.com and is blocked here. Every candidate is
    # still sha256-verified below - a bad mirror fails loudly, never installs.
    $cnProxy = if ($env:HERMES_CN_GH_PROXY) { $env:HERMES_CN_GH_PROXY } else { "https://ghproxy.net/" }
    $cnCandidates = @(
        ($cnProxy + $Url),
        ("https://gh-proxy.com/" + $Url),
        ($Url -replace '^https://github\.com/git-for-windows/git/releases/download/v([0-9.]+)\.windows\.([0-9]+)/',
                       'https://registry.npmmirror.com/-/binary/git-for-windows/v$1.windows.$2/')
    )
    foreach ($candidate in $cnCandidates) {
        if ($candidate -and $candidate -ne $Url -and $urls -notcontains $candidate) { $urls += $candidate }
    }
    if ($MirrorUrl -and $MirrorUrl -ne $Url) { $urls += $MirrorUrl }
'@
if (([regex]::Matches($text, [regex]::Escape($oldUrls))).Count -ne 1) {
    $bad += 'candidate list: anchor not found'
} else {
    $text = $text.Replace($oldUrls, $newUrls)
    Write-Ok 'fallback candidates -> domestic mirrors'
}

# Retarget origin after a mirror clone.
$oldOrigin = @'
        if ($env:HERMES_REPO_URL) {
            Invoke-Native { git -C $InstallDir remote set-url origin $RepoUrl }
            if ($LASTEXITCODE) { Fail "cannot point origin at $RepoUrl" git_fetch_failed }
        }
'@
$newOrigin = @'
        if ($env:HERMES_REPO_URL) {
            Invoke-Native { git -C $InstallDir remote set-url origin $RepoUrl }
            if ($LASTEXITCODE) { Fail "cannot point origin at $RepoUrl" git_fetch_failed }
        } elseif ($RepoOriginTarget) {
            # Cloned from the China mirror: point origin at upstream so
            # `hermes update` follows GitHub. Not fatal if it fails - a
            # working mirror clone beats no clone.
            Invoke-Native { git -C $InstallDir remote set-url origin $RepoOriginTarget } | Out-Null
            if ($LASTEXITCODE) {
                Log "could not point origin at $RepoOriginTarget; leaving it on the mirror"
            } else {
                Log "origin -> $RepoOriginTarget"
            }
        }
'@
if (([regex]::Matches($text, [regex]::Escape($oldOrigin))).Count -ne 1) {
    $bad += 'origin reset: anchor not found'
} else {
    $text = $text.Replace($oldOrigin, $newOrigin)
    Write-Ok 'origin rewriting after clone'
}

if ($bad.Count -gt 0) {
    Write-Fail 'upstream install.ps1 structure changed - refusing to patch'
    $bad | ForEach-Object { Write-Info "  $_" }
    Write-Info 'Run the official installer unchanged, or update this script.'
    exit 1
}

# ---------------------------------------------------------------- 3. syntax gate
Write-Step 'Validating the patched script'
$errs = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    Write-Fail "patched script has $($errs.Count) syntax error(s)"
    $errs | Select-Object -First 5 | ForEach-Object {
        Write-Info ("  L{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message)
    }
    exit 1
}
Write-Ok ('parse OK ({0:N0} bytes)' -f $text.Length)

# ---------------------------------------------------------------- 4. save
if (-not $OutFile) {
    $OutFile = Join-Path $env:TEMP ("hermes-install-cn-{0}.ps1" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
}
# Write BOM-less, even though PowerShell 5.1's -Encoding UTF8 adds one. The
# installer is a plain .ps1 so a BOM is harmless there, but the same practice
# applied to pip.ini/uv.toml breaks Python's configparser on a GBK locale
# ("UnicodeDecodeError: 'gbk' codec can't decode byte 0xbf"), so keep the habit
# consistent everywhere this project writes a file.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutFile, $text, $utf8NoBom)
Write-Ok "patched installer -> $OutFile"
if ($PatchOnly) {
    Write-Host "`n-PatchOnly: stopping here. Inspect the file above." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------- 5. run
Write-Step 'Running the installer'
Write-Info "repo : $RepoMirror"
Write-Info "git  : npmmirror CDN"
Write-Info "uv   : $UvProxy"
Write-Info 'pip  : tsinghua mirror (set by the installer)'
Write-Host ''

$psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $OutFile)
if ($Channel)   { $psArgs += @('-Channel', $Channel) }
if ($SkipSetup) { $psArgs += '-SkipSetup' }

$code = 1
try {
    & powershell @psArgs
    $code = $LASTEXITCODE
} catch {
    Write-Fail "installer threw: $($_.Exception.Message)"
}

Write-Host ''
if ($code -ne 0) {
    Write-Fail "installer exited with code $code"
    Write-Info "the patched script was left at $OutFile for inspection"
    Write-Info 're-running this script reuses anything already downloaded'
    exit $code
}

# ---------------------------------------------------------------- 6. verify
Write-Step 'Verifying'
$hermesRoot = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:LOCALAPPDATA 'hermes' }
$repo = Join-Path $hermesRoot 'hermes-agent'

if (Test-Path (Join-Path $repo '.git')) {
    Write-Ok 'repo has .git (hermes update available)'
    $origin = & git -C $repo config --get remote.origin.url 2>$null
    if ($origin) { Write-Info "origin: $origin" }
} elseif (Test-Path $repo) {
    Write-Warn2 'repo present but no .git - hermes update will refuse'
} else {
    Write-Warn2 'repo directory not found'
}

$cmd = Get-Command hermes -ErrorAction SilentlyContinue
if ($cmd) { Write-Ok "hermes -> $($cmd.Source)" } else { Write-Info 'hermes not on PATH yet (new terminal needed)' }

Write-Host @"

    Done.

    Next:
      1. Close this window, open a NEW terminal (PATH is read at startup)
      2. Run:  hermes
      3. Then: hermes setup

    Install home: $hermesRoot
"@ -ForegroundColor Green
