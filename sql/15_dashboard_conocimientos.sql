/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   15_dashboard_conocimientos.sql
   Cálculo en SQL de cada valor que muestra el dashboard de Power BI.
   Sirve para dos cosas:
     1) Documentar los cinco conocimientos y las dos decisiones con
        valores obtenidos directamente de los datos.
     2) Validar el dashboard: con el panel SIN filtros, cada visual debe
        mostrar los mismos números que su bloque aquí (E34 … E45).
   Base: pbi.* (script 14), todas las fuentes (simulado + físico).
   Uso: ejecutar bloque por bloque (cada uno termina en GO), capturar y
   guardar el resultado como CSV («Guardar resultados como…»). Solo lectura.
   ===================================================================== */
USE NeoGridDW;
GO

-- >>> E34 · Indicadores generales (tarjetas del dashboard) -------------
WITH op AS (
    SELECT COUNT_BIG(*) AS mediciones,
           COUNT(DISTINCT luminaria_key) AS luminarias,
           MIN(tiempo_key) AS desde, MAX(tiempo_key) AS hasta,
           SUM(energia_wh) / 1000 AS energia_kwh,
           SUM(energia_referencia_wh) / 1000 AS referencia_kwh,
           SUM(ahorro_wh) / 1000 AS ahorro_kwh,
           SUM(CAST(en_falla AS INT)) AS intervalos_falla,
           SUM(CAST(encendida_de_dia AS INT)) AS intervalos_encendida_dia,
           SUM(CASE WHEN es_noche = 0 THEN 1 ELSE 0 END) AS intervalos_dia
    FROM pbi.fact_operacion),
fa AS (
    SELECT COUNT(*) AS fallas, SUM(CAST(esta_abierta AS INT)) AS fallas_abiertas,
           AVG(horas_duracion) AS duracion_media_h
    FROM pbi.fact_falla),
fm AS (
    SELECT DISTINCT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY horas_duracion) OVER () AS duracion_mediana_h
    FROM pbi.fact_falla),
ev AS (
    SELECT SUM(CAST(cantidad_eventos AS INT)) AS eventos, SUM(CAST(es_critico AS INT)) AS eventos_criticos
    FROM pbi.fact_evento)
SELECT op.mediciones, op.luminarias, op.desde, op.hasta,
       CAST(op.energia_kwh AS DECIMAL(12,2)) AS energia_kwh,
       CAST(op.referencia_kwh AS DECIMAL(12,2)) AS referencia_kwh,
       CAST(100.0 * op.ahorro_kwh / op.referencia_kwh AS DECIMAL(5,1)) AS ahorro_pct,
       CAST(100.0 * (1 - 1.0 * op.intervalos_falla / op.mediciones) AS DECIMAL(5,2)) AS disponibilidad_pct,
       CAST(100.0 * op.intervalos_encendida_dia / op.intervalos_dia AS DECIMAL(5,2)) AS pct_encendida_de_dia,
       fa.fallas, fa.fallas_abiertas,
       CAST(fa.duracion_media_h AS DECIMAL(8,1)) AS duracion_media_h,
       CAST(fm.duracion_mediana_h AS DECIMAL(8,1)) AS duracion_mediana_h,
       ev.eventos, ev.eventos_criticos,
       CAST(100.0 * ev.eventos_criticos / ev.eventos AS DECIMAL(5,2)) AS pct_criticos
FROM op CROSS JOIN fa CROSS JOIN fm CROSS JOIN ev;
GO

-- >>> E35 · Univariado 1 · Distribución del brillo de noche (luminaria encendida)
WITH b AS (
    SELECT CASE WHEN brillo_pct >= 100 THEN 100 ELSE FLOOR(brillo_pct / 10) * 10 END AS rango_desde, brillo_pct
    FROM pbi.fact_operacion
    WHERE es_noche = 1 AND encendida = 1)
SELECT CONCAT(CAST(rango_desde AS INT), CASE WHEN rango_desde = 100 THEN '' ELSE CONCAT('–', CAST(rango_desde + 9.9 AS DECIMAL(4,1))) END, ' %') AS rango_brillo,
       COUNT_BIG(*) AS intervalos,
       CAST(100.0 * COUNT_BIG(*) / SUM(COUNT_BIG(*)) OVER () AS DECIMAL(5,2)) AS pct
FROM b GROUP BY rango_desde ORDER BY rango_desde;

