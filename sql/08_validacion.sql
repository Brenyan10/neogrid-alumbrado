/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   08_validacion.sql
   Plan de pruebas automático: verifica volumen, integridad, coherencia de
   la simulación y coherencia entre el modelo relacional y el DW.
   Cada prueba devuelve PASA o REVISAR con el valor esperado y el obtenido.
   Ejecutar DESPUÉS de cargar los datos (03 y 10) y del ETL (SSIS o T-SQL).
   Tarda aproximadamente 1 minuto. 42 pruebas (20 del relacional, 22 del DW).
   ===================================================================== */
USE NeoGridDW;
GO
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#val') IS NOT NULL DROP TABLE #val;
CREATE TABLE #val (
    n         INT IDENTITY(1,1) PRIMARY KEY,
    modelo    NVARCHAR(20),
    prueba    NVARCHAR(160),
    esperado  NVARCHAR(60),
    obtenido  NVARCHAR(60),
    pasa      BIT
);

DECLARE @x BIGINT, @y BIGINT, @a DECIMAL(18,4), @b DECIMAL(18,4), @t1 DATETIME2(0), @t2 DATETIME2(0);

/* =============================== RELACIONAL =============================== */

-- R1 · Volumen exacto de la tabla principal
SELECT @x = COUNT_BIG(*) FROM NeoGridRelacional.dbo.medicion WHERE origen_id = 1;
INSERT #val VALUES (N'Relacional', N'R1 · Mediciones simuladas en la tabla principal', N'1.000.000',
                    FORMAT(@x, 'N0', 'es-CO'), CASE WHEN @x = 1000000 THEN 1 ELSE 0 END);

-- R2 · Cada luminaria tiene la serie completa de 15.625 intervalos
SELECT @x = COUNT(*) FROM (SELECT luminaria_id FROM NeoGridRelacional.dbo.medicion WHERE origen_id = 1
                           GROUP BY luminaria_id HAVING COUNT(*) = 15625) q;
INSERT #val VALUES (N'Relacional', N'R2 · Luminarias con la serie completa (15.625 intervalos c/u)', N'64',
                    CONCAT(@x, N''), CASE WHEN @x = 64 THEN 1 ELSE 0 END);

-- R3 · Sin duplicados por luminaria y fecha (datos simulados y físicos)
SELECT @x = COUNT(*) FROM (SELECT luminaria_id, fecha_hora FROM NeoGridRelacional.dbo.medicion WHERE origen_id IN (1, 2)
                           GROUP BY luminaria_id, fecha_hora HAVING COUNT(*) > 1) q;
INSERT #val VALUES (N'Relacional', N'R3 · Mediciones duplicadas (luminaria + fecha)', N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- R4 · Rango temporal de la simulación
SELECT @t1 = MIN(fecha_hora), @t2 = MAX(fecha_hora) FROM NeoGridRelacional.dbo.medicion WHERE origen_id = 1;
INSERT #val VALUES (N'Relacional', N'R4 · Rango de la simulación', N'2026-05-01 00:00 a 2026-10-10 18:00',
                    CONCAT(CONVERT(CHAR(16), @t1, 120), N' a ', CONVERT(CHAR(16), @t2, 120)),
                    CASE WHEN @t1 = '2026-05-01T00:00:00' AND @t2 = '2026-10-10T18:00:00' THEN 1 ELSE 0 END);

-- R5 · Todas las FK y CHECK están activas y verificadas (sin huérfanos posibles)
SELECT @x = (SELECT COUNT(*) FROM NeoGridRelacional.sys.foreign_keys WHERE is_disabled = 1 OR is_not_trusted = 1)
          + (SELECT COUNT(*) FROM NeoGridRelacional.sys.check_constraints WHERE is_disabled = 1 OR is_not_trusted = 1);
