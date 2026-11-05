/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   03_relacional_generar_datos.sql
   Genera los datos simulados del modelo relacional:
     · condicion_ambiental   ~23.400 filas (6 zonas × hora)
     · falla                 ~70–90 filas
     · mantenimiento         ~400 filas (preventivos y correctivos)
     · medicion              EXACTAMENTE 1.000.000 de filas
                             (64 luminarias × 15.625 intervalos de 15 min,
                              del 2026-05-01 00:00 al 2026-10-10 18:00)
     · evento_operativo      ~100.000–150.000 filas
     · registro_luces_vivienda ~93.800 filas
     · consumo_energetico    ~10.400 filas (calculado)

   Los números "aleatorios" salen de HASHBYTES('MD5', …): son
   deterministas, así que cada ejecución produce exactamente los mismos
   datos y los resultados se pueden comparar entre equipos.

   Duración esperada en un portátil normal: 2 a 6 minutos.
   Requiere: 01 y 02.
   ===================================================================== */
USE NeoGridRelacional;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @inicio DATETIME2(0) = '2026-05-01T00:00:00';
DECLARE @slots  INT = 15625;                                   -- 15.625 × 64 = 1.000.000
DECLARE @lotes  INT = 5;                                       -- 5 lotes de 200.000 filas
DECLARE @fin    DATETIME2(0) = DATEADD(MINUTE, 15 * @slots, @inicio);  -- 2026-10-10 18:15 (exclusivo)
DECLARE @t0     DATETIME2(3) = SYSDATETIME();
DECLARE @msg    NVARCHAR(400);

IF (SELECT COUNT(*) FROM dbo.luminaria) <> 64
BEGIN
    RAISERROR(N'Se esperaban 64 luminarias. Ejecute primero 01 y 02.', 16, 1);
    RETURN;
END

/* ---------------------------------------------------------------------
   1. Limpieza de una ejecución anterior (solo datos simulados)
   --------------------------------------------------------------------- */
RAISERROR(N'1/10 Limpiando datos simulados anteriores...', 0, 1) WITH NOWAIT;
DELETE FROM dbo.evento_operativo WHERE origen_id = 1;
DELETE FROM dbo.consumo_energetico;
DELETE FROM dbo.registro_luces_vivienda WHERE origen_id = 1;
IF NOT EXISTS (SELECT 1 FROM dbo.medicion WHERE origen_id <> 1)
    TRUNCATE TABLE dbo.medicion;
ELSE
    DELETE FROM dbo.medicion WHERE origen_id = 1;
DELETE FROM dbo.mantenimiento WHERE origen_id = 1;
DELETE FROM dbo.falla WHERE origen_id = 1;
DELETE FROM dbo.condicion_ambiental WHERE origen_id = 1;

/* ---------------------------------------------------------------------
   2. Días: nubosidad diaria, amanecer/atardecer y modo ahorro
   Chía (4,86° N): el día dura ~12 h todo el año. Temporadas de lluvia
   en abril–mayo y octubre–noviembre (más nubosidad).
   Modo ahorro: después de un día muy nublado la batería solar queda
   baja y esa noche el brillo máximo se limita al 60 %.
   --------------------------------------------------------------------- */
RAISERROR(N'2/10 Calendario de días y luz natural...', 0, 1) WITH NOWAIT;
IF OBJECT_ID('tempdb..#dia') IS NOT NULL DROP TABLE #dia;
CREATE TABLE #dia (
    fecha       DATE   NOT NULL PRIMARY KEY,
    nub_dia     FLOAT  NOT NULL,
    amanecer    FLOAT  NOT NULL,
    atardecer   FLOAT  NOT NULL,
    ahorro      BIT    NOT NULL,
    fin_semana  BIT    NOT NULL
);

;WITH d AS (
    SELECT TOP (DATEDIFF(DAY, @inicio, @fin) + 1)
        DATEADD(DAY, CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) - 1, CAST(@inicio AS DATE)) AS fecha
    FROM sys.all_objects
)
INSERT INTO #dia (fecha, nub_dia, amanecer, atardecer, ahorro, fin_semana)
SELECT
    d.fecha,
    x.nub,
    5.70E0 + 0.10E0 * SIN(2 * PI() * (DATEPART(DAYOFYEAR, d.fecha) - 110) / 365.0E0),
    17.95E0 + 0.12E0 * SIN(2 * PI() * (DATEPART(DAYOFYEAR, d.fecha) - 110) / 365.0E0),
    CASE WHEN x.nub > 0.80 THEN 1 ELSE 0 END,
    CASE WHEN DATEDIFF(DAY, '20260105', d.fecha) % 7 IN (5, 6) THEN 1 ELSE 0 END
FROM d
CROSS APPLY (SELECT CAST(SUBSTRING(HASHBYTES('MD5', CONCAT('dia:', CONVERT(CHAR(8), d.fecha, 112))), 1, 3) AS INT) / 16777215.0E0 AS r) h
CROSS APPLY (SELECT CASE MONTH(d.fecha) WHEN 5 THEN 0.66E0 WHEN 6 THEN 0.55E0 WHEN 7 THEN 0.42E0
                                         WHEN 8 THEN 0.45E0 WHEN 9 THEN 0.55E0 ELSE 0.70E0 END AS base) b
CROSS APPLY (SELECT b.base + (h.r - 0.5E0) * 0.5E0 AS nub0) n0
CROSS APPLY (SELECT CASE WHEN n0.nub0 < 0.05 THEN 0.05E0 WHEN n0.nub0 > 0.97 THEN 0.97E0 ELSE n0.nub0 END AS nub) x;

/* ---------------------------------------------------------------------
   3. Intervalos de 15 minutos con la luz de cielo despejado
   --------------------------------------------------------------------- */