SELECT DISTINCT
       COUNT_BIG(*) OVER () AS intervalos,
       CAST(AVG(brillo_pct) OVER () AS DECIMAL(5,1)) AS media_pct,
       CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY brillo_pct) OVER () AS DECIMAL(5,1)) AS mediana_pct,
       CAST(STDEV(brillo_pct) OVER () AS DECIMAL(5,1)) AS desviacion_pct,
       MIN(brillo_pct) OVER () AS minimo, MAX(brillo_pct) OVER () AS maximo
FROM pbi.fact_operacion WHERE es_noche = 1 AND encendida = 1;
GO

-- >>> E36 · Univariado 2 · Duración de las fallas (horas) -----------------
SELECT CASE WHEN horas_duracion < 24 THEN '1. Menos de 24 h'
            WHEN horas_duracion < 72 THEN '2. 24 a 72 h'
            WHEN horas_duracion < 168 THEN '3. 3 a 7 días'
            WHEN horas_duracion < 336 THEN '4. 7 a 14 días'
            ELSE '5. 14 días o más' END AS rango_duracion,
       COUNT(*) AS fallas,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS pct
FROM pbi.fact_falla
GROUP BY CASE WHEN horas_duracion < 24 THEN '1. Menos de 24 h'
              WHEN horas_duracion < 72 THEN '2. 24 a 72 h'
              WHEN horas_duracion < 168 THEN '3. 3 a 7 días'
              WHEN horas_duracion < 336 THEN '4. 7 a 14 días'
              ELSE '5. 14 días o más' END
ORDER BY rango_duracion;

SELECT DISTINCT o.origen,
       COUNT(*) OVER (PARTITION BY o.origen) AS fallas,
       CAST(AVG(f.horas_duracion) OVER (PARTITION BY o.origen) AS DECIMAL(8,1)) AS media_h,
       CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.horas_duracion) OVER (PARTITION BY o.origen) AS DECIMAL(8,1)) AS mediana_h,
       CAST(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY f.horas_duracion) OVER (PARTITION BY o.origen) AS DECIMAL(8,1)) AS p90_h,
       MAX(f.horas_duracion) OVER (PARTITION BY o.origen) AS maximo_h
FROM pbi.fact_falla f JOIN pbi.dim_origen o ON o.origen_key = f.origen_key;
GO

-- >>> E37 · Univariado 3 · Frecuencia de las acciones homologadas --------
SELECT accion_homologada,
       SUM(CAST(cantidad_eventos AS INT)) AS eventos,
       CAST(100.0 * SUM(CAST(cantidad_eventos AS INT)) / SUM(SUM(CAST(cantidad_eventos AS INT))) OVER () AS DECIMAL(5,2)) AS pct
FROM pbi.fact_evento
GROUP BY accion_homologada
ORDER BY eventos DESC;
GO

-- >>> E38 · Bivariado 1 · Hora del día × consumo y ahorro --------------
SELECT h.hora, h.franja,
       COUNT_BIG(*) AS intervalos,
       CAST(SUM(f.energia_wh) / 1000 AS DECIMAL(10,2)) AS energia_kwh,
       CAST(SUM(f.energia_referencia_wh) / 1000 AS DECIMAL(10,2)) AS referencia_kwh,
       CAST(100.0 * SUM(f.ahorro_wh) / NULLIF(SUM(f.energia_referencia_wh), 0) AS DECIMAL(6,1)) AS ahorro_pct,
       CAST(AVG(f.brillo_pct) AS DECIMAL(5,1)) AS brillo_prom_pct,
       CAST(AVG(1.0 * f.detecciones) AS DECIMAL(6,2)) AS detecciones_por_intervalo
FROM pbi.fact_operacion f JOIN pbi.dim_hora h ON h.hora_key = f.hora_key
GROUP BY h.hora, h.franja
ORDER BY h.hora;
GO

-- >>> E39 · Bivariado 2 · Tipo de zona × presencia y consumo -----------
--     (por luminaria-día = 96 intervalos de 15 min)
SELECT u.tipo_zona,
       COUNT(DISTINCT f.luminaria_key) AS luminarias,
       COUNT_BIG(*) AS intervalos,
       CAST(96.0 * SUM(f.detecciones) / COUNT_BIG(*) AS DECIMAL(8,1)) AS detecciones_por_luminaria_dia,
       CAST(96.0 * SUM(f.energia_wh) / 1000 / COUNT_BIG(*) AS DECIMAL(8,4)) AS kwh_por_luminaria_dia,
       CAST(100.0 * SUM(f.ahorro_wh) / NULLIF(SUM(f.energia_referencia_wh), 0) AS DECIMAL(5,1)) AS ahorro_pct
