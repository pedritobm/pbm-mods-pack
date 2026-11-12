param(
    [string]$Nick,
    [switch]$QuickPlay
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$mc = Join-Path $root ".minecraft"

$versionId = "fabric-loader-0.20.1-1.21.1"
$versionDir = Join-Path $mc "versions\$versionId"
$jsonPath = Join-Path $versionDir "$versionId.json"

function Write-Head($text) {
    Write-Host ""
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ""
}

Write-Head "PBM's Mods - Minecraft 1.21.1 (Fabric, offline)"

if (-not (Test-Path $jsonPath)) {
    Write-Host "Falta el perfil Fabric dentro de la carpeta. Revisa que .minecraft\versions este completo." -ForegroundColor Red
    Read-Host "Enter para cerrar"
    exit 1
}

if (-not $Nick) {
    $Nick = Read-Host "Introduce tu nick"
}

$Nick = $Nick.Trim()
if ($Nick -notmatch '^[A-Za-z0-9_]{3,16}$') {
    Write-Host "Nick invalido: usa 3-16 caracteres (letras, numeros o _)." -ForegroundColor Red
    Read-Host "Enter para cerrar"
    exit 1
}

# ---------------------------------------------------------------- actualizacion
Clear-Host
Write-Host ""
Write-Host "  ==============================================" -ForegroundColor DarkCyan
Write-Host "   PBM's Mods - Comprobando actualizaciones" -ForegroundColor Cyan
Write-Host "  ==============================================" -ForegroundColor DarkCyan
Write-Host ""
$updater = Join-Path $PSScriptRoot "update.ps1"
if (Test-Path $updater) {
    try { & $updater -PackRoot $root -Quiet } catch { Write-Host "  [Pack] no se pudo comprobar la actualizacion." -ForegroundColor Yellow }
}

# Deja activo el resource pack del server desde el inicio, sin esperar a que Polymer lo mande al conectar.
$packName = "PBM_Server_Pack.zip"
$packFile = Join-Path $mc "resourcepacks\$packName"
$optionsFile = Join-Path $mc "options.txt"
if ((Test-Path $packFile) -and (Test-Path $optionsFile)) {
    try {
        $packEntry = "file/$packName"
        $lines = [System.IO.File]::ReadAllLines($optionsFile)
        $changed = $false
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i].StartsWith("resourcePacks:")) {
                $raw = $lines[$i].Substring("resourcePacks:".Length)
                try { $packs = @($raw | ConvertFrom-Json) } catch { $packs = @() }
                if ($packs -notcontains $packEntry) {
                    $packs += $packEntry
                    $lines[$i] = "resourcePacks:" + (ConvertTo-Json -InputObject ([object[]]$packs) -Compress)
                    $changed = $true
                }
                break
            }
        }
        if ($changed) {
            [System.IO.File]::WriteAllLines($optionsFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "  [Pack] resource pack del server activado." -ForegroundColor Green
        }
    } catch {
        Write-Host "  [Pack] no se pudo activar el resource pack local." -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host "  Iniciando Minecraft..." -ForegroundColor Green
Start-Sleep -Seconds 2
Clear-Host

# Si hay un PNG en la carpeta SKINS, lo asigna al nick automaticamente
$skinsFolder = Join-Path $root "SKINS"
if (Test-Path $skinsFolder) {
    $pngs = Get-ChildItem $skinsFolder -Filter *.png -File -ErrorAction SilentlyContinue | Sort-Object Name
    if ($pngs.Count -gt 0) {
        $chosen = $pngs | Where-Object { $_.BaseName -eq $Nick } | Select-Object -First 1
        if (-not $chosen) { $chosen = $pngs | Select-Object -First 1 }
        $skinDir = Join-Path $mc "strayskins\skin"
        New-Item -ItemType Directory -Force -Path $skinDir | Out-Null
        Copy-Item $chosen.FullName (Join-Path $skinDir "$Nick.png") -Force
        Write-Host "Skin asignada: $($chosen.Name) -> strayskins\skin\$Nick.png" -ForegroundColor Green
    }
}

$java = Join-Path $root "runtime\bin\javaw.exe"
if (-not (Test-Path $java)) {
    $fallback = Get-ChildItem "C:\Program Files\Eclipse Adoptium" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "bin\javaw.exe" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if ($fallback) {
        $java = $fallback
    } else {
        Write-Host "No encuentro Java. La carpeta runtime\ parece incompleta." -ForegroundColor Red
        Read-Host "Enter para cerrar"
        exit 1
    }
}

$ramBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
$ramGB = [math]::Round($ramBytes / 1GB)
$heapGB = [math]::Min(8, [math]::Max(2, [math]::Round($ramGB * 0.35)))
$override = Join-Path $root "memoria.txt"
if (Test-Path $override) {
    $value = (Get-Content $override -Raw).Trim() -replace "G$", ""
    if ($value -match '^\d+$') {
        $heapGB = [int]$value
    }
}
$heapGB = [math]::Min($heapGB, [math]::Max(2, $ramGB - 2))
$minHeapGB = [math]::Min(1, $heapGB)

$version = Get-Content $jsonPath -Raw | ConvertFrom-Json

function Test-LibraryAllowed($lib) {
    if (-not $lib.rules) { return $true }
    $allowed = $false
    foreach ($rule in $lib.rules) {
        $osName = $rule.os.name
        if ($osName -and $osName -ne "windows") { continue }
        if ($rule.action -eq "allow") { $allowed = $true }
        elseif ($rule.action -eq "disallow") { $allowed = $false }
    }
    return $allowed
}

$classpath = New-Object System.Collections.Generic.List[string]
foreach ($lib in $version.libraries) {
    if (-not (Test-LibraryAllowed $lib)) { continue }

    $parts = $lib.name -split ":"
    if ($parts.Count -lt 3) { continue }

    $group = $parts[0] -replace "\.", "\"
    $artifact = $parts[1]
    $libVersion = $parts[2]
    $classifier = if ($parts.Count -ge 4) { $parts[3] } else { $null }

    if ($classifier -and $classifier -like "natives*") { continue }

    $fileName = "$artifact-$libVersion"
    if ($classifier) { $fileName = "$fileName-$classifier" }
    $jar = Join-Path $mc "libraries\$group\$artifact\$libVersion\$fileName.jar"

    if (Test-Path $jar) {
        $classpath.Add($jar)
    }
}

$clientJar = Join-Path $versionDir "$versionId.jar"
if (-not (Test-Path $clientJar)) {
    Write-Host "Falta el jar del cliente en .minecraft\versions." -ForegroundColor Red
    Read-Host "Enter para cerrar"
    exit 1
}
$classpath.Add($clientJar)

$md5 = [System.Security.Cryptography.MD5]::Create()
$hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("OfflinePlayer:$Nick"))
$hash[6] = ($hash[6] -band 0x0F) -bor 0x30
$hash[8] = ($hash[8] -band 0x3F) -bor 0x80
$hex = ($hash | ForEach-Object { $_.ToString("x2") }) -join ""
$uuid = "$($hex.Substring(0,8))-$($hex.Substring(8,4))-$($hex.Substring(12,4))-$($hex.Substring(16,4))-$($hex.Substring(20,12))"

