"""Consultas analíticas del tablero.

Regla de diseño: las vistas analíticas leen el modelo multidimensional
(hechos agregados siempre que se pueda: fact_consumo_diario ~10 mil filas y
fact_operacion_horaria ~300 mil filas, en vez del millón del hecho detallado).
El hecho detallado solo se lee por índice (una luminaria o una noche).
Las vistas del modelo relacional leen NeoGridRelacional.
"""
from __future__ import annotations

import datetime as dt
import re

from . import cache
from .db import bd

ORIGENES = ("SIMULADO", "FISICO", "CALCULADO", "PRUEBA")
_RE_ZONA = re.compile(r"^[A-Z]{3}$")


# ---------------------------------------------------------------- utilidades
def tk_a_fecha(tk) -> str:
    s = str(int(tk))
    return f"{s[:4]}-{s[4:6]}-{s[6:]}"


def fecha_a_tk(fecha: dt.date) -> int:
    return fecha.year * 10000 + fecha.month * 100 + fecha.day


def tk_a_date(tk) -> dt.date:
    s = str(int(tk))
    return dt.date(int(s[:4]), int(s[4:6]), int(s[6:]))


def hk_a_hora(hk) -> str:
    hk = int(hk)
    return f"{hk // 100:02d}:{hk % 100:02d}"


def _entero(valor, minimo=None, maximo=None):
    try:
        n = int(str(valor).strip())
    except (TypeError, ValueError):
        return None
    if minimo is not None and n < minimo:
        return None
    if maximo is not None and n > maximo:
        return None
    return n


def _fecha(valor):
    if not valor:
        return None
    try:
        return dt.datetime.strptime(str(valor).strip()[:10], "%Y-%m-%d").date()
    except ValueError:
        return None


def _num(valor, decimales=2):
    if valor is None:
        return None
    return round(float(valor), decimales)


def _pct(parte, total, decimales=1):
    if not total:
        return None
    return round(100.0 * float(parte or 0) / float(total), decimales)


def extension() -> dict:
    """Rango de fechas con datos en el DW (y el de la simulación)."""
    def calcular():
        a = bd.uno("dw", "SELECT MIN(tiempo_key) AS tmin, MAX(tiempo_key) AS tmax FROM fact_consumo_diario WHERE tiempo_key > 0")
        s = bd.uno("dw", """SELECT MIN(c.tiempo_key) AS tmin, MAX(c.tiempo_key) AS tmax
                            FROM fact_consumo_diario c JOIN dim_origen o ON o.origen_key = c.origen_key
                            WHERE o.codigo = 'SIMULADO'""")
        f = bd.uno("dw", """SELECT MIN(c.tiempo_key) AS tmin, MAX(c.tiempo_key) AS tmax
                            FROM fact_consumo_diario c JOIN dim_origen o ON o.origen_key = c.origen_key
                            WHERE o.codigo = 'FISICO'""")
        tmin = a.get("tmin") or 20260501
        tmax = a.get("tmax") or 20261010
        return {
            "tk_min": int(tmin), "tk_max": int(tmax),
            "desde": tk_a_fecha(tmin), "hasta": tk_a_fecha(tmax),
            "simulado_desde": tk_a_fecha(s["tmin"]) if s.get("tmin") else None,
            "simulado_hasta": tk_a_fecha(s["tmax"]) if s.get("tmax") else None,
            "fisico_desde": tk_a_fecha(f["tmin"]) if f.get("tmin") else None,
            "fisico_hasta": tk_a_fecha(f["tmax"]) if f.get("tmax") else None,
        }
    return cache.obtener(("extension",), calcular)


class Filtros:
    """Filtros globales del tablero: fecha, zona/ubicación, luminaria y origen."""

    def __init__(self, args):
        ext = extension()
        d, h = _fecha(args.get("desde")), _fecha(args.get("hasta"))
        self.tk_desde = fecha_a_tk(d) if d else ext["tk_min"]
        self.tk_hasta = fecha_a_tk(h) if h else ext["tk_max"]
        if self.tk_desde > self.tk_hasta:
            self.tk_desde, self.tk_hasta = self.tk_hasta, self.tk_desde
        zona = (args.get("zona") or "").strip().upper()
        self.zona = zona if _RE_ZONA.match(zona) else None
        self.ubicacion = _entero(args.get("ubicacion"), 1, 32767)
        self.luminaria = _entero(args.get("luminaria"), 1, 32767)
        origen = (args.get("origen") or "").strip().upper()
        self.origen = origen if origen in ORIGENES else None

    @property
    def desde(self):
        return tk_a_fecha(self.tk_desde)

    @property
    def hasta(self):
        return tk_a_fecha(self.tk_hasta)

    @property
    def dias(self) -> int:
        return (tk_a_date(self.tk_hasta) - tk_a_date(self.tk_desde)).days + 1

    def clave(self):
        return (self.tk_desde, self.tk_hasta, self.zona, self.ubicacion, self.luminaria, self.origen)

    def donde(self, campo_tiempo: str, u: str | None = "u", l: str | None = None, o: str | None = None):
        partes, params = [f"{campo_tiempo} BETWEEN ? AND ?"], [self.tk_desde, self.tk_hasta]
        if u and self.ubicacion:
            partes.append(f"{u}.ubicacion_id = ?")
            params.append(self.ubicacion)
        elif u and self.zona:
            partes.append(f"{u}.zona_codigo = ?")
            params.append(self.zona)
        if l and self.luminaria:
            partes.append(f"{l}.luminaria_id = ?")
            params.append(self.luminaria)
        if o and self.origen:
            partes.append(f"{o}.codigo = ?")
            params.append(self.origen)
        return " AND ".join(partes), params

    def eco(self) -> dict:
        return {"desde": self.desde, "hasta": self.hasta, "zona": self.zona, "ubicacion": self.ubicacion,
                "luminaria": self.luminaria, "origen": self.origen, "dias": self.dias}


