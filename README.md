# ssh-maquina

Skill de Claude Code para conectarse por SSH a máquinas remotas desde Windows y ejecutar comandos en ellas: consultar su estado, lanzar scripts o traer ficheros. Funciona aunque haya que pasar por un bastión que solo acepta contraseña.

Claude nunca escribe contraseñas ni acepta huellas de servidor en tu nombre. Te autenticas tú en PuTTY y la skill reutiliza esa conexión ya abierta.

## Qué hace

- **Comprueba el acceso** a una máquina y muestra el sistema, el host, el usuario, la hora remota y si hay `sudo` sin contraseña.
- **Ejecuta comandos** remotos de forma no interactiva y devuelve su salida y su código de salida.
- **Ejecuta scripts locales** en la máquina remota: los envía por la entrada estándar a `sh -s`, sin copiarlos al servidor.
- **Trae ficheros** con los bytes tal cual (`cat fichero` + `-OutFile`), también binarios y `.gz`.
- **Pide confirmación** antes de ejecutar cualquier cosa que modifique la máquina (reiniciar servicios, `kill`, borrar o editar ficheros, `sudo`…). Las consultas de solo lectura no la necesitan.

Tiene dos vías de conexión:

| Vía | Cuándo usarla | Cómo autentica |
|---|---|---|
| **PuTTY / plink** (`-Putty`) | El acceso pasa por un bastión con contraseña y usas PuTTY | Te autenticas tú en una ventana de PuTTY y plink reutiliza esa conexión (*connection sharing*) |
| **OpenSSH** (`ssh.exe`) | La máquina acepta tu clave SSH | Clave en `ssh-agent` o `~/.ssh/config`, con bastión opcional (`-JumpHost`) |

## Requisitos

- Windows 10/11 con Windows PowerShell 5.1.
- **Vía PuTTY:**
  - PuTTY con `plink.exe`, en `C:\Program Files\PuTTY` o en el `PATH`.
  - Una sesión de PuTTY abierta en el bastión con un **reenvío dinámico (SOCKS)**, por ejemplo `D1080`.
- **Vía OpenSSH:** el cliente OpenSSH de Windows (`ssh.exe`) y una clave autorizada en el destino.

## Instalación

```bash
git clone https://github.com/JuanGalanGarcia86/ssh-maquina.git "$USERPROFILE/.claude/skills/ssh-maquina"
```

Claude Code carga automáticamente las skills de `~/.claude/skills`.

### Preparar la plantilla de PuTTY (vía PuTTY, una sola vez)

La skill crea una sesión de PuTTY por cada máquina, llamada `ssh-<host>`, a partir de una sesión plantilla llamada **`ssh-plantilla`**. Créala en PuTTY con:

1. **Session:** puerto `22` y protocolo SSH. El *Host Name* déjalo vacío.
2. **Connection > Data:** tu *Auto-login username*.
3. **Connection > Proxy:**
   - tipo **SOCKS 5**, host `127.0.0.1` y el puerto de tu reenvío dinámico (p. ej. `1080`);
   - *Do DNS name lookup at proxy end*: **Yes**.
4. **Connection > SSH:** marca **Share SSH connections if possible**.
5. Vuelve a **Session** y guárdala como `ssh-plantilla`.

## Uso desde Claude

Pídelo con naturalidad. Por ejemplo:

- «Conéctate a `app01.ejemplo.local` y dime cuánto disco libre tiene»
- «Mira en `app01` el estado del servicio nginx y las últimas 100 líneas de su log»
- «Tráete `/var/log/app/app.log` de `app01`»
- «Ejecuta este script en `app01`»

La primera vez que te conectas a una máquina, Claude te abre una ventana de PuTTY para ella. Autentícate en esa ventana (y acepta la huella si te la pide) y avisa a Claude. Te preguntará si quieres instalar tu clave pública en esa máquina (`-InstallKey`). Si aceptas, desde ese momento entra en ella solo con la clave, sin ventana ni contraseña. La sesión del bastión tiene que seguir abierta, porque es la que da el proxy.

### Acceso con clave

- La plantilla `ssh-plantilla` usa la clave `C:\Users\<usuario>\.ssh\id_ed25519.ppk` (en *Connection > SSH > Auth > Credentials*). plink solo acepta claves en formato `.ppk`: si tu clave está en formato OpenSSH, conviértela con PuTTYgen (*Load* y *Save private key*).
- `-InstallKey` crea `~/.ssh` (700) y `authorized_keys` (600) si no existen, y añade la clave solo si no estaba ya. Si el home tiene permisos de escritura para grupo u otros, avisa, porque en ese caso `sshd` ignoraría la clave.
- Comprueba antes que la política de seguridad de tu organización permite claves personales en esos servidores.