$natives = Join-Path $versionDir "natives"
$assetsDir = Join-Path $mc "assets"
$assetIndex = $version.assetIndex.id
$logConfig = Join-Path $assetsDir "log_configs\client-1.12.xml"

function Get-MissingAssets {
    $indexPath = Join-Path $assetsDir "indexes\$assetIndex.json"
    if (-not (Test-Path $indexPath)) { return $null }
    $index = Get-Content $indexPath -Raw | ConvertFrom-Json
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $index.objects.PSObject.Properties) {
        $h = $entry.Value.hash
        $p = Join-Path $assetsDir ("objects\" + $h.Substring(0,2) + "\" + $h)
        if (-not (Test-Path $p)) { $missing.Add($h) }
    }
    return $missing
}

function Ensure-Assets {
    $indexPath = Join-Path $assetsDir "indexes\$assetIndex.json"
    if (-not (Test-Path $indexPath)) {
        Write-Host "Falta el indice de assets. La carpeta esta incompleta." -ForegroundColor Red
        Read-Host "Enter para cerrar"
        exit 1
    }

    $missing = Get-MissingAssets
    $missingCount = if ($null -eq $missing) { 0 } else { $missing.Count }
    if ($missingCount -eq 0) { return }

    Write-Host "Primera ejecucion: descargando $missingCount archivos de recursos..." -ForegroundColor Yellow

    $urls = @($missing | ForEach-Object { "https://resources.download.minecraft.net/" + $_.Substring(0,2) + "/" + $_ })
    $paths = @($missing | ForEach-Object { Join-Path $assetsDir ("objects\" + $_.Substring(0,2) + "\" + $_) })

    $usedParallel = $false
    try {
        if (-not ("PbmAssetDownloader" -as [type])) {
            $code = @"
using System;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public static class PbmAssetDownloader {
    public static int Download(string[] urls, string[] paths, int threads) {
        int errors = 0;
        using (var client = new HttpClient()) {
            client.Timeout = TimeSpan.FromSeconds(60);
            var options = new ParallelOptions();
            options.MaxDegreeOfParallelism = threads;
            Parallel.For(0, urls.Length, options, i => {
                for (int attempt = 0; attempt < 3; attempt++) {
                    try {
                        Directory.CreateDirectory(Path.GetDirectoryName(paths[i]));
                        byte[] data = client.GetByteArrayAsync(urls[i]).GetAwaiter().GetResult();
                        File.WriteAllBytes(paths[i], data);
                        return;
                    } catch {
                        if (attempt == 2) { Interlocked.Increment(ref errors); }
                        else { Thread.Sleep(300); }
                    }
                }
            });
        }
        return errors;
    }
}
"@
            Add-Type -TypeDefinition $code -ReferencedAssemblies "System.Net.Http" -ErrorAction Stop
        }

        $errors = [PbmAssetDownloader]::Download($urls, $paths, 16)
        $usedParallel = $true
        if ($errors -gt 0) {
            Write-Host "  $errors archivos fallaron; reintentando..." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Descarga paralela no disponible, usando modo secuencial..." -ForegroundColor Yellow
    }

    if (-not $usedParallel) {
        $i = 0
        foreach ($u in $urls) {
            $dir = Split-Path $paths[$i] -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            Invoke-WebRequest -Uri $u -OutFile $paths[$i] -UseBasicParsing -TimeoutSec 60
            $i++
            if ($i % 200 -eq 0) { Write-Host "  $i / $($urls.Count)" }
        }
    }

    $still = Get-MissingAssets
    if ($still.Count -gt 0) {
        Write-Host "  Quedan $($still.Count) archivos; reintentando..." -ForegroundColor Yellow
        foreach ($h in $still) {
            $dir = Join-Path $assetsDir ("objects\" + $h.Substring(0,2))
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            $u = "https://resources.download.minecraft.net/" + $h.Substring(0,2) + "/" + $h
            try {
                Invoke-WebRequest -Uri $u -OutFile (Join-Path $dir $h) -UseBasicParsing -TimeoutSec 60
            } catch {
                Write-Host "  No se pudo descargar $u" -ForegroundColor Red
                Read-Host "Enter para cerrar"
                exit 1
            }
        }
    }

    Write-Host "Recursos listos." -ForegroundColor Green
}

Ensure-Assets

$jvmArgs = @(
    "-Xms$($minHeapGB)G",
    "-Xmx$($heapGB)G",
    "-XX:+UseG1GC",
    "-XX:+ParallelRefProcEnabled",
    "-XX:MaxGCPauseMillis=200",
    "-Djava.library.path=$natives",
    "-Djna.tmpdir=$natives",
    "-Dorg.lwjgl.system.SharedLibraryExtractPath=$natives",
    "-Dio.netty.native.workdir=$natives",
    "-Dminecraft.launcher.brand=PBM_Portable",
    "-Dminecraft.launcher.version=1.0",
    "-Dlog4j.configurationFile=$logConfig",
    "-cp",
    ($classpath -join ";")
)

$gameArgs = @(
    "net.fabricmc.loader.impl.launch.knot.KnotClient",
    "--username", $Nick,
    "--version", $versionId,
    "--gameDir", $mc,
    "--assetsDir", $assetsDir,
    "--assetIndex", "$assetIndex",
    "--uuid", $uuid,
    "--accessToken", "0",
    "--userType", "legacy",
    "--versionType", "release",
    "--width", "1280",
    "--height", "720"
)

if ($QuickPlay) {
    $gameArgs += @("--quickPlayMultiplayer", "sv24.minehost.com.ar:25425")
}

$allArgs = New-Object System.Collections.Generic.List[string]
foreach ($a in $jvmArgs) { $allArgs.Add("`"$a`"") }
foreach ($a in $gameArgs) { $allArgs.Add("`"$a`"") }

Write-Host "Nick: $Nick" -ForegroundColor Green
Write-Host "PC: $ramGB GB de RAM -> heap $heapGB GB"
Write-Host "Java: $java"
Write-Host "Lanzando Minecraft..."

$process = Start-Process -FilePath $java -ArgumentList $allArgs.ToArray() -WorkingDirectory $mc -PassThru
Start-Sleep -Seconds 6

if ($process.HasExited) {
    Write-Host ""
    Write-Host "El juego se cerro al arrancar. Ultimas lineas del log:" -ForegroundColor Red
    $log = Join-Path $mc "logs\latest.log"
    if (Test-Path $log) { Get-Content $log -Tail 25 }
    Read-Host "Enter para cerrar"
} else {
    Write-Host "Listo. Servidor ya agregado en Multijugador." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}
