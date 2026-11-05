/* =====================================================================
   NeoGrid · Alumbrado público inteligente
   02_relacional_catalogos.sql
   Carga los datos maestros: zonas, tramos, modelos, 64 luminarias
   (16 físicas de la maqueta + 48 simuladas), 45 sensores, 24 viviendas,
   estados, tipos de evento, fallas, mantenimiento y técnicos.
   Requiere: 01_relacional_esquema.sql
   ===================================================================== */
USE NeoGridRelacional;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;

INSERT INTO dbo.origen_dato (origen_id, codigo, nombre, descripcion) VALUES
 (1, 'SIMULADO',  N'Simulado',          N'Generado por el script de simulación con reglas del sistema de alumbrado.'),
 (2, 'FISICO',    N'Físico (maqueta)',  N'Medido por los ESP32 de la maqueta y recibido por MQTT.'),
 (3, 'CALCULADO', N'Calculado',         N'Derivado de otros datos: consumo diario, ahorro e indicadores.'),
 (4, 'PRUEBA',    N'Prueba del ETL',    N'Filas insertadas a propósito para comprobar las reglas de rechazo del ETL.');

INSERT INTO dbo.zona (zona_id, codigo, nombre, tipo_zona, es_fisica, descripcion) VALUES
 (1, 'OES', N'Sector Oeste (maqueta)', 'RESIDENCIAL',  1, N'Tablero de alumbrado oeste de la maqueta NeoGrid (15 × 100 cm).'),
 (2, 'EST', N'Sector Este (maqueta)',  'RESIDENCIAL',  1, N'Tablero de alumbrado este de la maqueta NeoGrid (15 × 100 cm).'),
 (3, 'AVC', N'Avenida Central',        'VIAL',         0, N'Corredor vial principal de la ciudad simulada.'),
 (4, 'HOS', N'Zona Hospitalaria',      'HOSPITALARIA', 0, N'Accesos, urgencias y parqueadero del hospital.'),
 (5, 'PLZ', N'Plaza Central',          'COMERCIAL',    0, N'Plazoleta y calle comercial.'),
 (6, 'NRT', N'Barrio Norte',           'RESIDENCIAL',  0, N'Barrio residencial simulado.');

INSERT INTO dbo.ubicacion (ubicacion_id, zona_id, codigo, nombre, tipo_via, longitud_m) VALUES
 (1,  1, 'OES-T1', N'Andén sector oeste · tramo norte (0–50 cm)', 'ANDEN',   0.5),
 (2,  1, 'OES-T2', N'Andén sector oeste · tramo sur (50–100 cm)', 'ANDEN',   0.5),
 (3,  2, 'EST-T1', N'Andén sector este · tramo norte (0–50 cm)',  'ANDEN',   0.5),
 (4,  2, 'EST-T2', N'Andén sector este · tramo sur (50–100 cm)',  'ANDEN',   0.5),
 (5,  3, 'AVC-T1', N'Avenida Central · calzada norte',            'CALZADA', 420.0),
 (6,  3, 'AVC-T2', N'Avenida Central · calzada sur',              'CALZADA', 420.0),
 (7,  3, 'AVC-T3', N'Avenida Central · glorieta',                 'CALZADA', 180.0),
 (8,  4, 'HOS-T1', N'Hospital · acceso principal',                'ACCESO',  160.0),
 (9,  4, 'HOS-T2', N'Hospital · urgencias y parqueadero',         'ACCESO',  220.0),
 (10, 5, 'PLZ-T1', N'Plaza Central · plazoleta',                  'PLAZA',   150.0),
 (11, 5, 'PLZ-T2', N'Plaza Central · calle comercial',            'CALLE',   260.0),
 (12, 6, 'NRT-T1', N'Barrio Norte · calle 1',                     'CALLE',   300.0),
 (13, 6, 'NRT-T2', N'Barrio Norte · calle 2',                     'CALLE',   300.0);

/* El modelo 1 representa los postes de la maqueta: un LED de 5 mm
   (≈ 0,045 W reales) que actúa como gemelo de una luminaria vial de 60 W.
   El consumo se calcula a escala real con la potencia del gemelo. */