FROM pbi.fact_operacion f JOIN pbi.dim_ubicacion u ON u.ubicacion_key = f.ubicacion_key
GROUP BY u.tipo_zona
ORDER BY detecciones_por_luminaria_dia DESC;
GO

-- >>> E40 · Bivariado 3 · Tipo de falla × duración ---------------------
SELECT DISTINCT tf.tipo_falla, tf.severidad,
       COUNT(*) OVER (PARTITION BY tf.tipo_falla) AS fallas,
       SUM(CAST(f.esta_abierta AS INT)) OVER (PARTITION BY tf.tipo_falla) AS abiertas,
       CAST(AVG(f.horas_duracion) OVER (PARTITION BY tf.tipo_falla) AS DECIMAL(8,1)) AS media_h,
       CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.horas_duracion) OVER (PARTITION BY tf.tipo_falla) AS DECIMAL(8,1)) AS mediana_h,
       CAST(SUM(f.costo_correctivo_cop) OVER (PARTITION BY tf.tipo_falla) AS DECIMAL(14,0)) AS costo_cop
FROM pbi.fact_falla f JOIN pbi.dim_tipo_falla tf ON tf.tipo_falla_key = f.tipo_falla_key
ORDER BY mediana_h DESC;
GO

-- >>> E41 · Multivariado · Ahorro por tipo de zona × franja × tipo de día
--     Calculado sobre la combinación de las tres variables (no por separado).
SELECT u.tipo_zona, h.franja, d.tipo_dia,
       COUNT_BIG(*) AS intervalos,
       CAST(AVG(1.0 * f.detecciones) AS DECIMAL(6,2)) AS detecciones_por_intervalo,
       CAST(SUM(f.energia_wh) / 1000 AS DECIMAL(10,2)) AS energia_kwh,
       CAST(100.0 * SUM(f.ahorro_wh) / NULLIF(SUM(f.energia_referencia_wh), 0) AS DECIMAL(6,1)) AS ahorro_pct
FROM pbi.fact_operacion f
JOIN pbi.dim_ubicacion u ON u.ubicacion_key = f.ubicacion_key
JOIN pbi.dim_hora h ON h.hora_key = f.hora_key
JOIN pbi.dim_fecha d ON d.tiempo_key = f.tiempo_key
WHERE h.franja IN (N'Noche', N'Madrugada')
GROUP BY u.tipo_zona, h.franja, d.tipo_dia
ORDER BY u.tipo_zona, h.franja DESC, d.tipo_dia;
GO

-- >>> E42 · Luminarias encendidas de día y su relación con fallas del LDR
WITH dia AS (
    SELECT f.luminaria_key, MIN(f.ubicacion_key) AS ubicacion_key,
           SUM(CAST(f.encendida_de_dia AS INT)) AS intervalos_encendida_dia,
           SUM(CASE WHEN f.encendida_de_dia = 1 THEN f.energia_wh ELSE 0 END) / 1000 AS kwh_de_dia
    FROM pbi.fact_operacion f GROUP BY f.luminaria_key),
ldr AS (
    SELECT f.luminaria_key, COUNT(*) AS fallas_ldr, SUM(f.horas_duracion) AS horas_falla_ldr
    FROM pbi.fact_falla f JOIN pbi.dim_tipo_falla tf ON tf.tipo_falla_key = f.tipo_falla_key
    WHERE tf.tipo_falla = 'LECTURA_LDR' GROUP BY f.luminaria_key)
SELECT TOP (12) l.luminaria, u.zona, l.tipo_luminaria,
       d.intervalos_encendida_dia,
       CAST(d.intervalos_encendida_dia / 4.0 AS DECIMAL(8,1)) AS horas_encendida_dia,
       CAST(d.kwh_de_dia AS DECIMAL(8,2)) AS kwh_de_dia,
       ISNULL(r.fallas_ldr, 0) AS fallas_ldr,
       CAST(ISNULL(r.horas_falla_ldr, 0) AS DECIMAL(8,1)) AS horas_falla_ldr
FROM dia d
JOIN pbi.dim_luminaria l ON l.luminaria_key = d.luminaria_key
JOIN pbi.dim_ubicacion u ON u.ubicacion_key = d.ubicacion_key
LEFT JOIN ldr r ON r.luminaria_key = d.luminaria_key
ORDER BY d.kwh_de_dia DESC;