J_CONSUMO = """FROM fact_consumo_diario c
JOIN dim_ubicacion u ON u.ubicacion_key = c.ubicacion_key
JOIN dim_luminaria l ON l.luminaria_key = c.luminaria_key
JOIN dim_origen o ON o.origen_key = c.origen_key"""

J_HORARIA = """FROM fact_operacion_horaria h
JOIN dim_ubicacion u ON u.ubicacion_key = h.ubicacion_key
JOIN dim_origen o ON o.origen_key = h.origen_key"""


def _clave_luminaria(luminaria_id: int):
    fila = bd.uno("dw", "SELECT luminaria_key FROM dim_luminaria WHERE luminaria_id = ?", (luminaria_id,))
    return fila.get("luminaria_key")


# ---------------------------------------------------------------- catálogos
def catalogos() -> dict:
    def calcular():
        zonas = bd.consultar("rel", """SELECT z.zona_id, z.codigo, z.nombre, z.tipo_zona, z.es_fisica
                                       FROM zona z ORDER BY z.zona_id""")
        ubicaciones = bd.consultar("rel", """SELECT u.ubicacion_id, u.codigo, u.nombre, u.tipo_via, u.longitud_m, z.codigo AS zona
                                             FROM ubicacion u JOIN zona z ON z.zona_id = u.zona_id ORDER BY u.ubicacion_id""")
        luminarias = red_luminarias()
        return {"zonas": zonas, "ubicaciones": ubicaciones,
                "luminarias": [{"luminaria_id": x["luminaria_id"], "codigo": x["codigo"], "zona": x["zona"],
                                "ubicacion_id": x["ubicacion_id"], "es_fisica": x["es_fisica"]} for x in luminarias],
                "extension": extension()}
    return cache.obtener(("catalogos",), calcular)


def red_luminarias() -> list[dict]:
    def calcular():
        return bd.consultar("rel", """
            SELECT l.luminaria_id, l.codigo, l.es_fisica, l.tablero, l.posicion_cm, l.fecha_instalacion,
                   u.ubicacion_id, u.codigo AS ubicacion, u.nombre AS ubicacion_nombre, u.tipo_via, u.longitud_m,
                   z.codigo AS zona, z.nombre AS zona_nombre, z.tipo_zona,
                   mo.codigo AS modelo, mo.descripcion AS modelo_descripcion, mo.potencia_nominal_w
            FROM luminaria l
            JOIN ubicacion u ON u.ubicacion_id = l.ubicacion_id
            JOIN zona z ON z.zona_id = u.zona_id
            JOIN modelo_luminaria mo ON mo.modelo_id = l.modelo_id
            ORDER BY l.luminaria_id""")
    return cache.obtener(("red_luminarias",), calcular)


def ultimo_estado_luminarias() -> dict:
    """Última medición registrada de cada luminaria (modelo relacional)."""
    def calcular():
        filas = bd.consultar("rel", """
            SELECT m.luminaria_id, m.fecha_hora, m.estado_id, e.codigo AS estado, m.brillo_pct, m.origen_id
            FROM (SELECT l.luminaria_id,
                         (SELECT MAX(m2.fecha_hora) FROM medicion m2 WHERE m2.luminaria_id = l.luminaria_id) AS ultima
                  FROM luminaria l) x
            JOIN medicion m ON m.luminaria_id = x.luminaria_id AND m.fecha_hora = x.ultima
            JOIN estado_operativo e ON e.estado_id = m.estado_id""")
        return {f["luminaria_id"]: f for f in filas}
    return cache.obtener(("ultimo_estado",), calcular, None)


# ---------------------------------------------------------------- vista general
def resumen(f: Filtros) -> dict:
    def calcular():
        w, p = f.donde("c.tiempo_key", "u", "l", "o")
        tot = bd.uno("dw", f"""
            SELECT SUM(c.energia_kwh) AS energia_kwh, SUM(c.energia_referencia_kwh) AS referencia_kwh,
                   SUM(c.ahorro_kwh) AS ahorro_kwh, SUM(c.horas_encendida) AS horas_encendida,
                   SUM(c.intervalos) AS intervalos, SUM(c.intervalos_falla) AS intervalos_falla,
                   SUM(c.intervalos_anomalos) AS intervalos_anomalos, SUM(c.intervalos_imputados) AS intervalos_imputados,
                   SUM(c.detecciones) AS detecciones, COUNT(DISTINCT c.luminaria_key) AS luminarias
            {J_CONSUMO} WHERE {w}""", p)
        serie = bd.consultar("dw", f"""
            SELECT c.tiempo_key, SUM(c.energia_kwh) AS energia_kwh, SUM(c.energia_referencia_kwh) AS referencia_kwh
            {J_CONSUMO} WHERE {w}
            GROUP BY c.tiempo_key ORDER BY c.tiempo_key""", p)
        por_origen = bd.consultar("dw", f"""
            SELECT o.codigo, o.nombre, SUM(c.intervalos) AS intervalos, SUM(c.energia_kwh) AS energia_kwh
            {J_CONSUMO} WHERE {w}
            GROUP BY o.codigo, o.nombre ORDER BY o.codigo""", p)
        wf, pf = f.donde("fa.tiempo_deteccion_key", "u", "l", "o")
        fallas = bd.uno("dw", f"""
            SELECT COUNT(*) AS total, SUM(fa.esta_abierta) AS abiertas,
                   AVG(CASE WHEN fa.esta_abierta = 0 THEN fa.horas_duracion END) AS mttr_h,
                   AVG(fa.horas_hasta_deteccion) AS mttd_h
            FROM fact_falla fa
            JOIN dim_ubicacion u ON u.ubicacion_key = fa.ubicacion_key
            JOIN dim_luminaria l ON l.luminaria_key = fa.luminaria_key
            JOIN dim_origen o ON o.origen_key = fa.origen_key
            WHERE {wf}""", pf)
        abiertas = bd.uno("dw", "SELECT COUNT(*) AS n FROM fact_falla WHERE esta_abierta = 1")
        pendientes = bd.uno("dw", "SELECT COUNT(*) AS n FROM fact_mantenimiento WHERE es_pendiente = 1")
        intervalos = tot.get("intervalos") or 0
        referencia = tot.get("referencia_kwh") or 0
        return {
            "filtros": f.eco(),
            "kpi": {
                "energia_kwh": _num(tot.get("energia_kwh")),
                "referencia_kwh": _num(tot.get("referencia_kwh")),
                "ahorro_kwh": _num(tot.get("ahorro_kwh")),
                "ahorro_pct": _pct(tot.get("ahorro_kwh"), referencia),
                "disponibilidad_pct": round(100 - (_pct(tot.get("intervalos_falla"), intervalos, 3) or 0), 2) if intervalos else None,
                "horas_encendida": _num(tot.get("horas_encendida"), 1),
                "intervalos": intervalos,
                "imputados_pct": _pct(tot.get("intervalos_imputados"), intervalos, 2),
                "anomalos_pct": _pct(tot.get("intervalos_anomalos"), intervalos, 2),
                "detecciones": tot.get("detecciones"),
                "luminarias": tot.get("luminarias"),
                "fallas_periodo": fallas.get("total"),
                "fallas_abiertas_periodo": fallas.get("abiertas"),
                "fallas_abiertas": abiertas.get("n"),
                "mantenimientos_pendientes": pendientes.get("n"),
                "mttr_h": _num(fallas.get("mttr_h"), 1),
                "mttd_h": _num(fallas.get("mttd_h"), 2),
            },
            "serie": [{"fecha": tk_a_fecha(x["tiempo_key"]), "energia_kwh": _num(x["energia_kwh"], 3),
                       "referencia_kwh": _num(x["referencia_kwh"], 3)} for x in serie],
            "por_origen": [{**x, "energia_kwh": _num(x["energia_kwh"], 2)} for x in por_origen],
            "volumen": volumen(),
            "ultima_etl": ultima_etl(),
        }
    return cache.obtener(("resumen",) + f.clave(), calcular)