INSERT INTO dbo.modelo_luminaria (modelo_id, codigo, descripcion, tecnologia, potencia_nominal_w, flujo_lm, vida_util_h, temperatura_color_k) VALUES
 (1, 'MAQ-LED5', N'Poste de maqueta (LED 5 mm) · gemelo de luminaria vial LED 60 W', 'LED', 60.00, 7200, 50000, 3000),
 (2, 'LV-060',   N'Luminaria vial LED 60 W',      'LED',  60.00,  7800, 60000, 4000),
 (3, 'LV-100',   N'Luminaria vial LED 100 W',     'LED', 100.00, 13000, 60000, 4000),
 (4, 'LV-150',   N'Luminaria vial LED 150 W',     'LED', 150.00, 19500, 60000, 4000),
 (5, 'LP-040',   N'Luminaria peatonal LED 40 W',  'LED',  40.00,  4800, 50000, 3000),
 (6, 'LV-080',   N'Luminaria vial LED 80 W',      'LED',  80.00, 10400, 60000, 4000);

/* 16 luminarias físicas: posiciones en cm medidas desde el borde norte */
INSERT INTO dbo.luminaria (luminaria_id, codigo, ubicacion_id, modelo_id, es_fisica, tablero, posicion_cm, fecha_instalacion, activa)
SELECT v.luminaria_id, v.codigo, v.ubicacion_id, 1, 1, v.tablero, v.posicion_cm, '20260401', 1
FROM (VALUES
 (1,  'O-P1', 1, 'OESTE', 8),  (2,  'O-P2', 1, 'OESTE', 16), (3,  'O-P3', 1, 'OESTE', 33), (4,  'O-P4', 1, 'OESTE', 44),
 (5,  'O-P5', 2, 'OESTE', 55), (6,  'O-P6', 2, 'OESTE', 66), (7,  'O-P7', 2, 'OESTE', 84), (8,  'O-P8', 2, 'OESTE', 92),
 (9,  'E-P1', 3, 'ESTE',  8),  (10, 'E-P2', 3, 'ESTE',  16), (11, 'E-P3', 3, 'ESTE',  33), (12, 'E-P4', 3, 'ESTE',  44),
 (13, 'E-P5', 4, 'ESTE',  55), (14, 'E-P6', 4, 'ESTE',  66), (15, 'E-P7', 4, 'ESTE',  84), (16, 'E-P8', 4, 'ESTE',  92)
) v (luminaria_id, codigo, ubicacion_id, tablero, posicion_cm);

/* 48 luminarias simuladas: AVC 14, HOS 10, PLZ 12, NRT 12 */
;WITH n AS (
    SELECT TOP (14) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) AS k
    FROM sys.all_objects
), g AS (
    SELECT prefijo, base_id, cantidad
    FROM (VALUES ('AVC', 16, 14), ('HOS', 30, 10), ('PLZ', 40, 12), ('NRT', 52, 12)) x (prefijo, base_id, cantidad)
)
INSERT INTO dbo.luminaria (luminaria_id, codigo, ubicacion_id, modelo_id, es_fisica, tablero, posicion_cm, fecha_instalacion, activa)
SELECT
    CAST(g.base_id + n.k AS SMALLINT),
    CONCAT(g.prefijo, '-L', RIGHT(CONCAT('0', n.k), 2)),
    CASE g.prefijo
        WHEN 'AVC' THEN CASE WHEN n.k <= 6 THEN 5 WHEN n.k <= 12 THEN 6 ELSE 7 END
        WHEN 'HOS' THEN CASE WHEN n.k <= 5 THEN 8 ELSE 9 END
        WHEN 'PLZ' THEN CASE WHEN n.k <= 6 THEN 10 ELSE 11 END
        ELSE CASE WHEN n.k <= 6 THEN 12 ELSE 13 END
    END,
    CASE g.prefijo
        WHEN 'AVC' THEN CASE WHEN n.k <= 12 THEN 4 ELSE 3 END
        WHEN 'HOS' THEN 6
        WHEN 'PLZ' THEN CASE WHEN n.k <= 6 THEN 5 ELSE 2 END
        ELSE 2
    END,
    0, NULL, NULL,
    DATEADD(DAY, -(((g.base_id + n.k) * 37) % 900), CAST('20260301' AS DATE)),
    1
FROM g
JOIN n ON n.k <= g.cantidad;

INSERT INTO dbo.tipo_sensor (tipo_sensor_id, codigo, nombre, magnitud, unidad, rango_min, rango_max) VALUES
 (1, 'LDR',         N'Fotorresistencia (módulo LDR, salida AO)', N'Luz ambiente',          N'ADC 0–4095', 0,   4095),
 (2, 'PIR',         N'Sensor de movimiento HC-SR501',            N'Presencia',             N'detecciones', 0,  1000),
 (3, 'INTERRUPTOR', N'Entrada digital de luz de vivienda',       N'Estado de luz',         N'on/off',      0,  1),
 (4, 'MEDIDOR',     N'Medidor de energía de la zona',            N'Potencia',              N'W',           0,  5000),
 (5, 'AMBIENTAL',   N'Estación ambiental',                       N'Temperatura y humedad', N'°C / %',     -10, 100);