RAISERROR(N'3/10 Intervalos de 15 minutos...', 0, 1) WITH NOWAIT;
IF OBJECT_ID('tempdb..#slot') IS NOT NULL DROP TABLE #slot;
CREATE TABLE #slot (
    n             INT           NOT NULL PRIMARY KEY,
    fecha_hora    DATETIME2(0)  NOT NULL,
    hora_redonda  DATETIME2(0)  NOT NULL,
    fecha         DATE          NOT NULL,
    hora          INT           NOT NULL,
    minuto        INT           NOT NULL,
    fin_semana    BIT           NOT NULL,
    lux_claro     FLOAT         NOT NULL,
    ahorro_noche  BIT           NOT NULL
);

;WITH n AS (
    SELECT TOP (@slots) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) - 1 AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO #slot (n, fecha_hora, hora_redonda, fecha, hora, minuto, fin_semana, lux_claro, ahorro_noche)
SELECT
    n.n,
    t.fh,
    DATEADD(HOUR, DATEDIFF(HOUR, @inicio, t.fh), @inicio),
    CAST(t.fh AS DATE),
    DATEPART(HOUR, t.fh),
    DATEPART(MINUTE, t.fh),
    d.fin_semana,
    lc.lux,
    ISNULL(da.ahorro, 0)
FROM n
CROSS APPLY (SELECT DATEADD(MINUTE, 15 * n.n, @inicio) AS fh) t
JOIN #dia d ON d.fecha = CAST(t.fh AS DATE)
LEFT JOIN #dia da ON da.fecha = CASE WHEN DATEPART(HOUR, t.fh) < 12 THEN DATEADD(DAY, -1, CAST(t.fh AS DATE)) ELSE CAST(t.fh AS DATE) END
CROSS APPLY (SELECT DATEPART(HOUR, t.fh) + DATEPART(MINUTE, t.fh) / 60.0E0 AS h) hh
CROSS APPLY (SELECT CASE WHEN hh.h < d.amanecer THEN d.amanecer - hh.h WHEN hh.h > d.atardecer THEN hh.h - d.atardecer ELSE 0.0E0 END AS fuera) f
CROSS APPLY (SELECT
    CASE
        WHEN hh.h >= d.amanecer AND hh.h <= d.atardecer
            THEN 400 + 110000 * POWER(SIN(PI() * (hh.h - d.amanecer) / (d.atardecer - d.amanecer)), 1.3E0)
        WHEN f.fuera < 0.6
            THEN 0.3 + 400 * POWER(1 - f.fuera / 0.6E0, 3)
        ELSE 0.3E0
    END AS lux) lc;

/* ---------------------------------------------------------------------
   4. Condiciones ambientales por zona y hora
   --------------------------------------------------------------------- */
RAISERROR(N'4/10 Condiciones ambientales...', 0, 1) WITH NOWAIT;
INSERT INTO dbo.condicion_ambiental (zona_id, fecha_hora, temperatura_c, humedad_pct, nubosidad_pct, precipitacion_mm, luz_natural_lux, origen_id)
SELECT
    z.zona_id,
    s.fecha_hora,
    CAST(ROUND(t.temp, 1) AS DECIMAL(4,1)),
    CAST(ROUND(hu.hum, 1) AS DECIMAL(4,1)),
    CAST(ROUND(nb.nub * 100, 1) AS DECIMAL(4,1)),
    CAST(ROUND(pr.mm, 2) AS DECIMAL(5,2)),
    CAST(ROUND(s.lux_claro * (1 - 0.75 * nb.nub), 1) AS DECIMAL(9,1)),
    1
FROM #slot s
JOIN #dia d ON d.fecha = s.fecha
CROSS JOIN dbo.zona z
CROSS APPLY (SELECT HASHBYTES('MD5', CONCAT('amb:', z.zona_id, ':', s.n)) AS h) hx
CROSS APPLY (SELECT
    CAST(SUBSTRING(hx.h, 1, 3) AS INT)  / 16777215.0E0 AS r1,
    CAST(SUBSTRING(hx.h, 4, 3) AS INT)  / 16777215.0E0 AS r2,
    CAST(SUBSTRING(hx.h, 7, 3) AS INT)  / 16777215.0E0 AS r3,
    CAST(SUBSTRING(hx.h, 10, 3) AS INT) / 16777215.0E0 AS r4) r
CROSS APPLY (SELECT d.nub_dia + (r.r1 - 0.5) * 0.25 + CASE WHEN s.hora BETWEEN 13 AND 18 THEN 0.08 ELSE 0 END AS nub0) n0
CROSS APPLY (SELECT CASE WHEN n0.nub0 < 0 THEN 0.0E0 WHEN n0.nub0 > 1 THEN 1.0E0 ELSE n0.nub0 END AS nub) nb
CROSS APPLY (SELECT CASE WHEN nb.nub > 0.78 AND r.r2 < (nb.nub - 0.70) * 1.6 THEN 0.2 + r.r3 * 4.5 * nb.nub ELSE 0.0E0 END AS mm) pr
CROSS APPLY (SELECT
    7.5E0 + CASE MONTH(s.fecha) WHEN 7 THEN -0.8 WHEN 8 THEN -0.5 ELSE 0 END AS tmin,
    19.5E0 + (1 - d.nub_dia) * 2.5 AS tmax,
    CASE WHEN s.hora <= 5 THEN 0.15 - 0.03 * s.hora
         WHEN s.hora <= 14 THEN (s.hora - 5) / 9.0E0
         ELSE 1 - (s.hora - 14) * 0.085 END AS ciclo) c