def volumen() -> dict:
    def calcular():
        rel = bd.consultar("rel", f"SELECT tabla, filas FROM {bd.meta('meta_tablas')}")
        dw = bd.consultar("dw", f"SELECT tabla, filas FROM {bd.meta('meta_tablas')}")
        porigen = bd.consultar("rel", """
            SELECT o.codigo, x.n FROM (SELECT origen_id, COUNT(*) AS n FROM medicion GROUP BY origen_id) x
            JOIN origen_dato o ON o.origen_id = x.origen_id ORDER BY o.codigo""")
        m_rel = {r["tabla"]: r["filas"] for r in rel}
        m_dw = {r["tabla"]: r["filas"] for r in dw}
        return {
            "relacional_tablas": len(rel), "relacional_filas": sum(int(r["filas"] or 0) for r in rel),
            "dw_tablas": len(dw), "dw_filas": sum(int(r["filas"] or 0) for r in dw),
            "medicion": m_rel.get("medicion"), "fact_operacion_luminaria": m_dw.get("fact_operacion_luminaria"),
            "mediciones_por_origen": {r["codigo"]: r["n"] for r in porigen},
        }
    return cache.obtener(("volumen",), calcular)


def ultima_etl() -> dict:
    sql, p = bd.paginar("""SELECT ejecucion_id, herramienta, paquete, estado, inicio, fin, filas_leidas, filas_insertadas,
                                  filas_rechazadas, filas_omitidas, filas_imputadas, mensaje
                           FROM etl_ejecucion ORDER BY ejecucion_id DESC""", 1)
    filas = bd.consultar("dw", sql, p)
    return filas[0] if filas else {}


def red_noche(fecha_txt: str | None) -> dict:
    """Estado de las 64 luminarias en cada intervalo de una noche (17:00 a 07:00)."""
    ext = extension()
    defecto = ext["simulado_hasta"] or ext["hasta"]
    d = _fecha(fecha_txt) or (tk_a_date(int(defecto.replace("-", ""))) - dt.timedelta(days=1))
    tk1, tk2 = fecha_a_tk(d), fecha_a_tk(d + dt.timedelta(days=1))

    def calcular():
        filas = bd.consultar("dw", """
            SELECT f.tiempo_key, f.hora_key, l.luminaria_id, f.brillo_pct, e.codigo AS estado, f.detecciones,
                   f.nivel_luz_lux, f.potencia_w, o.codigo AS origen
            FROM fact_operacion_luminaria f
            JOIN dim_luminaria l ON l.luminaria_key = f.luminaria_key
            JOIN dim_estado_operativo e ON e.estado_key = f.estado_key
            JOIN dim_origen o ON o.origen_key = f.origen_key
            WHERE (f.tiempo_key = ? AND f.hora_key >= 1700) OR (f.tiempo_key = ? AND f.hora_key <= 700)
            ORDER BY f.tiempo_key, f.hora_key, l.luminaria_id""", (tk1, tk2))
        intervalos: dict[tuple, dict] = {}
        for x in filas:
            k = (x["tiempo_key"], x["hora_key"])
            slot = intervalos.setdefault(k, {"fecha": tk_a_fecha(k[0]), "hora": hk_a_hora(k[1]), "luminarias": {}})
            slot["luminarias"][x["luminaria_id"]] = [_num(x["brillo_pct"], 1), x["estado"], x["detecciones"],
                                                      _num(x["nivel_luz_lux"], 1), _num(x["potencia_w"], 1), x["origen"]]
        return {"fecha": d.strftime("%Y-%m-%d"), "intervalos": [intervalos[k] for k in sorted(intervalos)],
                "campos": ["brillo_pct", "estado", "detecciones", "nivel_luz_lux", "potencia_w", "origen"]}

    datos = cache.obtener(("noche", tk1), calcular)
    return {**datos, "luminarias": red_luminarias(), "extension": ext}


