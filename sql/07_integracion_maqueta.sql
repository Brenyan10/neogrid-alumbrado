/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   07_integracion_maqueta.sql
   Integra los datos REALES de la maqueta (base NeoGridAlumbrado, que
   llena el suscriptor de Python) con el modelo relacional NeoGridRelacional.

   · NO modifica NeoGridAlumbrado: solo la lee mediante sinónimos (esquema maq).
   · Cada 15 minutos completos de lecturas (una cada 10 s por tablero) se
     convierten en 8 filas de medicion (los 8 postes del tablero comparten
     el mismo PWM), con origen_id = 2 (FÍSICO).
   · evento_poste y conexion_modulo  -> evento_operativo (+ fallas LDR y de comunicación)
   · conteo_casa                    -> registro_luces_vivienda
   · Es idempotente: se puede ejecutar cuantas veces se quiera.

     EXEC dbo.sp_importar_maqueta;           -- lo llama puente_nube.py cada minuto

   Conversión LDR -> lux (la misma que usa el generador de datos):
     lux = 10^((4095 - oscuridad) / 800) - 1
   Con esta curva "noche" (lux < 40) equivale a oscuridad > 2805, que
   coincide con los umbrales calibrados en los tableros (2757 y 2881).
   La maqueta no mide tensión ni energía: esas columnas quedan NULL y el
   ETL las imputa con la potencia del modelo MAQ-LED5 (dato CALCULADO).
   Requiere: 01, 02 y la base NeoGridAlumbrado (crear_base_neogrid.sql).
   ===================================================================== */
USE NeoGridRelacional;
GO

IF SCHEMA_ID('maq') IS NULL EXEC (N'CREATE SCHEMA maq AUTHORIZATION dbo;');
GO
DROP SYNONYM IF EXISTS maq.lectura_alumbrado;
DROP SYNONYM IF EXISTS maq.evento_poste;
DROP SYNONYM IF EXISTS maq.conteo_casa;
DROP SYNONYM IF EXISTS maq.conexion_modulo;
GO
CREATE SYNONYM maq.lectura_alumbrado FOR NeoGridAlumbrado.dbo.lectura_alumbrado;
CREATE SYNONYM maq.evento_poste      FOR NeoGridAlumbrado.dbo.evento_poste;
CREATE SYNONYM maq.conteo_casa       FOR NeoGridAlumbrado.dbo.conteo_casa;
CREATE SYNONYM maq.conexion_modulo   FOR NeoGridAlumbrado.dbo.conexion_modulo;
GO

/* ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_importar_maqueta
    @min_lecturas INT = 6,              -- mínimo de lecturas (1 min) para aceptar un intervalo de 15 min
    @hasta        DATETIME2(0) = NULL   -- solo para pruebas; por defecto, la hora actual
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF DB_ID(N'NeoGridAlumbrado') IS NULL
    BEGIN
        RAISERROR(N'No existe la base NeoGridAlumbrado; no hay datos de la maqueta para importar.', 0, 1) WITH NOWAIT;
        SELECT 0 AS mediciones_insertadas, 0 AS intervalos_omitidos, 0 AS eventos, 0 AS registros_casas,
               0 AS fallas_abiertas, 0 AS fallas_resueltas, CAST(NULL AS DATETIME2(0)) AS primer_intervalo,
               CAST(NULL AS DATETIME2(0)) AS ultimo_intervalo;
        RETURN;
    END

    DECLARE @base  DATETIME2(0) = '20000101';
    DECLARE @ahora DATETIME2(0) = ISNULL(@hasta, SYSDATETIME());
    /* Inicio del intervalo de 15 min en curso: solo se importan intervalos ya cerrados */
    DECLARE @corte DATETIME2(0) = DATEADD(MINUTE, (DATEDIFF(MINUTE, @base, @ahora) / 15) * 15, @base);

    DECLARE @marca_lect DATETIME2(0), @marca_casas DATETIME2(0), @id_eventos BIGINT, @id_conexion BIGINT;
    SELECT @marca_lect  = ultima_marca     FROM dbo.integracion_control WHERE proceso = 'MAQUETA_LECTURAS';
    SELECT @marca_casas = ultima_marca     FROM dbo.integracion_control WHERE proceso = 'MAQUETA_CASAS';
    SELECT @id_eventos  = ultimo_id_origen FROM dbo.integracion_control WHERE proceso = 'MAQUETA_EVENTOS';
    SELECT @id_conexion = ultimo_id_origen FROM dbo.integracion_control WHERE proceso = 'MAQUETA_CONEXION';
    SET @id_eventos = ISNULL(@id_eventos, 0);
    SET @id_conexion = ISNULL(@id_conexion, 0);

    DECLARE @n_med INT = 0, @n_cubetas INT = 0, @n_eventos INT = 0, @n_casas INT = 0,
            @n_abiertas INT = 0, @n_resueltas INT = 0,
            @primer DATETIME2(0), @ultimo DATETIME2(0),
            @max_ev BIGINT, @max_con BIGINT;

    BEGIN TRANSACTION;

    /* 1. Lecturas cada 10 s -> intervalos de 15 min por tablero -------- */
    IF OBJECT_ID('tempdb..#cubeta') IS NOT NULL DROP TABLE #cubeta;
    SELECT
        CAST(UPPER(l.tablero) AS VARCHAR(5)) AS tablero,
        b.cubeta,
        COUNT(*) AS lecturas,
        AVG(CAST(l.luz AS FLOAT)) AS luz_prom,
        AVG(CAST(l.oscuridad AS FLOAT)) AS oscuridad_prom,
        AVG(CASE WHEN l.noche = 1 THEN 1.0E0 ELSE 0.0E0 END) AS frac_noche,
        SUM(CASE WHEN l.estado = 'PERSONA' THEN 1 ELSE 0 END) AS lecturas_persona,
        AVG(CAST(ISNULL(l.brillo_pct, 0) AS FLOAT)) AS brillo_prom,
        MAX(CASE WHEN l.ahorro = 1 THEN 1 ELSE 0 END) AS hubo_ahorro,
        AVG(CASE WHEN l.ldr_falla = 1 THEN 1.0E0 ELSE 0.0E0 END) AS frac_falla_ldr
    INTO #cubeta
    FROM maq.lectura_alumbrado l
    CROSS APPLY (SELECT DATEADD(MINUTE, (DATEDIFF(MINUTE, @base, l.fecha_hora) / 15) * 15, @base) AS cubeta) b
    WHERE l.fecha_hora < @corte
      AND (@marca_lect IS NULL OR l.fecha_hora >= @marca_lect)
      AND UPPER(l.tablero) IN ('OESTE', 'ESTE')
      AND l.oscuridad IS NOT NULL
    GROUP BY UPPER(l.tablero), b.cubeta
    HAVING COUNT(*) >= @min_lecturas;
    SET @n_cubetas = @@ROWCOUNT;

    IF OBJECT_ID('tempdb..#mov') IS NOT NULL DROP TABLE #mov;
    SELECT CAST(UPPER(e.tablero) AS VARCHAR(5)) AS tablero, b.cubeta, COUNT(*) AS movimientos
    INTO #mov
    FROM maq.evento_poste e
    CROSS APPLY (SELECT DATEADD(MINUTE, (DATEDIFF(MINUTE, @base, e.fecha_hora) / 15) * 15, @base) AS cubeta) b
    WHERE e.tipo = 'movimiento'
      AND e.fecha_hora < @corte
      AND (@marca_lect IS NULL OR e.fecha_hora >= @marca_lect)
    GROUP BY UPPER(e.tablero), b.cubeta;

    /* Estado del intervalo (mismas reglas que el firmware y el generador):
       día -> APAGADA; día con LDR en falla y postes encendidos -> ENCENDIDA_DIA;
       noche con >= 3 min en PERSONA -> PRESENCIA (o AHORRO si hubo modo ahorro);
       noche con brillo promedio < 20 % -> MADRUGADA (15 %); resto -> NOCHE_BASE. */
    INSERT INTO dbo.medicion
        (luminaria_id, sensor_luz_id, sensor_presencia_id, estado_id, origen_id, fecha_hora, es_noche,
         lectura_ldr, nivel_luz_lux, detecciones, brillo_pct, tension_v, corriente_a, potencia_w, energia_wh,
         temperatura_c, es_anomala)
    SELECT
        lu.luminaria_id,
        sl.sensor_id,
        sp.sensor_id,
        x.estado_id,
        2,
        c.cubeta,
        n.es_noche,
        CAST(ROUND(c.oscuridad_prom, 0) AS SMALLINT),
        CAST(ROUND(CASE WHEN c.oscuridad_prom >= 4095 THEN 0.0E0
                        ELSE POWER(10.0E0, (4095 - c.oscuridad_prom) / 800.0E0) - 1 END, 1) AS DECIMAL(9,1)),
        CAST(ISNULL(m.movimientos, 0) AS SMALLINT),
        CAST(ROUND(c.brillo_prom, 1) AS DECIMAL(5,1)),
        NULL, NULL, NULL, NULL, NULL,
        CASE WHEN c.frac_falla_ldr >= 0.5 THEN 1 ELSE 0 END
    FROM #cubeta c
    JOIN dbo.luminaria lu ON lu.tablero = c.tablero AND lu.es_fisica = 1
    JOIN dbo.sensor sl ON sl.codigo = CASE c.tablero WHEN 'OESTE' THEN 'OES-LDR' ELSE 'EST-LDR' END
    JOIN dbo.sensor sp ON sp.codigo = CASE c.tablero WHEN 'OESTE' THEN 'OES-PIR' ELSE 'EST-PIR' END
    LEFT JOIN #mov m ON m.tablero = c.tablero AND m.cubeta = c.cubeta
    CROSS APPLY (SELECT CASE WHEN c.frac_noche >= 0.5 THEN 1 ELSE 0 END AS es_noche) n
    CROSS APPLY (SELECT CASE
            WHEN n.es_noche = 0 AND c.frac_falla_ldr >= 0.5 AND c.brillo_prom >= 10 THEN 6
            WHEN n.es_noche = 0 THEN 1
            WHEN c.lecturas_persona * 10 >= 180 THEN CASE WHEN c.hubo_ahorro = 1 THEN 5 ELSE 4 END
            WHEN c.brillo_prom < 20 THEN 3
            ELSE 2 END AS estado_id) x
    WHERE NOT EXISTS (SELECT 1 FROM dbo.medicion me
                      WHERE me.luminaria_id = lu.luminaria_id AND me.fecha_hora = c.cubeta)
    ORDER BY c.cubeta, lu.luminaria_id;
    SET @n_med = @@ROWCOUNT;

    SELECT @primer = MIN(cubeta), @ultimo = MAX(cubeta) FROM #cubeta;

    /* 2. Contador de luces de las casas: último valor de cada intervalo ---- */
    ;WITH u AS (
        SELECT c.casa_id, b.cubeta, c.encendidas, c.apagadas,
               ROW_NUMBER() OVER (PARTITION BY c.casa_id, b.cubeta ORDER BY c.fecha_hora DESC, c.id DESC) AS rn
        FROM maq.conteo_casa c
        CROSS APPLY (SELECT DATEADD(MINUTE, (DATEDIFF(MINUTE, @base, c.fecha_hora) / 15) * 15, @base) AS cubeta) b
        WHERE c.fecha_hora < @corte
          AND (@marca_casas IS NULL OR c.fecha_hora >= @marca_casas)
    )
    INSERT INTO dbo.registro_luces_vivienda (vivienda_id, origen_id, fecha_hora, luces_encendidas, luces_apagadas)
    SELECT v.vivienda_id, 2, u.cubeta, u.encendidas, u.apagadas
    FROM u
    JOIN dbo.vivienda v ON v.codigo = u.casa_id AND v.es_fisica = 1
    WHERE u.rn = 1
      AND NOT EXISTS (SELECT 1 FROM dbo.registro_luces_vivienda r WHERE r.vivienda_id = v.vivienda_id AND r.fecha_hora = u.cubeta);
    SET @n_casas = @@ROWCOUNT;

    /* 3. Eventos de los postes (sin las fallas de LDR, que van en el paso 4) */
    SELECT @max_ev = MAX(id) FROM maq.evento_poste WHERE id > @id_eventos;
    SELECT @max_con = MAX(id) FROM maq.conexion_modulo WHERE id > @id_conexion;

    INSERT INTO dbo.evento_operativo
        (luminaria_id, ubicacion_id, tipo_evento_id, origen_id, fecha_hora, estado_anterior_id, estado_nuevo_id,
         brillo_anterior, brillo_nuevo, falla_id, mantenimiento_id, detalle)
    SELECT NULL, u.ubicacion_id, t.tipo_evento_id, 2, e.fecha_hora, t.estado_ant, t.estado_nuevo,
           NULL, e.brillo_pct, NULL, NULL, t.detalle
    FROM maq.evento_poste e
    JOIN dbo.ubicacion u ON u.codigo = CASE UPPER(e.tablero) WHEN 'OESTE' THEN 'OES-T1' ELSE 'EST-T1' END
    CROSS APPLY (SELECT
        CASE e.ahora WHEN 'DIA' THEN 1
                     WHEN 'NOCHE' THEN CASE WHEN e.brillo_pct = 15 THEN 3 ELSE 2 END
                     WHEN 'PERSONA' THEN CASE WHEN e.brillo_pct = 60 THEN 5 ELSE 4 END END AS nuevo,
        CASE e.antes WHEN 'DIA' THEN 1 WHEN 'NOCHE' THEN 2 WHEN 'PERSONA' THEN 4 END AS ant) st
    CROSS APPLY (SELECT
        CASE e.tipo
            WHEN 'estado'            THEN CASE WHEN e.ahora = 'DIA' THEN 2 WHEN e.antes = 'DIA' THEN 1 ELSE 3 END
            WHEN 'movimiento'        THEN 4
            WHEN 'luz_ambiente'      THEN 5
            WHEN 'noche_por_horario' THEN 5
            WHEN 'modo_ahorro'       THEN CASE WHEN e.ahora = '1' THEN 10 ELSE 3 END
        END AS tipo_evento_id,
        CASE WHEN e.tipo = 'estado' THEN st.ant END AS estado_ant,
        CASE WHEN e.tipo = 'estado' THEN st.nuevo END AS estado_nuevo,
        CAST(CASE e.tipo
            WHEN 'estado'            THEN CONCAT(N'Tablero ', UPPER(e.tablero), N' (8 postes): ', e.antes, N' -> ', e.ahora)
            WHEN 'movimiento'        THEN CONCAT(N'PIR del tablero ', UPPER(e.tablero), N' detectó movimiento')
            WHEN 'luz_ambiente'      THEN CONCAT(N'LDR del tablero ', UPPER(e.tablero), N': ', e.antes, N' -> ', e.ahora)
            WHEN 'noche_por_horario' THEN CONCAT(N'Respaldo por horario (LDR en falla): ', e.antes, N' -> ', e.ahora)
            WHEN 'modo_ahorro'       THEN CASE WHEN e.ahora = '1' THEN N'Modo ahorro activado por el módulo de energía'
                                               ELSE N'Modo ahorro desactivado' END
        END AS NVARCHAR(200)) AS detalle) t
    WHERE e.id > @id_eventos
      AND e.id <= ISNULL(@max_ev, 0)
      AND UPPER(e.tablero) IN ('OESTE', 'ESTE')
      AND t.tipo_evento_id IS NOT NULL
    ORDER BY e.fecha_hora, e.id;
    SET @n_eventos = @@ROWCOUNT;

    /* 4. Fallas reales: LDR (evento falla_ldr) y comunicación (LWT de MQTT).
          Se procesan en orden cronológico para abrir y cerrar cada falla. */
    DECLARE @ev TABLE (fuente CHAR(1) NOT NULL, id BIGINT NOT NULL, tablero VARCHAR(5) NOT NULL,
                       fecha DATETIME2(0) NOT NULL, abre BIT NOT NULL);
    INSERT INTO @ev (fuente, id, tablero, fecha, abre)
    SELECT 'L', e.id, UPPER(e.tablero), e.fecha_hora, CASE WHEN e.ahora = '1' THEN 1 ELSE 0 END
    FROM maq.evento_poste e
    WHERE e.tipo = 'falla_ldr' AND e.id > @id_eventos AND e.id <= ISNULL(@max_ev, 0)
      AND UPPER(e.tablero) IN ('OESTE', 'ESTE');
    INSERT INTO @ev (fuente, id, tablero, fecha, abre)
    SELECT 'C', c.id, UPPER(c.tablero), c.fecha_hora, CASE WHEN c.estado = 'fuera_de_linea' THEN 1 ELSE 0 END
    FROM maq.conexion_modulo c
    WHERE c.id > @id_conexion AND c.id <= ISNULL(@max_con, 0)
      AND UPPER(c.tablero) IN ('OESTE', 'ESTE')
      AND c.estado IN ('en_linea', 'fuera_de_linea');

    DECLARE @fuente CHAR(1), @tablero VARCHAR(5), @fecha DATETIME2(0), @abre BIT,
            @lum SMALLINT, @ubi SMALLINT, @sensor SMALLINT, @tipo TINYINT, @fid INT, @tipo_ev TINYINT,
            @desc NVARCHAR(200);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT fuente, tablero, fecha, abre FROM @ev ORDER BY fecha, fuente, id;
    OPEN cur;
    FETCH NEXT FROM cur INTO @fuente, @tablero, @fecha, @abre;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @lum = luminaria_id FROM dbo.luminaria WHERE codigo = CASE @tablero WHEN 'OESTE' THEN 'O-P1' ELSE 'E-P1' END;
        SELECT @ubi = ubicacion_id FROM dbo.ubicacion WHERE codigo = CASE @tablero WHEN 'OESTE' THEN 'OES-T1' ELSE 'EST-T1' END;
        SET @tipo = CASE @fuente WHEN 'L' THEN 3 ELSE 5 END;
        SET @sensor = CASE WHEN @fuente = 'L'
                           THEN (SELECT sensor_id FROM dbo.sensor WHERE codigo = CASE @tablero WHEN 'OESTE' THEN 'OES-LDR' ELSE 'EST-LDR' END)
                      END;
        SET @fid = (SELECT TOP (1) falla_id FROM dbo.falla
                    WHERE luminaria_id = @lum AND tipo_falla_id = @tipo AND origen_id = 2 AND fecha_resolucion IS NULL
                    ORDER BY falla_id DESC);

        IF @abre = 1
        BEGIN
            IF @fid IS NULL
            BEGIN
                SET @desc = CASE @fuente
                    WHEN 'L' THEN CONCAT(N'LDR del tablero ', @tablero, N' con lectura fija durante 60 s; afecta los 8 postes (respaldo por horario).')
                    ELSE CONCAT(N'Tablero ', @tablero, N' fuera de línea (mensaje de última voluntad del broker MQTT).') END;
                INSERT INTO dbo.falla (luminaria_id, sensor_id, tipo_falla_id, origen_id, fecha_inicio, fecha_deteccion,
                                       fecha_resolucion, estado, descripcion)
                VALUES (@lum, @sensor, @tipo, 2,
                        DATEADD(SECOND, CASE @fuente WHEN 'L' THEN -60 ELSE -20 END, @fecha),  -- 60 s de confirmación del LDR · ~20 s de keepalive MQTT
                        @fecha, NULL, 'ABIERTA', @desc);
                SET @fid = CAST(SCOPE_IDENTITY() AS INT);
                SET @n_abiertas += 1;
                IF @fuente = 'C'   -- toda falla tiene su evento FALLA_DETECTADA (además del evento DESCONEXION)
                    INSERT INTO dbo.evento_operativo (luminaria_id, ubicacion_id, tipo_evento_id, origen_id, fecha_hora, falla_id, detalle)
                    VALUES (NULL, @ubi, 6, 2, @fecha, @fid, CONCAT(N'Tablero ', @tablero, N': falla de comunicación detectada'));
            END
        END
        ELSE IF @fid IS NOT NULL
        BEGIN
            UPDATE dbo.falla
               SET fecha_resolucion = CASE WHEN @fecha < fecha_deteccion THEN fecha_deteccion ELSE @fecha END,
                   estado = 'RESUELTA'
             WHERE falla_id = @fid;
            SET @n_resueltas += 1;
            IF @fuente = 'C'   -- y su evento FALLA_RESUELTA (además del evento CONEXION)
                INSERT INTO dbo.evento_operativo (luminaria_id, ubicacion_id, tipo_evento_id, origen_id, fecha_hora, falla_id, detalle)
                VALUES (NULL, @ubi, 7, 2, @fecha, @fid, CONCAT(N'Tablero ', @tablero, N': falla de comunicación resuelta'));
        END

        SET @tipo_ev = CASE WHEN @fuente = 'L' AND @abre = 1 THEN 6
                            WHEN @fuente = 'L' THEN 7
                            WHEN @abre = 1 THEN 12
                            ELSE 11 END;
        INSERT INTO dbo.evento_operativo
            (luminaria_id, ubicacion_id, tipo_evento_id, origen_id, fecha_hora, estado_anterior_id, estado_nuevo_id,
             brillo_anterior, brillo_nuevo, falla_id, mantenimiento_id, detalle)
        VALUES (NULL, @ubi, @tipo_ev, 2, @fecha, NULL, NULL, NULL, NULL, @fid, NULL,
                CONCAT(N'Tablero ', @tablero, CASE @tipo_ev WHEN 6 THEN N': falla del LDR' WHEN 7 THEN N': LDR normal'
                                                            WHEN 12 THEN N': fuera de línea' ELSE N': en línea' END));
        SET @n_eventos += 1;

        FETCH NEXT FROM cur INTO @fuente, @tablero, @fecha, @abre;
    END
    CLOSE cur;
    DEALLOCATE cur;

    /* 5. Marcas de agua ------------------------------------------------- */
    UPDATE dbo.integracion_control
       SET ultima_marca = @corte, ultima_ejecucion = SYSDATETIME(), filas_ultima_ejecucion = @n_med,
           ultimo_id_origen = ISNULL((SELECT MAX(id) FROM maq.lectura_alumbrado WHERE fecha_hora < @corte), ultimo_id_origen)
     WHERE proceso = 'MAQUETA_LECTURAS';
    UPDATE dbo.integracion_control
       SET ultima_marca = @corte, ultima_ejecucion = SYSDATETIME(), filas_ultima_ejecucion = @n_casas
     WHERE proceso = 'MAQUETA_CASAS';
    UPDATE dbo.integracion_control
       SET ultimo_id_origen = ISNULL(@max_ev, ultimo_id_origen), ultima_ejecucion = SYSDATETIME(),
           filas_ultima_ejecucion = @n_eventos
     WHERE proceso = 'MAQUETA_EVENTOS';
    UPDATE dbo.integracion_control
       SET ultimo_id_origen = ISNULL(@max_con, ultimo_id_origen), ultima_ejecucion = SYSDATETIME(),
           filas_ultima_ejecucion = @n_abiertas + @n_resueltas
     WHERE proceso = 'MAQUETA_CONEXION';

    COMMIT TRANSACTION;

    /* 6. Consumo diario (CALCULADO) de los días que recibieron datos ----- */
    IF @n_med > 0
    BEGIN
        DECLARE @desde DATE = CAST(@primer AS DATE);
        EXEC dbo.sp_calcular_consumo_diario @desde = @desde;
    END

    SELECT @n_med AS mediciones_insertadas,
           @n_cubetas * 8 - @n_med AS intervalos_omitidos,
           @n_eventos AS eventos,
           @n_casas AS registros_casas,
           @n_abiertas AS fallas_abiertas,
           @n_resueltas AS fallas_resueltas,
           @primer AS primer_intervalo,
           @ultimo AS ultimo_intervalo;
