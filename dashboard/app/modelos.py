"""Vistas de cada modelo (relacional y multidimensional), monitor ETL y comparación."""
from __future__ import annotations

import datetime as dt

from . import cache
from .consultas import Filtros, _entero, _fecha, _num, _pct, extension, hk_a_hora, tk_a_fecha
from .db import ConsultaCostosa, bd

# ======================================================================= RELACIONAL
SQL_REL_ORIGEN = """SELECT o.codigo, o.nombre, x.n
FROM (SELECT origen_id, COUNT(*) AS n FROM medicion GROUP BY origen_id) x
JOIN origen_dato o ON o.origen_id = x.origen_id
ORDER BY x.n DESC"""

SQL_REL_EVENTOS = """SELECT te.tipo_evento_id, te.codigo, te.nombre, te.categoria, x.n
FROM (SELECT tipo_evento_id, COUNT(*) AS n FROM evento_operativo GROUP BY tipo_evento_id) x
JOIN tipo_evento te ON te.tipo_evento_id = x.tipo_evento_id
ORDER BY x.n DESC"""

SQL_REL_CONSUMO = """SELECT ce.fecha, SUM(ce.energia_kwh) AS energia_kwh, SUM(ce.energia_referencia_kwh) AS referencia_kwh,
       SUM(ce.intervalos_imputados) AS imputados
FROM consumo_energetico ce
GROUP BY ce.fecha
ORDER BY ce.fecha"""


def relacional_resumen() -> dict:
    def calcular():
        tablas = bd.consultar("rel", f"SELECT tabla, descripcion, categoria, filas, columnas FROM {bd.meta('meta_tablas')} ORDER BY categoria, tabla")
        origen = bd.consultar("rel", SQL_REL_ORIGEN)
        eventos = bd.consultar("rel", SQL_REL_EVENTOS)
        hora = bd.hora("r.fecha_hora")
        sql_viv = f"""SELECT {hora} AS hora, v.es_fisica,
       AVG(r.luces_encendidas * 1.0 / v.numero_luces) AS fraccion_encendida, COUNT(*) AS registros
FROM registro_luces_vivienda r
JOIN vivienda v ON v.vivienda_id = r.vivienda_id
GROUP BY {hora}, v.es_fisica
ORDER BY 1, 2"""
        viv = bd.consultar("rel", sql_viv)
        consumo = bd.consultar("rel", SQL_REL_CONSUMO)
        fk = bd.uno("rel", f"SELECT COUNT(*) AS n FROM {bd.meta('meta_relaciones')}")
        idx = bd.uno("rel", f"SELECT COUNT(*) AS n FROM {bd.meta('meta_indices')}")
        perfil_viv = {0: [None] * 24, 1: [None] * 24}
        for x in viv:
            h, fis = int(x["hora"]), int(x["es_fisica"])
            if 0 <= h < 24:
                perfil_viv[fis][h] = round(100 * float(x["fraccion_encendida"] or 0), 1)
        return {
            "tablas": tablas, "relaciones": fk.get("n"), "indices": idx.get("n"),
            "mediciones_por_origen": origen, "eventos_por_tipo": eventos,
            "viviendas_perfil": {"horas": [f"{h:02d}" for h in range(24)], "simuladas": perfil_viv[0], "fisicas": perfil_viv[1]},
            "consumo_calculado": [{"fecha": x["fecha"], "energia_kwh": _num(x["energia_kwh"], 3),
                                   "referencia_kwh": _num(x["referencia_kwh"], 3), "imputados": x["imputados"]} for x in consumo],
            "sql": {"mediciones_por_origen": SQL_REL_ORIGEN, "eventos_por_tipo": SQL_REL_EVENTOS,
                    "viviendas": sql_viv, "consumo_calculado": SQL_REL_CONSUMO},
        }
    return cache.obtener(("rel_resumen",), calcular)


def _pagina_args(args, tam_defecto=25):
    pagina = _entero(args.get("pagina"), 1, 10_000_000) or 1
    tam = _entero(args.get("tam"), 5, 100) or tam_defecto
    return pagina, tam