SELECT @y = (SELECT COUNT(*) FROM NeoGridRelacional.sys.foreign_keys) + (SELECT COUNT(*) FROM NeoGridRelacional.sys.check_constraints);
INSERT #val VALUES (N'Relacional', CONCAT(N'R5 · Restricciones deshabilitadas o no confiables (de ', @y, N' FK y CHECK)'), N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- R6 · DBCC CHECKCONSTRAINTS no encuentra filas que violen restricciones
IF OBJECT_ID('tempdb..#dbcc') IS NOT NULL DROP TABLE #dbcc;
CREATE TABLE #dbcc (tabla NVARCHAR(400), restriccion NVARCHAR(400), condicion NVARCHAR(4000));
BEGIN TRY
    INSERT INTO #dbcc EXEC NeoGridRelacional.sys.sp_executesql N'DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS, NO_INFOMSGS';
    SELECT @x = COUNT(*) FROM #dbcc;
    INSERT #val VALUES (N'Relacional', N'R6 · Filas que violan FK/CHECK (DBCC CHECKCONSTRAINTS)', N'0',
                        CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);
END TRY
BEGIN CATCH
    INSERT #val VALUES (N'Relacional', N'R6 · DBCC CHECKCONSTRAINTS', N'0', LEFT(ERROR_MESSAGE(), 60), 0);
END CATCH

-- R7 · Proporción nocturna realista (Bogotá: ~12 h de noche)
SELECT @a = 100.0 * SUM(CASE WHEN es_noche = 1 THEN 1 ELSE 0 END) / COUNT(*) FROM NeoGridRelacional.dbo.medicion WHERE origen_id = 1;
INSERT #val VALUES (N'Relacional', N'R7 · % de intervalos nocturnos', N'entre 45 % y 55 %',
                    CONCAT(FORMAT(@a, 'N1', 'es-CO'), N' %'), CASE WHEN @a BETWEEN 45 AND 55 THEN 1 ELSE 0 END);

-- R8 · De día solo hay luz encendida si el LDR está en falla (estado 6)
SELECT @x = COUNT_BIG(*) FROM NeoGridRelacional.dbo.medicion
WHERE origen_id = 1 AND es_noche = 0 AND brillo_pct > 0 AND estado_id <> 6;
INSERT #val VALUES (N'Relacional', N'R8 · Luminarias encendidas de día sin falla de LDR', N'0',
                    FORMAT(@x, 'N0', 'es-CO'), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- R9 · En falla o mantenimiento el brillo es 0
SELECT @x = COUNT_BIG(*) FROM NeoGridRelacional.dbo.medicion WHERE origen_id IN (1, 2) AND estado_id IN (7, 8) AND brillo_pct <> 0;
INSERT #val VALUES (N'Relacional', N'R9 · Fuera de servicio con brillo distinto de 0', N'0',
                    FORMAT(@x, 'N0', 'es-CO'), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- R10 · Problemas de calidad sembrados (para que el ETL los trate)
SELECT @x = SUM(CASE WHEN nivel_luz_lux IS NULL OR tension_v IS NULL OR corriente_a IS NULL OR potencia_w IS NULL
                          OR energia_wh IS NULL OR temperatura_c IS NULL OR detecciones IS NULL OR energia_wh < 0 THEN 1 ELSE 0 END)
FROM NeoGridRelacional.dbo.medicion WHERE origen_id = 1;
INSERT #val VALUES (N'Relacional', N'R10 · Mediciones con nulos o valores inconsistentes (se imputan en el ETL)', N'> 0 y < 5 %',
                    CONCAT(FORMAT(@x, 'N0', 'es-CO'), N' (', FORMAT(@x / 10000.0, 'N2', 'es-CO'), N' %)'),
                    CASE WHEN @x > 0 AND @x < 50000 THEN 1 ELSE 0 END);

-- R11 · Una luminaria no tiene dos fallas simultáneas
SELECT @x = COUNT(*) FROM NeoGridRelacional.dbo.falla a
JOIN NeoGridRelacional.dbo.falla b ON b.luminaria_id = a.luminaria_id AND b.falla_id > a.falla_id
 AND b.fecha_inicio < ISNULL(a.fecha_resolucion, '99991231') AND a.fecha_inicio < ISNULL(b.fecha_resolucion, '99991231')
