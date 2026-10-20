---
name: ssh-maquina
description: Conecta por SSH a una máquina remota (Linux/Unix, directamente o a través del bastión mediante PuTTY) y ejecuta comandos en ella, lanza scripts o trae ficheros. Úsala siempre que el usuario quiera entrar en un servidor, ejecutar algo en una máquina, consultar su estado, leer un fichero remoto o comprobar si tiene acceso a un host, aunque no diga "SSH" explícitamente (p. ej. "entra en oa1", "mira el disco de tal máquina", "ejecuta esto en el servidor").
---

# Conexión SSH a máquinas

`<skill>` es el directorio base de esta skill (normalmente `%USERPROFILE%\.claude\skills\ssh-maquina`). Todo pasa por un único script:

```powershell
powershell -ExecutionPolicy Bypass -File "<skill>\scripts\Invoke-Ssh.ps1" -Target <host> -Putty [-Command '<comando>' | -ScriptFile <script.sh>] [-OutFile <fichero>]
```

Sin `-Command` ni `-ScriptFile`, solo comprueba el acceso y muestra el sistema, el usuario, la hora remota y si hay `sudo` sin contraseña.

## Elegir la vía

**PuTTY (`-Putty`), la habitual en este equipo.** Úsala si existe la sesión PuTTY `ssh-plantilla` en `HKCU\Software\SimonTatham\PuTTY\Sessions`.
- La plantilla tiene el usuario, el proxy SOCKS5 `127.0.0.1:1080` y la conexión compartida activada. El proxy es el reenvío dinámico de la sesión PuTTY *Salto*, que el usuario tiene que tener abierta.
- El script crea o actualiza la sesión `ssh-<host>` a partir de la plantilla. Si pasas `usuario@host`, cambia el usuario.
- plink reutiliza la conexión que el usuario tenga abierta y autenticada en PuTTY para ese host.

**OpenSSH (sin `-Putty`)**, para máquinas con autenticación por clave: `-Target <host|usuario@host|alias> [-JumpHost usuario@bastion] [-Port N]`.

## Códigos de salida

- **0 u otro número**: es el código de salida del comando remoto.
- **4** (`-Putty`): no había una conexión autenticada para ese host y el script ha abierto la ventana de PuTTY. Pide al usuario que se autentique allí (y que acepte la huella si es la primera vez), que deje la ventana abierta y te avise. Después repite el mismo comando.
- **2**: fallo de conexión o de autenticación. Explica al usuario el motivo que muestra el script. Con `-Putty`, lo primero es comprobar que la sesión *Salto* está abierta.
- **1**: error en los parámetros.

## Reglas

- **No escribas contraseñas ni aceptes huellas de host por el usuario.** El script nunca pregunta nada: usa `BatchMode=yes` en ssh y `-batch` en plink. Autenticarse es cosa del usuario, en PuTTY.
- **Pide confirmación antes de cambiar nada en la máquina.** Consultar es libre: `uptime`, `df`, `ps`, `journalctl`, `cat`, `ls`, `systemctl status`… Lo que modifica el sistema necesita un "sí" explícito del usuario para esa acción concreta: reiniciar o parar servicios, `kill`, borrar o editar ficheros, instalar paquetes, `sudo`. Explica antes qué hará el comando.
- **Cada `-Command` es una ejecución no interactiva independiente.** No hay sesión persistente: `cd` o las variables no se conservan de una llamada a otra. Encadena los pasos con `;` o `&&`, o usa `-ScriptFile`. Los programas interactivos (`top` sin `-b`, `vi`, `less`) no funcionan; usa sus modos por lotes (`top -bn1`, `cat`, `tail`).
- **Comillas:** pasa el comando entre comillas simples de PowerShell. Si el comando lleva comillas simples dentro, mejor escríbelo en un script y usa `-ScriptFile`.
- **Para traer ficheros** usa `-Command 'cat /ruta/fichero' -OutFile <local>`, que guarda los bytes tal cual (también sirve para binarios y `.gz`). Con ficheros grandes, comprueba antes su tamaño (`ls -lh`).
- La salida remota puede contener datos sensibles (IPs, usuarios, datos de clientes). No la publiques ni la envíes a ningún sitio sin preguntar.