def relacional_mediciones(args) -> dict:
    pagina, tam = _pagina_args(args)
    cond, params = ["1 = 1"], []
    lum = _entero(args.get("luminaria"), 1, 32767)
    if lum:
        cond.append("m.luminaria_id = ?")
        params.append(lum)
    d, h = _fecha(args.get("desde")), _fecha(args.get("hasta"))
    if d:
        cond.append("m.fecha_hora >= ?")
        params.append(f"{d:%Y-%m-%d} 00:00:00")
    if h:
        cond.append("m.fecha_hora < ?")
        params.append(f"{h + dt.timedelta(days=1):%Y-%m-%d} 00:00:00")
    origen = _entero(args.get("origen"), 1, 4)
    if origen:
        cond.append("m.origen_id = ?")
        params.append(origen)
    estado = _entero(args.get("estado"), 1, 8)
    if estado:
        cond.append("m.estado_id = ?")
        params.append(estado)
    where = " AND ".join(cond)
    interna, p_pag = bd.paginar(f"SELECT m.medicion_id FROM medicion m WHERE {where} ORDER BY m.fecha_hora DESC, m.medicion_id DESC",
                                tam, (pagina - 1) * tam)
    sql = f"""SELECT m.medicion_id, m.fecha_hora, l.codigo AS luminaria, z.codigo AS zona, e.codigo AS estado, o.codigo AS origen,
       m.es_noche, m.lectura_ldr, m.nivel_luz_lux, m.detecciones, m.brillo_pct, m.tension_v, m.corriente_a,
       m.potencia_w, m.energia_wh, m.temperatura_c, m.es_anomala
FROM medicion m
JOIN luminaria l ON l.luminaria_id = m.luminaria_id
JOIN ubicacion u ON u.ubicacion_id = l.ubicacion_id
JOIN zona z ON z.zona_id = u.zona_id
JOIN estado_operativo e ON e.estado_id = m.estado_id
JOIN origen_dato o ON o.origen_id = m.origen_id
WHERE m.medicion_id IN ({interna})
ORDER BY m.fecha_hora DESC, m.medicion_id DESC"""
    filas = bd.consultar("rel", sql, params + list(p_pag))

    def contar():
        if where == "1 = 1":
            fila = bd.uno("rel", f"SELECT filas FROM {bd.meta('meta_tablas')} WHERE tabla = 'medicion'")
            return fila.get("filas")
        try:
            return bd.uno("rel", f"SELECT COUNT(*) AS n FROM medicion m WHERE {where}", params).get("n")
        except ConsultaCostosa:
            return None
    total = cache.obtener(("rel_med_total", where, tuple(params)), contar)
    return {"pagina": pagina, "tam": tam, "total": total, "filas": filas, "sql": sql}


def relacional_eventos(args) -> dict:
    pagina, tam = _pagina_args(args)
    cond, params = ["1 = 1"], []
    tipo = _entero(args.get("tipo"), 1, 50)
    if tipo:
        cond.append("ev.tipo_evento_id = ?")
        params.append(tipo)
    origen = _entero(args.get("origen"), 1, 4)
    if origen:
        cond.append("ev.origen_id = ?")
        params.append(origen)
    lum = _entero(args.get("luminaria"), 1, 32767)
    if lum:
        cond.append("ev.luminaria_id = ?")
        params.append(lum)
    where = " AND ".join(cond)
    interna, p_pag = bd.paginar(f"SELECT ev.evento_id FROM evento_operativo ev WHERE {where} ORDER BY ev.fecha_hora DESC, ev.evento_id DESC",
                                tam, (pagina - 1) * tam)
    sql = f"""SELECT ev.evento_id, ev.fecha_hora, te.codigo AS tipo, te.categoria, l.codigo AS luminaria, u.codigo AS ubicacion,
       o.codigo AS origen, ea.codigo AS estado_anterior, en.codigo AS estado_nuevo, ev.brillo_nuevo, ev.falla_id,
       ev.mantenimiento_id, ev.detalle
FROM evento_operativo ev
JOIN tipo_evento te ON te.tipo_evento_id = ev.tipo_evento_id
JOIN ubicacion u ON u.ubicacion_id = ev.ubicacion_id
JOIN origen_dato o ON o.origen_id = ev.origen_id
LEFT JOIN luminaria l ON l.luminaria_id = ev.luminaria_id
LEFT JOIN estado_operativo ea ON ea.estado_id = ev.estado_anterior_id
LEFT JOIN estado_operativo en ON en.estado_id = ev.estado_nuevo_id
WHERE ev.evento_id IN ({interna})
ORDER BY ev.fecha_hora DESC, ev.evento_id DESC"""
    filas = bd.consultar("rel", sql, params + list(p_pag))

    def contar():
        if where == "1 = 1":
            return bd.uno("rel", f"SELECT filas FROM {bd.meta('meta_tablas')} WHERE tabla = 'evento_operativo'").get("filas")
        try:
            return bd.uno("rel", f"SELECT COUNT(*) AS n FROM evento_operativo ev WHERE {where}", params).get("n")
        except ConsultaCostosa:
            return None
    total = cache.obtener(("rel_ev_total", where, tuple(params)), contar)
    return {"pagina": pagina, "tam": tam, "total": total, "filas": filas, "sql": sql}