WHERE a.origen_id = 1 AND b.origen_id = 1;
INSERT #val VALUES (N'Relacional', N'R11 · Fallas simuladas superpuestas en una misma luminaria', N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- R12 · Los correctivos empiezan después de detectar la falla
SELECT @x = COUNT(*) FROM NeoGridRelacional.dbo.mantenimiento m
JOIN NeoGridRelacional.dbo.falla f ON f.falla_id = m.falla_id
WHERE m.fecha_inicio < f.fecha_deteccion;
INSERT #val VALUES (N'Relacional', N'R12 · Correctivos iniciados antes de detectar la falla', N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- R13 · Consumo diario (CALCULADO): una fila por luminaria y día con datos
SELECT @x = COUNT(*) FROM (SELECT DISTINCT luminaria_id, CAST(fecha_hora AS DATE) AS d
                           FROM NeoGridRelacional.dbo.medicion WHERE origen_id IN (1, 2)) q;
SELECT @y = COUNT(*) FROM NeoGridRelacional.dbo.consumo_energetico;
INSERT #val VALUES (N'Relacional', N'R13 · Filas de consumo diario = luminaria × día medidos',
                    FORMAT(@x, 'N0', 'es-CO'), FORMAT(@y, 'N0', 'es-CO'), CASE WHEN @x = @y THEN 1 ELSE 0 END);

-- R14 · Consumo diario cuadra con las mediciones
SELECT @a = SUM(CASE WHEN m.energia_wh IS NULL OR m.energia_wh < 0
                     THEN (mo.potencia_nominal_w * ISNULL(m.brillo_pct, 0) / 100.0 + 1.5) * 0.25
                     ELSE m.energia_wh END) / 1000.0
FROM NeoGridRelacional.dbo.medicion m
JOIN NeoGridRelacional.dbo.luminaria l ON l.luminaria_id = m.luminaria_id
JOIN NeoGridRelacional.dbo.modelo_luminaria mo ON mo.modelo_id = l.modelo_id
WHERE m.origen_id IN (1, 2);
SELECT @b = SUM(energia_kwh) FROM NeoGridRelacional.dbo.consumo_energetico;
INSERT #val VALUES (N'Relacional', N'R14 · kWh de consumo diario = kWh de las mediciones (±0,5 kWh por redondeo)',
                    FORMAT(@a, 'N2', 'es-CO'), FORMAT(@b, 'N2', 'es-CO'), CASE WHEN ABS(@a - @b) <= 0.5 THEN 1 ELSE 0 END);

-- R15 · Contador de casas: encendidas + apagadas = luces de la vivienda
SELECT @x = COUNT(*) FROM NeoGridRelacional.dbo.registro_luces_vivienda r
JOIN NeoGridRelacional.dbo.vivienda v ON v.vivienda_id = r.vivienda_id
WHERE r.luces_encendidas + r.luces_apagadas <> v.numero_luces;
INSERT #val VALUES (N'Relacional', N'R15 · Registros de casas con conteo incoherente', N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- R16 · Cada falla tiene su evento de detección
SELECT @x = COUNT(*) FROM NeoGridRelacional.dbo.falla f
WHERE NOT EXISTS (SELECT 1 FROM NeoGridRelacional.dbo.evento_operativo e WHERE e.falla_id = f.falla_id AND e.tipo_evento_id = 6);
INSERT #val VALUES (N'Relacional', N'R16 · Fallas sin evento FALLA_DETECTADA', N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- R17 · Cada proceso tiene exactamente un responsable
SELECT @x = COUNT(*) FROM NeoGridRelacional.dbo.proceso p
WHERE (SELECT COUNT(*) FROM NeoGridRelacional.dbo.usuario_proceso up
       WHERE up.proceso_id = p.proceso_id AND up.responsabilidad = 'RESPONSABLE') = 1;