# ---------------------------------------------------------------- luminarias y sensores
def luminarias(f: Filtros) -> dict:
    def calcular():
        w, p = f.donde("c.tiempo_key", "u", None, "o")
        stats = bd.consultar("dw", f"""
            SELECT l.luminaria_id, SUM(c.energia_kwh) AS energia_kwh, SUM(c.ahorro_kwh) AS ahorro_kwh,
                   SUM(c.energia_referencia_kwh) AS referencia_kwh, SUM(c.horas_encendida) AS horas_encendida,
                   SUM(c.intervalos) AS intervalos, SUM(c.intervalos_falla) AS intervalos_falla,
                   SUM(c.detecciones) AS detecciones, AVG(c.brillo_promedio_noche * 1.0) AS brillo_noche
            {J_CONSUMO} WHERE {w}
            GROUP BY l.luminaria_id""", p)
        wf, pf = f.donde("fa.tiempo_deteccion_key", "u", None, "o")
        fallas = bd.consultar("dw", f"""
            SELECT l.luminaria_id, COUNT(*) AS fallas, SUM(fa.esta_abierta) AS abiertas
            FROM fact_falla fa
            JOIN dim_luminaria l ON l.luminaria_key = fa.luminaria_key
            JOIN dim_ubicacion u ON u.ubicacion_key = fa.ubicacion_key
            JOIN dim_origen o ON o.origen_key = fa.origen_key
            WHERE {wf} GROUP BY l.luminaria_id""", pf)
        s = {x["luminaria_id"]: x for x in stats}
        fa = {x["luminaria_id"]: x for x in fallas}
        ultimo = ultimo_estado_luminarias()
        lista = []
        for lum in red_luminarias():
            if f.ubicacion and lum["ubicacion_id"] != f.ubicacion:
                continue
            if f.zona and not f.ubicacion and lum["zona"] != f.zona:
                continue
            st = s.get(lum["luminaria_id"], {})
            u = ultimo.get(lum["luminaria_id"], {})
            intervalos = st.get("intervalos") or 0
            lista.append({
                **lum,
                "energia_kwh": _num(st.get("energia_kwh"), 2),
                "ahorro_pct": _pct(st.get("ahorro_kwh"), st.get("referencia_kwh")),
                "horas_encendida": _num(st.get("horas_encendida"), 1),
                "disponibilidad_pct": round(100 - (_pct(st.get("intervalos_falla"), intervalos, 3) or 0), 2) if intervalos else None,
                "detecciones": st.get("detecciones"),
                "brillo_noche": _num(st.get("brillo_noche"), 1),
                "fallas": (fa.get(lum["luminaria_id"]) or {}).get("fallas", 0),
                "fallas_abiertas": (fa.get(lum["luminaria_id"]) or {}).get("abiertas", 0),
                "ultimo_estado": u.get("estado"), "ultimo_brillo": _num(u.get("brillo_pct"), 1),
                "ultima_medicion": u.get("fecha_hora"),
                "ultimo_origen": {1: "SIMULADO", 2: "FISICO", 3: "CALCULADO", 4: "PRUEBA"}.get(u.get("origen_id")),
            })
        return {"filtros": f.eco(), "luminarias": lista}
    return cache.obtener(("luminarias",) + f.clave(), calcular)


def luminaria_detalle(luminaria_id: int, f: Filtros) -> dict:
    info = next((x for x in red_luminarias() if x["luminaria_id"] == luminaria_id), None)
    if info is None:
        return {}

    def calcular():
        clave = _clave_luminaria(luminaria_id)
        # La serie de 15 minutos se limita a 7 días; para rangos mayores se usa el hecho diario
        if f.dias <= 7:
            modo = "15min"
            filas = bd.consultar("dw", """
                SELECT f.tiempo_key, f.hora_key, f.brillo_pct, f.nivel_luz_lux, f.detecciones, f.potencia_w,
                       f.energia_wh, f.temperatura_c, e.codigo AS estado, dc.codigo AS calidad, o.codigo AS origen
                FROM fact_operacion_luminaria f
                JOIN dim_estado_operativo e ON e.estado_key = f.estado_key
                JOIN dim_calidad_dato dc ON dc.calidad_key = f.calidad_key
                JOIN dim_origen o ON o.origen_key = f.origen_key
                WHERE f.luminaria_key = ? AND f.tiempo_key BETWEEN ? AND ?
                ORDER BY f.tiempo_key, f.hora_key""", (clave, f.tk_desde, f.tk_hasta))
            serie = [{"t": f"{tk_a_fecha(x['tiempo_key'])} {hk_a_hora(x['hora_key'])}", "brillo_pct": _num(x["brillo_pct"], 1),
                      "lux": _num(x["nivel_luz_lux"], 1), "detecciones": x["detecciones"], "potencia_w": _num(x["potencia_w"], 1),
                      "energia_wh": _num(x["energia_wh"], 2), "temperatura_c": _num(x["temperatura_c"], 1),
                      "estado": x["estado"], "calidad": x["calidad"], "origen": x["origen"]} for x in filas]
        else:
            modo = "diario"
            filas = bd.consultar("dw", """
                SELECT c.tiempo_key, c.energia_kwh, c.energia_referencia_kwh, c.horas_encendida, c.brillo_promedio_noche,
                       c.detecciones, c.intervalos, c.intervalos_falla, o.codigo AS origen
                FROM fact_consumo_diario c JOIN dim_origen o ON o.origen_key = c.origen_key
                WHERE c.luminaria_key = ? AND c.tiempo_key BETWEEN ? AND ?
                ORDER BY c.tiempo_key""", (clave, f.tk_desde, f.tk_hasta))
            serie = [{"t": tk_a_fecha(x["tiempo_key"]), "energia_kwh": _num(x["energia_kwh"], 3),
                      "referencia_kwh": _num(x["energia_referencia_kwh"], 3), "horas_encendida": _num(x["horas_encendida"], 2),
                      "brillo_noche": _num(x["brillo_promedio_noche"], 1), "detecciones": x["detecciones"],
                      "intervalos_falla": x["intervalos_falla"], "origen": x["origen"]} for x in filas]
        fallas = bd.consultar("dw", """
            SELECT fa.falla_id, t.codigo AS tipo, t.nombre AS tipo_nombre, t.severidad, fa.tiempo_deteccion_key,
                   fa.hora_deteccion_key, fa.tiempo_resolucion_key, fa.esta_abierta, fa.horas_hasta_deteccion,
                   fa.horas_duracion, fa.tiene_mantenimiento, fa.costo_correctivo_cop, o.codigo AS origen
            FROM fact_falla fa
            JOIN dim_tipo_falla t ON t.tipo_falla_key = fa.tipo_falla_key
            JOIN dim_origen o ON o.origen_key = fa.origen_key
            WHERE fa.luminaria_key = ?
            ORDER BY fa.tiempo_deteccion_key DESC, fa.hora_deteccion_key DESC""", (clave,))
        mants = bd.consultar("dw", """
            SELECT m.mantenimiento_id, t.nombre AS tipo, m.es_correctivo, m.estado, m.tiempo_programado_key,
                   m.tiempo_ejecucion_key, m.duracion_min, m.costo_cop, m.dias_retraso, te.nombre AS tecnico, m.falla_id
            FROM fact_mantenimiento m
            JOIN dim_tipo_mantenimiento t ON t.tipo_mantenimiento_key = m.tipo_mantenimiento_key
            JOIN dim_tecnico te ON te.tecnico_key = m.tecnico_key
            WHERE m.luminaria_key = ?
            ORDER BY m.tiempo_programado_key DESC""", (clave,))
        for x in fallas:
            x["detectada"] = f"{tk_a_fecha(x.pop('tiempo_deteccion_key'))} {hk_a_hora(x.pop('hora_deteccion_key'))}"
            tr = x.pop("tiempo_resolucion_key")
            x["resuelta"] = tk_a_fecha(tr) if tr else None
        for x in mants:
            x["programada"] = tk_a_fecha(x.pop("tiempo_programado_key"))
            te = x.pop("tiempo_ejecucion_key")
            x["ejecutada"] = tk_a_fecha(te) if te else None
        return {"modo": modo, "serie": serie, "fallas": fallas, "mantenimientos": mants}

    datos = cache.obtener(("luminaria", luminaria_id) + f.clave(), calcular)
    return {"filtros": f.eco(), "luminaria": info, **datos}