def relacional_viviendas() -> dict:
    def calcular():
        sql = """SELECT v.vivienda_id, v.codigo, v.numero_luces, v.es_fisica, u.codigo AS ubicacion, z.codigo AS zona,
       r.fecha_hora, r.luces_encendidas, r.luces_apagadas, o.codigo AS origen
FROM vivienda v
JOIN ubicacion u ON u.ubicacion_id = v.ubicacion_id
JOIN zona z ON z.zona_id = u.zona_id
LEFT JOIN registro_luces_vivienda r ON r.vivienda_id = v.vivienda_id
      AND r.fecha_hora = (SELECT MAX(r2.fecha_hora) FROM registro_luces_vivienda r2 WHERE r2.vivienda_id = v.vivienda_id)
LEFT JOIN origen_dato o ON o.origen_id = r.origen_id
ORDER BY v.vivienda_id"""
        return {"viviendas": bd.consultar("rel", sql), "sql": sql}
    return cache.obtener(("rel_viviendas",), calcular)


# ======================================================================= MULTIDIMENSIONAL
CUBOS = {
    "consumo": {
        "nombre": "fact_consumo_diario (luminaria × día)",
        "desde": """FROM fact_consumo_diario c
JOIN dim_ubicacion u ON u.ubicacion_key = c.ubicacion_key
JOIN dim_luminaria l ON l.luminaria_key = c.luminaria_key
JOIN dim_tiempo t ON t.tiempo_key = c.tiempo_key
JOIN dim_origen o ON o.origen_key = c.origen_key""",
        "tiempo": "c.tiempo_key",
        "medidas": {
            "energia_kwh": ("SUM(c.energia_kwh)", "Energía consumida (kWh)", 2),
            "referencia_kwh": ("SUM(c.energia_referencia_kwh)", "Energía sin control adaptativo (kWh)", 2),
            "ahorro_kwh": ("SUM(c.ahorro_kwh)", "Ahorro (kWh)", 2),
            "ahorro_pct": ("100.0 * SUM(c.ahorro_kwh) / NULLIF(SUM(c.energia_referencia_kwh), 0)", "Ahorro (%)", 1),
            "horas_encendida": ("SUM(c.horas_encendida)", "Horas encendida", 1),
            "disponibilidad_pct": ("100.0 - 100.0 * SUM(c.intervalos_falla) / NULLIF(SUM(c.intervalos), 0)", "Disponibilidad (%)", 2),
            "detecciones": ("SUM(c.detecciones)", "Detecciones de movimiento", 0),
            "intervalos_imputados": ("SUM(c.intervalos_imputados)", "Intervalos imputados por el ETL", 0),
        },
        "dimensiones": {
            "zona": ("u.zona_nombre", "u.zona_codigo", "Zona"),
            "tipo_zona": ("u.tipo_zona", "u.tipo_zona", "Tipo de zona"),
            "ubicacion": ("u.codigo", "u.codigo", "Ubicación (tramo)"),
            "luminaria": ("l.codigo", "l.luminaria_id", "Luminaria"),
            "modelo": ("l.modelo_codigo", "l.potencia_nominal_w", "Modelo de luminaria"),
            "anio_mes": ("t.anio_mes", "t.anio_mes", "Mes"),
            "semana": ("t.semana_anio", "t.semana_anio", "Semana ISO"),
            "dia_semana": ("t.nombre_dia", "t.dia_semana", "Día de la semana"),
            "tipo_dia": ("CASE WHEN t.es_festivo = 1 THEN 'Festivo' WHEN t.es_fin_semana = 1 THEN 'Fin de semana' ELSE 'Laboral' END",
                         "CASE WHEN t.es_festivo = 1 THEN 3 WHEN t.es_fin_semana = 1 THEN 2 ELSE 1 END", "Tipo de día"),
            "temporada": ("t.temporada", "t.temporada", "Temporada"),
            "origen": ("o.nombre", "o.codigo", "Origen del dato"),
        },
    },
    "operacion": {
        "nombre": "fact_operacion_horaria (día × 15 min × tramo × estado)",
        "desde": """FROM fact_operacion_horaria h
JOIN dim_ubicacion u ON u.ubicacion_key = h.ubicacion_key
JOIN dim_tiempo t ON t.tiempo_key = h.tiempo_key
JOIN dim_hora hr ON hr.hora_key = h.hora_key
JOIN dim_estado_operativo e ON e.estado_key = h.estado_key
JOIN dim_origen o ON o.origen_key = h.origen_key""",
        "tiempo": "h.tiempo_key",
        "medidas": {
            "intervalos": ("SUM(h.intervalos)", "Intervalos de 15 min", 0),
            "pct_encendida": ("100.0 * SUM(h.intervalos_encendida) / NULLIF(SUM(h.intervalos), 0)", "Tiempo encendida (%)", 1),
            "brillo_prom": ("SUM(h.suma_brillo) * 1.0 / NULLIF(SUM(h.intervalos), 0)", "Brillo promedio (%)", 1),
            "lux_prom": ("SUM(h.suma_lux) * 1.0 / NULLIF(SUM(h.intervalos), 0)", "Luz ambiente promedio (lux)", 1),
            "detecciones": ("SUM(h.detecciones)", "Detecciones de movimiento", 0),
            "energia_kwh": ("SUM(h.energia_wh) / 1000.0", "Energía consumida (kWh)", 2),
        },
        "dimensiones": {
            "zona": ("u.zona_nombre", "u.zona_codigo", "Zona"),
            "tipo_zona": ("u.tipo_zona", "u.tipo_zona", "Tipo de zona"),
            "ubicacion": ("u.codigo", "u.codigo", "Ubicación (tramo)"),
            "anio_mes": ("t.anio_mes", "t.anio_mes", "Mes"),
            "dia_semana": ("t.nombre_dia", "t.dia_semana", "Día de la semana"),
            "franja": ("hr.franja", "MIN(hr.hora_key)", "Franja horaria"),
            "hora": ("hr.hora", "hr.hora", "Hora del día"),
            "estado": ("e.nombre", "e.estado_id", "Estado operativo"),
            "categoria_estado": ("e.categoria", "e.categoria", "Categoría de estado"),
            "origen": ("o.nombre", "o.codigo", "Origen del dato"),
        },
    },
}


