/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   09_prueba_rechazos_etl.sql
   Prueba controlada de las reglas de calidad del ETL.
   Inserta 12 mediciones de PRUEBA (origen_id = 4) en la luminaria AVC-L01
   el 2026-10-20 entre 03:00 y 04:45, cada una diseñada para un caso:

     #  caso                                   resultado esperado
     1  medición correcta                      INSERTADA
     2  sin tensión ni corriente               INSERTADA (IMPUTADA: 220 V y P/V)
     3  medición correcta con presencia        INSERTADA
     4  mismo intervalo que la 1               RECHAZO DUPLICADO
     5  mismo intervalo que la 3 (03:37)       RECHAZO DUPLICADO
     6  fecha anterior al sistema (2025)       RECHAZO FECHA_INVALIDA
     7  fecha futura (2031)                    RECHAZO FECHA_INVALIDA
     8  brillo 140 %                           RECHAZO BRILLO_FUERA_DE_RANGO
     9  brillo nulo                            RECHAZO BRILLO_FUERA_DE_RANGO
    10  tensión 480 V                          RECHAZO VALOR_IMPOSIBLE
    11  luz ambiente negativa                  RECHAZO VALOR_IMPOSIBLE
    12  potencia negativa                      RECHAZO VALOR_IMPOSIBLE

   Esperado: leídas 12 · insertadas 3 · rechazadas 9 · imputadas 1.

   Uso:
     · Prueba con el ETL T-SQL: ejecutar el archivo completo (F5).
     · Prueba con SSIS: ejecutar la PARTE 1, luego el paquete ETL_NeoGrid.dtsx
       en Visual Studio y después la PARTE 3.
     · Limpieza (deja el DW como estaba): EXEC NeoGridDW.dbo.sp_etl_limpiar_prueba;
   ===================================================================== */

/* ----------------------- Procedimiento de limpieza ---------------------- */
USE NeoGridDW;
GO
CREATE OR ALTER PROCEDURE dbo.sp_etl_limpiar_prueba
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @desde INT, @hasta INT, @hechos INT, @mediciones INT;

    IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;
    SELECT medicion_id INTO #p FROM src.medicion WHERE origen_id = 4;

    SELECT @desde = MIN(f.tiempo_key), @hasta = MAX(f.tiempo_key)
    FROM dbo.fact_operacion_luminaria f JOIN #p p ON p.medicion_id = f.medicion_id;

    BEGIN TRANSACTION;
    DELETE f FROM dbo.fact_operacion_luminaria f JOIN #p p ON p.medicion_id = f.medicion_id;
    SET @hechos = @@ROWCOUNT;
    IF @desde IS NOT NULL
        EXEC dbo.sp_etl_actualizar_agregados @ejecucion_id = NULL, @tiempo_key_desde = @desde, @tiempo_key_hasta = @hasta;
    DELETE m FROM src.medicion m JOIN #p p ON p.medicion_id = m.medicion_id;
    SET @mediciones = @@ROWCOUNT;
    COMMIT TRANSACTION;

    /* El historial (etl_ejecucion, etl_paso, etl_rechazo) se conserva como evidencia. */
    SELECT @mediciones AS mediciones_prueba_borradas, @hechos AS hechos_prueba_borrados;
END
GO

/* =============================== PARTE 1 ================================
   Insertar las 12 mediciones de prueba en el modelo relacional
   ======================================================================= */
USE NeoGridRelacional;
GO
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM dbo.medicion WHERE origen_id = 4)
BEGIN
    RAISERROR(N'Ya hay mediciones de prueba. Ejecute primero: EXEC NeoGridDW.dbo.sp_etl_limpiar_prueba;', 16, 1);
    RETURN;
END

/* Luminaria 17 = AVC-L01 (LV-150, 150 W) · sensores 21 (AVC-LDR) y 25 (AVC-T1-PIR) */
INSERT INTO dbo.medicion
    (luminaria_id, sensor_luz_id, sensor_presencia_id, estado_id, origen_id, fecha_hora, es_noche,
     lectura_ldr, nivel_luz_lux, detecciones, brillo_pct, tension_v, corriente_a, potencia_w, energia_wh, temperatura_c, es_anomala)
