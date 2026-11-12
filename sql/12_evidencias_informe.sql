/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   12_evidencias_informe.sql
   Consultas de evidencia para el informe técnico. Cada bloque está
   marcado con el número de la evidencia (E02, E04 …).

   Uso: seleccione con el mouse el bloque completo (desde la línea
   "-- >>> Exx" hasta la siguiente) y presione F5. Capture la pantalla
   de los resultados y guárdelos también como CSV:
   clic derecho en la cuadrícula → «Guardar resultados como…» → Exx.csv
   (si un bloque devuelve varias tablas, guarde cada una: Exx_a.csv, Exx_b.csv…).

   Solo lectura: ninguna consulta modifica datos.
   ===================================================================== */

-- >>> E02 · Entorno de implementación ---------------------------------
SELECT @@SERVERNAME AS servidor,
       CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(30)) AS version,
       CAST(SERVERPROPERTY('ProductLevel') AS NVARCHAR(30)) AS nivel,
       CAST(SERVERPROPERTY('Edition') AS NVARCHAR(60)) AS edicion,
       (SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = 'max server memory (MB)') AS memoria_max_mb;
SELECT d.name AS base_de_datos, d.compatibility_level, d.recovery_model_desc, d.is_read_committed_snapshot_on AS rcsi,
       CAST(SUM(mf.size) * 8 / 1024.0 AS DECIMAL(10,1)) AS tamano_mb
FROM sys.databases d JOIN sys.master_files mf ON mf.database_id = d.database_id
WHERE d.name IN (N'NeoGridRelacional', N'NeoGridDW', N'NeoGridAlumbrado')
GROUP BY d.name, d.compatibility_level, d.recovery_model_desc, d.is_read_committed_snapshot_on;
SELECT @@VERSION AS version_completa;
GO

-- >>> E04 · Relaciones (FK) del modelo relacional --------------------
USE NeoGridRelacional;
SELECT f.name AS restriccion, OBJECT_NAME(f.parent_object_id) AS tabla_hija,
       COL_NAME(fc.parent_object_id, fc.parent_column_id) AS columna,
       OBJECT_NAME(f.referenced_object_id) AS tabla_padre,
       COL_NAME(fc.referenced_object_id, fc.referenced_column_id) AS columna_padre,
       CASE WHEN f.is_disabled = 0 AND f.is_not_trusted = 0 THEN 'SI' ELSE 'NO' END AS activa_y_confiable
FROM sys.foreign_keys f
JOIN sys.foreign_key_columns fc ON fc.constraint_object_id = f.object_id
ORDER BY tabla_hija, columna;
SELECT (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0) AS tablas,
       (SELECT COUNT(*) FROM sys.foreign_keys) AS claves_foraneas,
       (SELECT COUNT(*) FROM sys.check_constraints) AS restricciones_check,
       (SELECT COUNT(*) FROM sys.key_constraints WHERE type = 'UQ') AS restricciones_unique;
GO

-- >>> E05 · Usuarios, responsabilidades y acciones -------------------
USE NeoGridRelacional;
SELECT u.login, u.nombre, u.rol_nombre, u.cargo, p.codigo AS proceso, p.tipo_operacion, up.responsabilidad, up.funcion
FROM dbo.vw_usuario u
JOIN dbo.usuario_proceso up ON up.usuario_id = u.usuario_id
JOIN dbo.proceso p ON p.proceso_id = up.proceso_id
ORDER BY p.proceso_id, CASE up.responsabilidad WHEN 'RESPONSABLE' THEN 1 WHEN 'SUPERVISOR' THEN 2 WHEN 'EJECUTOR' THEN 3 ELSE 4 END, u.usuario_id;
SELECT u.login, u.nombre, u.rol_nombre,
       (SELECT COUNT(*) FROM dbo.falla f WHERE f.usuario_registra_id = u.usuario_id) AS fallas_registradas,
       (SELECT COUNT(*) FROM dbo.mantenimiento m WHERE m.usuario_programa_id = u.usuario_id) AS mantenimientos_programados,
       (SELECT COUNT(*) FROM dbo.mantenimiento m WHERE m.tecnico_id = u.tecnico_id AND m.estado = 'REALIZADO') AS mantenimientos_ejecutados,
       (SELECT COUNT(*) FROM dbo.usuario_proceso up WHERE up.usuario_id = u.usuario_id) AS procesos_asignados
