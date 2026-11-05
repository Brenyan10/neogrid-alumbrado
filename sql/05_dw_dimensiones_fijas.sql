/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   05_dw_dimensiones_fijas.sql
   Llena las dimensiones que no vienen del modelo relacional:
     · dim_tiempo  (2026-01-01 a 2027-12-31 + fila 0 "desconocido")
     · dim_hora    (96 intervalos de 15 minutos)
     · dim_calidad_dato (4 combinaciones de imputado / anómalo)
   y los miembros "sin sensor" y "sin asignar" de dim_sensor y dim_tecnico.
   Festivos: calendario oficial de Colombia (Ley 51 de 1983) para 2026 y 2027.
   Requiere: 04_dw_esquema.sql
   Se puede ejecutar varias veces: cada parte se carga solo si falta,
   así que una ejecución interrumpida se completa al repetirla.
   ===================================================================== */
USE NeoGridDW;
GO
SET NOCOUNT ON;

/* Corrección para bases creadas con la primera versión del script 04:
   nombre_dia admitía 10 caracteres y «Desconocido» tiene 11. */
IF COL_LENGTH('dbo.dim_tiempo', 'nombre_dia') < 24
BEGIN
    ALTER TABLE dbo.dim_tiempo ALTER COLUMN nombre_dia NVARCHAR(12) NOT NULL;
    RAISERROR(N'dim_tiempo.nombre_dia ampliada a NVARCHAR(12).', 0, 1) WITH NOWAIT;
END
GO
SET NOCOUNT ON;