/* 24 viviendas: 8 físicas (casas con contador de la maqueta) y 16 simuladas */
INSERT INTO dbo.vivienda (vivienda_id, codigo, ubicacion_id, numero_luces, es_fisica) VALUES
 (1, 'O-C1', 1, 2, 1), (2, 'O-C2', 1, 2, 1), (3, 'O-C3', 2, 2, 1), (4, 'O-C4', 2, 2, 1),
 (5, 'E-C1', 3, 2, 1), (6, 'E-C2', 3, 2, 1), (7, 'E-C3', 4, 2, 1), (8, 'E-C4', 4, 2, 1);

;WITH n AS (
    SELECT TOP (16) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS INT) AS k
    FROM sys.all_objects
)
INSERT INTO dbo.vivienda (vivienda_id, codigo, ubicacion_id, numero_luces, es_fisica)
SELECT CAST(8 + n.k AS SMALLINT), CONCAT('NRT-V', RIGHT(CONCAT('0', n.k), 2)), CASE WHEN n.k <= 8 THEN 12 ELSE 13 END, CAST(2 + n.k % 3 AS TINYINT), 0
FROM n;

/* 45 sensores. Los físicos llevan el pin del ESP32 (protoboard ordenada por colores). */
INSERT INTO dbo.sensor (sensor_id, codigo, tipo_sensor_id, ubicacion_id, vivienda_id, es_fisico, pin_gpio, modelo, fecha_instalacion, activo) VALUES
 (1,  'OES-LDR',    1, 1, NULL, 1, 'GPIO34', N'Módulo LDR 4 pines (AO)', '20260401', 1),
 (2,  'OES-PIR',    2, 2, NULL, 1, 'GPIO27', N'HC-SR501',                '20260401', 1),
 (3,  'EST-LDR',    1, 3, NULL, 1, 'GPIO34', N'Módulo LDR 4 pines (AO)', '20260401', 1),
 (4,  'EST-PIR',    2, 4, NULL, 1, 'GPIO27', N'HC-SR501',                '20260401', 1),
 (5,  'O-C1-A',     3, 1, 1,    1, 'GPIO32', N'SS12D00',                 '20260401', 1),
 (6,  'O-C1-B',     3, 1, 1,    1, 'GPIO33', N'SS12D00',                 '20260401', 1),
 (7,  'O-C2-A',     3, 1, 2,    1, 'GPIO35', N'SS12D00',                 '20260401', 1),
 (8,  'O-C2-B',     3, 1, 2,    1, 'GPIO36', N'SS12D00',                 '20260401', 1),
 (9,  'O-C3-A',     3, 2, 3,    1, 'GPIO39', N'SS12D00',                 '20260401', 1),
 (10, 'O-C3-B',     3, 2, 3,    1, 'GPIO4',  N'SS12D00',                 '20260401', 1),
 (11, 'O-C4-A',     3, 2, 4,    1, 'GPIO18', N'SS12D00',                 '20260401', 1),
 (12, 'O-C4-B',     3, 2, 4,    1, 'GPIO19', N'SS12D00',                 '20260401', 1),
 (13, 'E-C1-A',     3, 3, 5,    1, 'GPIO32', N'SS12D00',                 '20260401', 1),
 (14, 'E-C1-B',     3, 3, 5,    1, 'GPIO33', N'SS12D00',                 '20260401', 1),
 (15, 'E-C2-A',     3, 3, 6,    1, 'GPIO35', N'SS12D00',                 '20260401', 1),
 (16, 'E-C2-B',     3, 3, 6,    1, 'GPIO36', N'SS12D00',                 '20260401', 1),
 (17, 'E-C3-A',     3, 4, 7,    1, 'GPIO39', N'SS12D00',                 '20260401', 1),
 (18, 'E-C3-B',     3, 4, 7,    1, 'GPIO4',  N'SS12D00',                 '20260401', 1),
 (19, 'E-C4-A',     3, 4, 8,    1, 'GPIO18', N'SS12D00',                 '20260401', 1),
 (20, 'E-C4-B',     3, 4, 8,    1, 'GPIO19', N'SS12D00',                 '20260401', 1),
 (21, 'AVC-LDR',    1, 5,  NULL, 0, NULL, N'Fotocelda de zona',          '20250901', 1),
 (22, 'HOS-LDR',    1, 8,  NULL, 0, NULL, N'Fotocelda de zona',          '20250901', 1),
 (23, 'PLZ-LDR',    1, 10, NULL, 0, NULL, N'Fotocelda de zona',          '20250901', 1),
 (24, 'NRT-LDR',    1, 12, NULL, 0, NULL, N'Fotocelda de zona',          '20250901', 1),
 (25, 'AVC-T1-PIR', 2, 5,  NULL, 0, NULL, N'Sensor PIR de poste',        '20250901', 1),
 (26, 'AVC-T2-PIR', 2, 6,  NULL, 0, NULL, N'Sensor PIR de poste',        '20250901', 1),
 (27, 'AVC-T3-PIR', 2, 7,  NULL, 0, NULL, N'Sensor PIR de poste',        '20250901', 1),
 (28, 'HOS-T1-PIR', 2, 8,  NULL, 0, NULL, N'Sensor PIR de poste',        '20250901', 1),
 (29, 'HOS-T2-PIR', 2, 9,  NULL, 0, NULL, N'Sensor PIR de poste',        '20250901', 1),
 (30, 'PLZ-T1-PIR', 2, 10, NULL, 0, NULL, N'Sensor PIR de poste',        '20250901', 1),
 (31, 'PLZ-T2-PIR', 2, 11, NULL, 0, NULL, N'Sensor PIR de poste',        '20250901', 1),
 (32, 'NRT-T1-PIR', 2, 12, NULL, 0, NULL, N'Sensor PIR de poste',        '20250901', 1),
 (33, 'NRT-T2-PIR', 2, 13, NULL, 0, NULL, N'Sensor PIR de poste',        '20250901', 1),
 (34, 'OES-MED',    4, 1,  NULL, 0, NULL, N'Medidor de energía de zona', '20260401', 1),
 (35, 'EST-MED',    4, 3,  NULL, 0, NULL, N'Medidor de energía de zona', '20260401', 1),
 (36, 'AVC-MED',    4, 5,  NULL, 0, NULL, N'Medidor de energía de zona', '20250901', 1),
 (37, 'HOS-MED',    4, 8,  NULL, 0, NULL, N'Medidor de energía de zona', '20250901', 1),
 (38, 'PLZ-MED',    4, 10, NULL, 0, NULL, N'Medidor de energía de zona', '20250901', 1),
 (39, 'NRT-MED',    4, 12, NULL, 0, NULL, N'Medidor de energía de zona', '20250901', 1),
 (40, 'OES-AMB',    5, 1,  NULL, 0, NULL, N'Estación ambiental',         '20260401', 1),
 (41, 'EST-AMB',    5, 3,  NULL, 0, NULL, N'Estación ambiental',         '20260401', 1),
 (42, 'AVC-AMB',    5, 5,  NULL, 0, NULL, N'Estación ambiental',         '20250901', 1),
 (43, 'HOS-AMB',    5, 8,  NULL, 0, NULL, N'Estación ambiental',         '20250901', 1),
 (44, 'PLZ-AMB',    5, 10, NULL, 0, NULL, N'Estación ambiental',         '20250901', 1),
 (45, 'NRT-AMB',    5, 12, NULL, 0, NULL, N'Estación ambiental',         '20250901', 1);