def cubo_definicion() -> dict:
    return {k: {"nombre": v["nombre"],
                "medidas": [{"id": m, "nombre": d[1]} for m, d in v["medidas"].items()],
                "dimensiones": [{"id": m, "nombre": d[2]} for m, d in v["dimensiones"].items()]}
            for k, v in CUBOS.items()}


def _orden_expr(expr: str) -> str:
    return expr if expr.startswith("MIN(") else f"MIN({expr})"


def cubo(args) -> dict:
    f = Filtros(args)
    hecho = args.get("hecho") if args.get("hecho") in CUBOS else "consumo"
    c = CUBOS[hecho]
    medida = args.get("medida") if args.get("medida") in c["medidas"] else next(iter(c["medidas"]))
    filas_d = args.get("filas") if args.get("filas") in c["dimensiones"] else "zona"
    cols_d = args.get("columnas") if args.get("columnas") in c["dimensiones"] and args.get("columnas") != filas_d else None

    def calcular():
        m_expr, m_nombre, dec = c["medidas"][medida]
        w, p = f.donde(c["tiempo"], "u", "l" if hecho == "consumo" else None, "o")
        fe, fo, fn = c["dimensiones"][filas_d]
        if cols_d:
            ce, co, cn = c["dimensiones"][cols_d]
            sql = f"""SELECT {fe} AS fila, {_orden_expr(fo)} AS orden_fila, {ce} AS columna, {_orden_expr(co)} AS orden_columna,
       {m_expr} AS valor
{c['desde']}
WHERE {w}
GROUP BY {fe}, {ce}"""
        else:
            sql = f"""SELECT {fe} AS fila, {_orden_expr(fo)} AS orden_fila, {m_expr} AS valor
{c['desde']}
WHERE {w}
GROUP BY {fe}"""
        celdas, ms = bd.medir("dw", sql, p)
        tot_filas = bd.consultar("dw", f"SELECT {fe} AS fila, {m_expr} AS valor {c['desde']} WHERE {w} GROUP BY {fe}", p)
        total = bd.uno("dw", f"SELECT {m_expr} AS valor {c['desde']} WHERE {w}", p)
        filas_orden = sorted({(x["orden_fila"], x["fila"]) for x in celdas}, key=lambda t: (str(t[0]) if not isinstance(t[0], (int, float)) else f"{t[0]:020.4f}"))
        nombres_filas = [str(t[1]) for t in filas_orden]
        tf = {str(x["fila"]): _num(x["valor"], dec) for x in tot_filas}
        resultado = {"hecho": hecho, "hecho_nombre": c["nombre"], "medida": medida, "medida_nombre": m_nombre,
                     "filas_dim": filas_d, "filas_nombre": fn, "filas": nombres_filas,
                     "total_filas": [tf.get(n) for n in nombres_filas], "total": _num(total.get("valor"), dec),
                     "sql": sql, "ms": ms, "filtros": f.eco()}
        if cols_d:
            cols_orden = sorted({(x["orden_columna"], x["columna"]) for x in celdas},
                                key=lambda t: (str(t[0]) if not isinstance(t[0], (int, float)) else f"{t[0]:020.4f}"))
            nombres_cols = [str(t[1]) for t in cols_orden][:40]
            idx_f = {n: i for i, n in enumerate(nombres_filas)}
            idx_c = {n: i for i, n in enumerate(nombres_cols)}
            matriz = [[None] * len(nombres_cols) for _ in nombres_filas]
            for x in celdas:
                i, j = idx_f.get(str(x["fila"])), idx_c.get(str(x["columna"]))
                if i is not None and j is not None:
                    matriz[i][j] = _num(x["valor"], dec)
            tot_cols = bd.consultar("dw", f"SELECT {ce} AS columna, {m_expr} AS valor {c['desde']} WHERE {w} GROUP BY {ce}", p)
            tc = {str(x["columna"]): _num(x["valor"], dec) for x in tot_cols}
            resultado.update({"columnas_dim": cols_d, "columnas_nombre": cn, "columnas": nombres_cols,
                              "matriz": matriz, "total_columnas": [tc.get(n) for n in nombres_cols]})
        else:
            orden = {str(x["fila"]): _num(x["valor"], dec) for x in celdas}
            resultado["valores"] = [orden.get(n) for n in nombres_filas]
        return resultado
    return cache.obtener(("cubo", hecho, medida, filas_d, cols_d) + f.clave(), calcular)


