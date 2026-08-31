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

function Get-VSCodeExePath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\Code.exe"),
        (Join-Path ${env:ProgramFiles} "Microsoft VS Code\Code.exe")
    )

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    throw "No se encontro Code.exe. Instala VS Code o edita la ruta en el script."
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
    $iconPath = Join-Path $projectRoot "assets\icons\vscode-icon.ico"
    $githubUser = $appConfig.githubUser

    Write-Host "=== Nuevo proyecto VS Code ===" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path -LiteralPath $iconPath)) {
        throw "No se encontro el icono: $iconPath"
    }

    Assert-GitAvailable
    $vscodeExe = Get-VSCodeExePath
    $projectName = Read-RequiredText "Nombre de la carpeta del proyecto"

    if (-not (Test-Path -LiteralPath $basePath)) {
        New-Item -ItemType Directory -Path $basePath -Force | Out-Null
    }

    $projectPath = [System.IO.Path]::GetFullPath((Join-Path $basePath $projectName))
    $shortcutPath = Join-Path $desktopPath "$projectName.lnk"
    $originUrl = "https://github.com/$githubUser/$projectName.git"
    $summary = @()

    Initialize-ProjectGit -ProjectPath $projectPath -OriginUrl $originUrl -Summary ([ref]$summary)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $vscodeExe
    $shortcut.Arguments = "`"$projectPath`" --new-window"
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.WorkingDirectory = $projectPath
    $shortcut.Description = "Abrir $projectName en VS Code"
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
