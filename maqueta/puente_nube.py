"""puente_nube.py · NeoGrid
Une la maqueta física con el ecosistema de datos. Corre en el computador de la maqueta,
junto a Mosquitto y al suscriptor de Python (no los reemplaza ni los modifica).

Cada 60 s:  EXEC NeoGridRelacional.dbo.sp_importar_maqueta   (NeoGridAlumbrado -> modelo relacional)
            y, si llegaron mediciones nuevas, EXEC NeoGridDW.dbo.sp_etl_ejecutar_tsql (-> data warehouse)
Cada 10 s:  envía el estado en vivo de los dos tableros al tablero web (POST /api/maqueta/estado)

Requisitos: py -3.13 -m pip install pyodbc   +   ODBC Driver 18 for SQL Server
Configuración: archivo puente.env junto a este script (vea puente.env.example):
    URL_TABLERO=https://neogrid-alumbrado.onrender.com
    CLAVE_INGESTA=la misma clave que tiene el servicio en Render
Ejecutar:  py -3.13 C:\\neogrid\\puente_nube.py            (o con --sin-nube / --sin-etl / --una-vez)
"""
from __future__ import annotations

import argparse
import datetime as dt
import decimal
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import pyodbc

CARPETA = Path(__file__).resolve().parent


def leer_config() -> dict:
    cfg = {}
    archivo = CARPETA / "puente.env"
    if archivo.exists():
        for linea in archivo.read_text(encoding="utf-8").splitlines():
            linea = linea.strip()
            if linea and not linea.startswith("#") and "=" in linea:
                k, v = linea.split("=", 1)
                cfg[k.strip()] = v.strip()
    for k in ("URL_TABLERO", "CLAVE_INGESTA", "SQL_SERVIDOR"):
        if os.environ.get(k):
            cfg[k] = os.environ[k]
    cfg.setdefault("SQL_SERVIDOR", "localhost")
    cfg["URL_TABLERO"] = cfg.get("URL_TABLERO", "").rstrip("/")
    return cfg


def conectar(servidor: str, base: str):
    return pyodbc.connect(
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER={servidor};DATABASE={base};Trusted_Connection=yes;TrustServerCertificate=yes;APP=NeoGrid-Puente",
        autocommit=True, timeout=10)


def a_json(valor):
    if isinstance(valor, decimal.Decimal):
        return float(valor)
    if isinstance(valor, (dt.datetime, dt.date)):
        return valor.strftime("%Y-%m-%d %H:%M:%S") if isinstance(valor, dt.datetime) else valor.isoformat()
    return valor


def filas(cursor) -> list[dict]:
    """Primer conjunto de resultados con columnas (salta mensajes y conteos)."""
    while cursor.description is None:
        if not cursor.nextset():
            return []
    cols = [c[0] for c in cursor.description]
    datos = [{c: a_json(v) for c, v in zip(cols, f)} for f in cursor.fetchall()]
    while cursor.nextset():  # consumir el resto para que el lote termine
        pass
    return datos


def importar(cx_rel) -> dict:
    cur = cx_rel.cursor()
    cur.execute("EXEC dbo.sp_importar_maqueta")
    r = filas(cur)
    return r[0] if r else {}


def ejecutar_etl(cx_dw) -> str:
    cur = cx_dw.cursor()
    cur.execute("EXEC dbo.sp_etl_ejecutar_tsql")
    r = filas(cur)
    if not r:
        return "ETL sin resultado"
    e = r[0]
    return f"ETL #{e.get('ejecucion_id')} {e.get('estado')}: {e.get('mensaje')}"


def estado_vivo(cx_rel) -> tuple[list, list]:
    cur = cx_rel.cursor()
    cur.execute("EXEC dbo.sp_maqueta_estado_vivo")
    tableros = filas(cur)
    cur.execute("""SELECT TOP (20) fecha_hora, UPPER(tablero) AS tablero, tipo, antes, ahora, brillo_pct
                   FROM maq.evento_poste ORDER BY id DESC""")
    eventos = filas(cur)
    return tableros, eventos


