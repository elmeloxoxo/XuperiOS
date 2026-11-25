# XuperiOS

XuperiOS (antes "Marea") es un reproductor SwiftUI para iOS 17 o superior. El primer dispositivo objetivo es el iPhone 11. El proyecto es `XuperiOS.xcodeproj`, el target y el esquema son `XuperiOS` y el bundle id es `io.github.elmeloxoxo.xuperios`.

- `XuperiOS/XuperiOSApp.swift`: interfaz con pestañas Inicio (chips de categoría, carrusel destacado y filas de portadas), TV (lista de canales), Buscar y Perfil (gestión de listas), además del reproductor AVKit a pantalla completa.
- `XuperiOS/StreamCatalog.swift`: valida URLs HTTP/HTTPS, lee listas M3U (incluye `group-title` y `tvg-logo`), reconoce manifiestos HLS y guarda la biblioteca en el dispositivo (`LibraryStore`).
- `XuperiOS/Info.plist`: permite HTTP (ATS) y audio en segundo plano. Se combina con el Info.plist generado por Xcode.
- `XuperiOS/Assets.xcassets`: icono de la app (1024 px, propio, no es el logo de Xuper).
- `.github/workflows/build-ipa.yml`: compila un IPA sin firmar en un runner macOS de GitHub Actions (no hace falta Mac).
- `scripts/export-ipa.sh`: alternativa para quien sí tenga un Mac.

## Estilo visual

Inspirado en el APK de Xuper TV 4.99 (análisis de recursos con apktool): fondo `#0B0B0B`, acento rojo `#FF0033`, categorías tipo DESTACADOS / PELÍCULA / SERIES / TV / PARTIDOS / KIDS / Perfil. El APK es una app para Android TV (leanback) con barra lateral de pestañas; en iPhone se traduce a chips horizontales y barra inferior. No se copian logos ni imágenes del APK.

## Contenido

La app reproduce listas M3U o enlaces que el usuario aporta. No se integra con el backend ni las cuentas de Xuper TV (el APK es una versión modificada de un servicio de terceros y su catálogo no tiene API pública ni licencia).

## Colaborar entre Codex y Claude Code

Trabaja desde esta carpeta. Revisa los cambios existentes antes de editar y conserva los cambios del otro agente. Si trabajan en paralelo, asigna archivos distintos o usa ramas independientes. En cada traspaso deja un resumen de lo que cambió, cómo se verificó, qué falló y cuál es el primer paso pendiente.

## Estado (2026-11-25, Claude Code)

- Renombrado Marea → XuperiOS, nueva interfaz, icono, persistencia de la biblioteca, soporte HTTP y `tvg-logo`, workflow de GitHub Actions.
- Sin verificar todavía: no se ha compilado (no hay macOS en el entorno). La primera ejecución del workflow es la primera compilación real.
- Pendiente: subir esta carpeta a un repositorio de GitHub, ejecutar el workflow, instalar el IPA en el iPhone 11 con Sideloadly/AltStore y probar una lista M3U.