SELECT @y = COUNT(*) FROM NeoGridRelacional.dbo.proceso;
INSERT #val VALUES (N'Relacional', N'R17 · Procesos con un único usuario RESPONSABLE', CONCAT(@y, N' de ', @y),
                    CONCAT(@x, N' de ', @y), CASE WHEN @x = @y AND @y = 6 THEN 1 ELSE 0 END);

-- R18 · Cada tipo de evento pertenece al proceso que corresponde a su categoría
SELECT @x = COUNT(*) FROM NeoGridRelacional.dbo.tipo_evento te
JOIN NeoGridRelacional.dbo.proceso p ON p.proceso_id = te.proceso_id
WHERE p.tipo_operacion <> CASE te.categoria WHEN 'OPERACION' THEN 'CONTROL' WHEN 'SENSOR' THEN 'MONITOREO'
                                            WHEN 'COMUNICACION' THEN 'MONITOREO' WHEN 'FALLA' THEN 'ATENCION'
                                            WHEN 'MANTENIMIENTO' THEN 'GESTION' END;
INSERT #val VALUES (N'Relacional', N'R18 · Tipos de evento asignados a un proceso que no corresponde', N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- R19 · Las fallas simuladas las registra el operador del turno de detección
SELECT @x = COUNT(*) FROM NeoGridRelacional.dbo.falla f
JOIN NeoGridRelacional.dbo.usuario u ON u.usuario_id = f.usuario_registra_id
JOIN NeoGridRelacional.dbo.rol r ON r.rol_id = u.rol_id
WHERE f.origen_id = 1
  AND (r.codigo <> 'OPERADOR'
       OR (DATEPART(HOUR, f.fecha_deteccion) BETWEEN 6 AND 17 AND u.login <> 'agomez')
       OR (DATEPART(HOUR, f.fecha_deteccion) NOT BETWEEN 6 AND 17 AND u.login <> 'jcastro'));
INSERT #val VALUES (N'Relacional', N'R19 · Fallas simuladas registradas por un usuario que no es el operador del turno', N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- R20 · Todo técnico que ejecuta mantenimientos es un usuario del sistema
SELECT @x = COUNT(DISTINCT m.tecnico_id) FROM NeoGridRelacional.dbo.mantenimiento m
WHERE m.tecnico_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM NeoGridRelacional.dbo.usuario u WHERE u.tecnico_id = m.tecnico_id);
INSERT #val VALUES (N'Relacional', N'R20 · Técnicos con mantenimientos que no son usuarios', N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

/* ============================ MULTIDIMENSIONAL ============================ */

-- D1 · Dimensiones con el número de filas esperado (las que tienen miembro desconocido cuentan una fila más)
SELECT @x =
      CASE WHEN (SELECT COUNT(*) FROM dbo.dim_luminaria) = 65 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_ubicacion) = 13 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_sensor) = 46 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_estado_operativo) = 9 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_origen) = 4 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_tipo_falla) = 7 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_tipo_mantenimiento) = 7 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_tecnico) = 6 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_tiempo) = 731 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_hora) = 96 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_calidad_dato) = 4 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_tipo_evento) = 13 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_proceso) = 7 THEN 1 ELSE 0 END
    + CASE WHEN (SELECT COUNT(*) FROM dbo.dim_usuario) = 12 THEN 1 ELSE 0 END;
INSERT #val VALUES (N'DW', N'D1 · Dimensiones con las filas esperadas (luminaria 64+1, sensor 46, tiempo 731, usuario 11+1…)', N'14 de 14',
                    CONCAT(@x, N' de 14'), CASE WHEN @x = 14 THEN 1 ELSE 0 END);

-- D2 · Hecho principal: el millón de mediciones simuladas está cargado
SELECT @x = COUNT_BIG(*) FROM dbo.fact_operacion_luminaria f
JOIN dbo.dim_origen o ON o.origen_key = f.origen_key WHERE o.codigo = 'SIMULADO';
INSERT #val VALUES (N'DW', N'D2 · Filas del hecho con origen SIMULADO', N'1.000.000',
                    FORMAT(@x, 'N0', 'es-CO'), CASE WHEN @x = 1000000 THEN 1 ELSE 0 END);