VALUES
 (17, 21, 25, 3, 4, '2026-10-20T03:00:00', 1, 4004, 0.3,  0,  15.0, 221.40, 0.108,  24.00,  6.000, 14.2, 0),  --  1 correcta
 (17, 21, 25, 3, 4, '2026-10-20T03:15:00', 1, 4004, 0.3,  1,  15.0,   NULL,  NULL,  24.00,  6.000, 14.0, 0),  --  2 sin tensión
 (17, 21, 25, 4, 4, '2026-10-20T03:30:00', 1, 4004, 0.3,  6,  52.6, 219.80, 0.366,  80.40, 20.100, 15.1, 0),  --  3 correcta
 (17, 21, 25, 3, 4, '2026-10-20T03:00:00', 1, 4004, 0.3,  0,  15.0, 221.40, 0.108,  24.00,  6.000, 14.2, 0),  --  4 duplicada de la 1
 (17, 21, 25, 4, 4, '2026-10-20T03:37:00', 1, 4004, 0.3,  6,  52.6, 219.80, 0.366,  80.40, 20.100, 15.1, 0),  --  5 mismo intervalo que la 3
 (17, 21, 25, 3, 4, '2025-12-31T23:45:00', 1, 4004, 0.3,  0,  25.0, 220.10, 0.177,  39.00,  9.750, 15.0, 0),  --  6 fecha anterior
 (17, 21, 25, 3, 4, '2031-01-01T00:00:00', 1, 4004, 0.3,  0,  25.0, 220.10, 0.177,  39.00,  9.750, 15.0, 0),  --  7 fecha futura
 (17, 21, 25, 3, 4, '2026-10-20T03:45:00', 1, 4004, 0.3,  0, 140.0, 220.60, 0.961, 212.00, 53.000, 14.1, 0),  --  8 brillo 140 %
 (17, 21, 25, 3, 4, '2026-10-20T04:00:00', 1, 4004, 0.3,  0,  NULL, 220.60, 0.108,  24.00,  6.000, 14.1, 0),  --  9 brillo nulo
 (17, 21, 25, 3, 4, '2026-10-20T04:15:00', 1, 4004, 0.3,  0,  15.0, 480.00, 0.050,  24.00,  6.000, 14.0, 1),  -- 10 tensión imposible
 (17, 21, 25, 3, 4, '2026-10-20T04:30:00', 1, 4004, -5.0, 0,  15.0, 220.30, 0.108,  24.00,  6.000, 13.9, 0),  -- 11 lux negativo
 (17, 21, 25, 3, 4, '2026-10-20T04:45:00', 1, 4004, 0.3,  0,  15.0, 220.30, 0.091, -20.00, -5.000, 13.9, 0);  -- 12 potencia negativa

SELECT medicion_id, fecha_hora, brillo_pct, tension_v, nivel_luz_lux, potencia_w
FROM dbo.medicion WHERE origen_id = 4 ORDER BY medicion_id;
GO

/* =============================== PARTE 2 ================================
   Ejecutar el ETL (T-SQL). Si va a probar SSIS, NO ejecute esta parte:
   ejecute el paquete y continúe con la PARTE 3.
   ======================================================================= */
USE NeoGridDW;
GO
EXEC dbo.sp_etl_ejecutar_tsql;
GO

/* =============================== PARTE 3 ================================
   Evidencia: resultado de cada caso y comparación con lo esperado
   ======================================================================= */
USE NeoGridDW;
GO
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#prueba') IS NOT NULL DROP TABLE #prueba;
SELECT ROW_NUMBER() OVER (ORDER BY m.medicion_id) AS caso, m.medicion_id, m.fecha_hora, m.brillo_pct, m.tension_v,
       m.nivel_luz_lux, m.potencia_w,
       CASE WHEN f.medicion_id IS NOT NULL THEN 'INSERTADA' WHEN r.medicion_id IS NOT NULL THEN 'RECHAZADA' ELSE 'SIN PROCESAR' END AS resultado,
       r.motivo, dc.codigo AS calidad, f.tension_v AS tension_en_dw, f.corriente_a AS corriente_en_dw