def sensores() -> dict:
    def calcular():
        filas = bd.consultar("rel", """
            SELECT s.sensor_id, s.codigo, t.codigo AS tipo, t.nombre AS tipo_nombre, t.magnitud, t.unidad,
                   s.es_fisico, s.pin_gpio, s.modelo, s.activo, s.fecha_instalacion,
                   u.codigo AS ubicacion, u.nombre AS ubicacion_nombre, z.codigo AS zona, v.codigo AS vivienda,
                   (SELECT COUNT(*) FROM falla fa WHERE fa.sensor_id = s.sensor_id) AS fallas
            FROM sensor s
            JOIN tipo_sensor t ON t.tipo_sensor_id = s.tipo_sensor_id
            JOIN ubicacion u ON u.ubicacion_id = s.ubicacion_id
            JOIN zona z ON z.zona_id = u.zona_id
            LEFT JOIN vivienda v ON v.vivienda_id = s.vivienda_id
            ORDER BY s.sensor_id""")
        return {"sensores": filas}
    return cache.obtener(("sensores",), calcular)


def perfil_horario(f: Filtros) -> dict:
    def calcular():
        if f.luminaria:
            clave = _clave_luminaria(f.luminaria)
            filas = bd.consultar("dw", """
                SELECT f.hora_key, COUNT(*) AS intervalos, SUM(f.encendida) AS encendida, SUM(f.brillo_pct) AS suma_brillo,
                       SUM(f.nivel_luz_lux) AS suma_lux, SUM(f.detecciones) AS detecciones, SUM(f.energia_wh) AS energia_wh
                FROM fact_operacion_luminaria f
                WHERE f.luminaria_key = ? AND f.tiempo_key BETWEEN ? AND ?
                GROUP BY f.hora_key ORDER BY f.hora_key""", (clave, f.tk_desde, f.tk_hasta))
            por_tipo = []
        else:
            w, p = f.donde("h.tiempo_key", "u", None, "o")
            filas = bd.consultar("dw", f"""
                SELECT h.hora_key, SUM(h.intervalos) AS intervalos, SUM(h.intervalos_encendida) AS encendida,
                       SUM(h.suma_brillo) AS suma_brillo, SUM(h.suma_lux) AS suma_lux, SUM(h.detecciones) AS detecciones,
                       SUM(h.energia_wh) AS energia_wh
                {J_HORARIA} WHERE {w}
                GROUP BY h.hora_key ORDER BY h.hora_key""", p)
            por_tipo = bd.consultar("dw", f"""
                SELECT u.tipo_zona, h.hora_key, SUM(h.intervalos) AS intervalos, SUM(h.suma_brillo) AS suma_brillo,
                       SUM(h.detecciones) AS detecciones
                {J_HORARIA} WHERE {w}
                GROUP BY u.tipo_zona, h.hora_key ORDER BY u.tipo_zona, h.hora_key""", p)
        horas = [hk_a_hora(x["hora_key"]) for x in filas]

        def div(a, b, d=2):
            return round(float(a or 0) / float(b), d) if b else None

        series_tipo: dict[str, list] = {}
        for x in por_tipo:
            series_tipo.setdefault(x["tipo_zona"], {})[hk_a_hora(x["hora_key"])] = div(x["suma_brillo"], x["intervalos"], 1)
        return {
            "filtros": f.eco(),
            "horas": horas,
            "brillo_prom": [div(x["suma_brillo"], x["intervalos"], 1) for x in filas],
            "pct_encendida": [_pct(x["encendida"], x["intervalos"]) for x in filas],
            "lux_prom": [div(x["suma_lux"], x["intervalos"], 1) for x in filas],
            "detecciones_intervalo": [div(x["detecciones"], x["intervalos"], 2) for x in filas],
            "energia_kwh": [_num(float(x["energia_wh"] or 0) / 1000, 3) for x in filas],
            "brillo_por_tipo_zona": [{"nombre": k, "valores": [v.get(h) for h in horas]} for k, v in sorted(series_tipo.items())],
        }
    return cache.obtener(("perfil",) + f.clave(), calcular)