-- D3 · Volumen total del hecho principal
SELECT @x = COUNT_BIG(*) FROM dbo.fact_operacion_luminaria;
INSERT #val VALUES (N'DW', N'D3 · Filas totales del hecho (simuladas + físicas)', N'>= 1.000.000',
                    FORMAT(@x, 'N0', 'es-CO'), CASE WHEN @x >= 1000000 THEN 1 ELSE 0 END);

-- D4 · Completitud: toda medición procesada está en el hecho o en rechazos
DECLARE @wm BIGINT = (SELECT ultimo_medicion_id FROM dbo.etl_control WHERE proceso = 'FACT_OPERACION');
SELECT @x = COUNT(*) FROM (
    SELECT medicion_id FROM src.medicion WHERE medicion_id <= @wm
    EXCEPT SELECT medicion_id FROM dbo.fact_operacion_luminaria
    EXCEPT SELECT medicion_id FROM dbo.etl_rechazo) q;
INSERT #val VALUES (N'DW', N'D4 · Mediciones procesadas que no están ni en el hecho ni en rechazos', N'0',
                    FORMAT(@x, 'N0', 'es-CO'), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- D5 · Linaje: todo hecho apunta a una medición existente
SELECT @x = COUNT(*) FROM (
    SELECT medicion_id FROM dbo.fact_operacion_luminaria
    EXCEPT SELECT medicion_id FROM src.medicion) q;
INSERT #val VALUES (N'DW', N'D5 · Filas del hecho sin medición de origen', N'0',
                    FORMAT(@x, 'N0', 'es-CO'), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- D6 · Los valores no imputables coinciden fila a fila (brillo, estado, luminaria, fecha)
SELECT @x = COUNT_BIG(*)
FROM dbo.fact_operacion_luminaria f
JOIN src.medicion m ON m.medicion_id = f.medicion_id
JOIN dbo.dim_luminaria dl ON dl.luminaria_key = f.luminaria_key
JOIN dbo.dim_estado_operativo de ON de.estado_key = f.estado_key
WHERE f.brillo_pct <> m.brillo_pct
   OR de.estado_id <> m.estado_id
   OR dl.luminaria_id <> m.luminaria_id
   OR f.tiempo_key <> CAST(CONVERT(CHAR(8), m.fecha_hora, 112) AS INT);
INSERT #val VALUES (N'DW', N'D6 · Diferencias fila a fila entre hecho y medición', N'0',
                    FORMAT(@x, 'N0', 'es-CO'), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- D7 · Energía del hecho = energía de las mediciones aplicando la regla de imputación
SELECT @a = SUM(CAST(CASE WHEN m.energia_wh IS NULL OR m.energia_wh < 0
                          THEN CAST(ISNULL(m.potencia_w, mo.potencia_nominal_w * m.brillo_pct / 100 + 1.5) AS DECIMAL(8,2)) * 0.25
                          ELSE m.energia_wh END AS DECIMAL(10,3))) / 1000.0
FROM src.medicion m
JOIN src.luminaria l ON l.luminaria_id = m.luminaria_id
JOIN src.modelo_luminaria mo ON mo.modelo_id = l.modelo_id
WHERE EXISTS (SELECT 1 FROM dbo.fact_operacion_luminaria f WHERE f.medicion_id = m.medicion_id);
SELECT @b = SUM(energia_wh) / 1000.0 FROM dbo.fact_operacion_luminaria;
INSERT #val VALUES (N'DW', N'D7 · kWh del hecho = kWh de las mediciones cargadas (±0,01)',
                    FORMAT(@a, 'N3', 'es-CO'), FORMAT(@b, 'N3', 'es-CO'), CASE WHEN ABS(@a - @b) <= 0.01 THEN 1 ELSE 0 END);

