"""Servidor web del tablero NeoGrid (Flask). API REST + archivos estáticos."""
from __future__ import annotations

import hmac
import json
import logging
import os
import subprocess
import sys
import threading
import time
from collections import defaultdict, deque

from flask import Flask, Response, jsonify, request, send_from_directory

from . import config, consultas, explorador, modelos, vivo
from .db import ConsultaCostosa, DatosNoDisponibles, bd

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("neogrid")

STATIC = config.BASE / "static"
app = Flask(__name__, static_folder=None)
app.config["MAX_CONTENT_LENGTH"] = 64 * 1024
app.json.ensure_ascii = False
app.json.sort_keys = False


# ------------------------------------------------------------------ protección básica
_peticiones: dict[str, deque] = defaultdict(deque)
_candado = threading.Lock()


def _ip() -> str:
    reenviada = request.headers.get("X-Forwarded-For", "")
    return (reenviada.split(",")[0].strip() if reenviada else request.remote_addr) or "?"


@app.before_request
def limitar():
    if not request.path.startswith("/api/") or request.path == "/api/maqueta/estado" and request.method == "POST":
        return None
    ahora = time.monotonic()
    with _candado:
        cola = _peticiones[_ip()]
        while cola and ahora - cola[0] > 60:
            cola.popleft()
        if len(cola) >= config.LIMITE_PETICIONES_MIN:
            return jsonify(error="Demasiadas solicitudes. Espere un minuto."), 429
        cola.append(ahora)
        if len(_peticiones) > 5000:
            _peticiones.clear()
    return None


@app.after_request
def cabeceras(resp: Response):
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["Referrer-Policy"] = "same-origin"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Content-Security-Policy"] = (
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
        "font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
    if request.path.startswith("/api/"):
        resp.headers["Cache-Control"] = "no-store" if request.path.startswith(("/api/maqueta", "/api/etl")) else "private, max-age=60"
    return resp


@app.errorhandler(DatosNoDisponibles)
def _sin_datos(error):
    return jsonify(error=str(error)), 503


@app.errorhandler(ConsultaCostosa)
def _costosa(_):
    return jsonify(error="La consulta tardó demasiado en este servidor. Reduzca el rango de fechas o agregue un filtro."), 503


@app.errorhandler(explorador.ErrorExplorador)
def _explorador(error):
    return jsonify(error=str(error)), 400


@app.errorhandler(404)
def _no_encontrado(_):
    if request.path.startswith("/api/"):
        return jsonify(error="Ruta no encontrada."), 404
    return send_from_directory(STATIC, "index.html")


@app.errorhandler(Exception)
def _inesperado(error):
    if hasattr(error, "code") and isinstance(getattr(error, "code"), int) and error.code < 500:
        return jsonify(error=str(error)), error.code
    log.exception("Error no controlado")
    return jsonify(error="Error interno al consultar los datos."), 500


# ------------------------------------------------------------------ estáticos
@app.get("/")
def inicio():
    return send_from_directory(STATIC, "index.html", max_age=0)


@app.get("/static/<path:ruta>")
def estaticos(ruta):
    return send_from_directory(STATIC, ruta, max_age=3600)


# ------------------------------------------------------------------ información y salud
@app.get("/api/salud")
def salud():
    return jsonify(estado="ok", datos=bd.disponible(), modo=config.MODO_BD, version=config.VERSION)


@app.get("/api/meta/info")
def meta_info():
    return jsonify(modo=config.MODO_BD, version=config.VERSION, motor=bd.info_motor(),
                   catalogos=consultas.catalogos(), ingesta_habilitada=bool(config.CLAVE_INGESTA))


# ------------------------------------------------------------------ vista general
@app.get("/api/resumen")
def api_resumen():
    return jsonify(consultas.resumen(consultas.Filtros(request.args)))


@app.get("/api/red/noche")
def api_red_noche():
    return jsonify(consultas.red_noche(request.args.get("fecha")))


# ------------------------------------------------------------------ luminarias y sensores
@app.get("/api/luminarias")
def api_luminarias():
    return jsonify(consultas.luminarias(consultas.Filtros(request.args)))


@app.get("/api/luminaria/<int:luminaria_id>")
def api_luminaria(luminaria_id: int):
    datos = consultas.luminaria_detalle(luminaria_id, consultas.Filtros(request.args))
    if not datos:
        return jsonify(error="La luminaria no existe."), 404
    return jsonify(datos)


@app.get("/api/sensores")
def api_sensores():
    return jsonify(consultas.sensores())


@app.get("/api/operacion/perfil-horario")
def api_perfil():
    return jsonify(consultas.perfil_horario(consultas.Filtros(request.args)))


@app.get("/api/operacion/estados")
def api_estados():
    return jsonify(consultas.estados(consultas.Filtros(request.args)))


@app.get("/api/operacion/mapa-calor")
def api_calor():
    return jsonify(consultas.mapa_calor(consultas.Filtros(request.args)))