def estados(f: Filtros) -> dict:
    def calcular():
        if f.luminaria:
            clave = _clave_luminaria(f.luminaria)
            filas = bd.consultar("dw", """
                SELECT e.codigo, e.nombre, e.categoria, COUNT(*) AS intervalos
                FROM fact_operacion_luminaria f JOIN dim_estado_operativo e ON e.estado_key = f.estado_key
                WHERE f.luminaria_key = ? AND f.tiempo_key BETWEEN ? AND ?
                GROUP BY e.codigo, e.nombre, e.categoria""", (clave, f.tk_desde, f.tk_hasta))
        else:
            w, p = f.donde("h.tiempo_key", "u", None, "o")
            filas = bd.consultar("dw", f"""
                SELECT e.codigo, e.nombre, e.categoria, SUM(h.intervalos) AS intervalos
                {J_HORARIA} JOIN dim_estado_operativo e ON e.estado_key = h.estado_key
                WHERE {w}
                GROUP BY e.codigo, e.nombre, e.categoria""", p)
        total = sum(int(x["intervalos"] or 0) for x in filas)
        for x in filas:
            x["pct"] = _pct(x["intervalos"], total, 2)
        filas.sort(key=lambda x: -(x["intervalos"] or 0))
        return {"filtros": f.eco(), "total": total, "estados": filas}
    return cache.obtener(("estados",) + f.clave(), calcular)


def mapa_calor(f: Filtros) -> dict:
    """Detecciones de movimiento por día de la semana y hora."""
    def calcular():
        if f.luminaria:
            clave = _clave_luminaria(f.luminaria)
            filas = bd.consultar("dw", """
                SELECT t.dia_semana, f.hora_key / 100 AS hora, SUM(f.detecciones) AS detecciones, COUNT(*) AS intervalos,
                       SUM(f.brillo_pct) AS suma_brillo
                FROM fact_operacion_luminaria f JOIN dim_tiempo t ON t.tiempo_key = f.tiempo_key
                WHERE f.luminaria_key = ? AND f.tiempo_key BETWEEN ? AND ?
                GROUP BY t.dia_semana, f.hora_key / 100""", (clave, f.tk_desde, f.tk_hasta))
        else:
            w, p = f.donde("h.tiempo_key", "u", None, "o")
            filas = bd.consultar("dw", f"""
                SELECT t.dia_semana, h.hora_key / 100 AS hora, SUM(h.detecciones) AS detecciones,
                       SUM(h.intervalos) AS intervalos, SUM(h.suma_brillo) AS suma_brillo
                {J_HORARIA} JOIN dim_tiempo t ON t.tiempo_key = h.tiempo_key
                WHERE {w}
                GROUP BY t.dia_semana, h.hora_key / 100""", p)
        det = [[None] * 24 for _ in range(7)]
        bri = [[None] * 24 for _ in range(7)]
        for x in filas:
            d, h = int(x["dia_semana"]) - 1, int(x["hora"])
            if 0 <= d < 7 and 0 <= h < 24 and x["intervalos"]:
                det[d][h] = round(float(x["detecciones"] or 0) / float(x["intervalos"]), 2)
                bri[d][h] = round(float(x["suma_brillo"] or 0) / float(x["intervalos"]), 1)
        return {"filtros": f.eco(), "dias": ["Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado", "Domingo"],
                "horas": [f"{h:02d}" for h in range(24)], "detecciones": det, "brillo": bri}
    return cache.obtener(("calor",) + f.clave(), calcular)