-- D8 · Hechos agregados cuadran con el hecho principal
SELECT @x = COUNT_BIG(*) FROM dbo.fact_operacion_luminaria;
SELECT @y = SUM(CAST(intervalos AS BIGINT)) FROM dbo.fact_consumo_diario;
INSERT #val VALUES (N'DW', N'D8 · Intervalos en fact_consumo_diario = filas del hecho',
                    FORMAT(@x, 'N0', 'es-CO'), FORMAT(@y, 'N0', 'es-CO'), CASE WHEN @x = @y THEN 1 ELSE 0 END);
SELECT @y = SUM(CAST(intervalos AS BIGINT)) FROM dbo.fact_operacion_horaria;
INSERT #val VALUES (N'DW', N'D9 · Intervalos en fact_operacion_horaria = filas del hecho',
                    FORMAT(@x, 'N0', 'es-CO'), FORMAT(@y, 'N0', 'es-CO'), CASE WHEN @x = @y THEN 1 ELSE 0 END);
SELECT @a = SUM(energia_kwh) FROM dbo.fact_consumo_diario;
SELECT @b = SUM(energia_wh) / 1000.0 FROM dbo.fact_operacion_luminaria;
/* Cada fila diaria guarda los kWh con 4 decimales (0,1 Wh), así que el total puede diferir del hecho
   por redondeo. La prueba compara luminaria por luminaria y día por día: cada fila debe coincidir
   con la suma del hecho con un error máximo de medio dígito (0,00005 kWh). */
SELECT @x = COUNT(*)
FROM dbo.fact_consumo_diario c
FULL JOIN (SELECT tiempo_key, luminaria_key, origen_key, SUM(energia_wh) / 1000.0 AS kwh
           FROM dbo.fact_operacion_luminaria
           GROUP BY tiempo_key, luminaria_key, origen_key) h
       ON h.tiempo_key = c.tiempo_key AND h.luminaria_key = c.luminaria_key AND h.origen_key = c.origen_key
WHERE c.tiempo_key IS NULL OR h.tiempo_key IS NULL OR ABS(c.energia_kwh - h.kwh) > 0.00005;
INSERT #val VALUES (N'DW', N'D10 · kWh diarios = suma del hecho, fila por fila (solo redondeo a 4 decimales)',
                    CONCAT(FORMAT(@b, 'N3', 'es-CO'), N' kWh · 0 filas distintas'),
                    CONCAT(FORMAT(@a, 'N3', 'es-CO'), N' kWh · ', @x, N' filas distintas'),
                    CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- D11 · Grano único
SELECT @x = COUNT(*) FROM (SELECT luminaria_key, tiempo_key, hora_key FROM dbo.fact_operacion_luminaria
                           GROUP BY luminaria_key, tiempo_key, hora_key HAVING COUNT(*) > 1) q;
INSERT #val VALUES (N'DW', N'D11 · Filas repetidas en el grano luminaria × día × intervalo', N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- D12 · Hechos de fallas y mantenimiento completos
SELECT @x = (SELECT COUNT(*) FROM src.falla), @y = (SELECT COUNT(*) FROM dbo.fact_falla);
INSERT #val VALUES (N'DW', N'D12 · fact_falla = fallas del modelo relacional', CONCAT(@x, N''), CONCAT(@y, N''),
                    CASE WHEN @x = @y THEN 1 ELSE 0 END);
SELECT @x = (SELECT COUNT(*) FROM src.mantenimiento), @y = (SELECT COUNT(*) FROM dbo.fact_mantenimiento);
INSERT #val VALUES (N'DW', N'D13 · fact_mantenimiento = mantenimientos del modelo relacional', CONCAT(@x, N''), CONCAT(@y, N''),
                    CASE WHEN @x = @y THEN 1 ELSE 0 END);