GRANOS = {
    "fact_operacion_luminaria": "Una luminaria en un intervalo de 15 minutos (hecho transaccional principal).",
    "fact_consumo_diario": "Una luminaria en un día y un origen (hecho agregado).",
    "fact_operacion_horaria": "Un tramo, un intervalo de 15 minutos de un día, un estado y un origen (hecho agregado).",
    "fact_falla": "Una falla (hecho de eventos, acumula su ciclo de vida).",
    "fact_mantenimiento": "Una orden de mantenimiento (hecho de eventos).",
}


def dw_resumen() -> dict:
    def calcular():
        tablas = bd.consultar("dw", f"SELECT tabla, descripcion, categoria, filas, columnas FROM {bd.meta('meta_tablas')} ORDER BY categoria, tabla")
        rel = bd.consultar("dw", f"SELECT tabla_origen, columna_origen, tabla_destino, columna_destino FROM {bd.meta('meta_relaciones')}")
        hechos = []
        for t in tablas:
            if t["categoria"] in ("HECHO", "HECHO_AGREGADO"):
                dims = sorted({r["tabla_destino"] for r in rel if r["tabla_origen"] == t["tabla"] and r["tabla_destino"].startswith("dim_")})
                cols = bd.consultar("dw", f"SELECT columna, tipo, es_fk FROM {bd.meta('meta_columnas')} WHERE tabla = ? ORDER BY orden", (t["tabla"],))
                medidas = [x["columna"] for x in cols if not x["es_fk"] and not x["columna"].endswith("_key")
                           and x["columna"] not in ("fact_id", "medicion_id", "falla_id", "mantenimiento_id", "fecha_carga", "ejecucion_id", "estado")]
                hechos.append({**t, "grano": GRANOS.get(t["tabla"], ""), "dimensiones": dims, "medidas": medidas})
        calidad = bd.consultar("dw", """SELECT dc.codigo, dc.descripcion, x.n
            FROM (SELECT calidad_key, COUNT(*) AS n FROM fact_operacion_luminaria GROUP BY calidad_key) x
            JOIN dim_calidad_dato dc ON dc.calidad_key = x.calidad_key ORDER BY dc.calidad_key""")
        return {"tablas": tablas, "hechos": hechos, "calidad": calidad, "cubos": cubo_definicion()}
    return cache.obtener(("dw_resumen",), calcular)