# ------------------------------------------------------------------ consumo y fallas
@app.get("/api/consumo")
def api_consumo():
    return jsonify(consultas.consumo(consultas.Filtros(request.args), request.args.get("agrupar", "")))


@app.get("/api/fallas")
def api_fallas():
    return jsonify(consultas.fallas(consultas.Filtros(request.args)))


# ------------------------------------------------------------------ modelos
@app.get("/api/relacional/resumen")
def api_rel_resumen():
    return jsonify(modelos.relacional_resumen())


@app.get("/api/relacional/mediciones")
def api_rel_mediciones():
    return jsonify(modelos.relacional_mediciones(request.args))


@app.get("/api/relacional/eventos")
def api_rel_eventos():
    return jsonify(modelos.relacional_eventos(request.args))


@app.get("/api/relacional/viviendas")
def api_rel_viviendas():
    return jsonify(modelos.relacional_viviendas())


@app.get("/api/dw/resumen")
def api_dw_resumen():
    return jsonify(modelos.dw_resumen())


@app.get("/api/dw/cubo")
def api_dw_cubo():
    return jsonify(modelos.cubo(request.args))


@app.get("/api/etl")
def api_etl():
    return jsonify(modelos.etl(request.args))


@app.get("/api/comparacion")
def api_comparacion():
    return jsonify(modelos.comparacion_modelos())


@app.get("/api/comparacion/consulta")
def api_comparacion_consulta():
    return jsonify(modelos.comparacion_consulta(request.args))


# ------------------------------------------------------------------ explorador
@app.get("/api/explorar/<modelo>/tablas")
def api_exp_tablas(modelo):
    return jsonify(explorador.tablas(modelo))


@app.get("/api/explorar/<modelo>/tabla/<nombre>")
def api_exp_tabla(modelo, nombre):
    return jsonify(explorador.tabla(modelo, nombre))


@app.get("/api/explorar/<modelo>/tabla/<nombre>/datos")
def api_exp_datos(modelo, nombre):
    return jsonify(explorador.datos(modelo, nombre, request.args))


@app.get("/api/explorar/<modelo>/diagrama")
def api_exp_diagrama(modelo):
    return jsonify(explorador.diagrama(modelo))


# ------------------------------------------------------------------ maqueta en vivo
@app.get("/api/maqueta/estado")
def api_maqueta_get():
    return jsonify(vivo.obtener())


@app.post("/api/maqueta/estado")
def api_maqueta_post():
    if not config.CLAVE_INGESTA:
        return jsonify(error="La ingesta en vivo no está habilitada en este servidor."), 403
    clave = request.headers.get("X-API-Key", "")
    if not hmac.compare_digest(clave.encode(), config.CLAVE_INGESTA.encode()):
        return jsonify(error="Clave de ingesta no válida."), 401
    try:
        cuerpo = json.loads(request.get_data(as_text=True) or "{}")
        datos = vivo.validar(cuerpo)
    except (ValueError, json.JSONDecodeError) as error:
        return jsonify(error=f"Datos no válidos: {error}"), 400
    vivo.guardar(datos)
    return jsonify(estado="recibido", tableros=len(datos["tableros"]), eventos=len(datos["eventos"]))


# ------------------------------------------------------------------ precalentado de la caché
def _precalentar():
    if not bd.disponible() and bd.dialecto == "sqlite" and os.environ.get("DATOS_URL"):
        # Respaldo: si la compilación no dejó los datos en el servicio, se descargan al arrancar.
        log.info("No están los archivos de datos; descargando desde DATOS_URL...")
        try:
            subprocess.run([sys.executable, str(config.BASE / "scripts" / "descargar_datos.py")], check=True, timeout=900)
        except Exception:
            log.exception("No se pudieron descargar los datos")
    if not bd.disponible():
        log.warning("No hay datos disponibles; el tablero mostrará el aviso de configuración.")
        return
    inicio = time.monotonic()
    vacio: dict = {}
    pasos = [
        lambda: consultas.catalogos(),
        lambda: consultas.resumen(consultas.Filtros(vacio)),
        lambda: consultas.red_noche(None),
        lambda: consultas.luminarias(consultas.Filtros(vacio)),
        lambda: consultas.perfil_horario(consultas.Filtros(vacio)),
        lambda: consultas.estados(consultas.Filtros(vacio)),
        lambda: consultas.mapa_calor(consultas.Filtros(vacio)),
        lambda: consultas.consumo(consultas.Filtros(vacio), ""),
        lambda: consultas.fallas(consultas.Filtros(vacio)),
        lambda: modelos.relacional_resumen(),
        lambda: modelos.dw_resumen(),
        lambda: modelos.comparacion_modelos(),
        lambda: explorador.estructura("relacional"),
        lambda: explorador.estructura("multidimensional"),
    ]
    for paso in pasos:
        try:
            paso()
        except Exception:
            log.exception("Precalentado: falló un paso")
    log.info("Caché precalentada en %.1f s", time.monotonic() - inicio)


if config.PRECALENTAR:
    threading.Thread(target=_precalentar, name="precalentar", daemon=True).start()