END
GO

/* ------------------------------------------------------------------
   Estado en vivo de cada tablero (lo publica puente_nube.py en el tablero web)
   ------------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.sp_maqueta_estado_vivo
AS
BEGIN
    SET NOCOUNT ON;
    IF DB_ID(N'NeoGridAlumbrado') IS NULL
    BEGIN
        SELECT CAST(NULL AS VARCHAR(5)) AS tablero WHERE 1 = 0;
        RETURN;
    END

    ;WITH t AS (
        SELECT v.tablero FROM (VALUES ('OESTE'), ('ESTE')) v (tablero)
    )
    SELECT
        t.tablero,
        ul.fecha_hora,
        ul.luz AS lectura_ldr,
        ul.oscuridad,
        CAST(ROUND(CASE WHEN ul.oscuridad IS NULL THEN NULL WHEN ul.oscuridad >= 4095 THEN 0
                        ELSE POWER(10.0E0, (4095 - ul.oscuridad) / 800.0E0) - 1 END, 1) AS DECIMAL(9,1)) AS nivel_luz_lux,
        CAST(ul.noche AS TINYINT) AS es_noche,
        ul.estado,
        ul.brillo_pct,
        CAST(ul.pir AS TINYINT) AS pir,
        CAST(ul.ahorro AS TINYINT) AS ahorro,
        CAST(ul.ldr_falla AS TINYINT) AS ldr_falla,
        uc.estado AS conexion,
        uc.fecha_hora AS fecha_conexion,
        ISNULL(cs.encendidas, 0) AS luces_casas_encendidas,
        ISNULL(cs.apagadas, 0) AS luces_casas_apagadas,
        DATEDIFF(SECOND, ul.fecha_hora, SYSDATETIME()) AS segundos_desde_lectura
    FROM t
    OUTER APPLY (SELECT TOP (1) l.fecha_hora, l.luz, l.oscuridad, l.noche, l.estado, l.brillo_pct, l.pir, l.ahorro, l.ldr_falla
                 FROM maq.lectura_alumbrado l WHERE UPPER(l.tablero) = t.tablero ORDER BY l.id DESC) ul
    OUTER APPLY (SELECT TOP (1) c.estado, c.fecha_hora
                 FROM maq.conexion_modulo c WHERE UPPER(c.tablero) = t.tablero ORDER BY c.id DESC) uc
    OUTER APPLY (SELECT SUM(x.encendidas) AS encendidas, SUM(x.apagadas) AS apagadas
                 FROM (SELECT c.encendidas, c.apagadas,
                              ROW_NUMBER() OVER (PARTITION BY c.casa_id ORDER BY c.id DESC) AS rn
                       FROM maq.conteo_casa c WHERE UPPER(c.tablero) = t.tablero) x
                 WHERE x.rn = 1) cs;
END
GO

/* Completa los eventos de las fallas de comunicación importadas con la primera versión de este
   script (que solo registraba DESCONEXION / CONEXION). Es idempotente. */