-- D14 · Claves foráneas del DW activas y verificadas
SELECT @x = COUNT(*) FROM sys.foreign_keys WHERE is_disabled = 1 OR is_not_trusted = 1;
INSERT #val VALUES (N'DW', N'D14 · FK del DW deshabilitadas o no confiables', N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- D15 · Calidad: filas marcadas como imputadas = mediciones con nulos o energía negativa
SELECT @x = COUNT_BIG(*) FROM dbo.fact_operacion_luminaria WHERE calidad_key IN (2, 4);
SELECT @y = COUNT_BIG(*) FROM src.medicion m
WHERE (m.nivel_luz_lux IS NULL OR m.tension_v IS NULL OR m.corriente_a IS NULL OR m.potencia_w IS NULL
       OR m.energia_wh IS NULL OR m.temperatura_c IS NULL OR m.detecciones IS NULL OR m.energia_wh < 0)
  AND EXISTS (SELECT 1 FROM dbo.fact_operacion_luminaria f WHERE f.medicion_id = m.medicion_id);
INSERT #val VALUES (N'DW', N'D15 · Filas IMPUTADAS en el DW = mediciones incompletas cargadas',
                    FORMAT(@y, 'N0', 'es-CO'), FORMAT(@x, 'N0', 'es-CO'), CASE WHEN @x = @y THEN 1 ELSE 0 END);

-- D16 · Última ejecución del ETL cerrada y con conteos cuadrados
SELECT TOP (1) @x = CASE WHEN estado IN ('EXITOSA', 'CON_RECHAZOS')
                          AND filas_leidas = filas_insertadas + filas_rechazadas + filas_omitidas THEN 1 ELSE 0 END,
               @y = ejecucion_id
FROM dbo.etl_ejecucion ORDER BY ejecucion_id DESC;
INSERT #val VALUES (N'DW', N'D16 · Última ejecución ETL: estado final y leídas = insertadas + rechazadas + omitidas', N'1',
                    CONCAT(ISNULL(@x, 0), N' (ejecución ', ISNULL(@y, 0), N')'), CASE WHEN @x = 1 THEN 1 ELSE 0 END);

-- D17 · Consumo: relacional (CALCULADO) frente a DW, diferencia menor a 0,5 %
SELECT @a = SUM(energia_kwh) FROM NeoGridRelacional.dbo.consumo_energetico;
SELECT @b = SUM(energia_kwh) FROM dbo.fact_consumo_diario;
INSERT #val VALUES (N'Ambos', N'D17 · kWh totales relacional vs DW (diferencia por la regla de imputación, < 0,5 %)',
                    FORMAT(@a, 'N2', 'es-CO'), FORMAT(@b, 'N2', 'es-CO'),
                    CASE WHEN @a > 0 AND ABS(@a - @b) / @a < 0.005 THEN 1 ELSE 0 END);

-- D18 · Completitud de eventos: todo evento procesado está en el hecho o en rechazos
DECLARE @wme BIGINT = (SELECT ultimo_medicion_id FROM dbo.etl_control WHERE proceso = 'FACT_EVENTO');
SELECT @x = COUNT(*) FROM (
    SELECT evento_id FROM src.evento_operativo WHERE evento_id <= @wme
    EXCEPT SELECT evento_id FROM dbo.fact_evento_operativo
    EXCEPT SELECT evento_id FROM dbo.etl_rechazo WHERE evento_id IS NOT NULL) q;
SELECT @y = COUNT(*) FROM src.evento_operativo WHERE evento_id <= @wme;
INSERT #val VALUES (N'DW', CONCAT(N'D18 · Eventos procesados (', FORMAT(@y, 'N0', 'es-CO'), N') que no están ni en el hecho ni en rechazos'), N'0',
                    FORMAT(@x, 'N0', 'es-CO'), CASE WHEN @x = 0 AND @y > 0 THEN 1 ELSE 0 END);

-- D19 · Linaje y grano del hecho de eventos (un evento_id por fila, todos existen en el relacional)
SELECT @x = (SELECT COUNT(*) FROM (SELECT evento_id FROM dbo.fact_evento_operativo GROUP BY evento_id HAVING COUNT(*) > 1) q)
          + (SELECT COUNT(*) FROM (SELECT evento_id FROM dbo.fact_evento_operativo EXCEPT SELECT evento_id FROM src.evento_operativo) q);
