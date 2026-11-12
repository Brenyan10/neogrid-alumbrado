/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   13_consultas_analiticas.sql
   Consultas analíticas sobre el data warehouse (NeoGridDW).
   Cada consulta responde una pregunta del módulo de alumbrado público
   y está marcada con su número de evidencia (E24 … E33).

   Uso: seleccione el bloque completo y presione F5. Capture la pantalla
   y guarde el resultado como CSV (clic derecho → «Guardar resultados como…»).
   Solo lectura.
   ===================================================================== */
USE NeoGridDW;
GO

-- >>> E24 · ¿Cuánta energía consume y ahorra cada zona por mes? -------
--     (ahorro = energía de referencia sin control adaptativo − energía consumida)
SELECT u.zona_nombre, u.tipo_zona, t.anio_mes,
       CAST(SUM(c.energia_kwh) AS DECIMAL(12,2)) AS energia_kwh,
       CAST(SUM(c.energia_referencia_kwh) AS DECIMAL(12,2)) AS referencia_kwh,
       CAST(SUM(c.ahorro_kwh) AS DECIMAL(12,2)) AS ahorro_kwh,
       CAST(100.0 * SUM(c.ahorro_kwh) / NULLIF(SUM(c.energia_referencia_kwh), 0) AS DECIMAL(5,1)) AS ahorro_pct
FROM dbo.fact_consumo_diario c
JOIN dbo.dim_ubicacion u ON u.ubicacion_key = c.ubicacion_key
JOIN dbo.dim_tiempo t ON t.tiempo_key = c.tiempo_key
JOIN dbo.dim_origen o ON o.origen_key = c.origen_key
WHERE o.codigo = 'SIMULADO'
GROUP BY u.zona_nombre, u.tipo_zona, t.anio_mes
ORDER BY u.zona_nombre, t.anio_mes;
GO

-- >>> E25 · ¿Cómo cambian el brillo, la presencia y el consumo a lo largo de la noche?
SELECT h.hora, h.franja,
       SUM(f.intervalos) AS intervalos,
       CAST(SUM(f.suma_brillo) / NULLIF(SUM(f.intervalos), 0) AS DECIMAL(5,1)) AS brillo_prom_pct,
       CAST(1.0 * SUM(f.detecciones) / NULLIF(SUM(f.intervalos), 0) AS DECIMAL(6,2)) AS detecciones_por_intervalo,
       CAST(100.0 * SUM(f.intervalos_encendida) / NULLIF(SUM(f.intervalos), 0) AS DECIMAL(5,1)) AS pct_encendida,
       CAST(SUM(f.energia_wh) / 1000 AS DECIMAL(12,2)) AS energia_kwh,
       CAST(100.0 * (1 - SUM(f.energia_wh) / NULLIF(SUM(f.energia_referencia_wh), 0)) AS DECIMAL(5,1)) AS ahorro_pct
FROM dbo.fact_operacion_horaria f
JOIN dbo.dim_hora h ON h.hora_key = f.hora_key
JOIN dbo.dim_origen o ON o.origen_key = f.origen_key
WHERE o.codigo = 'SIMULADO'
GROUP BY h.hora, h.franja
ORDER BY h.hora;
GO

-- >>> E26 · ¿Qué luminarias consumen más y cuánto ahorran? -----------
SELECT TOP (10) l.codigo AS luminaria, l.modelo_codigo, l.potencia_nominal_w, u.zona_nombre,
       CAST(SUM(c.energia_kwh) AS DECIMAL(10,2)) AS energia_kwh,
       CAST(SUM(c.horas_encendida) AS DECIMAL(10,1)) AS horas_encendida,
       SUM(c.detecciones) AS detecciones,
       CAST(100.0 * SUM(c.ahorro_kwh) / NULLIF(SUM(c.energia_referencia_kwh), 0) AS DECIMAL(5,1)) AS ahorro_pct,
       SUM(c.intervalos_falla) AS intervalos_en_falla
