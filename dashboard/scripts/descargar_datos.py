"""Descarga la copia de los datos (neogrid_datos.zip) durante la compilación en Render.

Variables de entorno:
    DATOS_URL     enlace de descarga directa del zip (activo de una versión de GitHub)
    DATOS_SHA256  (opcional) huella SHA-256 del zip para verificar la descarga
    RUTA_DATOS    (opcional) carpeta destino; por defecto dashboard/datos
"""
from __future__ import annotations

import hashlib
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
DESTINO = Path(os.environ.get("RUTA_DATOS", str(BASE / "datos")))
ARCHIVOS = ("relacional.sqlite", "dw.sqlite")


def main() -> int:
    if all((DESTINO / a).exists() for a in ARCHIVOS) and not os.environ.get("FORZAR_DESCARGA"):
        print("Los datos ya están en", DESTINO)
        return 0
    url = os.environ.get("DATOS_URL", "").strip()
    if not url:
        print("ERROR: defina la variable de entorno DATOS_URL con el enlace de neogrid_datos.zip.", file=sys.stderr)
        return 1
    if not url.startswith("https://"):
        print("ERROR: DATOS_URL debe empezar por https://", file=sys.stderr)
        return 1
    DESTINO.mkdir(parents=True, exist_ok=True)
    print("Descargando", url)
    huella = hashlib.sha256()
    with tempfile.NamedTemporaryFile(delete=False, suffix=".zip", dir=DESTINO) as tmp:
        peticion = urllib.request.Request(url, headers={"User-Agent": "neogrid-render-build"})
        with urllib.request.urlopen(peticion, timeout=300) as resp:
            total = 0
            while True:
                bloque = resp.read(1 << 20)
                if not bloque:
                    break
                tmp.write(bloque)
                huella.update(bloque)
                total += len(bloque)
                if total % (50 << 20) < (1 << 20):
                    print(f"   {total / 1e6:.0f} MB", flush=True)
        ruta_zip = Path(tmp.name)
    esperada = os.environ.get("DATOS_SHA256", "").strip().lower()
    if esperada and huella.hexdigest() != esperada:
        ruta_zip.unlink(missing_ok=True)
        print("ERROR: la huella SHA-256 del archivo descargado no coincide.", file=sys.stderr)
        return 1
    with zipfile.ZipFile(ruta_zip) as z:
        nombres = set(z.namelist())
        faltan = [a for a in ARCHIVOS if a not in nombres]
        if faltan:
            print("ERROR: el zip no contiene", ", ".join(faltan), file=sys.stderr)
            return 1
        for a in ARCHIVOS:
            with z.open(a) as origen, open(DESTINO / a, "wb") as destino:
                shutil.copyfileobj(origen, destino, 1 << 20)
            print(f"   {a}: {(DESTINO / a).stat().st_size / 1e6:.1f} MB")
    ruta_zip.unlink(missing_ok=True)
    print("Datos listos en", DESTINO)
    return 0


if __name__ == "__main__":
    sys.exit(main())