CROSS APPLY (SELECT c.tmin + (c.tmax - c.tmin) * c.ciclo
                    - CASE WHEN pr.mm > 0 THEN 1.5 ELSE 0 END
                    + CASE z.codigo WHEN 'AVC' THEN 1.0 WHEN 'PLZ' THEN 0.8 WHEN 'HOS' THEN 0.5 ELSE 0 END
                    + (r.r4 - 0.5) * 1.2 AS temp) t
CROSS APPLY (SELECT 97 - (t.temp - c.tmin) * 3.2 + nb.nub * 6 + CASE WHEN pr.mm > 0 THEN 6 ELSE 0 END AS hum0) h0
CROSS APPLY (SELECT CASE WHEN h0.hum0 > 100 THEN 100.0E0 WHEN h0.hum0 < 40 THEN 40.0E0 ELSE h0.hum0 END AS hum) hu
WHERE s.minuto = 0
ORDER BY s.fecha_hora, z.zona_id;

/* ---------------------------------------------------------------------
   5. Luminarias con su zona, potencia y sensores asociados
   --------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#lum') IS NOT NULL DROP TABLE #lum;
CREATE TABLE #lum (
    luminaria_id         SMALLINT     NOT NULL PRIMARY KEY,
    codigo               VARCHAR(10)  NOT NULL,
    zona_id              TINYINT      NOT NULL,
    ubicacion_id         SMALLINT     NOT NULL,
    tipo_zona            VARCHAR(15)  NOT NULL,
    es_fisica            BIT          NOT NULL,
    potencia_nominal_w   FLOAT        NOT NULL,
    sensor_luz_id        SMALLINT     NULL,
    sensor_presencia_id  SMALLINT     NULL
);
INSERT INTO #lum
SELECT l.luminaria_id, l.codigo, u.zona_id, l.ubicacion_id, z.tipo_zona, l.es_fisica, mo.potencia_nominal_w, sl.sensor_id, sp.sensor_id
FROM dbo.luminaria l
JOIN dbo.ubicacion u ON u.ubicacion_id = l.ubicacion_id
JOIN dbo.zona z ON z.zona_id = u.zona_id
JOIN dbo.modelo_luminaria mo ON mo.modelo_id = l.modelo_id
OUTER APPLY (SELECT TOP (1) s.sensor_id FROM dbo.sensor s JOIN dbo.ubicacion us ON us.ubicacion_id = s.ubicacion_id
             WHERE s.tipo_sensor_id = 1 AND us.zona_id = u.zona_id ORDER BY s.sensor_id) sl
OUTER APPLY (SELECT TOP (1) s.sensor_id FROM dbo.sensor s JOIN dbo.ubicacion us ON us.ubicacion_id = s.ubicacion_id
             WHERE s.tipo_sensor_id = 2 AND us.zona_id = u.zona_id
             ORDER BY CASE WHEN s.ubicacion_id = l.ubicacion_id THEN 0 ELSE 1 END, s.sensor_id) sp;

/* ---------------------------------------------------------------------
   6. Fallas: hasta 3 por luminaria, una en cada tercio del periodo
   (los tercios no se solapan, así una luminaria no tiene dos fallas
   simultáneas). Algunas del último tercio quedan abiertas.
   --------------------------------------------------------------------- */
RAISERROR(N'5/10 Fallas...', 0, 1) WITH NOWAIT;
;WITH c AS (
    SELECT l.luminaria_id, l.codigo, l.es_fisica, l.sensor_luz_id, l.sensor_presencia_id, s.seg,
           HASHBYTES('MD5', CONCAT('falla:', l.luminaria_id, ':', s.seg)) AS h
    FROM #lum l
    CROSS JOIN (VALUES (0), (1), (2)) s (seg)
), r AS (
    SELECT c.*,
        CAST(SUBSTRING(c.h, 1, 3) AS INT)  / 16777215.0E0 AS r1,
        CAST(SUBSTRING(c.h, 4, 3) AS INT)  / 16777215.0E0 AS r2,
        CAST(SUBSTRING(c.h, 7, 3) AS INT)  / 16777215.0E0 AS r3,
        CAST(SUBSTRING(c.h, 10, 3) AS INT) / 16777215.0E0 AS r4,
        CAST(SUBSTRING(c.h, 13, 3) AS INT) / 16777215.0E0 AS r5
    FROM c
), t AS (
    SELECT r.*,
        CASE WHEN r.r2 < 0.16 THEN 1 WHEN r.r2 < 0.30 THEN 2 WHEN r.r2 < 0.45 THEN 3 WHEN r.r2 < 0.58 THEN 4
             WHEN r.r2 < 0.83 THEN 5 WHEN r.r2 < 0.92 THEN 6 ELSE 7 END AS tipo_falla_id
    FROM r
    WHERE r.r1 < CASE WHEN r.es_fisica = 1 THEN 0.30 ELSE 0.42 END
), v AS (
    SELECT t.*,
        DATEADD(MINUTE, 15 * (t.seg * 5208 + 96 + CAST(FLOOR(t.r4 * 4300) AS INT)) + CAST(t.r3 * 1000 AS INT) % 14, @inicio) AS inicio,
        CASE t.tipo_falla_id WHEN 1 THEN 18 + t.r3 * 60 WHEN 2 THEN 12 + t.r3 * 72 WHEN 3 THEN 24 + t.r3 * 96
             WHEN 4 THEN 36 + t.r3 * 144 WHEN 5 THEN 1 + t.r3 * 10 WHEN 6 THEN 1 + t.r3 * 5 ELSE 4 + t.r3 * 30 END AS horas,
        CASE t.tipo_falla_id WHEN 5 THEN 5 WHEN 4 THEN 600 WHEN 3 THEN 180 ELSE 15 END AS minutos_deteccion
    FROM t
), w AS (
    SELECT v.*,
        DATEADD(MINUTE, CAST(v.horas * 60 AS INT), v.inicio) AS fin_teorico,
        CASE WHEN (v.seg = 2 AND v.r5 < 0.30) OR DATEADD(MINUTE, CAST(v.horas * 60 AS INT), v.inicio) >= @fin THEN 1 ELSE 0 END AS abierta
    FROM v
)
INSERT INTO dbo.falla (luminaria_id, sensor_id, tipo_falla_id, origen_id, fecha_inicio, fecha_deteccion, fecha_resolucion, estado, descripcion)
SELECT
    w.luminaria_id,
    CASE w.tipo_falla_id WHEN 3 THEN w.sensor_luz_id WHEN 4 THEN w.sensor_presencia_id ELSE NULL END,
    w.tipo_falla_id,
    1,
    w.inicio,
    DATEADD(MINUTE, w.minutos_deteccion, w.inicio),
    CASE WHEN w.abierta = 1 THEN NULL ELSE w.fin_teorico END,
    CASE WHEN w.abierta = 0 THEN 'RESUELTA' WHEN w.r5 < 0.12 THEN 'EN_ATENCION' ELSE 'ABIERTA' END,
    CONCAT(tf.nombre, N' · ', w.codigo)
