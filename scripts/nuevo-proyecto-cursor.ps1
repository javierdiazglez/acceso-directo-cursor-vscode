#Requires -Version 5.1

$ErrorActionPreference = "Stop"

function Get-ProjectRoot {
    $startDir = if ($PSScriptRoot) {
        $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        throw "No se pudo determinar la ubicacion del script."
    }

    $dir = $startDir
    while ($dir) {
        $configPath = Join-Path $dir "config\config.json"

        if (Test-Path -LiteralPath $configPath) {
            return (Resolve-Path -LiteralPath $dir).Path
        }

        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) {
            break
        }

        $dir = $parent
    }

    throw "No se encontro config/config.json. Crea o edita config/config.json en la raiz del proyecto."
}

function Get-AppConfig {
    param(
        [string]$ProjectRoot
    )

    $configPath = Join-Path $ProjectRoot "config\config.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "No se encontro config/config.json. Crea o edita config/config.json con tus valores."
    }

    $rawConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

    foreach ($field in @("githubUser", "projectsFolder", "shortcutsFolder")) {
        if ([string]::IsNullOrWhiteSpace($rawConfig.$field)) {
            throw "El campo '$field' es obligatorio en config/config.json."
        }
    }

    return $rawConfig
}

function Resolve-ShortcutsFolder {
    param(
        [string]$ShortcutsFolder
    )

    if ($ShortcutsFolder -eq "Desktop") {
        return [Environment]::GetFolderPath("Desktop")
    }

    return [System.IO.Path]::GetFullPath($ShortcutsFolder)
}

function Get-CursorExePath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\cursor\cursor.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Cursor\Cursor.exe")
    )

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    throw "No se encontro cursor.exe. Instala Cursor o edita la ruta en el script."
}

function Assert-GitAvailable {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        throw "No se encontro git. Instala Git for Windows y vuelve a ejecutar el script."
    }
}

function Invoke-Git {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments
    )

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $output = & git -C $WorkingDirectory @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            $command = "git $($Arguments -join ' ')"
            throw "Git fallo ($command): $output"
        }

        return $output
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
}

function Invoke-GitClone {
    param(
        [string]$RepositoryUrl,
        [string]$DestinationPath
    )

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $output = & git clone $RepositoryUrl $DestinationPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "No se pudo clonar el repositorio: $output"
        }

        return $output
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
}

function Read-RequiredText {
    param(
        [string]$Prompt
    )

    do {
        $value = Read-Host $Prompt
        $value = $value.Trim()
    } while ([string]::IsNullOrWhiteSpace($value))

    return $value
}

function Resolve-ProjectInput {
    param(
        [string]$RelativeInput,
        [string]$BasePath
    )

    $relative = $RelativeInput.Trim()
    $relative = $relative -replace '/', '\'

    if ([string]::IsNullOrWhiteSpace($relative)) {
        throw "La ruta del proyecto no puede estar vacia."
    }

    if ([System.IO.Path]::IsPathRooted($relative)) {
        throw "Usa una ruta relativa bajo Proyectos, no una ruta absoluta."
    }

    foreach ($segment in $relative.Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($segment -eq '..') {
            throw "La ruta no puede contener '..'."
        }
    }

    $normalizedBase = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $normalizedBase.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $normalizedBase += [System.IO.Path]::DirectorySeparatorChar
    }

    $projectPath = [System.IO.Path]::GetFullPath((Join-Path $BasePath $relative))

    if (-not $projectPath.StartsWith($normalizedBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "La ruta debe estar dentro de la carpeta de proyectos."
    }

    $baseTrimmed = $normalizedBase.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ($projectPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar) -eq $baseTrimmed) {
        throw "Indica el nombre o la ruta de la carpeta del proyecto, no solo la carpeta base."
    }

    $repoName = [System.IO.Path]::GetFileName($projectPath.TrimEnd('\', '/'))
    if ([string]::IsNullOrWhiteSpace($repoName)) {
        throw "No se pudo determinar el nombre del repositorio."
    }

    return [PSCustomObject]@{
        RelativePath = $relative
        ProjectPath  = $projectPath
        RepoName     = $repoName
    }
}

function Write-Separator {
    Write-Host ("-" * 50) -ForegroundColor DarkGray
}

function Write-PathLine {
    param(
        [string]$Label,
        [string]$Path
    )

    Write-Host "$Label " -NoNewline
    Write-Host $Path -ForegroundColor Cyan
}

function Wait-BeforeExit {
    Read-Host "Pulsa Enter para cerrar"
}

function Initialize-ProjectGit {
    param(
        [string]$ProjectPath,
        [string]$OriginUrl,
        [ref]$Summary
    )

    $gitDir = Join-Path $ProjectPath ".git"
    $folderExists = Test-Path -LiteralPath $ProjectPath

    if ($folderExists -and -not (Test-Path -LiteralPath $gitDir)) {
        throw "La carpeta ya existe pero no es un repositorio Git. Eliminala o elige otro nombre."
    }

    if (-not $folderExists) {
        $parentDir = Split-Path -Parent $ProjectPath
        if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }

        Write-Host "Clonando repositorio..." -ForegroundColor Yellow
        Invoke-GitClone -RepositoryUrl $OriginUrl -DestinationPath $ProjectPath | Out-Null
        $Summary.Value += "Repositorio clonado desde $OriginUrl."
    } else {
        Write-Host ""
        Write-Host "La carpeta ya existe. Se actualizara Git y el acceso directo." -ForegroundColor Yellow
        Invoke-Git -WorkingDirectory $ProjectPath -Arguments @("remote", "set-url", "origin", $OriginUrl) | Out-Null
        $Summary.Value += "Carpeta existente reutilizada."
        $Summary.Value += "Remoto origin actualizado."
    }

    Invoke-Git -WorkingDirectory $ProjectPath -Arguments @("branch", "-M", "main") | Out-Null
    $Summary.Value += "Rama principal configurada como main."
}