FROM dbo.vw_usuario u
ORDER BY u.usuario_id;
SELECT te.codigo AS tipo_evento, te.categoria, p.codigo AS proceso, p.tipo_operacion,
       (SELECT COUNT(*) FROM dbo.evento_operativo e WHERE e.tipo_evento_id = te.tipo_evento_id) AS eventos
FROM dbo.tipo_evento te JOIN dbo.proceso p ON p.proceso_id = te.proceso_id
ORDER BY p.proceso_id, te.tipo_evento_id;
GO

-- >>> E06 · Volumen: el millón de mediciones (sin tablas de referencia)
USE NeoGridRelacional;
SELECT o.codigo AS origen, COUNT_BIG(m.medicion_id) AS mediciones
FROM dbo.origen_dato o LEFT JOIN dbo.medicion m ON m.origen_id = o.origen_id
GROUP BY o.origen_id, o.codigo ORDER BY o.origen_id;
SELECT tabla, categoria, filas FROM dbo.vw_meta_tablas ORDER BY CASE categoria WHEN 'TRANSACCIONAL' THEN 1 WHEN 'CALCULADA' THEN 2 WHEN 'MAESTRA' THEN 3 WHEN 'CATALOGO' THEN 4 ELSE 5 END, filas DESC;
GO

-- >>> E07 · Período y frecuencia de la simulación --------------------
USE NeoGridRelacional;
SELECT MIN(fecha_hora) AS primera_medicion, MAX(fecha_hora) AS ultima_medicion,
       DATEDIFF(DAY, MIN(fecha_hora), MAX(fecha_hora)) + 1 AS dias,
       COUNT(DISTINCT fecha_hora) AS intervalos_distintos,
       COUNT(DISTINCT luminaria_id) AS luminarias,
       COUNT_BIG(*) AS mediciones,
       COUNT(DISTINCT fecha_hora) * COUNT(DISTINCT luminaria_id) AS esperado_luminarias_x_intervalos
FROM dbo.medicion WHERE origen_id = 1;
SELECT minutos_entre_mediciones, COUNT_BIG(*) AS casos
FROM (SELECT DATEDIFF(MINUTE, LAG(fecha_hora) OVER (PARTITION BY luminaria_id ORDER BY fecha_hora), fecha_hora) AS minutos_entre_mediciones
      FROM dbo.medicion WHERE origen_id = 1) q
WHERE minutos_entre_mediciones IS NOT NULL
GROUP BY minutos_entre_mediciones;
SELECT MIN(n) AS min_mediciones_por_luminaria, MAX(n) AS max_mediciones_por_luminaria
FROM (SELECT luminaria_id, COUNT(*) AS n FROM dbo.medicion WHERE origen_id = 1 GROUP BY luminaria_id) q;
GO