FROM w
JOIN dbo.tipo_falla tf ON tf.tipo_falla_id = w.tipo_falla_id
ORDER BY w.inicio, w.luminaria_id;

/* ---------------------------------------------------------------------
   7. Mantenimientos: correctivos (uno por falla) y preventivos
   (cada 45 días por luminaria, de mayo a diciembre de 2026)
   --------------------------------------------------------------------- */
RAISERROR(N'6/10 Mantenimientos...', 0, 1) WITH NOWAIT;
INSERT INTO dbo.mantenimiento (luminaria_id, tipo_mantenimiento_id, tecnico_id, falla_id, origen_id, fecha_programada, fecha_inicio, fecha_fin, estado, costo_cop, observaciones)
SELECT
    f.luminaria_id,
    tm.tipo_mantenimiento_id,
    CASE WHEN l.es_fisica = 1 THEN 5 ELSE 1 + CAST(FLOOR(r.r1 * 4) AS INT) END,
    f.falla_id,
    1,
    CASE WHEN f.fecha_resolucion IS NULL THEN DATEADD(HOUR, 18 + CAST(r.r2 * 96 AS INT), f.fecha_deteccion) ELSE DATEADD(HOUR, 1, f.fecha_deteccion) END,
    CASE WHEN f.fecha_resolucion IS NULL THEN NULL ELSE ini.fecha_inicio END,
    f.fecha_resolucion,
    CASE WHEN f.fecha_resolucion IS NULL THEN 'PROGRAMADO' ELSE 'REALIZADO' END,
    CASE WHEN f.fecha_resolucion IS NULL THEN NULL
         ELSE CAST(ROUND(cb.base * (0.8 + r.r3 * 0.5) * CASE WHEN l.es_fisica = 1 THEN 0.1 ELSE 1 END, -2) AS DECIMAL(12,2)) END,
    CONCAT(N'Correctivo por falla: ', tf.nombre)
FROM dbo.falla f
JOIN #lum l ON l.luminaria_id = f.luminaria_id
JOIN dbo.tipo_falla tf ON tf.tipo_falla_id = f.tipo_falla_id
CROSS APPLY (SELECT CASE f.tipo_falla_id WHEN 1 THEN 4 WHEN 2 THEN 5 WHEN 3 THEN 7 WHEN 4 THEN 7 WHEN 5 THEN 6 ELSE 5 END AS tipo_mantenimiento_id) tm
JOIN dbo.tipo_mantenimiento tmd ON tmd.tipo_mantenimiento_id = tm.tipo_mantenimiento_id
CROSS APPLY (SELECT HASHBYTES('MD5', CONCAT('corr:', f.falla_id)) AS h) hx
CROSS APPLY (SELECT
    CAST(SUBSTRING(hx.h, 1, 3) AS INT) / 16777215.0E0 AS r1,
    CAST(SUBSTRING(hx.h, 4, 3) AS INT) / 16777215.0E0 AS r2,
    CAST(SUBSTRING(hx.h, 7, 3) AS INT) / 16777215.0E0 AS r3,
    CAST(SUBSTRING(hx.h, 10, 3) AS INT) / 16777215.0E0 AS r4) r
CROSS APPLY (SELECT CASE tm.tipo_mantenimiento_id WHEN 4 THEN 280000 WHEN 5 THEN 190000 WHEN 6 THEN 70000 ELSE 95000 END AS base) cb
CROSS APPLY (SELECT CAST(tmd.duracion_estimada_min * (0.7 + r.r4 * 0.6) AS INT) AS minutos) du
CROSS APPLY (SELECT CASE WHEN DATEADD(MINUTE, -du.minutos, f.fecha_resolucion) < DATEADD(MINUTE, 10, f.fecha_deteccion)
                         THEN DATEADD(MINUTE, 10, f.fecha_deteccion)
                         ELSE DATEADD(MINUTE, -du.minutos, f.fecha_resolucion) END AS fecha_inicio) ini
WHERE f.origen_id = 1
ORDER BY f.fecha_deteccion;