INSERT INTO dbo.estado_operativo (estado_id, codigo, nombre, categoria, brillo_referencia_pct) VALUES
 (1, 'APAGADA',       N'Apagada por luz natural suficiente',          'APAGADA',           0),
 (2, 'NOCHE_BASE',    N'Encendida en nivel base nocturno',            'ENCENDIDA',         25),
 (3, 'MADRUGADA',     N'Encendida en nivel de madrugada (2:00–5:00)', 'ENCENDIDA',         15),
 (4, 'PRESENCIA',     N'Al 100 % por detección de movimiento',        'ENCENDIDA',         100),
 (5, 'AHORRO',        N'Presencia con tope de modo ahorro (60 %)',    'ENCENDIDA',         60),
 (6, 'ENCENDIDA_DIA', N'Encendida de día (lectura de luz inválida)',  'ENCENDIDA',         25),
 (7, 'FALLA',         N'Fuera de servicio por falla',                 'FUERA_DE_SERVICIO', 0),
 (8, 'MANTENIMIENTO', N'Fuera de servicio por mantenimiento',         'FUERA_DE_SERVICIO', 0);

INSERT INTO dbo.tipo_evento (tipo_evento_id, codigo, nombre, categoria) VALUES
 (1,  'ENCENDIDO',             N'Encendido',                    'OPERACION'),
 (2,  'APAGADO',               N'Apagado',                      'OPERACION'),
 (3,  'CAMBIO_BRILLO',         N'Cambio de brillo',             'OPERACION'),
 (4,  'DETECCION_MOVIMIENTO',  N'Detección de movimiento',      'SENSOR'),
 (5,  'CAMBIO_LUZ_AMBIENTE',   N'Cambio día/noche por luz',     'SENSOR'),
 (6,  'FALLA_DETECTADA',       N'Falla detectada',              'FALLA'),
 (7,  'FALLA_RESUELTA',        N'Falla resuelta',               'FALLA'),
 (8,  'INICIO_MANTENIMIENTO',  N'Inicio de mantenimiento',      'MANTENIMIENTO'),
 (9,  'FIN_MANTENIMIENTO',     N'Fin de mantenimiento',         'MANTENIMIENTO'),
 (10, 'MODO_AHORRO',           N'Entrada en modo ahorro',       'OPERACION'),
 (11, 'CONEXION',              N'Módulo en línea',              'COMUNICACION'),
 (12, 'DESCONEXION',           N'Módulo fuera de línea',        'COMUNICACION');