-- Concentración: cuánto del consumo diurno explican las luminarias con falla LDR
WITH dia AS (
    SELECT f.luminaria_key, SUM(CASE WHEN f.encendida_de_dia = 1 THEN f.energia_wh ELSE 0 END) / 1000 AS kwh_de_dia
    FROM pbi.fact_operacion f GROUP BY f.luminaria_key),
con_ldr AS (
    SELECT DISTINCT f.luminaria_key FROM pbi.fact_falla f
    JOIN pbi.dim_tipo_falla tf ON tf.tipo_falla_key = f.tipo_falla_key WHERE tf.tipo_falla = 'LECTURA_LDR')
SELECT CASE WHEN c.luminaria_key IS NULL THEN 'Sin falla LDR registrada' ELSE 'Con falla LDR registrada' END AS grupo,
       COUNT(*) AS luminarias,
       CAST(SUM(d.kwh_de_dia) AS DECIMAL(10,2)) AS kwh_de_dia,
       CAST(100.0 * SUM(d.kwh_de_dia) / SUM(SUM(d.kwh_de_dia)) OVER () AS DECIMAL(5,1)) AS pct_kwh_de_dia,
       CAST(AVG(d.kwh_de_dia) AS DECIMAL(8,2)) AS kwh_de_dia_por_luminaria
FROM dia d LEFT JOIN con_ldr c ON c.luminaria_key = d.luminaria_key
GROUP BY CASE WHEN c.luminaria_key IS NULL THEN 'Sin falla LDR registrada' ELSE 'Con falla LDR registrada' END;
GO

-- >>> E43 · Encendido diurno durante la falla y fuera de ella ---------
SELECT CASE f.en_falla WHEN 1 THEN 'Intervalo en falla' ELSE 'Intervalo sin falla' END AS estado,
       COUNT_BIG(*) AS intervalos_de_dia,
       SUM(CAST(f.encendida AS INT)) AS encendida,
       CAST(100.0 * SUM(CAST(f.encendida AS INT)) / COUNT_BIG(*) AS DECIMAL(6,2)) AS pct_encendida
FROM pbi.fact_operacion f
WHERE f.es_noche = 0
GROUP BY f.en_falla;
GO

-- >>> E44 · Validación · influencia de datos imputados y anómalos -----
SELECT c.calidad,
       COUNT_BIG(*) AS intervalos,
       CAST(100.0 * COUNT_BIG(*) / SUM(COUNT_BIG(*)) OVER () AS DECIMAL(5,2)) AS pct,
       CAST(100.0 * SUM(f.ahorro_wh) / NULLIF(SUM(f.energia_referencia_wh), 0) AS DECIMAL(6,1)) AS ahorro_pct,
       CAST(AVG(f.brillo_pct) AS DECIMAL(5,1)) AS brillo_prom_pct
FROM pbi.fact_operacion f JOIN pbi.dim_calidad c ON c.calidad_key = f.calidad_key
GROUP BY c.calidad_key, c.calidad
ORDER BY c.calidad_key;

SELECT 'Todos los intervalos' AS conjunto,
       CAST(100.0 * SUM(ahorro_wh) / SUM(energia_referencia_wh) AS DECIMAL(6,2)) AS ahorro_pct
FROM pbi.fact_operacion
UNION ALL
SELECT 'Solo ORIGINAL (sin imputados ni anómalos)',
       CAST(100.0 * SUM(f.ahorro_wh) / SUM(f.energia_referencia_wh) AS DECIMAL(6,2))
FROM pbi.fact_operacion f JOIN pbi.dim_calidad c ON c.calidad_key = f.calidad_key
WHERE c.fue_imputado = 0 AND c.es_anomalo = 0;
GO

-- >>> E45 · Validación · fallas más largas (valores atípicos) ---------
SELECT TOP (8) f.falla_id, tf.tipo_falla, o.origen, l.luminaria,
       CAST(f.horas_duracion AS DECIMAL(8,1)) AS horas_duracion,
       f.esta_abierta, f.tiene_mantenimiento
FROM pbi.fact_falla f
JOIN pbi.dim_tipo_falla tf ON tf.tipo_falla_key = f.tipo_falla_key
JOIN pbi.dim_origen o ON o.origen_key = f.origen_key
JOIN pbi.dim_luminaria l ON l.luminaria_key = f.luminaria_key
ORDER BY f.horas_duracion DESC;
GO