/* dim_tiempo -------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM dbo.dim_tiempo WHERE tiempo_key = 0)
    INSERT INTO dbo.dim_tiempo (tiempo_key, fecha, anio, semestre, trimestre, mes, nombre_mes, anio_mes, semana_anio,
                                dia_mes, dia_semana, nombre_dia, es_fin_semana, es_festivo, temporada)
    VALUES (0, '19000101', 1900, 0, 0, 0, N'Desconocido', '0000-00', 0, 0, 0, N'Desconocido', 0, 0, N'N/A');

IF NOT EXISTS (SELECT 1 FROM dbo.dim_tiempo WHERE tiempo_key > 0)
BEGIN
;WITH d AS (
    SELECT TOP (730) DATEADD(DAY, CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) - 1, CAST('20260101' AS DATE)) AS fecha
    FROM sys.all_objects
), festivo AS (
    SELECT CAST(f AS DATE) AS fecha
    FROM (VALUES
        ('20260101'), ('20260112'), ('20260323'), ('20260402'), ('20260403'), ('20260501'), ('20260518'),
        ('20260608'), ('20260615'), ('20260629'), ('20260720'), ('20260807'), ('20260817'), ('20261012'),
        ('20261102'), ('20261116'), ('20261208'), ('20261225'),
        ('20270101'), ('20270111'), ('20270322'), ('20270325'), ('20270326'), ('20270501'), ('20270510'),
        ('20270531'), ('20270607'), ('20270705'), ('20270720'), ('20270807'), ('20270816'), ('20271018'),
        ('20271101'), ('20271115'), ('20271208'), ('20271225')
    ) x (f)
)
INSERT INTO dbo.dim_tiempo (tiempo_key, fecha, anio, semestre, trimestre, mes, nombre_mes, anio_mes, semana_anio,
                            dia_mes, dia_semana, nombre_dia, es_fin_semana, es_festivo, temporada)
SELECT
    CAST(CONVERT(CHAR(8), d.fecha, 112) AS INT),
    d.fecha,
    YEAR(d.fecha),
    CASE WHEN MONTH(d.fecha) <= 6 THEN 1 ELSE 2 END,
    DATEPART(QUARTER, d.fecha),
    MONTH(d.fecha),
    CASE MONTH(d.fecha) WHEN 1 THEN N'Enero' WHEN 2 THEN N'Febrero' WHEN 3 THEN N'Marzo' WHEN 4 THEN N'Abril'
                        WHEN 5 THEN N'Mayo' WHEN 6 THEN N'Junio' WHEN 7 THEN N'Julio' WHEN 8 THEN N'Agosto'
                        WHEN 9 THEN N'Septiembre' WHEN 10 THEN N'Octubre' WHEN 11 THEN N'Noviembre' ELSE N'Diciembre' END,
    CONVERT(CHAR(7), d.fecha, 120),
    DATEPART(ISO_WEEK, d.fecha),
    DAY(d.fecha),
    ds.dia,
    CASE ds.dia WHEN 1 THEN N'Lunes' WHEN 2 THEN N'Martes' WHEN 3 THEN N'Miércoles' WHEN 4 THEN N'Jueves'
                WHEN 5 THEN N'Viernes' WHEN 6 THEN N'Sábado' ELSE N'Domingo' END,
    CASE WHEN ds.dia >= 6 THEN 1 ELSE 0 END,
    CASE WHEN fe.fecha IS NOT NULL THEN 1 ELSE 0 END,
    CASE WHEN MONTH(d.fecha) IN (3, 4, 5, 10, 11) THEN N'Lluviosa' ELSE N'Seca' END
FROM d
CROSS APPLY (SELECT (DATEDIFF(DAY, '20260105', d.fecha) % 7 + 7) % 7 + 1 AS dia) ds   -- 2026-01-05 fue lunes
LEFT JOIN festivo fe ON fe.fecha = d.fecha;
END

/* dim_hora ---------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM dbo.dim_hora)
BEGIN
;WITH n AS (
    SELECT TOP (96) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) - 1 AS i
    FROM sys.all_objects
)
INSERT INTO dbo.dim_hora (hora_key, hora, minuto, etiqueta, franja, es_horario_nocturno)
SELECT
    CAST((n.i / 4) * 100 + (n.i % 4) * 15 AS SMALLINT),
    n.i / 4,
    (n.i % 4) * 15,
    RIGHT(CONCAT('0', n.i / 4), 2) + ':' + RIGHT(CONCAT('0', (n.i % 4) * 15), 2),
    CASE WHEN n.i / 4 < 6 THEN N'Madrugada' WHEN n.i / 4 < 12 THEN N'Mañana' WHEN n.i / 4 < 18 THEN N'Tarde' ELSE N'Noche' END,
    CASE WHEN n.i / 4 >= 18 OR n.i / 4 < 6 THEN 1 ELSE 0 END
FROM n;
END

/* dim_calidad_dato ------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM dbo.dim_calidad_dato)
INSERT INTO dbo.dim_calidad_dato (calidad_key, codigo, descripcion, fue_imputado, es_anomalo) VALUES
 (1, 'ORIGINAL',           N'Registro completo y dentro de lo esperado.',                               0, 0),
 (2, 'IMPUTADO',           N'El ETL completó valores nulos o corrigió valores inconsistentes.',         1, 0),
 (3, 'ANOMALO',            N'Registro completo con un comportamiento anómalo (falla o tensión fuera de rango).', 0, 1),
 (4, 'IMPUTADO_Y_ANOMALO', N'Registro imputado y además anómalo.',                                      1, 1);

/* Miembros desconocidos ---------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM dbo.dim_sensor WHERE sensor_id = 0)
BEGIN
    SET IDENTITY_INSERT dbo.dim_sensor ON;
    INSERT INTO dbo.dim_sensor (sensor_key, sensor_id, codigo, tipo_codigo, tipo_nombre, magnitud, unidad, es_fisico, pin_gpio, modelo, ubicacion_codigo, zona_codigo, activo)
    VALUES (0, 0, 'SIN-SENSOR', 'N/A', N'Sin sensor asociado', N'N/A', N'N/A', 0, NULL, N'N/A', 'N/A', 'N/A', 0);
    SET IDENTITY_INSERT dbo.dim_sensor OFF;
END

IF NOT EXISTS (SELECT 1 FROM dbo.dim_tecnico WHERE tecnico_id = 0)
BEGIN
    SET IDENTITY_INSERT dbo.dim_tecnico ON;
    INSERT INTO dbo.dim_tecnico (tecnico_key, tecnico_id, codigo, nombre, especialidad, activo)
    VALUES (0, 0, 'N/A', N'Sin asignar', N'N/A', 0);
    SET IDENTITY_INSERT dbo.dim_tecnico OFF;
END

SELECT 'dim_tiempo' AS tabla, COUNT(*) AS filas FROM dbo.dim_tiempo
UNION ALL SELECT 'dim_hora', COUNT(*) FROM dbo.dim_hora
UNION ALL SELECT 'dim_calidad_dato', COUNT(*) FROM dbo.dim_calidad_dato
UNION ALL SELECT 'festivos', SUM(CAST(es_festivo AS INT)) FROM dbo.dim_tiempo;
-- Esperado: dim_tiempo 731 · dim_hora 96 · dim_calidad_dato 4 · festivos 36
GO