;WITH k AS (
    SELECT TOP (6) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) - 1 AS k
    FROM sys.all_objects
), p AS (
    SELECT l.luminaria_id, l.es_fisica, k.k,
           1 + (k.k + l.luminaria_id) % 3 AS tipo_mantenimiento_id,
           HASHBYTES('MD5', CONCAT('prev:', l.luminaria_id, ':', k.k)) AS h
    FROM #lum l CROSS JOIN k
), q AS (
    SELECT p.*,
        CAST(SUBSTRING(p.h, 1, 3) AS INT) / 16777215.0E0 AS r1,
        CAST(SUBSTRING(p.h, 4, 3) AS INT) / 16777215.0E0 AS r2,
        CAST(SUBSTRING(p.h, 7, 3) AS INT) / 16777215.0E0 AS r3,
        CAST(SUBSTRING(p.h, 10, 3) AS INT) / 16777215.0E0 AS r4,
        DATEADD(MINUTE, CAST((CAST(SUBSTRING(p.h, 1, 3) AS INT) / 16777215.0E0) * 420 AS INT),
            DATEADD(HOUR, 8, CAST(DATEADD(DAY, (p.luminaria_id * 7) % 45 + 45 * p.k, CAST('20260503' AS DATE)) AS DATETIME2(0)))) AS programada
    FROM p
), e AS (
    SELECT q.*,
        CASE WHEN q.programada >= DATEADD(DAY, -3, @fin) THEN 'PROGRAMADO'
             WHEN q.r2 < 0.03 THEN 'CANCELADO'
             ELSE 'REALIZADO' END AS estado,
        DATEADD(MINUTE, CAST(q.r3 * 90 AS INT) + CASE WHEN q.r2 > 0.90 THEN 2880 ELSE 0 END, q.programada) AS inicio_real
    FROM q
    WHERE q.programada <= '2026-12-31T23:59:59'
)
INSERT INTO dbo.mantenimiento (luminaria_id, tipo_mantenimiento_id, tecnico_id, falla_id, origen_id, fecha_programada, fecha_inicio, fecha_fin, estado, costo_cop, observaciones)
SELECT
    e.luminaria_id,
    e.tipo_mantenimiento_id,
    CASE WHEN e.es_fisica = 1 THEN 5 ELSE 1 + CAST(FLOOR(e.r1 * 4) AS INT) END,
    NULL,
    1,
    e.programada,
    CASE WHEN e.estado = 'REALIZADO' THEN e.inicio_real END,
    CASE WHEN e.estado = 'REALIZADO' THEN DATEADD(MINUTE, CAST(tm.duracion_estimada_min * (0.8 + e.r4 * 0.5) AS INT), e.inicio_real) END,
    e.estado,
    CASE WHEN e.estado = 'REALIZADO'
         THEN CAST(ROUND(CASE e.tipo_mantenimiento_id WHEN 1 THEN 45000 WHEN 2 THEN 30000 ELSE 38000 END
                         * (0.85 + e.r4 * 0.3) * CASE WHEN e.es_fisica = 1 THEN 0.1 ELSE 1 END, -2) AS DECIMAL(12,2)) END,
    CASE e.estado WHEN 'CANCELADO' THEN N'Cancelado por lluvia' WHEN 'PROGRAMADO' THEN N'Pendiente de ejecución' ELSE N'Preventivo realizado' END
FROM e
JOIN dbo.tipo_mantenimiento tm ON tm.tipo_mantenimiento_id = e.tipo_mantenimiento_id
ORDER BY e.programada, e.luminaria_id;

/* ---------------------------------------------------------------------
   8. Ventanas de falla y de mantenimiento en índices de intervalo
   --------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#ventana') IS NOT NULL DROP TABLE #ventana;
CREATE TABLE #ventana (
    luminaria_id   SMALLINT  NOT NULL,
    slot_ini       INT       NOT NULL,
    slot_fin       INT       NOT NULL,
    clase          CHAR(1)   NOT NULL,
    tipo_falla_id  TINYINT   NULL,
    prioridad      TINYINT   NOT NULL
);
INSERT INTO #ventana (luminaria_id, slot_ini, slot_fin, clase, tipo_falla_id, prioridad)
SELECT f.luminaria_id,
       DATEDIFF(MINUTE, @inicio, f.fecha_inicio) / 15,
       CASE WHEN f.fecha_resolucion IS NULL THEN @slots + 1 ELSE (DATEDIFF(MINUTE, @inicio, f.fecha_resolucion) + 14) / 15 END,
       'F', f.tipo_falla_id, 2
FROM dbo.falla f
WHERE f.origen_id = 1;
INSERT INTO #ventana (luminaria_id, slot_ini, slot_fin, clase, tipo_falla_id, prioridad)
SELECT m.luminaria_id,
       DATEDIFF(MINUTE, @inicio, m.fecha_inicio) / 15,
       (DATEDIFF(MINUTE, @inicio, m.fecha_fin) + 14) / 15,
       'M', NULL, 1
FROM dbo.mantenimiento m
WHERE m.origen_id = 1 AND m.estado = 'REALIZADO' AND m.fecha_inicio < @fin;
CREATE CLUSTERED INDEX IX_ventana ON #ventana (luminaria_id, slot_ini);

/* ---------------------------------------------------------------------
   9. MEDICIONES: 5 lotes × 200.000 = 1.000.000 de filas
   Reglas por intervalo (las mismas del firmware de la maqueta):
     · luz < 40 lux  → noche
     · noche sin gente → 25 % (15 % de 2:00 a 4:59)
     · detecciones del PIR suben el brillo hacia 100 % (60 % en modo ahorro)
     · fallas y mantenimientos cambian el estado y las lecturas
   Problemas de calidad incluidos a propósito para el ETL:
     · ~0,2 % sin lectura de luz, ~0,15 % sin tensión,
       ~0,03 % con energía negativa (error de signo),
       intervalos sin datos eléctricos durante fallas de comunicación.
   --------------------------------------------------------------------- */