-- >>> E08 · Rangos de las variables simuladas ------------------------
USE NeoGridRelacional;
SELECT v.variable, v.unidad, v.minimo, v.maximo, v.promedio, v.nulos
FROM (
    SELECT N'nivel_luz_lux' AS variable, N'lux' AS unidad, CAST(MIN(nivel_luz_lux) AS DECIMAL(12,2)) AS minimo, CAST(MAX(nivel_luz_lux) AS DECIMAL(12,2)) AS maximo,
           CAST(AVG(nivel_luz_lux) AS DECIMAL(12,2)) AS promedio, SUM(CASE WHEN nivel_luz_lux IS NULL THEN 1 ELSE 0 END) AS nulos, 1 AS orden FROM dbo.medicion WHERE origen_id = 1
    UNION ALL SELECT N'lectura_ldr', N'0–4095', MIN(lectura_ldr), MAX(lectura_ldr), AVG(CAST(lectura_ldr AS DECIMAL(12,2))), SUM(CASE WHEN lectura_ldr IS NULL THEN 1 ELSE 0 END), 2 FROM dbo.medicion WHERE origen_id = 1
    UNION ALL SELECT N'detecciones', N'por 15 min', MIN(detecciones), MAX(detecciones), AVG(CAST(detecciones AS DECIMAL(12,2))), SUM(CASE WHEN detecciones IS NULL THEN 1 ELSE 0 END), 3 FROM dbo.medicion WHERE origen_id = 1
    UNION ALL SELECT N'brillo_pct', N'%', MIN(brillo_pct), MAX(brillo_pct), AVG(brillo_pct), SUM(CASE WHEN brillo_pct IS NULL THEN 1 ELSE 0 END), 4 FROM dbo.medicion WHERE origen_id = 1
    UNION ALL SELECT N'tension_v', N'V', MIN(tension_v), MAX(tension_v), AVG(tension_v), SUM(CASE WHEN tension_v IS NULL THEN 1 ELSE 0 END), 5 FROM dbo.medicion WHERE origen_id = 1
    UNION ALL SELECT N'corriente_a', N'A', MIN(corriente_a), MAX(corriente_a), AVG(corriente_a), SUM(CASE WHEN corriente_a IS NULL THEN 1 ELSE 0 END), 6 FROM dbo.medicion WHERE origen_id = 1
    UNION ALL SELECT N'potencia_w', N'W', MIN(potencia_w), MAX(potencia_w), AVG(potencia_w), SUM(CASE WHEN potencia_w IS NULL THEN 1 ELSE 0 END), 7 FROM dbo.medicion WHERE origen_id = 1
    UNION ALL SELECT N'energia_wh', N'Wh', MIN(energia_wh), MAX(energia_wh), AVG(energia_wh), SUM(CASE WHEN energia_wh IS NULL THEN 1 ELSE 0 END), 8 FROM dbo.medicion WHERE origen_id = 1
    UNION ALL SELECT N'temperatura_c', N'°C', MIN(temperatura_c), MAX(temperatura_c), AVG(temperatura_c), SUM(CASE WHEN temperatura_c IS NULL THEN 1 ELSE 0 END), 9 FROM dbo.medicion WHERE origen_id = 1
) v ORDER BY v.orden;
SELECT SUM(CASE WHEN energia_wh < 0 THEN 1 ELSE 0 END) AS energia_negativa,
       SUM(CASE WHEN tension_v NOT BETWEEN 198 AND 242 THEN 1 ELSE 0 END) AS tension_fuera_de_rango_10pct,
       SUM(CASE WHEN es_anomala = 1 THEN 1 ELSE 0 END) AS marcadas_anomalas,
       SUM(CASE WHEN nivel_luz_lux IS NULL OR tension_v IS NULL OR corriente_a IS NULL OR potencia_w IS NULL
                  OR energia_wh IS NULL OR temperatura_c IS NULL OR detecciones IS NULL OR energia_wh < 0 THEN 1 ELSE 0 END) AS con_nulos_o_inconsistentes
FROM dbo.medicion WHERE origen_id = 1;
GO

-- >>> E09 · Variación por tipo de zona y franja horaria --------------
USE NeoGridRelacional;
SELECT z.tipo_zona,
       CASE WHEN DATEPART(HOUR, m.fecha_hora) BETWEEN 6 AND 17 THEN N'1 Día (06–18)'
            WHEN DATEPART(HOUR, m.fecha_hora) BETWEEN 18 AND 21 THEN N'2 Noche temprana (18–22)'
            WHEN DATEPART(HOUR, m.fecha_hora) IN (22, 23, 0, 1) THEN N'3 Noche (22–02)'
            ELSE N'4 Madrugada (02–06)' END AS franja,
       COUNT_BIG(*) AS mediciones,
       CAST(AVG(CAST(m.detecciones AS DECIMAL(9,2))) AS DECIMAL(9,2)) AS detecciones_prom_15min,
       CAST(AVG(m.brillo_pct) AS DECIMAL(5,1)) AS brillo_prom_pct,
       CAST(100.0 * SUM(CASE WHEN m.brillo_pct > 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,1)) AS pct_encendida,
       CAST(SUM(m.energia_wh) / 1000 AS DECIMAL(12,2)) AS energia_kwh