FROM dbo.fact_consumo_diario c
JOIN dbo.dim_luminaria l ON l.luminaria_key = c.luminaria_key
JOIN dbo.dim_ubicacion u ON u.ubicacion_key = c.ubicacion_key
GROUP BY l.codigo, l.modelo_codigo, l.potencia_nominal_w, u.zona_nombre
ORDER BY energia_kwh DESC;
GO

-- >>> E27 · ¿Qué fallas ocurren, cuánto tardan en detectarse y resolverse y cuánto cuestan?
SELECT tf.codigo AS tipo_falla, tf.severidad, o.codigo AS origen,
       COUNT(*) AS fallas,
       SUM(f.esta_abierta) AS abiertas,
       CAST(AVG(f.horas_hasta_deteccion) AS DECIMAL(8,2)) AS horas_prom_deteccion,
       CAST(AVG(f.horas_duracion) AS DECIMAL(8,2)) AS horas_prom_duracion,
       CAST(SUM(f.costo_correctivo_cop) AS DECIMAL(14,0)) AS costo_correctivo_cop
FROM dbo.fact_falla f
JOIN dbo.dim_tipo_falla tf ON tf.tipo_falla_key = f.tipo_falla_key
JOIN dbo.dim_origen o ON o.origen_key = f.origen_key
GROUP BY tf.codigo, tf.severidad, o.codigo
ORDER BY fallas DESC;
GO

-- >>> E28 · ¿Cómo rinde el mantenimiento por técnico y tipo? ---------
SELECT te.nombre AS tecnico, te.especialidad, tm.codigo AS tipo_mantenimiento,
       COUNT(*) AS ordenes,
       SUM(CASE WHEN m.estado = 'REALIZADO' THEN 1 ELSE 0 END) AS realizadas,
       SUM(m.es_pendiente) AS pendientes,
       CAST(AVG(CAST(m.duracion_min AS DECIMAL(9,1))) AS DECIMAL(9,1)) AS duracion_prom_min,
       tm.duracion_estimada_min,
       CAST(AVG(m.dias_retraso) AS DECIMAL(7,2)) AS dias_retraso_prom,
       CAST(SUM(m.costo_cop) AS DECIMAL(14,0)) AS costo_cop
FROM dbo.fact_mantenimiento m
JOIN dbo.dim_tecnico te ON te.tecnico_key = m.tecnico_key
JOIN dbo.dim_tipo_mantenimiento tm ON tm.tipo_mantenimiento_key = m.tipo_mantenimiento_key
GROUP BY te.nombre, te.especialidad, tm.codigo, tm.duracion_estimada_min
ORDER BY te.nombre, tm.codigo;
GO

-- >>> E29 · ¿Qué procesos generan los eventos y qué usuarios son responsables?
SELECT p.tipo_operacion, p.nombre AS proceso, p.responsable_nombre, u.nombre AS usuario_que_actua, u.rol_nombre,
       SUM(f.cantidad_eventos) AS eventos,
       SUM(f.es_critico) AS eventos_criticos,
       COUNT(DISTINCT f.tiempo_key) AS dias_con_eventos
FROM dbo.fact_evento_operativo f
JOIN dbo.dim_proceso p ON p.proceso_key = f.proceso_key
JOIN dbo.dim_usuario u ON u.usuario_key = f.usuario_key
GROUP BY p.proceso_id, p.tipo_operacion, p.nombre, p.responsable_nombre, u.nombre, u.rol_nombre
ORDER BY p.proceso_id, eventos DESC;
GO

-- >>> E30 · ¿Las dos fuentes (simulación y maqueta) describen las acciones igual tras la homologación?
SELECT f.accion_homologada,
       SUM(CASE WHEN o.codigo = 'SIMULADO' THEN f.cantidad_eventos ELSE 0 END) AS simulados,
       SUM(CASE WHEN o.codigo = 'FISICO' THEN f.cantidad_eventos ELSE 0 END) AS fisicos,
       CAST(AVG(f.variacion_brillo_pct) AS DECIMAL(6,1)) AS variacion_brillo_prom,
       CAST(AVG(CAST(f.minutos_desde_anterior AS DECIMAL(12,1))) AS DECIMAL(12,1)) AS minutos_prom_desde_evento_anterior
