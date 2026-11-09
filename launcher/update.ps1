param(
    [string]$PackRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$Quiet,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$ManifestUrls = @(
    "https://raw.githubusercontent.com/pedritobm/pbm-mods-pack/main/manifest.json",
    "https://cdn.jsdelivr.net/gh/pedritobm/pbm-mods-pack@main/manifest.json"
)
$AllowedHosts = @(
    "raw.githubusercontent.com", "cdn.jsdelivr.net", "cdn.modrinth.com",
    "github.com", "objects.githubusercontent.com"
)
$LogPath = Join-Path $PSScriptRoot "update.log"
$LockPath = Join-Path $PSScriptRoot ".update.lock"
$StatePath = Join-Path $PackRoot ".minecraft\pack-state.json"
$QuarantineRoot = Join-Path $PackRoot ".minecraft\_PBM_Revisados"
$VerifyDays = 7

function Write-Log([string]$msg, [string]$color = "Gray") {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch {}
    if (-not $Quiet) { Write-Host $msg -ForegroundColor $color }
}

function Get-Sha256([string]$path) {
    return (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
}

function Test-HostAllowed([string]$url) {
    try { $h = ([Uri]$url).Host.ToLower() } catch { return $false }
    foreach ($a in $AllowedHosts) { if ($h -eq $a) { return $true } }
    if ($h.EndsWith(".githubusercontent.com")) { return $true }
    if ($h.EndsWith(".modrinth.com")) { return $true }
    if ($h.EndsWith(".jsdelivr.net")) { return $true }
    return $false
}

function Get-Manifest {
    foreach ($u in $ManifestUrls) {
        try {
            $url = "$u?t=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
            $r = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 15 -Headers @{ "User-Agent" = "PBM-Mods-Updater/1.0" }
            if ($r -and $r.version -and $r.files) { return $r }
        } catch { }
    }
    return $null
}

# ---------------------------------------------------------------- lock
if (Test-Path $LockPath) {
    $other = 0
    $txt = Get-Content $LockPath -Raw -ErrorAction SilentlyContinue
    if ($txt -and [int]::TryParse(($txt -replace '\D', ''), [ref]$other)) {
        if (Get-Process -Id $other -ErrorAction SilentlyContinue) { exit 0 }
    }
    Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
}
Set-Content -Path $LockPath -Value $PID -Encoding ASCII

$tmpRoot = $null
try {
    $manifest = Get-Manifest
    if (-not $manifest) {
        Write-Log "No se pudo leer el manifest (sin internet o GitHub caido). Se juega con lo que hay." "Yellow"
        exit 0
    }

    $state = $null
    if (Test-Path $StatePath) {
        try { $state = Get-Content $StatePath -Raw | ConvertFrom-Json } catch { $state = $null }
    }

    if ($state -and $state.version -eq $manifest.version -and -not $Force) {
        $verified = $null
        if ($state.verifiedAt) { try { $verified = [datetime]$state.verifiedAt } catch {} }
        if ($verified -and ((Get-Date) - $verified).TotalDays -lt $VerifyDays) { exit 0 }
    }

    if (-not $Quiet) {
        if ($state -and $state.version -ne $manifest.version) {
            Write-Host "Actualizando pack $($state.version) -> $($manifest.version)..." -ForegroundColor Cyan
        } elseif (-not $state) {
            Write-Host "Verificando pack ($($manifest.version))..." -ForegroundColor Cyan
        }
    }

    $tmpRoot = Join-Path $env:TEMP ("pbm-update-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    $backupDir = Join-Path $QuarantineRoot ("backup-" + $manifest.version)
    $downloaded = 0
    $errors = 0

    foreach ($f in $manifest.files) {
        $rel = [string]$f.path
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $relFs = $rel -replace '/', '\'
        $dest = [IO.Path]::GetFullPath((Join-Path $PackRoot $relFs))
        $rootFull = [IO.Path]::GetFullPath($PackRoot)
        if (-not $dest.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Log "Ruta invalida en manifest: $rel" "Yellow"
            continue
        }

        $exists = Test-Path $dest
        if ($f.mode -eq "add-if-missing" -and $exists) { continue }
        if ($exists) {
            if ((Get-Sha256 $dest) -eq ([string]$f.sha256).ToLower()) { continue }
        }

        if (-not (Test-HostAllowed ([string]$f.url))) {
            Write-Log "URL no permitida: $($f.url)" "Yellow"
            $errors++
            continue
        }

        $tmp = Join-Path $tmpRoot ([guid]::NewGuid().ToString("N") + ".tmp")
        $ok = $false
        for ($t = 0; $t -lt 2 -and -not $ok; $t++) {
            try {
                Invoke-WebRequest -Uri $f.url -OutFile $tmp -UseBasicParsing -TimeoutSec 90 -Headers @{ "User-Agent" = "PBM-Mods-Updater/1.0" }
                if ((Get-Sha256 $tmp) -eq ([string]$f.sha256).ToLower()) { $ok = $true }
            } catch {
                Start-Sleep -Milliseconds 400
            }
        }
        if (-not $ok) {
            Write-Log "Fallo la descarga: $rel" "Red"
            $errors++
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            continue
        }

        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        if ($exists) {
            $bak = Join-Path $backupDir $relFs
            New-Item -ItemType Directory -Force -Path (Split-Path $bak -Parent) | Out-Null
            Copy-Item $dest $bak -Force
        }
        Move-Item $tmp $dest -Force
        $downloaded++
    }

    # Quitar archivos que ya no estan en el manifest (solo en las carpetas gestionadas)
    $manifestPaths = @{}
    foreach ($f in $manifest.files) { $manifestPaths[($f.path -replace '/', '\')] = $true }
    if ($manifest.syncRoots) {
        foreach ($rootRel in $manifest.syncRoots) {
            $rootDir = Join-Path $PackRoot ($rootRel -replace '/', '\')
            if (-not (Test-Path $rootDir)) { continue }
            $removedDir = Join-Path $QuarantineRoot ("removed-" + $manifest.version)
            foreach ($item in @(Get-ChildItem $rootDir -Recurse -File -ErrorAction SilentlyContinue)) {
                $full = [IO.Path]::GetFullPath($item.FullName)
                $relToRoot = $full.Substring($rootFull.Length).TrimStart('\')
                if (-not $manifestPaths.ContainsKey($relToRoot)) {
                    New-Item -ItemType Directory -Force -Path $removedDir | Out-Null
                    $target = Join-Path $removedDir $item.Name
                    $n = 1
                    while (Test-Path $target) {
                        $target = Join-Path $removedDir ([IO.Path]::GetFileNameWithoutExtension($item.Name) + "_$n" + [IO.Path]::GetExtension($item.Name))
                        $n++
                    }
                    Move-Item $item.FullName $target -Force
                    Write-Log "Movido a cuarentena: $($item.Name)" "DarkYellow"
                }
            }
        }
    }

    if ($errors -eq 0) {
        $newState = [ordered]@{
            version    = $manifest.version
            updatedAt  = (Get-Date).ToString("s")
            verifiedAt = (Get-Date).ToString("s")
            files      = @($manifest.files).Count
        }
        $newState | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
        if ($downloaded -gt 0) {
            Write-Log "Pack actualizado a $($manifest.version) ($downloaded archivo/s)." "Green"
        } else {
            Write-Log "Pack al dia ($($manifest.version))." "Green"
        }
    } else {
        Write-Log "Pack con $errors error(es); se reintenta en el proximo inicio (ver launcher\update.log)." "Yellow"
    }
} catch {
    Write-Log "Error de actualizacion: $($_.Exception.Message)" "Yellow"
} finally {
    if ($tmpRoot -and (Test-Path $tmpRoot)) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
}