FROM dbo.medicion m
JOIN dbo.luminaria l ON l.luminaria_id = m.luminaria_id
JOIN dbo.ubicacion u ON u.ubicacion_id = l.ubicacion_id
JOIN dbo.zona z ON z.zona_id = u.zona_id
WHERE m.origen_id = 1
GROUP BY z.tipo_zona,
       CASE WHEN DATEPART(HOUR, m.fecha_hora) BETWEEN 6 AND 17 THEN N'1 Día (06–18)'
            WHEN DATEPART(HOUR, m.fecha_hora) BETWEEN 18 AND 21 THEN N'2 Noche temprana (18–22)'
            WHEN DATEPART(HOUR, m.fecha_hora) IN (22, 23, 0, 1) THEN N'3 Noche (22–02)'
            ELSE N'4 Madrugada (02–06)' END
ORDER BY z.tipo_zona, franja;
GO

-- >>> E10 · Situaciones relevantes simuladas -------------------------
USE NeoGridRelacional;
SELECT e.codigo AS estado, e.categoria, COUNT_BIG(m.medicion_id) AS mediciones,
       CAST(100.0 * COUNT_BIG(m.medicion_id) / SUM(COUNT_BIG(m.medicion_id)) OVER () AS DECIMAL(5,2)) AS pct
FROM dbo.estado_operativo e LEFT JOIN dbo.medicion m ON m.estado_id = e.estado_id AND m.origen_id = 1
GROUP BY e.estado_id, e.codigo, e.categoria ORDER BY e.estado_id;
SELECT tf.codigo AS tipo_falla, tf.severidad, COUNT(f.falla_id) AS fallas,
       SUM(CASE WHEN f.estado = 'RESUELTA' THEN 1 ELSE 0 END) AS resueltas,
       CAST(AVG(DATEDIFF(MINUTE, f.fecha_inicio, f.fecha_deteccion) / 60.0) AS DECIMAL(8,2)) AS horas_prom_hasta_deteccion
FROM dbo.tipo_falla tf LEFT JOIN dbo.falla f ON f.tipo_falla_id = tf.tipo_falla_id AND f.origen_id = 1
GROUP BY tf.tipo_falla_id, tf.codigo, tf.severidad ORDER BY tf.tipo_falla_id;
SELECT tm.codigo AS tipo_mantenimiento, tm.es_correctivo, m.estado, COUNT(*) AS mantenimientos
FROM dbo.mantenimiento m JOIN dbo.tipo_mantenimiento tm ON tm.tipo_mantenimiento_id = m.tipo_mantenimiento_id
WHERE m.origen_id = 1 GROUP BY tm.tipo_mantenimiento_id, tm.codigo, tm.es_correctivo, m.estado ORDER BY tm.tipo_mantenimiento_id, m.estado;
SELECT COUNT(*) AS horas_zona_registradas,
       SUM(CASE WHEN precipitacion_mm > 0 THEN 1 ELSE 0 END) AS horas_con_lluvia,
       CAST(MAX(precipitacion_mm) AS DECIMAL(6,2)) AS lluvia_max_mm,
       CAST(MIN(temperatura_c) AS DECIMAL(5,1)) AS temp_min, CAST(MAX(temperatura_c) AS DECIMAL(5,1)) AS temp_max
FROM dbo.condicion_ambiental;
SELECT o.codigo AS origen, te.codigo AS tipo_evento, COUNT(*) AS eventos
FROM dbo.evento_operativo e JOIN dbo.tipo_evento te ON te.tipo_evento_id = e.tipo_evento_id
JOIN dbo.origen_dato o ON o.origen_id = e.origen_id
GROUP BY o.origen_id, o.codigo, te.tipo_evento_id, te.codigo ORDER BY o.origen_id, te.tipo_evento_id;
GO