INSERT INTO dbo.evento_operativo (luminaria_id, ubicacion_id, tipo_evento_id, origen_id, fecha_hora, falla_id, detalle)
SELECT NULL, l.ubicacion_id, 6, f.origen_id, f.fecha_deteccion, f.falla_id,
       CONCAT(N'Tablero ', l.tablero, N': falla de comunicación detectada')
FROM dbo.falla f
JOIN dbo.luminaria l ON l.luminaria_id = f.luminaria_id
WHERE f.origen_id = 2 AND f.tipo_falla_id = 5
  AND NOT EXISTS (SELECT 1 FROM dbo.evento_operativo e WHERE e.falla_id = f.falla_id AND e.tipo_evento_id = 6);

INSERT INTO dbo.evento_operativo (luminaria_id, ubicacion_id, tipo_evento_id, origen_id, fecha_hora, falla_id, detalle)
SELECT NULL, l.ubicacion_id, 7, f.origen_id, f.fecha_resolucion, f.falla_id,
       CONCAT(N'Tablero ', l.tablero, N': falla de comunicación resuelta')
FROM dbo.falla f
JOIN dbo.luminaria l ON l.luminaria_id = f.luminaria_id
WHERE f.origen_id = 2 AND f.tipo_falla_id = 5 AND f.fecha_resolucion IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.evento_operativo e WHERE e.falla_id = f.falla_id AND e.tipo_evento_id = 7);
GO

PRINT N'Integración con la maqueta lista. Pruebe: EXEC dbo.sp_importar_maqueta;  y  EXEC dbo.sp_maqueta_estado_vivo;';
GO

/* Consultas de verificación (ejecutar por separado):
SELECT * FROM dbo.integracion_control;
SELECT TOP (32) * FROM dbo.medicion WHERE origen_id = 2 ORDER BY medicion_id DESC;
SELECT TOP (50) * FROM dbo.evento_operativo WHERE origen_id = 2 ORDER BY evento_id DESC;
SELECT * FROM dbo.falla WHERE origen_id = 2 ORDER BY falla_id DESC;
SELECT TOP (16) * FROM dbo.registro_luces_vivienda WHERE origen_id = 2 ORDER BY registro_id DESC;
*/