def enviar(url: str, clave: str, cuerpo: dict) -> str:
    datos = json.dumps(cuerpo, ensure_ascii=False).encode("utf-8")
    peticion = urllib.request.Request(url + "/api/maqueta/estado", data=datos, method="POST",
                                      headers={"Content-Type": "application/json", "X-API-Key": clave,
                                               "User-Agent": "neogrid-puente"})
    with urllib.request.urlopen(peticion, timeout=20) as resp:
        return resp.read().decode("utf-8")[:200]


def main() -> int:
    p = argparse.ArgumentParser(description="Puente entre la maqueta NeoGrid y el ecosistema de datos")
    p.add_argument("--sin-nube", action="store_true", help="no enviar el estado en vivo al tablero web")
    p.add_argument("--sin-etl", action="store_true", help="no ejecutar el ETL hacia el data warehouse")
    p.add_argument("--una-vez", action="store_true", help="importar, cargar y enviar una sola vez")
    a = p.parse_args()
    cfg = leer_config()
    nube = not a.sin_nube and cfg.get("URL_TABLERO") and cfg.get("CLAVE_INGESTA")
    if not a.sin_nube and not nube:
        print("Aviso: falta URL_TABLERO o CLAVE_INGESTA en puente.env; solo se actualizarán las bases locales.")

    cx_rel = cx_dw = None
    ultimo_import = 0.0
    ultimo_envio = 0.0
    resumen_import: dict = {}
    print("Puente NeoGrid iniciado. Ctrl+C para detener.")
    while True:
        try:
            if cx_rel is None:
                cx_rel = conectar(cfg["SQL_SERVIDOR"], "NeoGridRelacional")
                print("Conectado a NeoGridRelacional.")
            if cx_dw is None and not a.sin_etl:
                cx_dw = conectar(cfg["SQL_SERVIDOR"], "NeoGridDW")
                print("Conectado a NeoGridDW.")
            ahora = time.monotonic()
            if ahora - ultimo_import >= 60 or a.una_vez:
                ultimo_import = ahora
                r = importar(cx_rel)
                resumen_import = {k: r.get(k) for k in ("mediciones_insertadas", "eventos", "registros_casas",
                                                        "fallas_abiertas", "fallas_resueltas", "ultimo_intervalo")}
                hora = dt.datetime.now().strftime("%H:%M:%S")
                print(f"{hora} importación: {r.get('mediciones_insertadas', 0)} mediciones, {r.get('eventos', 0)} eventos, "
                      f"{r.get('registros_casas', 0)} conteos de casas, fallas +{r.get('fallas_abiertas', 0)}/-{r.get('fallas_resueltas', 0)}")
                if not a.sin_etl and ((r.get("mediciones_insertadas") or 0) > 0 or (r.get("fallas_abiertas") or 0) > 0
                                      or (r.get("fallas_resueltas") or 0) > 0):
                    texto = ejecutar_etl(cx_dw)
                    resumen_import["etl"] = texto
                    print(f"{hora} {texto}")
            if nube and (ahora - ultimo_envio >= 10 or a.una_vez):
                ultimo_envio = ahora
                tableros, eventos = estado_vivo(cx_rel)
                cuerpo = {"generado": dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "tableros": tableros,
                          "eventos": eventos, "importacion": resumen_import}
                try:
                    enviar(cfg["URL_TABLERO"], cfg["CLAVE_INGESTA"], cuerpo)
                except urllib.error.HTTPError as e:
                    print(f"El tablero respondió {e.code}: revise CLAVE_INGESTA.")
                except (urllib.error.URLError, TimeoutError) as e:
                    print(f"No se pudo enviar al tablero (¿sin internet o el servicio está despertando?): {e}")
        except pyodbc.Error as e:
            print("Error de SQL Server:", str(e)[:300])
            for cx in (cx_rel, cx_dw):
                try:
                    cx and cx.close()
                except Exception:
                    pass
            cx_rel = cx_dw = None
            time.sleep(10)
        if a.una_vez:
            return 0
        time.sleep(2)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nPuente detenido.")