-- >>> E11 · Integridad de las mediciones -----------------------------
USE NeoGridRelacional;
SELECT N'luminaria' AS referencia, COUNT(*) AS huerfanas FROM dbo.medicion m WHERE NOT EXISTS (SELECT 1 FROM dbo.luminaria x WHERE x.luminaria_id = m.luminaria_id)
UNION ALL SELECT N'sensor de luz', COUNT(*) FROM dbo.medicion m WHERE m.sensor_luz_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.sensor x WHERE x.sensor_id = m.sensor_luz_id)
UNION ALL SELECT N'sensor de presencia', COUNT(*) FROM dbo.medicion m WHERE m.sensor_presencia_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.sensor x WHERE x.sensor_id = m.sensor_presencia_id)
UNION ALL SELECT N'estado operativo', COUNT(*) FROM dbo.medicion m WHERE NOT EXISTS (SELECT 1 FROM dbo.estado_operativo x WHERE x.estado_id = m.estado_id)
UNION ALL SELECT N'origen', COUNT(*) FROM dbo.medicion m WHERE NOT EXISTS (SELECT 1 FROM dbo.origen_dato x WHERE x.origen_id = m.origen_id)
UNION ALL SELECT N'evento → tipo de evento', COUNT(*) FROM dbo.evento_operativo e WHERE NOT EXISTS (SELECT 1 FROM dbo.tipo_evento x WHERE x.tipo_evento_id = e.tipo_evento_id)
UNION ALL SELECT N'falla → usuario que registra', COUNT(*) FROM dbo.falla f WHERE NOT EXISTS (SELECT 1 FROM dbo.usuario x WHERE x.usuario_id = f.usuario_registra_id);
SELECT COUNT(*) AS grupos_duplicados_luminaria_fecha
FROM (SELECT luminaria_id, fecha_hora FROM dbo.medicion WHERE origen_id IN (1, 2) GROUP BY luminaria_id, fecha_hora HAVING COUNT(*) > 1) q;
SELECT SUM(CASE WHEN es_noche = 0 AND brillo_pct > 0 AND estado_id <> 6 THEN 1 ELSE 0 END) AS encendidas_de_dia_sin_falla_ldr,
       SUM(CASE WHEN estado_id IN (7, 8) AND brillo_pct <> 0 THEN 1 ELSE 0 END) AS fuera_de_servicio_con_brillo
FROM dbo.medicion WHERE origen_id = 1;
GO

-- >>> E14 · Granularidad de los hechos -------------------------------
USE NeoGridDW;
SELECT N'fact_operacion_luminaria' AS hecho, N'luminaria × día × intervalo de 15 min' AS grano,
       COUNT_BIG(*) AS filas,
       (SELECT COUNT_BIG(*) FROM (SELECT DISTINCT luminaria_key, tiempo_key, hora_key FROM dbo.fact_operacion_luminaria) q) AS combinaciones_distintas_del_grano,
       COUNT(DISTINCT medicion_id) AS mediciones_distintas
FROM dbo.fact_operacion_luminaria
UNION ALL
SELECT N'fact_evento_operativo', N'un evento operativo', COUNT_BIG(*), COUNT(DISTINCT evento_id), COUNT(DISTINCT evento_id)
FROM dbo.fact_evento_operativo
UNION ALL
SELECT N'fact_consumo_diario', N'luminaria × día × origen', COUNT_BIG(*),
       (SELECT COUNT_BIG(*) FROM (SELECT DISTINCT tiempo_key, luminaria_key, origen_key FROM dbo.fact_consumo_diario) q), NULL
FROM dbo.fact_consumo_diario
UNION ALL
SELECT N'fact_operacion_horaria', N'día × intervalo × tramo × estado × origen', COUNT_BIG(*),
       (SELECT COUNT_BIG(*) FROM (SELECT DISTINCT tiempo_key, hora_key, ubicacion_key, estado_key, origen_key FROM dbo.fact_operacion_horaria) q), NULL
