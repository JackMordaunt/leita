# Python 3.10+ must already be provisioned; this script installs nothing.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PythonPath,
    [Parameter(Mandatory = $true)][string]$LeitaPath,
    [Parameter(Mandatory = $true)][string]$Target,
    [int]$WarnUsed = 80,
    [int]$FailUsed = 95,
    [long]$MinFreeBytes = 0,
    [double]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
try {
    $pythonRoot = [System.IO.Path]::GetPathRoot($PythonPath)
    $isAbsolute = [System.IO.Path]::IsPathRooted($PythonPath)
    if ([System.IO.Path]::DirectorySeparatorChar -eq [char]92) {
        # Windows drive-relative C:python.exe and root-relative \python.exe
        # are rooted, but depend on the task's current drive/directory.
        # GetPathRoot works on Windows PowerShell 5.1/.NET Framework too.
        $isAbsolute = $isAbsolute -and $pythonRoot.Length -gt 2
    }
    if (-not $isAbsolute -or
        -not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
        throw 'PythonPath must name an existing absolute Python 3.10+ executable'
    }
    $arguments = @(
        (Join-Path $PSScriptRoot 'check.py'),
        '--leita', $LeitaPath, '--target', $Target,
        '--warn-used', [string]$WarnUsed, '--fail-used', [string]$FailUsed,
        '--min-free-bytes', [string]$MinFreeBytes,
        '--timeout-seconds', $TimeoutSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    )
    # Scanner diagnostics on native stderr must not turn a valid warning into
    # a terminating PowerShell error. Preserve the actual Python exit status.
    $exitCode = $null
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        & $PythonPath @arguments
        $exitCode = $global:LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
    }
    if ($null -eq $exitCode) { throw 'Python could not be executed' }
    exit $exitCode
} catch {
    [Console]::Error.WriteLine('leita-rmm: ' + $_.Exception.Message)
    exit 1
}