INTO #prueba
FROM src.medicion m
LEFT JOIN dbo.fact_operacion_luminaria f ON f.medicion_id = m.medicion_id
LEFT JOIN dbo.dim_calidad_dato dc ON dc.calidad_key = f.calidad_key
OUTER APPLY (SELECT TOP (1) x.medicion_id, x.motivo FROM dbo.etl_rechazo x
             WHERE x.medicion_id = m.medicion_id ORDER BY x.rechazo_id DESC) r
WHERE m.origen_id = 4;

SELECT * FROM #prueba ORDER BY caso;

;WITH esperado AS (
    SELECT v.concepto, v.valor FROM (VALUES
        (N'Leídas', 12), (N'Insertadas', 3), (N'Rechazadas', 9), (N'Imputadas', 1),
        (N'DUPLICADO', 2), (N'FECHA_INVALIDA', 2), (N'BRILLO_FUERA_DE_RANGO', 2), (N'VALOR_IMPOSIBLE', 3)) v (concepto, valor)
), obtenido AS (
    SELECT N'Leídas' AS concepto, COUNT(*) AS valor FROM #prueba WHERE resultado <> 'SIN PROCESAR'
    UNION ALL SELECT N'Insertadas', COUNT(*) FROM #prueba WHERE resultado = 'INSERTADA'
    UNION ALL SELECT N'Rechazadas', COUNT(*) FROM #prueba WHERE resultado = 'RECHAZADA'
    UNION ALL SELECT N'Imputadas', COUNT(*) FROM #prueba WHERE calidad IN ('IMPUTADO', 'IMPUTADO_Y_ANOMALO')
    UNION ALL SELECT N'DUPLICADO', COUNT(*) FROM #prueba WHERE motivo = N'DUPLICADO'
    UNION ALL SELECT N'FECHA_INVALIDA', COUNT(*) FROM #prueba WHERE motivo = N'FECHA_INVALIDA'
    UNION ALL SELECT N'BRILLO_FUERA_DE_RANGO', COUNT(*) FROM #prueba WHERE motivo = N'BRILLO_FUERA_DE_RANGO'
    UNION ALL SELECT N'VALOR_IMPOSIBLE', COUNT(*) FROM #prueba WHERE motivo = N'VALOR_IMPOSIBLE'
)
SELECT e.concepto, e.valor AS esperado, o.valor AS obtenido,
       CASE WHEN e.valor = o.valor THEN 'PASA' ELSE 'REVISAR' END AS resultado
FROM esperado e JOIN obtenido o ON o.concepto = e.concepto;

/* Registro de la ejecución que procesó la prueba */
SELECT TOP (1) e.ejecucion_id, e.herramienta, e.estado, e.inicio, e.fin, e.filas_leidas, e.filas_insertadas,
       e.filas_rechazadas, e.filas_omitidas, e.filas_imputadas, e.mensaje
FROM dbo.etl_ejecucion e
WHERE EXISTS (SELECT 1 FROM dbo.etl_rechazo r JOIN #prueba p ON p.medicion_id = r.medicion_id WHERE r.ejecucion_id = e.ejecucion_id)
ORDER BY e.ejecucion_id DESC;

SELECT p.paso, p.inicio, p.fin, p.filas, p.estado, p.mensaje
FROM dbo.etl_paso p
WHERE p.ejecucion_id = (SELECT MAX(r.ejecucion_id) FROM dbo.etl_rechazo r JOIN #prueba x ON x.medicion_id = r.medicion_id)
ORDER BY p.paso_id;

/* Re-ejecutar el ETL no debe duplicar nada: la marca de agua ya pasó estas filas. */
GO