FROM dbo.fact_operacion_horaria
UNION ALL
SELECT N'fact_falla', N'una falla', COUNT_BIG(*), COUNT(DISTINCT falla_id), NULL FROM dbo.fact_falla
UNION ALL
SELECT N'fact_mantenimiento', N'una orden de mantenimiento', COUNT_BIG(*), COUNT(DISTINCT mantenimiento_id), NULL FROM dbo.fact_mantenimiento;
SELECT tabla, categoria, filas, columnas FROM dbo.vw_meta_tablas
ORDER BY CASE categoria WHEN 'HECHO' THEN 1 WHEN 'HECHO_AGREGADO' THEN 2 WHEN 'DIMENSION' THEN 3 ELSE 4 END, tabla;
GO

-- >>> E19 · Conteos de la ejecución del ETL (última ejecución SSIS) --
USE NeoGridDW;
DECLARE @id INT = (SELECT MAX(ejecucion_id) FROM dbo.etl_ejecucion WHERE herramienta = 'SSIS');
SELECT ejecucion_id, herramienta, estado, inicio, fin, DATEDIFF(SECOND, inicio, fin) AS segundos,
       watermark_inicial, watermark_final, filas_leidas, filas_insertadas, filas_rechazadas, filas_omitidas,
       filas_imputadas, filas_anomalas,
       evento_watermark_inicial, evento_watermark_final, eventos_leidos, eventos_insertados, eventos_rechazados, eventos_omitidos,
       dimensiones_actualizadas
FROM dbo.etl_ejecucion WHERE ejecucion_id = @id;
SELECT paso_id, paso, inicio, fin, DATEDIFF(SECOND, inicio, fin) AS segundos, filas, estado, mensaje
FROM dbo.etl_paso WHERE ejecucion_id = @id ORDER BY paso_id;
SELECT CASE WHEN medicion_id IS NOT NULL THEN 'MEDICION' ELSE 'EVENTO' END AS entidad, motivo, COUNT(*) AS filas
FROM dbo.etl_rechazo WHERE ejecucion_id = @id
GROUP BY CASE WHEN medicion_id IS NOT NULL THEN 'MEDICION' ELSE 'EVENTO' END, motivo ORDER BY entidad, motivo;
GO

-- >>> E20 · Consistencia origen → destino y efecto de la agregación --
USE NeoGridDW;
/* Mediciones: relacional frente a DW por origen. Diferencia = rechazadas (con su motivo) + pendientes de cargar */
SELECT o.codigo AS origen,
       (SELECT COUNT_BIG(*) FROM src.medicion m WHERE m.origen_id = o.origen_id) AS en_relacional,
       (SELECT COUNT_BIG(*) FROM dbo.fact_operacion_luminaria f WHERE f.origen_key = o.origen_key) AS en_dw,
       (SELECT COUNT_BIG(*) FROM dbo.etl_rechazo r JOIN src.medicion m ON m.medicion_id = r.medicion_id WHERE m.origen_id = o.origen_id) AS rechazadas,
       (SELECT COUNT_BIG(*) FROM src.medicion m WHERE m.origen_id = o.origen_id
           AND m.medicion_id > (SELECT ultimo_medicion_id FROM dbo.etl_control WHERE proceso = 'FACT_OPERACION')) AS pendientes_nuevas
FROM dbo.dim_origen o WHERE o.origen_id > 0 ORDER BY o.origen_id;
/* Eventos: relacional frente a DW por origen */
SELECT o.codigo AS origen,
       (SELECT COUNT_BIG(*) FROM src.evento_operativo e WHERE e.origen_id = o.origen_id) AS en_relacional,
       (SELECT COUNT_BIG(*) FROM dbo.fact_evento_operativo f WHERE f.origen_key = o.origen_key) AS en_dw,
       (SELECT COUNT_BIG(*) FROM dbo.etl_rechazo r JOIN src.evento_operativo e ON e.evento_id = r.evento_id WHERE e.origen_id = o.origen_id) AS rechazados,
       (SELECT COUNT_BIG(*) FROM src.evento_operativo e WHERE e.origen_id = o.origen_id
           AND e.evento_id > (SELECT ultimo_medicion_id FROM dbo.etl_control WHERE proceso = 'FACT_EVENTO')) AS pendientes_nuevos