# ======================================================================= ETL
def etl(args) -> dict:
    def base():
        sql, p = bd.paginar("""SELECT ejecucion_id, herramienta, paquete, estado, inicio, fin, watermark_inicial, watermark_final,
                                      filas_leidas, filas_insertadas, filas_rechazadas, filas_omitidas, filas_imputadas,
                                      filas_anomalas, dimensiones_actualizadas, mensaje
                               FROM etl_ejecucion ORDER BY ejecucion_id DESC""", 40)
        ejecuciones = bd.consultar("dw", sql, p)
        motivos = bd.consultar("dw", "SELECT motivo, COUNT(*) AS n FROM etl_rechazo GROUP BY motivo ORDER BY COUNT(*) DESC")
        herramientas = bd.consultar("dw", """SELECT herramienta, COUNT(*) AS ejecuciones, SUM(filas_leidas) AS leidas,
                                             SUM(filas_insertadas) AS insertadas, SUM(filas_rechazadas) AS rechazadas
                                      FROM etl_ejecucion GROUP BY herramienta""")
        control = bd.consultar("dw", "SELECT proceso, ultimo_medicion_id, ultima_ejecucion_id, actualizado FROM etl_control")
        integracion = bd.consultar("rel", "SELECT proceso, ultimo_id_origen, ultima_marca, ultima_ejecucion, filas_ultima_ejecucion FROM integracion_control")
        pendientes = bd.uno("rel", "SELECT MAX(medicion_id) AS maximo FROM medicion")
        sql_r, p_r = bd.paginar("SELECT rechazo_id, ejecucion_id, medicion_id, motivo, detalle, fecha_rechazo FROM etl_rechazo ORDER BY rechazo_id DESC", 40)
        rechazos = bd.consultar("dw", sql_r, p_r)
        wm = control[0]["ultimo_medicion_id"] if control else 0
        return {"ejecuciones": ejecuciones, "rechazos_por_motivo": motivos, "por_herramienta": herramientas,
                "control": control, "integracion_maqueta": integracion, "ultimos_rechazos": rechazos,
                "pendientes_por_cargar": max(0, int(pendientes.get("maximo") or 0) - int(wm or 0))}
    datos = cache.obtener(("etl",), base, 20)
    sel = _entero(args.get("ejecucion"), 1)
    if not sel and datos["ejecuciones"]:
        sel = datos["ejecuciones"][0]["ejecucion_id"]
    pasos = bd.consultar("dw", "SELECT paso_id, paso, inicio, fin, filas, estado, mensaje FROM etl_paso WHERE ejecucion_id = ? ORDER BY paso_id", (sel or 0,))
    motivos_sel = bd.consultar("dw", "SELECT motivo, COUNT(*) AS n FROM etl_rechazo WHERE ejecucion_id = ? GROUP BY motivo ORDER BY COUNT(*) DESC", (sel or 0,))
    return {**datos, "seleccionada": sel, "pasos": pasos, "rechazos_seleccionada": motivos_sel}