FROM dbo.fact_evento_operativo f
JOIN dbo.dim_origen o ON o.origen_key = f.origen_key
GROUP BY f.accion_homologada
ORDER BY SUM(f.cantidad_eventos) DESC;
GO

-- >>> E31 · ¿Cambia la operación en fines de semana y festivos? -------
SELECT CASE WHEN t.es_festivo = 1 THEN N'Festivo' WHEN t.es_fin_semana = 1 THEN N'Fin de semana' ELSE N'Laboral' END AS tipo_dia,
       u.tipo_zona,
       COUNT(DISTINCT c.tiempo_key) AS dias,
       CAST(1.0 * SUM(c.detecciones) / NULLIF(COUNT(*), 0) AS DECIMAL(8,1)) AS detecciones_por_luminaria_dia,
       CAST(AVG(c.brillo_promedio_noche) AS DECIMAL(5,1)) AS brillo_prom_noche_pct,
       CAST(AVG(c.energia_kwh) AS DECIMAL(8,4)) AS kwh_por_luminaria_dia
FROM dbo.fact_consumo_diario c
JOIN dbo.dim_tiempo t ON t.tiempo_key = c.tiempo_key
JOIN dbo.dim_ubicacion u ON u.ubicacion_key = c.ubicacion_key
JOIN dbo.dim_origen o ON o.origen_key = c.origen_key
WHERE o.codigo = 'SIMULADO'
GROUP BY CASE WHEN t.es_festivo = 1 THEN N'Festivo' WHEN t.es_fin_semana = 1 THEN N'Fin de semana' ELSE N'Laboral' END, u.tipo_zona
ORDER BY u.tipo_zona, tipo_dia;
GO

-- >>> E32 · Maqueta física frente a simulación (por luminaria y día) --
SELECT o.codigo AS origen, l.es_fisica,
       COUNT(DISTINCT c.luminaria_key) AS luminarias,
       COUNT(DISTINCT c.tiempo_key) AS dias,
       SUM(c.intervalos) AS intervalos,
       CAST(AVG(c.horas_encendida) AS DECIMAL(6,2)) AS horas_encendida_dia,
       CAST(AVG(c.brillo_promedio_noche) AS DECIMAL(5,1)) AS brillo_prom_noche_pct,
       CAST(1.0 * SUM(c.detecciones) / NULLIF(COUNT(*), 0) AS DECIMAL(8,1)) AS detecciones_por_luminaria_dia,
       CAST(100.0 * SUM(c.ahorro_kwh) / NULLIF(SUM(c.energia_referencia_kwh), 0) AS DECIMAL(5,1)) AS ahorro_pct
FROM dbo.fact_consumo_diario c
JOIN dbo.dim_origen o ON o.origen_key = c.origen_key
JOIN dbo.dim_luminaria l ON l.luminaria_key = c.luminaria_key
GROUP BY o.codigo, l.es_fisica
ORDER BY o.codigo;
GO

-- >>> E33 · Calidad del dato cargado por zona ------------------------
SELECT u.zona_nombre, dc.codigo AS calidad, COUNT_BIG(*) AS intervalos,
       CAST(100.0 * COUNT_BIG(*) / SUM(COUNT_BIG(*)) OVER (PARTITION BY u.zona_nombre) AS DECIMAL(5,2)) AS pct_de_la_zona
FROM dbo.fact_operacion_luminaria f
JOIN dbo.dim_ubicacion u ON u.ubicacion_key = f.ubicacion_key
JOIN dbo.dim_calidad_dato dc ON dc.calidad_key = f.calidad_key
GROUP BY u.zona_nombre, dc.calidad_key, dc.codigo
ORDER BY u.zona_nombre, dc.calidad_key;
GO
