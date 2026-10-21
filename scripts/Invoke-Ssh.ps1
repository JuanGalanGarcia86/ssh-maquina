<#
.SYNOPSIS
  Conecta por SSH a una máquina remota y ejecuta comandos de forma no interactiva.

.DESCRIPTION
  Dos vías:
  - PuTTY (-Putty): crea, si no existe, la sesión guardada "ssh-<host>" a partir de la plantilla
    (proxy SOCKS, conexión compartida, usuario). El usuario se autentica en la ventana de PuTTY y
    plink reutiliza esa conexión sin pedir contraseña.
  - OpenSSH (ssh.exe): para máquinas con autenticación por clave, con bastión opcional (-JumpHost).
  Nunca pide ni introduce contraseñas ni acepta huellas de host nuevas (BatchMode / plink -batch).

.EXAMPLE
  .\Invoke-Ssh.ps1 -Target oa1.tf2hcs1c1.cdn -Putty                       # comprobar acceso
.EXAMPLE
  .\Invoke-Ssh.ps1 -Target oa1.tf2hcs1c1.cdn -Putty -Command 'uptime; df -h'
.EXAMPLE
  .\Invoke-Ssh.ps1 -Target oa1.tf2hcs1c1.cdn -Putty -Command 'cat /var/log/app.log' -OutFile .\app.log
.EXAMPLE
  .\Invoke-Ssh.ps1 -Target app01 -JumpHost user@bastion -ScriptFile .\diag.sh

  Códigos de salida: el del comando remoto · 1 parámetros/local · 2 conexión o autenticación
                     4 (-Putty) se ha abierto PuTTY: el usuario debe autenticarse y después se reintenta