# ======================================================================= COMPARACIÓN
CASOS = {
    "consumo_zona": {
        "titulo": "Energía consumida por zona",
        "rel": """SELECT z.nombre AS grupo,
       SUM(CASE WHEN m.energia_wh IS NULL OR m.energia_wh < 0
                THEN (mo.potencia_nominal_w * COALESCE(m.brillo_pct, 0) / 100.0 + 1.5) * 0.25
                ELSE m.energia_wh END) / 1000.0 AS valor
FROM medicion m
JOIN luminaria l ON l.luminaria_id = m.luminaria_id
JOIN modelo_luminaria mo ON mo.modelo_id = l.modelo_id
JOIN ubicacion u ON u.ubicacion_id = l.ubicacion_id
JOIN zona z ON z.zona_id = u.zona_id
WHERE m.origen_id IN (1, 2) AND m.fecha_hora >= ? AND m.fecha_hora < ?
GROUP BY z.nombre
ORDER BY z.nombre""",
        "dw_detalle": """SELECT u.zona_nombre AS grupo, SUM(f.energia_wh) / 1000.0 AS valor
FROM fact_operacion_luminaria f
JOIN dim_ubicacion u ON u.ubicacion_key = f.ubicacion_key
JOIN dim_origen o ON o.origen_key = f.origen_key
WHERE o.codigo IN ('SIMULADO', 'FISICO') AND f.tiempo_key BETWEEN ? AND ?
GROUP BY u.zona_nombre
ORDER BY u.zona_nombre""",
        "dw_agregado": """SELECT u.zona_nombre AS grupo, SUM(c.energia_kwh) AS valor
FROM fact_consumo_diario c
JOIN dim_ubicacion u ON u.ubicacion_key = c.ubicacion_key
JOIN dim_origen o ON o.origen_key = c.origen_key
WHERE o.codigo IN ('SIMULADO', 'FISICO') AND c.tiempo_key BETWEEN ? AND ?
GROUP BY u.zona_nombre
ORDER BY u.zona_nombre""",
        "unidad": "kWh",
    },
    "brillo_hora": {
        "titulo": "Brillo promedio por hora del día",
        "rel": "",  # se arma con la función de hora del dialecto
        "dw_detalle": """SELECT hr.hora AS grupo, AVG(f.brillo_pct * 1.0) AS valor
FROM fact_operacion_luminaria f
JOIN dim_hora hr ON hr.hora_key = f.hora_key
JOIN dim_origen o ON o.origen_key = f.origen_key
WHERE o.codigo IN ('SIMULADO', 'FISICO') AND f.tiempo_key BETWEEN ? AND ?
GROUP BY hr.hora
ORDER BY hr.hora""",
        "dw_agregado": """SELECT hr.hora AS grupo, SUM(h.suma_brillo) * 1.0 / SUM(h.intervalos) AS valor
FROM fact_operacion_horaria h
JOIN dim_hora hr ON hr.hora_key = h.hora_key
JOIN dim_origen o ON o.origen_key = h.origen_key
WHERE o.codigo IN ('SIMULADO', 'FISICO') AND h.tiempo_key BETWEEN ? AND ?
GROUP BY hr.hora
ORDER BY hr.hora""",
        "unidad": "%",
    },
}