DECLARE @lote INT = 0;
DECLARE @por_lote INT = @slots / @lotes;
WHILE @lote < @lotes
BEGIN
    SET @msg = CONCAT(N'7/10 Mediciones: lote ', @lote + 1, N' de ', @lotes, N'...');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    INSERT INTO dbo.medicion WITH (TABLOCK)
        (luminaria_id, sensor_luz_id, sensor_presencia_id, estado_id, origen_id, fecha_hora, es_noche,
         lectura_ldr, nivel_luz_lux, detecciones, brillo_pct, tension_v, corriente_a, potencia_w, energia_wh, temperatura_c, es_anomala)
    SELECT
        l.luminaria_id,
        l.sensor_luz_id,
        l.sensor_presencia_id,
        e.estado_id,
        1,
        s.fecha_hora,
        a.es_noche,
        CASE WHEN q.nulo_luz = 1 THEN NULL WHEN w.fa = 3 THEN CAST(4095 AS SMALLINT) ELSE CAST(ROUND(a.ldr, 0) AS SMALLINT) END,
        CASE WHEN q.nulo_luz = 1 OR w.fa = 3 THEN NULL ELSE CAST(ROUND(a.lux, 1) AS DECIMAL(9,1)) END,
        CAST(p.det AS SMALLINT),
        CAST(ROUND(b.brillo, 1) AS DECIMAL(5,1)),
        CASE WHEN q.nulo_elec = 1 THEN NULL ELSE CAST(ROUND(el.tension, 2) AS DECIMAL(6,2)) END,
        CASE WHEN q.nulo_elec = 1 THEN NULL ELSE CAST(ROUND(el.corriente, 3) AS DECIMAL(7,3)) END,
        CASE WHEN q.nulo_pot = 1 THEN NULL ELSE CAST(ROUND(el.potencia, 2) AS DECIMAL(8,2)) END,
        CASE WHEN q.nulo_pot = 1 THEN NULL
             WHEN q.signo_err = 1 THEN -CAST(ROUND(el.potencia * 0.25, 3) AS DECIMAL(10,3))
             ELSE CAST(ROUND(el.potencia * 0.25, 3) AS DECIMAL(10,3)) END,
        CASE WHEN q.nulo_pot = 1 THEN NULL ELSE CAST(ROUND(el.temp, 1) AS DECIMAL(5,1)) END,
        el.anomala
    FROM #slot s
    CROSS JOIN #lum l
    JOIN dbo.condicion_ambiental ca ON ca.zona_id = l.zona_id AND ca.fecha_hora = s.hora_redonda
    CROSS APPLY (SELECT HASHBYTES('MD5', CONCAT('med:', l.luminaria_id, ':', s.n)) AS h) hx
    CROSS APPLY (SELECT
        CAST(SUBSTRING(hx.h, 1, 3) AS INT)  / 16777215.0E0 AS r1,
        CAST(SUBSTRING(hx.h, 4, 3) AS INT)  / 16777215.0E0 AS r2,
        CAST(SUBSTRING(hx.h, 7, 3) AS INT)  / 16777215.0E0 AS r3,
        CAST(SUBSTRING(hx.h, 10, 3) AS INT) / 16777215.0E0 AS r4,
        CAST(SUBSTRING(hx.h, 13, 3) AS INT) / 16777215.0E0 AS r5) r
    OUTER APPLY (SELECT TOP (1) v.clase, v.tipo_falla_id
                 FROM #ventana v
                 WHERE v.luminaria_id = l.luminaria_id AND v.slot_ini <= s.n AND v.slot_fin > s.n
                 ORDER BY v.prioridad) vv
    CROSS APPLY (SELECT CASE WHEN vv.clase = 'M' THEN 1 ELSE 0 END AS en_mant,
                        CASE WHEN vv.clase = 'F' THEN vv.tipo_falla_id ELSE 0 END AS fa) w
    CROSS APPLY (SELECT s.lux_claro * (1 - 0.75 * ca.nubosidad_pct / 100.0E0) * (0.92 + r.r1 * 0.16) AS lux) a0
    CROSS APPLY (SELECT a0.lux AS lux,
                        CASE WHEN a0.lux < 40 THEN 1 ELSE 0 END AS es_noche,
                        CASE WHEN 4095 - LOG10(1 + a0.lux) * 800 < 0 THEN 0.0E0 ELSE 4095 - LOG10(1 + a0.lux) * 800 END AS ldr) a
    CROSS APPLY (SELECT
        CASE l.tipo_zona
            WHEN 'RESIDENCIAL'  THEN CASE WHEN s.hora BETWEEN 18 AND 20 THEN 4.0 WHEN s.hora BETWEEN 21 AND 22 THEN 1.6
                                          WHEN s.hora BETWEEN 5 AND 6 THEN 2.5 WHEN s.hora = 23 OR s.hora <= 4 THEN 0.25 ELSE 3.0 END
            WHEN 'VIAL'         THEN CASE WHEN s.hora BETWEEN 17 AND 20 THEN 9.0 WHEN s.hora BETWEEN 21 AND 23 THEN 4.0
                                          WHEN s.hora BETWEEN 5 AND 6 THEN 6.0 WHEN s.hora <= 4 THEN 1.0 ELSE 8.0 END
            WHEN 'HOSPITALARIA' THEN CASE WHEN s.hora BETWEEN 18 AND 22 THEN 5.0 WHEN s.hora = 23 OR s.hora <= 4 THEN 2.5
                                          WHEN s.hora BETWEEN 5 AND 6 THEN 4.0 ELSE 6.0 END
            ELSE                     CASE WHEN s.hora BETWEEN 18 AND 21 THEN 10.0 WHEN s.hora BETWEEN 22 AND 23 THEN 3.0
                                          WHEN s.hora <= 4 THEN 0.3 WHEN s.hora BETWEEN 5 AND 6 THEN 1.5 ELSE 9.0 END
        END
        * CASE WHEN s.fin_semana = 1 AND l.tipo_zona = 'COMERCIAL' AND s.hora >= 18 THEN 1.4
               WHEN s.fin_semana = 1 AND l.tipo_zona = 'VIAL' THEN 0.75 ELSE 1.0 END
        * CASE WHEN ca.precipitacion_mm > 0 THEN 0.55 ELSE 1.0 END AS lambda) lm
    CROSS APPLY (SELECT CASE WHEN w.fa = 4 THEN 0.0E0 ELSE FLOOR(lm.lambda * (0.35 + 1.3 * r.r2)) END AS det) p
    CROSS APPLY (SELECT CASE WHEN p.det * 0.35 > 15 THEN 15.0E0 ELSE p.det * 0.35 END AS min100,
                        CASE WHEN s.hora BETWEEN 2 AND 4 THEN 15 ELSE 25 END AS base,
                        CASE WHEN s.ahorro_noche = 1 THEN 60 ELSE 100 END AS techo) pr
    CROSS APPLY (SELECT CASE
            WHEN w.en_mant = 1 THEN 8
            WHEN w.fa IN (1, 6, 7) THEN 7
            WHEN a.es_noche = 0 AND w.fa = 3 THEN 6
            WHEN a.es_noche = 0 THEN 1
            WHEN pr.min100 >= 3 THEN CASE WHEN s.ahorro_noche = 1 THEN 5 ELSE 4 END
            WHEN pr.base = 15 THEN 3
            ELSE 2 END AS estado_id) e
    CROSS APPLY (SELECT CASE
            WHEN e.estado_id IN (1, 7, 8) THEN 0.0E0
            WHEN e.estado_id = 6 THEN 25.0E0
            ELSE pr.base + (pr.techo - pr.base) * pr.min100 / 15.0E0 END AS brillo0) b0
    CROSS APPLY (SELECT CASE WHEN w.fa = 2 AND b0.brillo0 > 0
                             THEN CASE WHEN b0.brillo0 * (0.6 + 0.5 * r.r3) > 100 THEN 100.0E0 ELSE b0.brillo0 * (0.6 + 0.5 * r.r3) END
                             ELSE b0.brillo0 END AS brillo) b
    CROSS APPLY (SELECT
        CASE WHEN w.fa = 7 THEN 0.0E0
             WHEN w.fa = 6 THEN 252 + r.r4 * 16
             WHEN r.r5 < 0.004 THEN 194 + r.r4 * 10
             ELSE 220 * (0.985 + r.r4 * 0.03) END AS tension,
        CASE WHEN w.fa = 7 THEN 0.0E0
             WHEN e.estado_id IN (7, 8) THEN 1.5E0
             ELSE l.potencia_nominal_w * b.brillo / 100.0E0 * CASE WHEN w.fa = 2 THEN 1.3 ELSE 1.0 END + 1.5 END AS potencia) el0
    CROSS APPLY (SELECT
        el0.tension AS tension,
        el0.potencia AS potencia,
        CASE WHEN el0.tension > 0 THEN el0.potencia / el0.tension ELSE 0.0E0 END AS corriente,
        ca.temperatura_c + CASE WHEN b.brillo > 0 THEN 3 + 9 * b.brillo / 100.0E0 ELSE 0.5 END + (r.r3 - 0.5) AS temp,
        CASE WHEN e.estado_id = 6 OR w.fa IN (2, 6, 7) OR el0.tension < 205 OR el0.tension > 235 THEN 1 ELSE 0 END AS anomala) el
    CROSS APPLY (SELECT
        CASE WHEN w.fa = 5 OR (r.r5 >= 0.950 AND r.r5 < 0.952) THEN 1 ELSE 0 END AS nulo_luz,
        CASE WHEN w.fa = 5 OR (r.r5 >= 0.960 AND r.r5 < 0.9615) THEN 1 ELSE 0 END AS nulo_elec,
        CASE WHEN w.fa = 5 THEN 1 ELSE 0 END AS nulo_pot,
        CASE WHEN r.r5 >= 0.970 AND r.r5 < 0.9703 THEN 1 ELSE 0 END AS signo_err) q
    WHERE s.n >= @lote * @por_lote
      AND s.n < (@lote + 1) * @por_lote
    ORDER BY s.n, l.luminaria_id;

    SET @lote += 1;
