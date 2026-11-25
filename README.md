# XuperiOS

Reproductor IPTV/M3U para iPhone (iOS 17 o superior), pensado primero para el iPhone 11, con una interfaz inspirada en Xuper TV: fondo negro, acento rojo, carrusel destacado, filas de portadas por categoría, lista de canales, búsqueda y perfil.

## Qué hace

- **Inicio**: chips de categoría (DESTACADOS + las categorías de tu lista), carrusel y filas de portadas. Usa las imágenes `tvg-logo` de la lista si las trae.
- **TV**: lista de canales agrupada por categoría.
- **Buscar**: por título o categoría.
- **Perfil**: cargar una lista por enlace, importar un archivo `.m3u`, borrar la biblioteca y probar la señal Bip Bop.
- La lista se guarda en el iPhone y sigue ahí al reabrir la app. Acepta enlaces HTTP y HTTPS.
- Reproduce lo que AVPlayer soporta: HLS (`.m3u8`), MP4 y MOV. Flujos `.ts` sueltos, MKV o RTMP no funcionan en el reproductor nativo de iOS.

## Compilar el IPA sin Mac (GitHub Actions)

1. Crea un repositorio en GitHub (puede ser privado) y sube el contenido de esta carpeta `XuperiOS` a la raíz, en la rama `main`.
2. Cada push a `main` (o **Actions → Compilar IPA → Run workflow**) compila en un Mac de GitHub.
3. Al terminar (unos 5 minutos), descarga `XuperiOS-unsigned.ipa` desde **Releases → latest** o desde los artefactos de la ejecución.

GitHub Actions es gratis para repos públicos; en privados, los minutos de macOS cuentan 10× contra la cuota gratuita (2 000 min/mes), así que cada compilación gasta unos 50 minutos de cuota.

## Instalar en el iPhone 11

El IPA va sin firmar; iOS solo instala apps firmadas, así que se firma al instalar:

- **Sideloadly (Windows o Mac)**: instala iTunes e iCloud (versiones de la web de Apple, no de la Microsoft Store), conecta el iPhone por cable, arrastra el IPA, pon tu Apple ID y pulsa Start. Con un Apple ID gratuito la app caduca a los 7 días y hay que reinstalarla (se conservan los datos).
- **AltStore / SideStore**: alternativa que renueva la firma cada 7 días desde el propio iPhone.
- **TrollStore**: solo en iOS 14.0 – 16.6.1 y 17.0; instala sin caducidad.

En el iPhone: **Ajustes → General → VPN y gestión de dispositivos** → confía en tu Apple ID, y activa **Ajustes → Privacidad y seguridad → Modo de desarrollador** (iOS 16 o superior) y reinicia.

## Si tienes un Mac

```bash
bash scripts/export-ipa.sh --unsigned ./dist
XUPER_DEVELOPMENT_TEAM=ID_DEL_EQUIPO bash scripts/export-ipa.sh --signed ./dist
```

## Continuar con Claude Code o Codex

Abre esta carpeta como proyecto. `CLAUDE.md` importa `AGENTS.md`, que tiene el mapa del código y el estado.