def _sql_rel(caso: str) -> str:
    if caso != "brillo_hora":
        return CASOS[caso]["rel"]
    hora = bd.hora("m.fecha_hora")
    return f"""SELECT {hora} AS grupo, AVG(m.brillo_pct * 1.0) AS valor
FROM medicion m
WHERE m.origen_id IN (1, 2) AND m.fecha_hora >= ? AND m.fecha_hora < ?
GROUP BY {hora}
ORDER BY 1"""


def comparacion_modelos() -> dict:
    def calcular():
        salida = {}
        for modelo in ("rel", "dw"):
            tablas = bd.consultar(modelo, f"SELECT tabla, categoria, filas, columnas FROM {bd.meta('meta_tablas')}")
            rel = bd.uno(modelo, f"SELECT COUNT(*) AS n FROM {bd.meta('meta_relaciones')}")
            idx = bd.uno(modelo, f"SELECT COUNT(*) AS n FROM {bd.meta('meta_indices')}")
            cats: dict[str, dict] = {}
            for t in tablas:
                c = cats.setdefault(t["categoria"] or "SIN_CATEGORIA", {"tablas": 0, "filas": 0})
                c["tablas"] += 1
                c["filas"] += int(t["filas"] or 0)
            principal = "medicion" if modelo == "rel" else "fact_operacion_luminaria"
            salida[modelo] = {
                "tablas": len(tablas), "columnas": sum(int(t["columnas"] or 0) for t in tablas),
                "filas": sum(int(t["filas"] or 0) for t in tablas), "relaciones": rel.get("n"), "indices": idx.get("n"),
                "principal": principal, "filas_principal": next((t["filas"] for t in tablas if t["tabla"] == principal), None),
                "por_categoria": cats,
            }
        return salida
    return {"modelos": cache.obtener(("comparacion",), calcular),
            "casos": [{"id": k, "titulo": v["titulo"], "unidad": v["unidad"]} for k, v in CASOS.items()],
            "extension": extension()}


def comparacion_consulta(args) -> dict:
    caso = args.get("caso") if args.get("caso") in CASOS else "consumo_zona"
    ext = extension()
    h = _fecha(args.get("hasta")) or _fecha(ext["simulado_hasta"] or ext["hasta"])
    d = _fecha(args.get("desde")) or (h - dt.timedelta(days=29))
    if d > h:
        d, h = h, d

    def calcular():
        c = CASOS[caso]
        tk1, tk2 = int(d.strftime("%Y%m%d")), int(h.strftime("%Y%m%d"))
        planes = [
            ("rel", "Relacional normalizado (medicion + 4 JOIN)", _sql_rel(caso),
             (f"{d:%Y-%m-%d} 00:00:00", f"{h + dt.timedelta(days=1):%Y-%m-%d} 00:00:00")),
            ("dw", "Estrella: hecho detallado (15 min)", c["dw_detalle"], (tk1, tk2)),
            ("dw", "Estrella: hecho agregado", c["dw_agregado"], (tk1, tk2)),
        ]
        resultados = []
        for modelo, nombre, sql, params in planes:
            try:
                filas, ms = bd.medir(modelo, sql, params, limite_seg=30)
                resultados.append({"modelo": modelo, "nombre": nombre, "sql": sql, "ms": ms,
                                   "filas": [{"grupo": str(x["grupo"]), "valor": _num(x["valor"], 3)} for x in filas]})
            except ConsultaCostosa:
                resultados.append({"modelo": modelo, "nombre": nombre, "sql": sql, "ms": None, "filas": [],
                                   "error": "La consulta superó 30 s en este servidor."})
        return {"caso": caso, "titulo": c["titulo"], "unidad": c["unidad"], "desde": f"{d:%Y-%m-%d}", "hasta": f"{h:%Y-%m-%d}",
                "resultados": resultados, "motor": bd.dialecto}
    return cache.obtener(("bench", caso, str(d), str(h)), calcular, 86400 if bd.dialecto == "sqlite" else 60)


def horas_lista():
    return [hk_a_hora(h * 100) for h in range(24)]


__all__ = ["relacional_resumen", "relacional_mediciones", "relacional_eventos", "relacional_viviendas", "cubo",
           "dw_resumen", "etl", "comparacion_modelos", "comparacion_consulta", "tk_a_fecha", "_pct"]
