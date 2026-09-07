$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'."
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot "src\QuotaWake.psm1") -Force -DisableNameChecking

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("qw-claude-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $sandbox | Out-Null

function Write-Credentials {
    param(
        [string]$Dir,
        [string]$AccessToken = "tok",
        [Nullable[long]]$ExpiresAtMs,
        [Nullable[long]]$RefreshExpiresAtMs
    )
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $oauth = [ordered]@{ accessToken = $AccessToken; refreshToken = "ref" }
    if ($null -ne $ExpiresAtMs) { $oauth.expiresAt = $ExpiresAtMs }
    if ($null -ne $RefreshExpiresAtMs) { $oauth.refreshTokenExpiresAt = $RefreshExpiresAtMs }
    $payload = @{ claudeAiOauth = $oauth } | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath (Join-Path $Dir ".credentials.json") -Value $payload -Encoding UTF8
}

function To-Ms {
    param([DateTime]$Utc)
    return [DateTimeOffset]::new($Utc, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
}

$now = [DateTime]::UtcNow

# --- Get-ClaudeReadOnlyToken -------------------------------------------------
# A live token is usable.
$live = Join-Path $sandbox "live"
Write-Credentials -Dir $live -AccessToken "live-token" -ExpiresAtMs (To-Ms $now.AddHours(2))
Assert-Equal "live-token" `
    (Get-ClaudeReadOnlyToken -CredentialsPath (Join-Path $live ".credentials.json") -UtcNow $now) `
    "a live token is returned"

# A cold token is reported as absent - read-only mode cannot renew it, and
# sending it only earns a 401.
$cold = Join-Path $sandbox "cold"
Write-Credentials -Dir $cold -AccessToken "cold-token" -ExpiresAtMs (To-Ms $now.AddHours(-2))
Assert-True `
    ($null -eq (Get-ClaudeReadOnlyToken -CredentialsPath (Join-Path $cold ".credentials.json") -UtcNow $now)) `
    "an expired token is treated as absent"

# An unrecorded expiry makes no claim to be expired.
$noExpiry = Join-Path $sandbox "noexpiry"
Write-Credentials -Dir $noExpiry -AccessToken "unknown-expiry"
Assert-Equal "unknown-expiry" `
    (Get-ClaudeReadOnlyToken -CredentialsPath (Join-Path $noExpiry ".credentials.json") -UtcNow $now) `
    "a token with no recorded expiry is still usable"

# Missing files must not throw.
Assert-True `
    ($null -eq (Get-ClaudeReadOnlyToken -CredentialsPath (Join-Path $sandbox "missing\.credentials.json") -UtcNow $now)) `
    "a missing credentials file yields no token"

# --- Get-ClaudeLoginExpiryWarning -------------------------------------------
# Warn while the login still works, so it never dies silently.
$soon = Join-Path $sandbox "soon"
Write-Credentials -Dir $soon -ExpiresAtMs (To-Ms $now.AddHours(4)) -RefreshExpiresAtMs (To-Ms $now.AddHours(60))
$warning = Get-ClaudeLoginExpiryWarning -ConfigDir $soon -UtcNow $now
Assert-True ($warning -like "*2 days*") "warning states the remaining time: $warning"
Assert-True ($warning -like "*/login*") "warning names the fix: $warning"
Assert-True ($warning -notlike "*claude auth*") "warning avoids the nonexistent 'claude auth'"

# A healthy login must not nag.
$healthy = Join-Path $sandbox "healthy"
Write-Credentials -Dir $healthy -ExpiresAtMs (To-Ms $now.AddHours(4)) -RefreshExpiresAtMs (To-Ms $now.AddDays(11))
Assert-True `
    ($null -eq (Get-ClaudeLoginExpiryWarning -ConfigDir $healthy -UtcNow $now)) `
    "a healthy login produces no warning"

# A signed-out profile is reported outright.
$signedOut = Join-Path $sandbox "signedout"
Write-Credentials -Dir $signedOut -AccessToken "" -RefreshExpiresAtMs (To-Ms $now.AddDays(-3))
$out = Get-ClaudeLoginExpiryWarning -ConfigDir $signedOut -UtcNow $now
Assert-True ($out -like "*signed out*") "a signed-out profile is reported: $out"

# An already-closed window is reported as expired.
$expired = Join-Path $sandbox "expired"
Write-Credentials -Dir $expired -ExpiresAtMs (To-Ms $now.AddHours(1)) -RefreshExpiresAtMs (To-Ms $now.AddHours(-1))
Assert-True `
    ((Get-ClaudeLoginExpiryWarning -ConfigDir $expired -UtcNow $now) -like "*has expired*") `
    "an expired login window is reported"

# --- Test-ClaudeAuthFailure --------------------------------------------------
$authFailure = [pscustomobject]@{
    name = "Claude"; success = $false
    error = "Claude exited with code 1. Failed to authenticate: OAuth session expired and could not be refreshed"
}
Assert-True (Test-ClaudeAuthFailure -Result $authFailure) "an OAuth expiry is an auth failure"

$quotaFailure = [pscustomobject]@{
    name = "Claude"; success = $false; error = "You've hit your usage limit."
}
Assert-True (-not (Test-ClaudeAuthFailure -Result $quotaFailure)) `
    "a quota exhaustion is not an auth failure - the fallback cannot help"

$successResult = [pscustomobject]@{ name = "Claude"; success = $true; error = $null }
Assert-True (-not (Test-ClaudeAuthFailure -Result $successResult)) "a success is not an auth failure"
Assert-True (-not (Test-ClaudeAuthFailure -Result $null)) "a missing result is not an auth failure"

# --- Invoke-ClaudeReadOnlyProbe ---------------------------------------------
# A cold token must skip rather than send a request that can only 401.
$skipped = Invoke-ClaudeReadOnlyProbe -CredentialsPath (Join-Path $cold ".credentials.json")
Assert-True (-not $skipped.success) "a cold token does not report success"
Assert-True ($skipped.skipped) "a cold token is reported as skipped"

# A live token sends exactly one request carrying the OAuth headers, and the
# probe never writes credentials back.
$captured = $null
$ok = Invoke-ClaudeReadOnlyProbe `
    -CredentialsPath (Join-Path $live ".credentials.json") `
    -Sender { param($h, $b) $script:captured = @{ headers = $h; body = $b }; '{"model":"haiku","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":4,"output_tokens":1}}' }
Assert-True $ok.success "a live token produces a successful probe"
Assert-Equal "read-only-fallback" $ok.via "the result records how it was obtained"
Assert-Equal 5 $ok.usage.totalTokens "fallback retains token evidence"
foreach ($response in @('{}', '{"content":[{"type":"text","text":"wrong"}],"usage":{"input_tokens":4,"output_tokens":1}}', '{"content":[{"type":"text","text":"hi"}]}')) {
    $bad = Invoke-ClaudeReadOnlyProbe -CredentialsPath (Join-Path $live ".credentials.json") -Sender { param($h,$b) $response | ConvertFrom-Json }
    Assert-True (-not $bad.success) "invalid response must not count as a successful wake"
}
Assert-Equal "Bearer live-token" $script:captured.headers["Authorization"] "the live token is sent"
Assert-Equal "oauth-2025-04-20" $script:captured.headers["anthropic-beta"] "the OAuth beta header is sent"
Assert-True ($script:captured.body -like "*Claude Code*") "the Claude Code system prompt is sent"
Assert-Equal "live-token" `
    (Get-ClaudeReadOnlyToken -CredentialsPath (Join-Path $live ".credentials.json") -UtcNow $now) `
    "the probe leaves the credentials untouched"

# A transport failure is reported, not thrown.
$failed = Invoke-ClaudeReadOnlyProbe `
    -CredentialsPath (Join-Path $live ".credentials.json") `
    -Sender { param($h, $b) throw "network unreachable" }
Assert-True (-not $failed.success) "a transport failure reports failure"
Assert-True ($failed.error -like "*network unreachable*") "the reason is preserved: $($failed.error)"

Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
Write-Host "Claude fallback tests passed."