INSERT INTO dbo.tipo_falla (tipo_falla_id, codigo, nombre, severidad, deja_fuera_servicio, descripcion) VALUES
 (1, 'LED_FUNDIDO',  N'LED o módulo fundido',               'ALTA',  1, N'La luminaria no enciende cuando debería.'),
 (2, 'DRIVER',       N'Driver inestable (parpadeo)',        'MEDIA', 0, N'Potencia irregular y brillo inestable.'),
 (3, 'LECTURA_LDR',  N'Lectura de luz inválida',            'MEDIA', 0, N'El controlador recibe una lectura de luz fija; la luminaria queda encendida de día.'),
 (4, 'LECTURA_PIR',  N'Sin señal de presencia',             'BAJA',  0, N'El controlador no recibe detecciones; nunca sube al 100 %.'),
 (5, 'COMUNICACION', N'Pérdida de comunicación',            'MEDIA', 0, N'Sin datos por Wi-Fi/MQTT; el control local sigue funcionando.'),
 (6, 'SOBRETENSION', N'Sobretensión en la red',             'ALTA',  1, N'Tensión fuera de rango; la protección apaga la luminaria.'),
 (7, 'FUSIBLE',      N'Fusible abierto',                    'ALTA',  1, N'Cortocircuito; la luminaria queda sin alimentación.');

INSERT INTO dbo.tecnico (tecnico_id, codigo, nombre, especialidad, activo) VALUES
 (1, 'T01', N'Laura Méndez',                N'Electricista',           1),
 (2, 'T02', N'Carlos Ruiz',                 N'Electrónica',            1),
 (3, 'T03', N'Diana Torres',                N'Redes y comunicaciones', 1),
 (4, 'T04', N'Jorge Peña',                  N'Electricista',           1),
 (5, 'T05', N'Equipo NeoGrid (maqueta)',    N'Mantenimiento de maqueta', 1);

INSERT INTO dbo.tipo_mantenimiento (tipo_mantenimiento_id, codigo, nombre, es_correctivo, duracion_estimada_min) VALUES
 (1, 'REVISION_ELECTRICA',    N'Revisión eléctrica preventiva',                     0, 60),
 (2, 'LIMPIEZA',              N'Limpieza de luminaria y sensores',                  0, 40),
 (3, 'CALIBRACION',           N'Calibración de sensores (LDR y PIR)',               0, 45),
 (4, 'CORRECTIVO_LED',        N'Reemplazo de LED o módulo',                         1, 90),
 (5, 'CORRECTIVO_ELECTRICO',  N'Reparación eléctrica (driver, fusible, protección)', 1, 120),
 (6, 'CORRECTIVO_RED',        N'Restablecimiento de comunicación',                  1, 45),
 (7, 'CORRECTIVO_SENSOR',     N'Ajuste o reemplazo de sensor',                      1, 60);

INSERT INTO dbo.integracion_control (proceso, ultimo_id_origen, ultima_marca) VALUES
 ('MAQUETA_LECTURAS', 0, NULL),
 ('MAQUETA_EVENTOS', 0, NULL),
 ('MAQUETA_CASAS', 0, NULL),
 ('MAQUETA_CONEXION', 0, NULL);

COMMIT TRANSACTION;

SELECT 'luminaria' AS tabla, COUNT(*) AS filas FROM dbo.luminaria
UNION ALL SELECT 'sensor', COUNT(*) FROM dbo.sensor
UNION ALL SELECT 'vivienda', COUNT(*) FROM dbo.vivienda
UNION ALL SELECT 'ubicacion', COUNT(*) FROM dbo.ubicacion;
-- Esperado: luminaria 64 · sensor 45 · vivienda 24 · ubicacion 13
GO