INSERT #val VALUES (N'DW', N'D19 · Eventos repetidos en el hecho o sin evento de origen', N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- D20 · Homologación: todo evento cargado tiene una acción estándar coherente con su tipo
SELECT @x = COUNT(*) FROM dbo.fact_evento_operativo f
JOIN dbo.dim_tipo_evento t ON t.tipo_evento_key = f.tipo_evento_key
WHERE f.accion_homologada = N'OTRO'
   OR (t.codigo = 'CAMBIO_BRILLO' AND f.accion_homologada NOT IN (N'SUBE_BRILLO', N'BAJA_BRILLO', N'AJUSTE_BRILLO'))
   OR (t.codigo = 'CAMBIO_LUZ_AMBIENTE' AND f.accion_homologada NOT IN (N'ANOCHECER', N'AMANECER', N'CAMBIO_LUZ'))
   OR (t.codigo = 'CAMBIO_BRILLO' AND f.variacion_brillo_pct > 0 AND f.accion_homologada <> N'SUBE_BRILLO')
   OR (t.codigo = 'CAMBIO_BRILLO' AND f.variacion_brillo_pct < 0 AND f.accion_homologada <> N'BAJA_BRILLO');
INSERT #val VALUES (N'DW', N'D20 · Eventos con acción homologada incoherente con su tipo o su variación de brillo', N'0',
                    FORMAT(@x, 'N0', 'es-CO'), CASE WHEN @x = 0 THEN 1 ELSE 0 END);

-- D21 · El usuario de cada FALLA_DETECTADA en el DW es quien registró la falla en el relacional
SELECT @x = COUNT(*) FROM dbo.fact_evento_operativo f
JOIN dbo.dim_tipo_evento t ON t.tipo_evento_key = f.tipo_evento_key
JOIN dbo.dim_usuario u ON u.usuario_key = f.usuario_key
JOIN src.falla fa ON fa.falla_id = f.falla_id
WHERE t.codigo = 'FALLA_DETECTADA' AND u.usuario_id <> fa.usuario_registra_id;
SELECT @y = COUNT(*) FROM dbo.fact_evento_operativo f
JOIN dbo.dim_tipo_evento t ON t.tipo_evento_key = f.tipo_evento_key WHERE t.codigo = 'FALLA_DETECTADA';
INSERT #val VALUES (N'Ambos', CONCAT(N'D21 · Detecciones de falla (', @y, N') con usuario distinto al que registró la falla'), N'0',
                    CONCAT(@x, N''), CASE WHEN @x = 0 AND @y > 0 THEN 1 ELSE 0 END);

-- D22 · Última ejecución: eventos leídos = insertados + rechazados + omitidos
SELECT TOP (1) @x = CASE WHEN eventos_leidos = eventos_insertados + eventos_rechazados + eventos_omitidos THEN 1 ELSE 0 END,
               @y = ejecucion_id
FROM dbo.etl_ejecucion ORDER BY ejecucion_id DESC;
INSERT #val VALUES (N'DW', N'D22 · Última ejecución ETL: eventos leídos = insertados + rechazados + omitidos', N'1',
                    CONCAT(ISNULL(@x, 0), N' (ejecución ', ISNULL(@y, 0), N')'), CASE WHEN @x = 1 THEN 1 ELSE 0 END);

/* =============================== RESULTADO =============================== */
SELECT n AS [#], modelo, prueba, esperado, obtenido,
       CASE pasa WHEN 1 THEN 'PASA' ELSE 'REVISAR' END AS resultado
FROM #val ORDER BY n;

SELECT SUM(CASE WHEN pasa = 1 THEN 1 ELSE 0 END) AS pruebas_ok, COUNT(*) AS pruebas_total FROM #val;

IF EXISTS (SELECT 1 FROM #dbcc)
    SELECT tabla, restriccion, condicion FROM #dbcc;   -- detalle de violaciones, si las hay
GO