## Uso directo del script

```powershell
$s = "$env:USERPROFILE\.claude\skills\ssh-maquina\scripts\Invoke-Ssh.ps1"

# Comprobar acceso
powershell -ExecutionPolicy Bypass -File $s -Target app01.ejemplo.local -Putty

# Ejecutar un comando
powershell -ExecutionPolicy Bypass -File $s -Target app01.ejemplo.local -Putty -Command 'uptime; df -h'

# Traer un fichero (binario seguro)
powershell -ExecutionPolicy Bypass -File $s -Target app01.ejemplo.local -Putty -Command 'cat /var/log/app.log' -OutFile .\app.log

# Ejecutar un script local en remoto
powershell -ExecutionPolicy Bypass -File $s -Target app01.ejemplo.local -Putty -ScriptFile .\diag.sh

# Vía OpenSSH con bastión (autenticación por clave)
powershell -ExecutionPolicy Bypass -File $s -Target usuario@app01 -JumpHost usuario@bastion -Command 'hostname'
```

### Parámetros

| Parámetro | Descripción |
|---|---|
| `-Target` | `host`, `usuario@host` o alias de `~/.ssh/config`. Con `-Putty`, `usuario@host` cambia el usuario de la sesión. |
| `-Putty` | Usa PuTTY/plink: crea o actualiza la sesión `ssh-<host>` a partir de la plantilla. |
| `-PuttyTemplate` | Nombre de la sesión plantilla (por defecto `ssh-plantilla`). |
| `-PuttySession` | Usa directamente una sesión de PuTTY ya existente, en lugar de `-Target`. |
| `-Command` | Comando remoto. Escríbelo entre comillas simples de PowerShell. |
| `-ScriptFile` | Script local que se ejecuta en remoto con `sh -s`. |
| `-OutFile` | Guarda la salida remota tal cual en este fichero. |
| `-CheckOnly` | Solo comprueba el acceso. Es lo que hace si no se indica `-Command`, `-ScriptFile` ni `-InstallKey`. |
| `-InstallKey` | Añade tu clave pública a `~/.ssh/authorized_keys` del destino. Es idempotente. |
| `-PublicKeyFile` | Clave pública que instala `-InstallKey` (por defecto `~/.ssh/id_ed25519.pub`). |
| `-JumpHost` | (OpenSSH) Bastión o bastiones: `usuario@bastion` o `b1,b2`. |
| `-Port` | (OpenSSH) Puerto SSH del destino. |
| `-HostKeyAlias` | (OpenSSH) Nombre para `known_hosts` cuando se entra por un túnel local. |
| `-ConnectTimeout` | Segundos de espera para conectar (por defecto 15). |
| `-TimeoutSec` | Tiempo máximo de ejecución en segundos (por defecto 600). |

### Códigos de salida

| Código | Significado |
|---|---|
| `0` u otro | Código de salida del comando remoto. |
| `1` | Error en los parámetros o en el equipo local. |
| `2` | Fallo de conexión o de autenticación. Con `-Putty`, comprueba que la sesión del bastión (el proxy SOCKS) está abierta. |
| `4` | (`-Putty`) El host no acepta la clave y no había una conexión abierta: se ha abierto PuTTY. Autentícate, ejecuta `-InstallKey` si quieres y vuelve a lanzar el comando. |

## Limitaciones

- Cada ejecución es independiente: `cd` y las variables no se conservan entre comandos. Encadénalos con `;` o `&&`, o usa `-ScriptFile`.
- No admite programas interactivos (`vi`, `less`, `top` sin `-b`). Usa sus modos por lotes (`cat`, `tail`, `top -bn1`).
- Si el comando lleva comillas simples dentro, mejor ponlo en un script y usa `-ScriptFile`.
- En hosts sin clave instalada, la conexión compartida solo funciona mientras sigan abiertas la ventana de PuTTY del host y la del bastión. Con clave instalada basta con la del bastión.

## Seguridad

- Nunca pide ni introduce contraseñas, y no acepta huellas de host nuevas: usa `BatchMode=yes` en ssh y `-batch` en plink.
- Valida `-Target`, `-JumpHost` y los nombres de sesión para evitar inyección en la línea de comandos.
- No instala nada en la máquina remota.
- La salida puede contener datos sensibles. Trátala como tal.