# ---------------------------------------------------------------- consumo y eficiencia
def consumo(f: Filtros, agrupar: str) -> dict:
    agrupar = agrupar if agrupar in ("dia", "semana", "mes") else ("dia" if f.dias <= 62 else "semana")

    def calcular():
        w, p = f.donde("c.tiempo_key", "u", "l", "o")
        jt = "JOIN dim_tiempo t ON t.tiempo_key = c.tiempo_key"
        if agrupar == "dia":
            g_sel, g_by, g_ord = "c.tiempo_key AS clave, MIN(c.tiempo_key) AS inicio", "c.tiempo_key", "c.tiempo_key"
        elif agrupar == "semana":
            g_sel, g_by, g_ord = "t.anio * 100 + t.semana_anio AS clave, MIN(c.tiempo_key) AS inicio", "t.anio * 100 + t.semana_anio", "MIN(c.tiempo_key)"
        else:
            g_sel, g_by, g_ord = "t.anio_mes AS clave, MIN(c.tiempo_key) AS inicio", "t.anio_mes", "MIN(c.tiempo_key)"
        serie = bd.consultar("dw", f"""
            SELECT {g_sel}, SUM(c.energia_kwh) AS energia_kwh, SUM(c.energia_referencia_kwh) AS referencia_kwh,
                   SUM(c.ahorro_kwh) AS ahorro_kwh
            {J_CONSUMO} {jt} WHERE {w}
            GROUP BY {g_by} ORDER BY {g_ord}""", p)
        base = f"""SUM(c.energia_kwh) AS energia_kwh, SUM(c.energia_referencia_kwh) AS referencia_kwh,
                   SUM(c.ahorro_kwh) AS ahorro_kwh, SUM(c.horas_encendida) AS horas_encendida, SUM(c.intervalos) AS intervalos,
                   COUNT(DISTINCT c.luminaria_key) AS luminarias, COUNT(DISTINCT c.tiempo_key) AS dias"""
        por_zona = bd.consultar("dw", f"""
            SELECT u.zona_codigo, u.zona_nombre, u.tipo_zona, {base}, AVG(c.brillo_promedio_noche * 1.0) AS brillo_noche
            {J_CONSUMO} WHERE {w}
            GROUP BY u.zona_codigo, u.zona_nombre, u.tipo_zona ORDER BY u.zona_codigo""", p)
        por_origen = bd.consultar("dw", f"""
            SELECT o.codigo, o.nombre, {base}
            {J_CONSUMO} WHERE {w}
            GROUP BY o.codigo, o.nombre ORDER BY o.codigo""", p)
        por_modelo = bd.consultar("dw", f"""
            SELECT l.modelo_codigo, l.potencia_nominal_w, {base}
            {J_CONSUMO} WHERE {w}
            GROUP BY l.modelo_codigo, l.potencia_nominal_w ORDER BY l.potencia_nominal_w""", p)
        por_luminaria = bd.consultar("dw", f"""
            SELECT l.luminaria_id, l.codigo, u.zona_codigo, {base}
            {J_CONSUMO} WHERE {w}
            GROUP BY l.luminaria_id, l.codigo, u.zona_codigo""", p)

        def enriquecer(x):
            ref = x.get("referencia_kwh") or 0
            lums, dias = x.get("luminarias") or 0, x.get("dias") or 0
            return {**x, "energia_kwh": _num(x.get("energia_kwh"), 3), "referencia_kwh": _num(ref, 3),
                    "ahorro_kwh": _num(x.get("ahorro_kwh"), 3), "ahorro_pct": _pct(x.get("ahorro_kwh"), ref),
                    "horas_encendida": _num(x.get("horas_encendida"), 1),
                    "kwh_luminaria_dia": round(float(x.get("energia_kwh") or 0) / (lums * dias), 4) if lums and dias else None,
                    "horas_noche": round(float(x.get("horas_encendida") or 0) / (lums * dias), 2) if lums and dias else None,
                    "brillo_noche": _num(x.get("brillo_noche"), 1) if "brillo_noche" in x else None}

        def etiqueta(x):
            if agrupar == "dia":
                return tk_a_fecha(x["clave"])
            if agrupar == "semana":
                return f"Semana {int(x['clave']) % 100} ({tk_a_fecha(x['inicio'])[5:]})"
            return str(x["clave"])

        lums = [enriquecer(x) for x in por_luminaria]
        total = {k: sum(float(x.get(k) or 0) for x in por_zona) for k in ("energia_kwh", "referencia_kwh", "ahorro_kwh", "horas_encendida")}
        return {
            "filtros": f.eco(), "agrupar": agrupar,
            "total": {**{k: round(v, 2) for k, v in total.items()}, "ahorro_pct": _pct(total["ahorro_kwh"], total["referencia_kwh"])},
            "serie": [{"etiqueta": etiqueta(x), "inicio": tk_a_fecha(x["inicio"]), "energia_kwh": _num(x["energia_kwh"], 3),
                       "referencia_kwh": _num(x["referencia_kwh"], 3), "ahorro_kwh": _num(x["ahorro_kwh"], 3)} for x in serie],
            "por_zona": [enriquecer(x) for x in por_zona],
            "por_origen": [enriquecer(x) for x in por_origen],
            "por_modelo": [enriquecer(x) for x in por_modelo],
            "top_consumo": sorted(lums, key=lambda x: -(x["energia_kwh"] or 0))[:10],
            "top_ahorro": sorted([x for x in lums if x["ahorro_pct"] is not None], key=lambda x: -x["ahorro_pct"])[:10],
        }
    return cache.obtener(("consumo", agrupar) + f.clave(), calcular)


