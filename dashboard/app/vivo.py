"""Estado en vivo de la maqueta física.

* En la nube, el puente de la maqueta (maqueta/puente_nube.py) publica cada
  10 s el estado de los dos tableros con POST /api/maqueta/estado y la cabecera
  X-API-Key. El último estado se guarda en memoria (no se persiste nada).
* En modo SQL Server (tablero local) se consulta directamente
  NeoGridRelacional.dbo.sp_maqueta_estado_vivo.
"""
from __future__ import annotations

import datetime as dt
import threading
import time

from .db import bd

_candado = threading.Lock()
_estado: dict = {}
_recibido: float | None = None

TABLEROS = ("OESTE", "ESTE")
ESTADOS = ("DIA", "NOCHE", "PERSONA")
_CAMPOS_NUM = ("lectura_ldr", "oscuridad", "nivel_luz_lux", "brillo_pct", "segundos_desde_lectura",
               "luces_casas_encendidas", "luces_casas_apagadas")
_CAMPOS_BIN = ("es_noche", "pir", "ahorro", "ldr_falla")


def _texto(valor, largo=40):
    return None if valor is None else str(valor)[:largo]


def _numero(valor):
    try:
        n = float(valor)
    except (TypeError, ValueError):
        return None
    return n if -1e9 < n < 1e9 else None


def validar(cuerpo: dict) -> dict:
    """Valida y normaliza lo que envía el puente; ignora cualquier campo desconocido."""
    if not isinstance(cuerpo, dict):
        raise ValueError("El cuerpo debe ser un objeto JSON.")
    tableros = []
    for t in (cuerpo.get("tableros") or [])[:2]:
        if not isinstance(t, dict) or str(t.get("tablero", "")).upper() not in TABLEROS:
            continue
        item = {"tablero": str(t["tablero"]).upper(), "fecha_hora": _texto(t.get("fecha_hora"), 19),
                "estado": str(t.get("estado")).upper() if str(t.get("estado", "")).upper() in ESTADOS else None,
                "conexion": _texto(t.get("conexion"), 20), "fecha_conexion": _texto(t.get("fecha_conexion"), 19)}
        for c in _CAMPOS_NUM:
            item[c] = _numero(t.get(c))
        for c in _CAMPOS_BIN:
            item[c] = 1 if t.get(c) in (1, True, "1", "true") else 0
        tableros.append(item)
    eventos = []
    for e in (cuerpo.get("eventos") or [])[:30]:
        if isinstance(e, dict):
            eventos.append({"fecha_hora": _texto(e.get("fecha_hora"), 19), "tablero": _texto(e.get("tablero"), 8),
                            "tipo": _texto(e.get("tipo"), 30), "antes": _texto(e.get("antes"), 10),
                            "ahora": _texto(e.get("ahora"), 10), "brillo_pct": _numero(e.get("brillo_pct"))})
    imp = cuerpo.get("importacion") if isinstance(cuerpo.get("importacion"), dict) else {}
    importacion = {k: _numero(imp.get(k)) for k in ("mediciones_insertadas", "eventos", "registros_casas",
                                                     "fallas_abiertas", "fallas_resueltas")}
    importacion["ultimo_intervalo"] = _texto(imp.get("ultimo_intervalo"), 19)
    importacion["etl"] = _texto(imp.get("etl"), 200)
    return {"generado": _texto(cuerpo.get("generado"), 19), "tableros": tableros, "eventos": eventos,
            "importacion": importacion}


def guardar(datos: dict) -> None:
    global _estado, _recibido
    with _candado:
        _estado = datos
        _recibido = time.time()


def obtener() -> dict:
    if bd.dialecto == "mssql":
        try:
            filas = bd.consultar("rel", "EXEC dbo.sp_maqueta_estado_vivo")
            eventos = bd.consultar("rel", """SELECT TOP (20) fecha_hora, UPPER(tablero) AS tablero, tipo, antes, ahora, brillo_pct
                                             FROM maq.evento_poste ORDER BY id DESC""")
            return {"fuente": "SQL Server (directo)", "edad_segundos": 0, "tableros": filas, "eventos": eventos,
                    "actualizado": dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
        except Exception as error:  # la maqueta es opcional: el tablero sigue funcionando sin ella
            return {"fuente": "sin datos", "error": str(error)[:200], "tableros": [], "eventos": []}
    with _candado:
        if not _estado:
            return {"fuente": "sin datos", "tableros": [], "eventos": [],
                    "mensaje": "El puente de la maqueta no ha enviado datos a este servidor."}
        edad = round(time.time() - (_recibido or 0))
        return {"fuente": "puente de la maqueta", "edad_segundos": edad, **_estado,
                "actualizado": dt.datetime.fromtimestamp(_recibido).strftime("%Y-%m-%d %H:%M:%S")}
