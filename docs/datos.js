// Valores tomados de los CSV de evidencias (bloques indicados en "fuente").
window.DATOS = {
 "horas": {
  "hora": [
   0,
   1,
   2,
   3,
   4,
   5,
   6,
   7,
   8,
   9,
   10,
   11,
   12,
   13,
   14,
   15,
   16,
   17,
   18,
   19,
   20,
   21,
   22,
   23
  ],
  "energia_kwh": [
   227.42,
   227.4,
   146.3,
   146.25,
   146.29,
   173.77,
   17.86,
   17.87,
   17.87,
   17.86,
   17.87,
   17.9,
   17.94,
   17.96,
   17.96,
   17.94,
   17.91,
   17.93,
   175.24,
   304.73,
   305.15,
   268.74,
   256.2,
   245.97
  ],
  "ahorro_pct": [
   73.0,
   73.0,
   82.7,
   82.7,
   82.7,
   67.4,
   -14.1,
   -14.2,
   -14.2,
   -14.1,
   -14.2,
   -14.4,
   -14.7,
   -14.8,
   -14.8,
   -14.6,
   -14.5,
   -14.6,
   62.9,
   63.7,
   63.6,
   68.0,
   69.4,
   70.7
  ],
  "fuente": "E25"
 },
 "luminarias": {
  "luminaria": [
   "AVC-L10",
   "AVC-L01",
   "AVC-L12",
   "AVC-L11",
   "AVC-L05",
   "AVC-L07",
   "AVC-L09",
   "AVC-L02",
   "AVC-L08",
   "AVC-L04"
  ],
  "horas_encendida": [
   2340.3,
   1878.5,
   1817.5,
   1816.8,
   1816.0,
   1815.5,
   1814.5,
   1806.0,
   1805.3,
   1808.3
  ],
  "fuente": "E26"
 },
 "zona_dia": {
  "zonas": [
   "RESIDENCIAL",
   "HOSPITALARIA",
   "VIAL",
   "COMERCIAL"
  ],
  "tipos": [
   "Laboral",
   "Fin de semana",
   "Festivo"
  ],
  "valores": {
   "Laboral": [
    171.9,
    398.4,
    522.8,
    546.3
   ],
   "Fin de semana": [
    171.4,
    398.1,
    375.9,
    607.8
   ],
   "Festivo": [
    175.0,
    408.6,
    533.2,
    554.7
   ]
  },
  "fuente": "E31"
 },
 "fallas": {
  "tipo": [
   "COMUNICACION",
   "LECTURA_PIR",
   "SOBRETENSION",
   "DRIVER",
   "LECTURA_LDR",
   "LED_FUNDIDO",
   "FUSIBLE"
  ],
  "media_h": [
   321.46,
   307.4,
   299.72,
   240.06,
   173.3,
   50.27,
   23.63
  ],
  "n": [
   14,
   7,
   14,
   13,
   15,
   9,
   9
  ],
  "fuente": "E27 (simuladas)"
 },
 "actores": {
  "actor": [
   "Control automático",
   "Otros procesos automáticos",
   "Técnicos",
   "Operadores"
  ],
  "eventos": [
   64817,
   1009,
   655,
   81
  ],
  "fuente": "E29"
 }
};