FROM dbo.dim_origen o WHERE o.origen_id > 0 ORDER BY o.origen_id;
/* Agregación: menos filas, mismas cantidades */
SELECT N'fact_operacion_luminaria (base)' AS tabla, COUNT_BIG(*) AS filas, COUNT_BIG(*) AS intervalos_representados,
       CAST(SUM(energia_wh) / 1000 AS DECIMAL(14,3)) AS energia_kwh, SUM(CAST(detecciones AS BIGINT)) AS detecciones
FROM dbo.fact_operacion_luminaria
UNION ALL
SELECT N'fact_operacion_horaria (día × intervalo × tramo × estado)', COUNT_BIG(*), SUM(CAST(intervalos AS BIGINT)),
       CAST(SUM(energia_wh) / 1000 AS DECIMAL(14,3)), SUM(CAST(detecciones AS BIGINT))
FROM dbo.fact_operacion_horaria
UNION ALL
SELECT N'fact_consumo_diario (luminaria × día)', COUNT_BIG(*), SUM(CAST(intervalos AS BIGINT)),
       CAST(SUM(energia_kwh) AS DECIMAL(14,3)), SUM(CAST(detecciones AS BIGINT))
FROM dbo.fact_consumo_diario;
GO

-- >>> E21 · Re-ejecución sin duplicados (ejecutar DESPUÉS de la segunda corrida)
USE NeoGridDW;
SELECT TOP (2) ejecucion_id, herramienta, estado, inicio, watermark_inicial, watermark_final, filas_leidas, filas_insertadas,
       filas_rechazadas, filas_omitidas, evento_watermark_inicial, evento_watermark_final, eventos_leidos, eventos_insertados,
       eventos_rechazados, eventos_omitidos, mensaje
FROM dbo.etl_ejecucion ORDER BY ejecucion_id DESC;
SELECT (SELECT COUNT_BIG(*) FROM dbo.fact_operacion_luminaria) AS filas_hecho_operacion,
       (SELECT COUNT(*) FROM (SELECT luminaria_key, tiempo_key, hora_key FROM dbo.fact_operacion_luminaria
                              GROUP BY luminaria_key, tiempo_key, hora_key HAVING COUNT(*) > 1) q) AS grupos_duplicados_grano,
       (SELECT COUNT(*) FROM (SELECT medicion_id FROM dbo.fact_operacion_luminaria GROUP BY medicion_id HAVING COUNT(*) > 1) q) AS mediciones_repetidas,
       (SELECT COUNT_BIG(*) FROM dbo.fact_evento_operativo) AS filas_hecho_eventos,
       (SELECT COUNT(*) FROM (SELECT evento_id FROM dbo.fact_evento_operativo GROUP BY evento_id HAVING COUNT(*) > 1) q) AS eventos_repetidos;
SELECT proceso, ultimo_medicion_id AS ultimo_id_cargado, ultima_ejecucion_id, actualizado FROM dbo.etl_control;
GO

-- >>> E22 · Registros rechazados y su motivo (todas las ejecuciones) -
USE NeoGridDW;
SELECT r.ejecucion_id, e.herramienta, CASE WHEN r.medicion_id IS NOT NULL THEN 'MEDICION' ELSE 'EVENTO' END AS entidad,
       r.motivo, COUNT(*) AS filas, MIN(r.detalle) AS ejemplo
FROM dbo.etl_rechazo r JOIN dbo.etl_ejecucion e ON e.ejecucion_id = r.ejecucion_id
GROUP BY r.ejecucion_id, e.herramienta, CASE WHEN r.medicion_id IS NOT NULL THEN 'MEDICION' ELSE 'EVENTO' END, r.motivo
ORDER BY r.ejecucion_id, entidad, r.motivo;
/* Por qué hay eventos DUPLICADO en los datos reales: el PIR de la maqueta envía el mismo
   mensaje más de una vez en el mismo segundo; se conserva el primero. */
SELECT TOP (10) r.evento_id, ev.fecha_hora, ev.detalle, r.motivo
FROM dbo.etl_rechazo r JOIN src.evento_operativo ev ON ev.evento_id = r.evento_id
WHERE r.motivo = N'DUPLICADO' AND ev.origen_id = 2
ORDER BY r.evento_id;
GO