# ---------------------------------------------------------------- fallas y mantenimiento
def fallas(f: Filtros) -> dict:
    def calcular():
        J_F = """FROM fact_falla fa
            JOIN dim_tipo_falla t ON t.tipo_falla_key = fa.tipo_falla_key
            JOIN dim_ubicacion u ON u.ubicacion_key = fa.ubicacion_key
            JOIN dim_luminaria l ON l.luminaria_key = fa.luminaria_key
            JOIN dim_origen o ON o.origen_key = fa.origen_key"""
        w, p = f.donde("fa.tiempo_deteccion_key", "u", "l", "o")
        kpi = bd.uno("dw", f"""
            SELECT COUNT(*) AS total, SUM(fa.esta_abierta) AS abiertas, AVG(fa.horas_hasta_deteccion) AS mttd_h,
                   AVG(CASE WHEN fa.esta_abierta = 0 THEN fa.horas_duracion END) AS mttr_h,
                   SUM(fa.costo_correctivo_cop) AS costo_cop, SUM(fa.tiene_mantenimiento) AS con_mantenimiento
            {J_F} WHERE {w}""", p)
        por_tipo = bd.consultar("dw", f"""
            SELECT t.codigo, t.nombre, t.severidad, COUNT(*) AS n, SUM(fa.esta_abierta) AS abiertas,
                   AVG(fa.horas_duracion) AS horas_prom, AVG(fa.horas_hasta_deteccion) AS deteccion_prom
            {J_F} WHERE {w}
            GROUP BY t.codigo, t.nombre, t.severidad ORDER BY COUNT(*) DESC""", p)
        por_zona = bd.consultar("dw", f"""
            SELECT u.zona_codigo, u.zona_nombre, COUNT(*) AS n, SUM(fa.horas_duracion) AS horas
            {J_F} WHERE {w}
            GROUP BY u.zona_codigo, u.zona_nombre ORDER BY COUNT(*) DESC""", p)
        por_mes = bd.consultar("dw", f"""
            SELECT td.anio_mes, COUNT(*) AS n, SUM(fa.horas_duracion) AS horas
            {J_F} JOIN dim_tiempo td ON td.tiempo_key = fa.tiempo_deteccion_key
            WHERE {w}
            GROUP BY td.anio_mes ORDER BY td.anio_mes""", p)
        w_ab, p_ab = f.donde("fa.tiempo_deteccion_key", "u", "l", "o")
        w_ab = w_ab.replace("fa.tiempo_deteccion_key BETWEEN ? AND ?", "fa.esta_abierta = 1")
        abiertas = bd.consultar("dw", f"""
            SELECT fa.falla_id, l.luminaria_id, l.codigo AS luminaria, u.zona_codigo, t.nombre AS tipo, t.severidad,
                   fa.tiempo_deteccion_key, fa.hora_deteccion_key, fa.horas_duracion, fa.tiene_mantenimiento, o.codigo AS origen
            {J_F} WHERE {w_ab}
            ORDER BY fa.tiempo_deteccion_key DESC, fa.hora_deteccion_key DESC""", p_ab[2:])
        for x in abiertas:
            x["detectada"] = f"{tk_a_fecha(x.pop('tiempo_deteccion_key'))} {hk_a_hora(x.pop('hora_deteccion_key'))}"

        J_M = """FROM fact_mantenimiento m
            JOIN dim_tipo_mantenimiento t ON t.tipo_mantenimiento_key = m.tipo_mantenimiento_key
            JOIN dim_tecnico te ON te.tecnico_key = m.tecnico_key
            JOIN dim_ubicacion u ON u.ubicacion_key = m.ubicacion_key
            JOIN dim_luminaria l ON l.luminaria_key = m.luminaria_key
            JOIN dim_origen o ON o.origen_key = m.origen_key"""
        wm, pm = f.donde("m.tiempo_programado_key", "u", "l", "o")
        m_estado = bd.consultar("dw", f"SELECT m.estado, COUNT(*) AS n {J_M} WHERE {wm} GROUP BY m.estado ORDER BY COUNT(*) DESC", pm)
        m_tipo = bd.consultar("dw", f"""
            SELECT t.nombre, m.es_correctivo, COUNT(*) AS n, SUM(m.costo_cop) AS costo_cop, AVG(m.duracion_min * 1.0) AS duracion_prom
            {J_M} WHERE {wm}
            GROUP BY t.nombre, m.es_correctivo ORDER BY COUNT(*) DESC""", pm)
        m_tecnico = bd.consultar("dw", f"""
            SELECT te.nombre, COUNT(*) AS n, SUM(m.duracion_min) AS minutos, AVG(m.dias_retraso * 1.0) AS retraso_prom
            {J_M} WHERE {wm} AND m.estado = 'REALIZADO'
            GROUP BY te.nombre ORDER BY COUNT(*) DESC""", pm)
        m_mes = bd.consultar("dw", f"""
            SELECT tp.anio_mes, SUM(m.es_correctivo) AS correctivos, COUNT(*) - SUM(m.es_correctivo) AS preventivos,
                   SUM(m.costo_cop) AS costo_cop
            {J_M} JOIN dim_tiempo tp ON tp.tiempo_key = m.tiempo_programado_key
            WHERE {wm}
            GROUP BY tp.anio_mes ORDER BY tp.anio_mes""", pm)
        sql_p, par_p = bd.paginar(f"""
            SELECT m.mantenimiento_id, l.luminaria_id, l.codigo AS luminaria, u.zona_codigo, t.nombre AS tipo, m.es_correctivo,
                   m.estado, m.tiempo_programado_key, te.nombre AS tecnico, m.falla_id
            {J_M} WHERE m.es_pendiente = 1
            ORDER BY m.tiempo_programado_key""", 40)
        pendientes = bd.consultar("dw", sql_p, par_p)
        for x in pendientes:
            x["programada"] = tk_a_fecha(x.pop("tiempo_programado_key"))
        wc, pc = f.donde("c.tiempo_key", "u", "l", "o")
        disp = bd.uno("dw", f"SELECT SUM(c.intervalos) AS intervalos, SUM(c.intervalos_falla) AS falla {J_CONSUMO} WHERE {wc}", pc)
        return {
            "filtros": f.eco(),
            "kpi": {"total": kpi.get("total"), "abiertas_periodo": kpi.get("abiertas"),
                    "mttd_h": _num(kpi.get("mttd_h"), 2), "mttr_h": _num(kpi.get("mttr_h"), 1),
                    "costo_cop": _num(kpi.get("costo_cop"), 0), "con_mantenimiento": kpi.get("con_mantenimiento"),
                    "abiertas": len(abiertas), "pendientes": len(pendientes),
                    "disponibilidad_pct": round(100 - (_pct(disp.get("falla"), disp.get("intervalos"), 3) or 0), 2) if disp.get("intervalos") else None},
            "por_tipo": [{**x, "horas_prom": _num(x["horas_prom"], 1), "deteccion_prom": _num(x["deteccion_prom"], 2)} for x in por_tipo],
            "por_zona": [{**x, "horas": _num(x["horas"], 1)} for x in por_zona],
            "por_mes": [{**x, "horas": _num(x["horas"], 1)} for x in por_mes],
            "abiertas": abiertas,
            "mantenimiento": {
                "por_estado": m_estado,
                "por_tipo": [{**x, "costo_cop": _num(x["costo_cop"], 0), "duracion_prom": _num(x["duracion_prom"], 0)} for x in m_tipo],
                "por_tecnico": [{**x, "horas": _num(float(x["minutos"] or 0) / 60, 1), "retraso_prom": _num(x["retraso_prom"], 2)} for x in m_tecnico],
                "por_mes": [{**x, "costo_cop": _num(x["costo_cop"], 0)} for x in m_mes],
                "pendientes": pendientes,
            },
        }
    return cache.obtener(("fallas",) + f.clave(), calcular)