END

DECLARE @total_med INT = (SELECT COUNT(*) FROM dbo.medicion WHERE origen_id = 1);
SET @msg = CONCAT(N'   Mediciones simuladas: ', FORMAT(@total_med, 'N0', 'es-CO'));
RAISERROR(@msg, 0, 1) WITH NOWAIT;
IF @total_med <> 1000000
    RAISERROR(N'ATENCIÓN: no se generaron exactamente 1.000.000 de mediciones.', 16, 1);

/* ---------------------------------------------------------------------
   10. Eventos operativos derivados de los cambios de estado,
       de las fallas y de los mantenimientos
   --------------------------------------------------------------------- */
RAISERROR(N'8/10 Eventos operativos...', 0, 1) WITH NOWAIT;
INSERT INTO dbo.evento_operativo
    (luminaria_id, ubicacion_id, tipo_evento_id, origen_id, fecha_hora, estado_anterior_id, estado_nuevo_id,
     brillo_anterior, brillo_nuevo, falla_id, mantenimiento_id, detalle)
SELECT x.luminaria_id, l.ubicacion_id, x.tipo_evento_id, 1, x.fecha_hora, x.estado_anterior_id, x.estado_nuevo_id,
       x.brillo_anterior, x.brillo_nuevo, x.falla_id, x.mantenimiento_id, x.detalle