try {
    $projectRoot = Get-ProjectRoot
    $appConfig = Get-AppConfig -ProjectRoot $projectRoot
    $basePath = Join-Path $env:USERPROFILE $appConfig.projectsFolder
    $desktopPath = Resolve-ShortcutsFolder -ShortcutsFolder $appConfig.shortcutsFolder
    $iconPath = Join-Path $projectRoot "assets\icons\cursor-ai-code-icon.ico"
    $githubUser = $appConfig.githubUser

    Write-Host "=== Nuevo proyecto Cursor ===" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path -LiteralPath $iconPath)) {
        throw "No se encontro el icono: $iconPath"
    }

    Assert-GitAvailable
    $cursorExe = Get-CursorExePath
    $relativeInput = Read-RequiredText "Ruta del proyecto"

    if (-not (Test-Path -LiteralPath $basePath)) {
        New-Item -ItemType Directory -Path $basePath -Force | Out-Null
    }

    $resolved = Resolve-ProjectInput -RelativeInput $relativeInput -BasePath $basePath
    $projectPath = $resolved.ProjectPath
    $repoName = $resolved.RepoName
    $shortcutPath = Join-Path $desktopPath "$repoName.lnk"
    $originUrl = "https://github.com/$githubUser/$repoName.git"
    $summary = @()

    Initialize-ProjectGit -ProjectPath $projectPath -OriginUrl $originUrl -Summary ([ref]$summary)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $cursorExe
    $shortcut.Arguments = "`"$projectPath`" --new-window"
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.WorkingDirectory = $projectPath
    $shortcut.Description = "Abrir $repoName en Cursor"
    $shortcut.Save()

    $summary += "Acceso directo creado en el Escritorio."

    $currentBranch = (Invoke-Git -WorkingDirectory $projectPath -Arguments @("branch", "--show-current")).Trim()

    Write-Host ""
    Write-Separator
    Write-Host "Listo." -ForegroundColor Green
    Write-Host ""
    Write-Host "Resumen:" -ForegroundColor Cyan
    foreach ($line in $summary) {
        Write-Host "  - $line"
    }
    Write-Host ""
    Write-PathLine "Carpeta:" $projectPath
    Write-PathLine "Acceso directo:" $shortcutPath
    Write-PathLine "Repositorio remoto:" $originUrl
    Write-Host "Rama principal: " -NoNewline
    Write-Host $currentBranch -ForegroundColor Cyan
    Write-Separator
    Write-Host ""
} catch {
    Write-Host ""
    Write-Separator
    Write-Host "Error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Separator
} finally {
    Wait-BeforeExit
}
