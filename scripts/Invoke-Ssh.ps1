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
.EXAMPLE
  .\Invoke-Ssh.ps1 -Target app01.ejemplo.local -Putty -InstallKey        # deja la clave pública instalada en el host

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
    [switch]$InstallKey,                             # añadir la clave pública a ~/.ssh/authorized_keys del destino (idempotente)
    [string]$PublicKeyFile = "$env:USERPROFILE\.ssh\id_ed25519.pub",
    [int]$ConnectTimeout = 15,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
function Fail([int]$Code, [string]$Msg) { Write-Host "ERROR: $Msg" -ForegroundColor Red; exit $Code }

$hostRx = '^[A-Za-z0-9_.@:\[\]%,\-]+$'
$puttyRoot = 'HKCU:\Software\SimonTatham\PuTTY\Sessions'

if ($Command -and $ScriptFile) { Fail 1 'Usa -Command o -ScriptFile, no ambos' }
if ($ScriptFile -and -not (Test-Path -LiteralPath $ScriptFile)) { Fail 1 "No existe el script '$ScriptFile'" }
if ($InstallKey -and ($Command -or $ScriptFile)) { Fail 1 'Usa -InstallKey solo, sin -Command ni -ScriptFile' }
if ($InstallKey -and -not (Test-Path -LiteralPath $PublicKeyFile)) { Fail 1 "No existe la clave pública '$PublicKeyFile'" }
if (-not $Command -and -not $ScriptFile -and -not $InstallKey) { $CheckOnly = $true }

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
} elseif ($ScriptFile -or $InstallKey) {
    $remote = 'sh -s'
} else {
    $remote = $Command
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$stdin = $null
if ($ScriptFile) {
    $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ScriptFile), $utf8)
    $stdin = $utf8.GetBytes(($text.TrimStart([char]0xFEFF) -replace "`r`n", "`n"))
} elseif ($InstallKey) {
    $pub = ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $PublicKeyFile), $utf8)).Trim()
    if ($pub -notmatch '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp\d+) [A-Za-z0-9+/=]+( [^\r\n'']*)?$') { Fail 1 "'$PublicKeyFile' no parece una clave pública OpenSSH" }
    # Idempotente: crea ~/.ssh y authorized_keys con permisos 700/600 y añade la clave solo si no estaba.
    $install = @(
        'umask 077'
        'mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" || exit 1'
        "k='$pub'"
        'touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys" || exit 1'
        'if grep -qxF "$k" "$HOME/.ssh/authorized_keys"; then echo "clave_ya_instalada"; else printf ''%s\n'' "$k" >> "$HOME/.ssh/authorized_keys" && echo "clave_instalada"; fi'
        'if [ -n "$(find "$HOME" -maxdepth 0 -perm /022)" ]; then echo "AVISO: el home tiene permisos de escritura para grupo/otros; sshd puede ignorar la clave"; fi'
    ) -join "`n"
    $stdin = $utf8.GetBytes($install + "`n")
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
    Write-Host 'Para no volver a necesitar la ventana en este host, ejecuta después una vez con -InstallKey.'
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
