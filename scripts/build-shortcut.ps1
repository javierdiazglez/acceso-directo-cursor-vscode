#Requires -Version 5.1

param(
    [ValidateSet("cursor", "vscode")]
    [string]$Target = "cursor"
)

$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$scriptsDir = Join-Path $projectRoot "scripts"

$targetConfig = @{
    cursor = @{
        ScriptName = "nuevo-proyecto-cursor.ps1"
        ShortcutName = "nuevo-proyecto-cursor.lnk"
        Description = "Ejecutar nuevo-proyecto-cursor.ps1"
    }
    vscode = @{
        ScriptName = "nuevo-proyecto-vscode.ps1"
        ShortcutName = "nuevo-proyecto-vscode.lnk"
        Description = "Ejecutar nuevo-proyecto-vscode.ps1"
    }
}

$config = $targetConfig[$Target]
$scriptPath = Join-Path $scriptsDir $config.ScriptName
$shortcutPath = Join-Path $projectRoot $config.ShortcutName
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "No se encontro el script: $scriptPath"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellExe
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
$shortcut.WorkingDirectory = $scriptsDir
$shortcut.Description = $config.Description
$shortcut.Save()

Write-Host "Acceso directo creado:" -ForegroundColor Green
Write-Host $shortcutPath -ForegroundColor Cyan
Write-Host ""
