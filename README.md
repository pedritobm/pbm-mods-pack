# PBM Mods 1.21.1 - manifest del pack

Repo de versionado y distribucion del pack **PBM Mods** (Fabric 1.21.1).

El launcher de cada jugador lee `manifest.json` al iniciar Minecraft y aplica
solo los cambios necesarios. Los jars se descargan de la CDN de Modrinth; los
archivos propios (mods nuestros, configs y resourcepacks por defecto) se sirven
desde este repo.

## Estructura

```
manifest.json                 <- manifiesto que lee el launcher (version actual)
files/                        <- archivos por defecto servidos por raw.githubusercontent
  .minecraft/config/          <- configs por defecto (solo se agregan si faltan)
  .minecraft/resourcepacks/   <- packs por defecto (solo se agregan si faltan)
  .minecraft/mods/            <- jars propios que no estan en Modrinth
launcher/update.ps1           <- actualizador del cliente
tools/build-manifest.py       <- genera el manifest y sincroniza files/
```

## Que toca y que no

| Ruta | Modo |
|------|------|
| `.minecraft/mods` | `sync`: agrega, actualiza y manda a cuarentena lo que sobra |
| `.minecraft/config` | `add-if-missing`: solo agrega si no existe |
| `.minecraft/resourcepacks` | `add-if-missing`: solo agrega, nunca borra |
| `.minecraft/shaderpacks` | `add-if-missing`: solo agrega, nunca borra |
| `options.txt`, `servers.dat`, saves, screenshots, xaero, skins, keybinds | **nunca** |

Lo que se reemplaza o se quita queda en `.minecraft/_PBM_Revisados/` (backup por
version y removidos). Nunca se borra nada de forma definitiva.

## Publicar una version nueva

1. Actualizar el pack local (mods/configs/packs).
2. Ejecutar:

```powershell
python tools/build-manifest.py --pack "C:\ruta\PBM Mods 1.21.1" --repo . --version 1.1.0
```

3. Commit y push del `manifest.json` y de `files/`.
4. Listo: los launcher lo toman en el proximo inicio.

El script:

- resuelve cada jar contra Modrinth por SHA-1 y usa la URL de la CDN,
- copia a `files/` solo los jars que no estan en Modrinth,
- sincroniza las configs y resourcepacks por defecto (con lista de exclusiones
  para no subir datos personales),
- calcula SHA-256 de todo y escribe `manifest.json`.

## Seguridad

- Solo se descarga desde hosts permitidos (`cdn.modrinth.com`,
  `raw.githubusercontent.com`, `cdn.jsdelivr.net`, GitHub).
- Cada archivo se verifica por SHA-256 antes de aplicarse.
- Si no hay internet o falla GitHub, el juego arranca igual con lo que ya tiene.
- Hay lock para evitar dos actualizaciones a la vez y log en
  `launcher/update.log`.

## Exclusiones de configs (no se suben)

`config/juxtui` (panoramas personales), `config/voicechat`, `config/xaero`,
`iris.properties`, `sodium-options.json`, `sodium-extra-options.json`,
`watut-client.toml`, `watut-common.toml`, `lumevale-camera.json`,
`last-world-panorama.json`, `xaerohud.txt`, `xaeropatreon.txt`.