FROM (
    SELECT
        m.luminaria_id,
        CASE WHEN m.estado_id IN (2, 3, 4, 5, 6) AND m.estado_ant IN (1, 7, 8) THEN 1
             WHEN m.estado_id = 1 AND m.estado_ant IN (2, 3, 4, 5, 6) THEN 2
             WHEN m.estado_id = 5 THEN 10
             ELSE 3 END AS tipo_evento_id,
        m.fecha_hora,
        m.estado_ant AS estado_anterior_id,
        m.estado_id AS estado_nuevo_id,
        m.brillo_ant AS brillo_anterior,
        m.brillo_pct AS brillo_nuevo,
        CAST(NULL AS INT) AS falla_id,
        CAST(NULL AS INT) AS mantenimiento_id,
        CAST(NULL AS NVARCHAR(200)) AS detalle
    FROM (
        SELECT luminaria_id, fecha_hora, estado_id, brillo_pct,
               LAG(estado_id) OVER (PARTITION BY luminaria_id ORDER BY fecha_hora, medicion_id) AS estado_ant,
               LAG(brillo_pct) OVER (PARTITION BY luminaria_id ORDER BY fecha_hora, medicion_id) AS brillo_ant
        FROM dbo.medicion
        WHERE origen_id = 1
    ) m
    WHERE m.estado_ant IS NOT NULL
      AND m.estado_ant <> m.estado_id
      AND m.estado_id NOT IN (7, 8)
      AND NOT (m.estado_ant IN (7, 8) AND m.estado_id = 1)
    UNION ALL
    SELECT f.luminaria_id, 6, f.fecha_deteccion, NULL, NULL, NULL, NULL, f.falla_id, NULL, f.descripcion
    FROM dbo.falla f WHERE f.origen_id = 1
    UNION ALL
    SELECT f.luminaria_id, 7, f.fecha_resolucion, NULL, NULL, NULL, NULL, f.falla_id, NULL, f.descripcion
    FROM dbo.falla f WHERE f.origen_id = 1 AND f.fecha_resolucion IS NOT NULL AND f.fecha_resolucion < @fin
    UNION ALL
    SELECT mt.luminaria_id, 8, mt.fecha_inicio, NULL, NULL, NULL, NULL, mt.falla_id, mt.mantenimiento_id, tm.nombre
    FROM dbo.mantenimiento mt JOIN dbo.tipo_mantenimiento tm ON tm.tipo_mantenimiento_id = mt.tipo_mantenimiento_id
    WHERE mt.origen_id = 1 AND mt.estado = 'REALIZADO' AND mt.fecha_inicio < @fin
    UNION ALL
    SELECT mt.luminaria_id, 9, mt.fecha_fin, NULL, NULL, NULL, NULL, mt.falla_id, mt.mantenimiento_id, tm.nombre
    FROM dbo.mantenimiento mt JOIN dbo.tipo_mantenimiento tm ON tm.tipo_mantenimiento_id = mt.tipo_mantenimiento_id
    WHERE mt.origen_id = 1 AND mt.estado = 'REALIZADO' AND mt.fecha_fin < @fin
) x
JOIN dbo.luminaria l ON l.luminaria_id = x.luminaria_id
ORDER BY x.fecha_hora, x.luminaria_id;

/* ---------------------------------------------------------------------
   11. Contador de luces de las viviendas (una lectura por hora)
   --------------------------------------------------------------------- */
RAISERROR(N'9/10 Contador de luces de viviendas...', 0, 1) WITH NOWAIT;
INSERT INTO dbo.registro_luces_vivienda (vivienda_id, origen_id, fecha_hora, luces_encendidas, luces_apagadas)
SELECT v.vivienda_id, 1, s.fecha_hora, x.enc, v.numero_luces - x.enc
FROM #slot s
CROSS JOIN dbo.vivienda v
CROSS APPLY (SELECT HASHBYTES('MD5', CONCAT('viv:', v.vivienda_id, ':', s.n)) AS h) hx
CROSS APPLY (SELECT
    CAST(SUBSTRING(hx.h, 1, 3) AS INT)  / 16777215.0E0 AS r1,
    CAST(SUBSTRING(hx.h, 4, 3) AS INT)  / 16777215.0E0 AS r2,
    CAST(SUBSTRING(hx.h, 7, 3) AS INT)  / 16777215.0E0 AS r3,
    CAST(SUBSTRING(hx.h, 10, 3) AS INT) / 16777215.0E0 AS r4) r
CROSS APPLY (SELECT CASE WHEN s.hora <= 4 THEN 0.05
                         WHEN s.hora <= 6 THEN CASE WHEN s.fin_semana = 1 THEN 0.20 ELSE 0.45 END
                         WHEN s.hora <= 16 THEN 0.08
                         WHEN s.hora = 17 THEN 0.30
                         WHEN s.hora <= 21 THEN 0.75
                         WHEN s.hora = 22 THEN 0.40
                         ELSE 0.18 END AS p) pp
CROSS APPLY (SELECT CAST(
                 CASE WHEN r.r1 < pp.p THEN 1 ELSE 0 END
               + CASE WHEN r.r2 < pp.p THEN 1 ELSE 0 END
               + CASE WHEN v.numero_luces >= 3 AND r.r3 < pp.p THEN 1 ELSE 0 END
               + CASE WHEN v.numero_luces >= 4 AND r.r4 < pp.p THEN 1 ELSE 0 END AS TINYINT) AS enc) x
WHERE s.minuto = 0
ORDER BY s.fecha_hora, v.vivienda_id;

/* ---------------------------------------------------------------------
   12. Consumo diario (calculado)
   --------------------------------------------------------------------- */
RAISERROR(N'10/10 Consumo diario por luminaria...', 0, 1) WITH NOWAIT;
EXEC dbo.sp_calcular_consumo_diario @desde = NULL;

SET @msg = CONCAT(N'Listo en ', DATEDIFF(SECOND, @t0, SYSDATETIME()), N' segundos.');
RAISERROR(@msg, 0, 1) WITH NOWAIT;

SELECT tabla, filas, categoria
FROM dbo.vw_meta_tablas
ORDER BY filas DESC;
GO