#>
[CmdletBinding()]
param(
    [string]$Target,                                 # host, usuario@host o alias de ~/.ssh/config
    [switch]$Putty,                                  # vía PuTTY/plink con la sesión "ssh-<host>" creada desde la plantilla
    [string]$PuttyTemplate = 'ssh-plantilla',        # sesión PuTTY plantilla
    [string]$PuttySession,                           # usar directamente una sesión PuTTY ya existente
    [string]$JumpHost,                               # (ssh.exe) bastión(es): "user@bastion" o "b1,b2"
    [int]$Port,                                      # (ssh.exe) puerto del destino
    [string]$HostKeyAlias,                           # (ssh.exe) nombre para known_hosts al ir por túnel local
    [string]$Command,                                # comando remoto
    [string]$ScriptFile,                             # script local que se ejecuta en remoto con "sh -s" (stdin)
    [string]$OutFile,                                # guardar la salida tal cual (binario) en este fichero
    [switch]$CheckOnly,                              # solo comprobar acceso (por defecto si no hay -Command/-ScriptFile)
    [int]$ConnectTimeout = 15,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
function Fail([int]$Code, [string]$Msg) { Write-Host "ERROR: $Msg" -ForegroundColor Red; exit $Code }

$hostRx = '^[A-Za-z0-9_.@:\[\]%,\-]+$'
$puttyRoot = 'HKCU:\Software\SimonTatham\PuTTY\Sessions'

if ($Command -and $ScriptFile) { Fail 1 'Usa -Command o -ScriptFile, no ambos' }
if ($ScriptFile -and -not (Test-Path -LiteralPath $ScriptFile)) { Fail 1 "No existe el script '$ScriptFile'" }
if (-not $Command -and -not $ScriptFile) { $CheckOnly = $true }

# --- Selección de vía -------------------------------------------------------------------------
if ($Putty) {
    if (-not $Target -or $Target -notmatch '^(?:([A-Za-z0-9_.\-]+)@)?([A-Za-z0-9_.\-]+)$') { Fail 1 "Con -Putty, -Target debe ser host o usuario@host: '$Target'" }
    $pUser = $Matches[1]; $pHost = $Matches[2]
    if ($JumpHost -or $Port -or $HostKeyAlias) { Fail 1 'Con -Putty el proxy/bastión sale de la plantilla: no uses -JumpHost/-Port/-HostKeyAlias' }
    if (-not (Test-Path "$puttyRoot\$PuttyTemplate")) { Fail 1 "No existe la sesión plantilla de PuTTY '$PuttyTemplate'" }
    $PuttySession = 'ssh-' + $pHost
    $sessKey = "$puttyRoot\$PuttySession"
    if (-not (Test-Path $sessKey)) {
        Copy-Item -Path "$puttyRoot\$PuttyTemplate" -Destination $sessKey -Recurse
        Write-Host "Creada la sesión PuTTY '$PuttySession' a partir de '$PuttyTemplate'"
    }
    Set-ItemProperty $sessKey -Name HostName -Value $pHost
    if ($pUser) { Set-ItemProperty $sessKey -Name UserName -Value $pUser }
} elseif ($PuttySession) {
    if ($PuttySession -notmatch '^[A-Za-z0-9_.\-]+$') { Fail 1 "PuttySession no válida: '$PuttySession'" }
    if (-not (Test-Path "$puttyRoot\$PuttySession")) { Fail 1 "No existe la sesión PuTTY '$PuttySession'" }
    if ($Target -or $JumpHost -or $Port -or $HostKeyAlias) { Fail 1 'Con -PuttySession no uses -Target/-JumpHost/-Port/-HostKeyAlias' }
} else {
    if (-not $Target) { Fail 1 'Indica -Target (con o sin -Putty) o -PuttySession' }
    if ($Target -notmatch $hostRx) { Fail 1 "Target no válido: '$Target'" }
    if ($JumpHost -and $JumpHost -notmatch $hostRx) { Fail 1 "JumpHost no válido: '$JumpHost'" }
    if ($HostKeyAlias -and $HostKeyAlias -notmatch '^[A-Za-z0-9_.\-]+$') { Fail 1 "HostKeyAlias no válido: '$HostKeyAlias'" }
}

if ($PuttySession) {
    $exe = (Get-Command plink.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) { $exe = @("$env:ProgramFiles\PuTTY\plink.exe", "${env:ProgramFiles(x86)}\PuTTY\plink.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1 }
    if (-not $exe) { Fail 1 'No se encuentra plink.exe (viene con PuTTY)' }
    # -batch: nunca pregunta (contraseñas, huellas). -share: se cuelga de la conexión abierta en PuTTY.
    $baseArgs = @('-batch', '-share', '-T', '-load', $PuttySession)
    $label = "sesión PuTTY $PuttySession"
} else {
    $exe = (Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) { Fail 1 'No se encuentra ssh.exe (característica OpenSSH Client de Windows)' }
    $baseArgs = @('-T', '-o', 'BatchMode=yes', '-o', "ConnectTimeout=$ConnectTimeout",
                  '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4')
    if ($JumpHost) {
        # -J no propaga BatchMode al salto: se quedaría esperando una contraseña hasta agotar el tiempo.
        $hops = $JumpHost -split ','
        $inner = "$exe -o BatchMode=yes -o ConnectTimeout=$ConnectTimeout"
        if ($hops.Count -gt 1) { $inner += ' -J ' + ($hops[0..($hops.Count - 2)] -join ',') }
        $baseArgs += @('-o', "ProxyCommand=$inner -W [%h]:%p $($hops[-1])")
    }
    if ($Port) { $baseArgs += @('-p', $Port) }
    if ($HostKeyAlias) { $baseArgs += @('-o', "HostKeyAlias=$HostKeyAlias") }
    $baseArgs += $Target
    $label = $Target + $(if ($JumpHost) { " vía $JumpHost" } else { '' })
}

# --- Ejecución con stdin/stdout binarios (PowerShell 5.1 corrompe binarios en tuberías) ------------
function Join-NativeArgs([string[]]$List) {
    ($List | ForEach-Object {
        if ($_ -notmatch '[\s"]' -and $_) { $_ }
        else { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }) -join ' '
}

function Invoke-Remote([string]$RemoteCommand, [byte[]]$Stdin, [string]$StdoutFile) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = Join-NativeArgs ($baseArgs + $RemoteCommand)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    # .NET Framework crea StandardInput con Console.InputEncoding; si es UTF-8 con preámbulo, antepone un BOM
    # a lo que se envía por stdin (en remoto: "sh: line 1: ﻿: command not found"). Se fuerza UTF-8 sin BOM al arrancar.
    $prevIn = $null
    try { $prevIn = [Console]::InputEncoding; [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    finally { if ($prevIn) { try { [Console]::InputEncoding = $prevIn } catch { } } }
    $errTask = $p.StandardError.ReadToEndAsync()
    $fs = $null
    if ($StdoutFile) { $fs = [IO.File]::Create($StdoutFile); $outTask = $p.StandardOutput.BaseStream.CopyToAsync($fs) }
    else { $script:outMem = New-Object IO.MemoryStream; $outTask = $p.StandardOutput.BaseStream.CopyToAsync($script:outMem) }
    try {
        if ($Stdin) { $p.StandardInput.BaseStream.Write($Stdin, 0, $Stdin.Length); $p.StandardInput.BaseStream.Flush() }
        $p.StandardInput.Close()
    } catch { }   # si el proceso muere antes de leer stdin, el error real llega por stderr
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        if ($fs) { $fs.Close() }
        return [pscustomobject]@{ ExitCode = 124; StdErr = "Tiempo agotado tras $TimeoutSec s"; StdOut = '' }
    }
    $outTask.Wait(); $p.WaitForExit()
    if ($fs) { $fs.Close() }
    [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdErr   = $errTask.Result
        StdOut   = $(if ($StdoutFile) { '' } else { [Text.Encoding]::UTF8.GetString($script:outMem.ToArray()) })
    }
}

function Explain-Error([string]$Err) {
    if ($PuttySession) { return 'Fallo de plink; revisa el mensaje. ¿Está abierta la sesión PuTTY que da el proxy (p. ej. "Salto")?' }
    if ($Err -match 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED') {
        return 'Clave de host desconocida o cambiada. Conéctate una vez a mano y verifica la huella; no se acepta automáticamente.'
    }
    if ($Err -match 'Permission denied|banner exchange') {
        return 'Autenticación por clave rechazada: el servidor pide contraseña y este script no las usa. Usa la vía PuTTY (-Putty) o autoriza tu clave pública en ese servidor.'
    }
    if ($Err -match 'Could not resolve hostname') { return 'No se resuelve el nombre. ¿VPN conectada? ¿Alias correcto en ~/.ssh/config?' }
    if ($Err -match 'timed out|Connection refused|No route to host') { return 'Sin conectividad con el destino o el bastión. Comprueba VPN, -JumpHost y el puerto SSH.' }
    return 'Fallo de SSH; revisa el mensaje.'
}

# --- Conexión -----------------------------------------------------------------------------------
if ($CheckOnly) {
    $check = 'echo "sistema=$(uname -srm)"; echo "host=$(hostname)"; id; date "+hora_remota=%Y-%m-%d %H:%M:%S %Z %z"; ' +
             'if sudo -n true 2>/dev/null; then echo sudo_sin_password=si; else echo sudo_sin_password=no; fi'
    $remote = "sh -c '$check'"
} elseif ($ScriptFile) {
    $remote = 'sh -s'
} else {
    $remote = $Command
}

$stdin = $null
if ($ScriptFile) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $stdin = $utf8.GetBytes(([IO.File]::ReadAllText((Resolve-Path -LiteralPath $ScriptFile), $utf8) -replace "`r`n", "`n"))
}

Write-Host "Conectando a $label..."
$r = Invoke-Remote $remote $stdin $OutFile

$plinkFatal = $PuttySession -and $r.ExitCode -ne 0 -and $r.StdErr -match 'FATAL ERROR'
if ($plinkFatal -and $r.StdErr -match 'interactive prompts|host key') {
    # No hay conexión compartida abierta: se abre PuTTY para que el usuario se autentique él mismo.
    $open = Get-CimInstance Win32_Process -Filter "Name='putty.exe'" | Where-Object { $_.CommandLine -match "-load\s+`"?$([regex]::Escape($PuttySession))`"?(\s|$)" }
    if (-not $open) {
        Start-Process (Join-Path (Split-Path $exe) 'putty.exe') -ArgumentList '-load', $PuttySession
        Write-Host "Se ha abierto PuTTY con la sesión '$PuttySession'."
    } else {
        Write-Host "La ventana PuTTY de '$PuttySession' está abierta pero aún no autenticada."
    }
    Write-Host 'Autentícate en esa ventana (acepta la huella si es la primera vez), déjala abierta y vuelve a ejecutar.'
    exit 4
}
if ($r.ExitCode -eq 255 -or $r.ExitCode -eq 124 -or $plinkFatal) {
    Write-Host $r.StdErr.Trim()
    Fail 2 (Explain-Error $r.StdErr)
}

if ($OutFile) { Write-Host "Salida guardada en $OutFile ($((Get-Item $OutFile).Length) bytes)" }
elseif ($r.StdOut) { Write-Output $r.StdOut.TrimEnd() }
if ($r.StdErr.Trim()) { Write-Host $r.StdErr.Trim() }
if ($CheckOnly) { Write-Host "Conexión OK ($label)" }
exit $r.ExitCode
