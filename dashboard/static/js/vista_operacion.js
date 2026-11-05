/* NeoGrid · vistas de operación: luminarias y sensores, consumo y eficiencia, fallas y mantenimiento. */
(function () {
  "use strict";
  const NG = window.NG;
  NG.vistas = NG.vistas || {};
  const T = () => NG.ESTADO_TXT || {};
  const ZONA_TIPO = { RESIDENCIAL: "Residencial", VIAL: "Vial", HOSPITALARIA: "Hospitalaria", COMERCIAL: "Comercial" };

  function ordenable(lista, clave, dir) {
    return lista.slice().sort((a, b) => {
      const x = a[clave], y = b[clave];
      if (x === y) return 0;
      if (x === null || x === undefined) return 1;
      if (y === null || y === undefined) return -1;
      return (x < y ? -1 : 1) * (dir === "desc" ? -1 : 1);
    });
  }

  // ================================================================== luminarias y sensores
  NG.vistas.luminarias = {
    titulo: "Luminarias y sensores",
    orden: "codigo", dir: "asc",
    async render(c, params) {
      c.append(NG.encabezado("Luminarias y sensores", "Comportamiento de las 64 luminarias y de los sensores que las controlan: brillo por hora, presencia detectada por los PIR y estado de cada equipo."));
      const p = NG.paramsFiltro();
      const [perfil, calor, estados, lums, sensores] = await Promise.all([
        NG.api("operacion/perfil-horario", p), NG.api("operacion/mapa-calor", p), NG.api("operacion/estados", p),
        NG.api("luminarias", p), NG.api("sensores", p),
      ]);
      const r1 = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(r1);
      const pBrillo = NG.panel({ titulo: "Brillo promedio por hora del día", subtitulo: perfil.brillo_por_tipo_zona.length ? "Por tipo de zona. El nivel base nocturno es 25 % y baja a 15 % entre las 2:00 y las 5:00." : "Luminaria seleccionada." });
      r1.append(pBrillo.raiz);
      const series = perfil.brillo_por_tipo_zona.length
        ? perfil.brillo_por_tipo_zona.map((s) => ({ nombre: ZONA_TIPO[s.nombre] || s.nombre, valores: s.valores }))
        : [{ nombre: "Brillo", valores: perfil.brillo_prom, area: true }];
      const filasPerfil = perfil.horas.map((h, i) => Object.assign({ hora: h, brillo: perfil.brillo_prom[i], encendida: perfil.pct_encendida[i], lux: perfil.lux_prom[i], det: perfil.detecciones_intervalo[i] },
        ...perfil.brillo_por_tipo_zona.map((s) => ({ ["z_" + s.nombre]: s.valores[i] }))));
      NG.graf.tarjeta(pBrillo, (d) => NG.graf.linea(d, { x: perfil.horas, series, alto: 250, formatoY: (v) => NG.fmt.num(v, 0) + " %", formatoTooltip: (v) => NG.fmt.num(v, 1) + " %" }),
        { columnas: [{ clave: "hora", titulo: "Hora" }, { clave: "brillo", titulo: "Brillo prom. (%)", num: true, formato: (v) => NG.fmt.num(v, 1) },
          { clave: "encendida", titulo: "Encendida (%)", num: true, formato: (v) => NG.fmt.num(v, 1) }, { clave: "lux", titulo: "Luz ambiente (lux)", num: true, formato: (v) => NG.fmt.num(v, 1) },
          { clave: "det", titulo: "Detecciones / intervalo", num: true, formato: (v) => NG.fmt.num(v, 2) }].concat(
          perfil.brillo_por_tipo_zona.map((s) => ({ clave: "z_" + s.nombre, titulo: (ZONA_TIPO[s.nombre] || s.nombre) + " (%)", num: true, formato: (v) => NG.fmt.num(v, 1) }))),
        filas: filasPerfil }, null, "perfil_horario");

      const pCalor = NG.panel({ titulo: "Presencia detectada por los sensores PIR", subtitulo: "Detecciones promedio por intervalo de 15 minutos, según el día de la semana y la hora." });
      r1.append(pCalor.raiz);
      NG.graf.tarjeta(pCalor, (d) => NG.graf.mapaCalor(d, { filas: calor.dias, columnas: calor.horas, valores: calor.detecciones, formato: (v) => NG.fmt.num(v, 2),
        nombreValor: "detecciones por intervalo", formatoColumna: (h) => h + "h" }),
        { columnas: [{ clave: "dia", titulo: "Día" }].concat(calor.horas.map((h, j) => ({ clave: "h" + j, titulo: h + "h", num: true, formato: (v) => NG.fmt.num(v, 2) }))),
          filas: calor.dias.map((dia, i) => Object.assign({ dia }, ...calor.horas.map((_, j) => ({ ["h" + j]: calor.detecciones[i][j] })))) }, null, "presencia_pir");

      const r2 = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(r2);
      const pEst = NG.panel({ titulo: "Tiempo en cada estado operativo", subtitulo: NG.fmt.num(estados.total) + " intervalos de 15 minutos en el periodo." });
      r2.append(pEst.raiz);
      NG.graf.tarjeta(pEst, (d) => NG.graf.barras(d, { categorias: estados.estados.map((e) => T()[e.codigo] || e.nombre), valores: estados.estados.map((e) => e.pct),
        formato: (v) => NG.fmt.pct(v, 2), nombreValor: "del tiempo",
        extra: estados.estados.map((e) => ({ color: e.categoria === "FUERA_DE_SERVICIO" ? "--gris-contexto" : "--s1", tooltip: [{ valor: NG.fmt.num(e.intervalos), etiqueta: "intervalos" }] })) }),
        { columnas: [{ clave: "codigo", titulo: "Estado" }, { clave: "categoria", titulo: "Categoría" }, { clave: "intervalos", titulo: "Intervalos", num: true, formato: (v) => NG.fmt.num(v) },
          { clave: "pct", titulo: "% del tiempo", num: true, formato: (v) => NG.fmt.num(v, 2) }], filas: estados.estados }, null, "estados");

      const pEnc = NG.panel({ titulo: "Encendido según la luz ambiente", subtitulo: "Porcentaje del tiempo con la luminaria encendida en cada hora. El LDR la enciende cuando la luz baja de unos 40 lux." });
      r2.append(pEnc.raiz);
      NG.graf.tarjeta(pEnc, (d) => NG.graf.linea(d, { x: perfil.horas, series: [{ nombre: "Tiempo encendida", valores: perfil.pct_encendida, area: true }], alto: 230,
        formatoY: (v) => NG.fmt.num(v, 0) + " %", formatoTooltip: (v) => NG.fmt.num(v, 1) + " %" }),
        { columnas: [{ clave: "hora", titulo: "Hora" }, { clave: "encendida", titulo: "Encendida (%)", num: true, formato: (v) => NG.fmt.num(v, 1) },
          { clave: "lux", titulo: "Luz ambiente prom. (lux)", num: true, formato: (v) => NG.fmt.num(v, 1) }], filas: filasPerfil }, null, "encendido_por_hora");

      // ----- tabla de luminarias + detalle
      const pTabla = NG.panel({ titulo: "Luminarias", subtitulo: "Haga clic en una fila para ver su serie de tiempo, sus fallas y sus mantenimientos." });
      c.append(pTabla.raiz);
      const contTabla = NG.el("div");
      const detalle = NG.el("div", { estilo: "margin-top:16px" });
      pTabla.cuerpo.append(contTabla, detalle);
      const self = this;
      let seleccion = parseInt(params.get("id") || "", 10) || null;
      const cols = [
        { clave: "codigo", titulo: "Luminaria" }, { clave: "zona_nombre", titulo: "Zona" }, { clave: "ubicacion", titulo: "Tramo" }, { clave: "modelo", titulo: "Modelo" },
        { clave: "es_fisica", titulo: "Origen", nodo: (v) => NG.etiquetaOrigen(v ? "FISICO" : "SIMULADO") },
        { clave: "ultimo_estado", titulo: "Último estado", formato: (v) => T()[v] || v },
        { clave: "energia_kwh", titulo: "Energía (kWh)", num: true, formato: (v) => NG.fmt.num(v, 1) },
        { clave: "ahorro_pct", titulo: "Ahorro (%)", num: true, formato: (v) => NG.fmt.num(v, 1) },
        { clave: "horas_encendida", titulo: "Horas encendida", num: true, formato: (v) => NG.fmt.num(v, 0) },
        { clave: "disponibilidad_pct", titulo: "Disponibilidad (%)", num: true, formato: (v) => NG.fmt.num(v, 2) },
        { clave: "fallas", titulo: "Fallas", num: true },
      ];
      function pintarTabla() {
        NG.vaciar(contTabla);
        contTabla.append(NG.tabla(cols, ordenable(lums.luminarias, self.orden, self.dir), {
          alta: true, orden: self.orden, dir: self.dir,
          ordenar: (k) => { if (self.orden === k) self.dir = self.dir === "asc" ? "desc" : "asc"; else { self.orden = k; self.dir = k === "codigo" ? "asc" : "desc"; } pintarTabla(); },
          alClic: (f) => { seleccion = f.luminaria_id; pintarTabla(); verDetalle(seleccion); history.replaceState(null, "", "#/luminarias?id=" + seleccion); },
          clave: (f) => f.luminaria_id, seleccion,
        }));
      }
      async function verDetalle(id, rango) {
        NG.vaciar(detalle);
        detalle.append(NG.el("p", { clase: "cargando", texto: "Cargando la luminaria…" }));
        const prm = NG.paramsFiltro(rango || {});
        let d;
        try { d = await NG.api("luminaria/" + id, prm); } catch (e) { NG.vaciar(detalle); detalle.append(NG.aviso(e.message, true)); return; }
        NG.vaciar(detalle);
        const l = d.luminaria;
        detalle.append(NG.el("div", { clase: "titulo-vista" }, NG.el("h2", { texto: l.codigo + " · " + l.ubicacion_nombre }), NG.etiquetaOrigen(l.es_fisica ? "FISICO" : "SIMULADO")),
          NG.el("p", { clase: "nota", texto: `${l.modelo_descripcion} · ${NG.fmt.num(l.potencia_nominal_w, 0)} W · instalada el ${NG.fmt.fecha(l.fecha_instalacion)}` + (l.tablero ? ` · tablero ${l.tablero.toLowerCase()}, a ${l.posicion_cm} cm del borde norte` : "") }));
        const rj = NG.el("div", { clase: "rejilla rejilla-2", estilo: "margin-top:12px" });
        detalle.append(rj);
        if (d.modo === "15min") {
          const pS = NG.panel({ titulo: "Brillo cada 15 minutos", subtitulo: NG.fmt.fecha(d.filtros.desde) + " a " + NG.fmt.fecha(d.filtros.hasta) + ". Fuente: fact_operacion_luminaria." });
          rj.append(pS.raiz);
          NG.graf.tarjeta(pS, (g) => NG.graf.linea(g, { x: d.serie.map((s) => s.t), series: [{ nombre: "Brillo", valores: d.serie.map((s) => s.brillo_pct), area: true }], alto: 230,
            formatoX: (v) => String(v).slice(5, 16).replace("-", "/"), formatoY: (v) => NG.fmt.num(v, 0) + " %", formatoTooltip: (v) => NG.fmt.num(v, 1) + " %" }),
            { columnas: [{ clave: "t", titulo: "Intervalo" }, { clave: "estado", titulo: "Estado" }, { clave: "brillo_pct", titulo: "Brillo (%)", num: true },
              { clave: "lux", titulo: "Lux", num: true }, { clave: "detecciones", titulo: "Detecciones", num: true }, { clave: "potencia_w", titulo: "Potencia (W)", num: true },
              { clave: "energia_wh", titulo: "Energía (Wh)", num: true }, { clave: "calidad", titulo: "Calidad" }, { clave: "origen", titulo: "Origen" }], filas: d.serie }, null, "serie_" + l.codigo);
          const pD = NG.panel({ titulo: "Detecciones del sensor PIR", subtitulo: "Personas o vehículos detectados en cada intervalo." });
          rj.append(pD.raiz);
          NG.graf.tarjeta(pD, (g) => NG.graf.columnas(g, { categorias: d.serie.map((s) => s.t), series: [{ nombre: "Detecciones", valores: d.serie.map((s) => s.detecciones) }], alto: 230,
            formatoX: (v) => String(v).slice(11, 16), formato: (v) => NG.fmt.num(v, 0) }), null, null);
        } else {
          const pS = NG.panel({ titulo: "Energía diaria", subtitulo: "Para ver la serie cada 15 minutos elija un rango de 7 días o menos." });
          pS.acciones.append(NG.el("button", { type: "button", onclick: () => {
            const fin = d.filtros.hasta; const ini = new Date(fin + "T12:00:00"); ini.setDate(ini.getDate() - 2);
            verDetalle(id, { desde: ini.toISOString().slice(0, 10), hasta: fin });
          } }, "Últimos 3 días"));
          rj.append(pS.raiz);
          NG.graf.tarjeta(pS, (g) => NG.graf.linea(g, { x: d.serie.map((s) => s.t), alto: 230, formatoX: (v) => NG.fmt.fechaCorta(v), formatoXTooltip: (v) => NG.fmt.fecha(v),
            formatoY: (v) => NG.fmt.num(v, 2), formatoTooltip: (v) => NG.fmt.num(v, 3) + " kWh",
            series: [{ nombre: "Consumo real", valores: d.serie.map((s) => s.energia_kwh), area: true }, { nombre: "Sin control adaptativo", valores: d.serie.map((s) => s.referencia_kwh), contexto: true }] }),
            { columnas: [{ clave: "t", titulo: "Fecha" }, { clave: "energia_kwh", titulo: "kWh", num: true }, { clave: "referencia_kwh", titulo: "Referencia (kWh)", num: true },
              { clave: "horas_encendida", titulo: "Horas encendida", num: true }, { clave: "brillo_noche", titulo: "Brillo noche (%)", num: true },
              { clave: "detecciones", titulo: "Detecciones", num: true }, { clave: "intervalos_falla", titulo: "Intervalos en falla", num: true }, { clave: "origen", titulo: "Origen" }], filas: d.serie }, null, "diario_" + l.codigo);
          const pH = NG.panel({ titulo: "Horas encendida por noche", subtitulo: "Fuente: fact_consumo_diario." });
          rj.append(pH.raiz);
          NG.graf.tarjeta(pH, (g) => NG.graf.linea(g, { x: d.serie.map((s) => s.t), alto: 230, formatoX: (v) => NG.fmt.fechaCorta(v), formatoXTooltip: (v) => NG.fmt.fecha(v),
            formatoY: (v) => NG.fmt.num(v, 0) + " h", formatoTooltip: (v) => NG.fmt.num(v, 2) + " h", series: [{ nombre: "Horas encendida", valores: d.serie.map((s) => s.horas_encendida) }] }), null, null);
        }
        const rj2 = NG.el("div", { clase: "rejilla rejilla-2", estilo: "margin-top:16px" });
        detalle.append(rj2);
        const pF = NG.panel({ titulo: "Fallas de la luminaria", subtitulo: NG.fmt.num(d.fallas.length) + " registradas." });
        rj2.append(pF.raiz);
        pF.cuerpo.append(NG.tabla([{ clave: "falla_id", titulo: "#", num: true }, { clave: "tipo_nombre", titulo: "Tipo" }, { clave: "severidad", titulo: "Severidad" },
          { clave: "detectada", titulo: "Detectada" }, { clave: "resuelta", titulo: "Resuelta", formato: (v) => v || "Abierta" },
          { clave: "horas_duracion", titulo: "Duración (h)", num: true, formato: (v) => NG.fmt.num(v, 1) }, { clave: "origen", titulo: "Origen", nodo: (v) => NG.etiquetaOrigen(v) }], d.fallas, { vacio: "Sin fallas registradas." }));
        const pM = NG.panel({ titulo: "Mantenimientos", subtitulo: NG.fmt.num(d.mantenimientos.length) + " órdenes." });
        rj2.append(pM.raiz);
        pM.cuerpo.append(NG.tabla([{ clave: "programada", titulo: "Programada" }, { clave: "tipo", titulo: "Tipo" }, { clave: "estado", titulo: "Estado" },
          { clave: "tecnico", titulo: "Técnico" }, { clave: "costo_cop", titulo: "Costo (COP)", num: true, formato: (v) => NG.fmt.cop(v) }], d.mantenimientos, { alta: true, vacio: "Sin mantenimientos." }));
        if (!rango) detalle.scrollIntoView({ behavior: "smooth", block: "start" });
      }
      pintarTabla();
      if (seleccion) verDetalle(seleccion);

      const pSen = NG.panel({ titulo: "Sensores", subtitulo: "Los sensores físicos llevan el pin del ESP32 al que están conectados." });
      c.append(pSen.raiz);
      pSen.cuerpo.append(NG.tabla([{ clave: "codigo", titulo: "Sensor" }, { clave: "tipo_nombre", titulo: "Tipo" }, { clave: "unidad", titulo: "Unidad" },
        { clave: "ubicacion_nombre", titulo: "Ubicación" }, { clave: "vivienda", titulo: "Vivienda", formato: (v) => v || "—" },
        { clave: "es_fisico", titulo: "Origen", nodo: (v) => NG.etiquetaOrigen(v ? "FISICO" : "SIMULADO") }, { clave: "pin_gpio", titulo: "Pin", formato: (v) => v || "—" },
        { clave: "modelo", titulo: "Modelo" }, { clave: "fallas", titulo: "Fallas", num: true }], sensores.sensores, { alta: true }));
    },
  };

  // ================================================================== consumo y eficiencia
  NG.vistas.consumo = {
    titulo: "Consumo y eficiencia",
    agrupar: "",
    async render(c) {
      c.append(NG.encabezado("Consumo y eficiencia", "Energía consumida frente a la que gastaría la red encendida al 100 % toda la noche, por zona, modelo y origen del dato. Fuente: fact_consumo_diario del data warehouse."));
      const d = await NG.api("consumo", NG.paramsFiltro({ agrupar: this.agrupar }));
      const t = d.total;
      const fis = d.por_origen.find((o) => o.codigo === "FISICO"), sim = d.por_origen.find((o) => o.codigo === "SIMULADO");
      c.append(NG.cifras([
        { etiqueta: "Energía consumida", valor: NG.fmt.num(t.energia_kwh, 0), unidad: "kWh" },
        { etiqueta: "Sin control adaptativo", valor: NG.fmt.num(t.referencia_kwh, 0), unidad: "kWh", nota: "Referencia: 100 % toda la noche" },
        { etiqueta: "Ahorro", valor: NG.fmt.num(t.ahorro_pct, 1), unidad: "%", nota: NG.fmt.num(t.ahorro_kwh, 0) + " kWh" },
        { etiqueta: "Por luminaria y noche (simulado)", valor: sim ? NG.fmt.num(sim.kwh_luminaria_dia, 3) : "—", unidad: "kWh", nota: sim ? NG.fmt.num(sim.horas_noche, 1) + " h encendida en promedio" : "" },
        { etiqueta: "Por poste y noche (maqueta)", valor: fis ? NG.fmt.num(fis.kwh_luminaria_dia, 3) : "—", unidad: "kWh", nota: fis ? "Gemelo de 60 W · " + NG.fmt.num(fis.dias) + " días con datos" : "Aún no hay datos físicos en el periodo" },
      ]));
      const pSerie = NG.panel({ titulo: "Consumo en el tiempo", subtitulo: "Consumo real y referencia sin control adaptativo." });
      ["dia", "semana", "mes"].forEach((a) => {
        const b = NG.el("button", { type: "button", "aria-pressed": String(d.agrupar === a) }, a === "dia" ? "Día" : a === "semana" ? "Semana" : "Mes");
        b.addEventListener("click", () => { this.agrupar = a; NG.recargar(); });
        pSerie.acciones.append(b);
      });
      c.append(pSerie.raiz);
      NG.graf.tarjeta(pSerie, (g) => NG.graf.linea(g, { x: d.serie.map((s) => s.etiqueta), alto: 260,
        formatoX: (v) => d.agrupar === "dia" ? NG.fmt.fechaCorta(v) : String(v).split(" (")[0], formatoY: (v) => NG.fmt.num(v, 0), formatoTooltip: (v) => NG.fmt.num(v, 1) + " kWh",
        series: [{ nombre: "Consumo real", valores: d.serie.map((s) => s.energia_kwh), area: true }, { nombre: "Sin control adaptativo", valores: d.serie.map((s) => s.referencia_kwh), contexto: true }] }),
        { columnas: [{ clave: "etiqueta", titulo: "Periodo" }, { clave: "energia_kwh", titulo: "Consumo (kWh)", num: true, formato: (v) => NG.fmt.num(v, 2) },
          { clave: "referencia_kwh", titulo: "Referencia (kWh)", num: true, formato: (v) => NG.fmt.num(v, 2) }, { clave: "ahorro_kwh", titulo: "Ahorro (kWh)", num: true, formato: (v) => NG.fmt.num(v, 2) }],
          filas: d.serie }, null, "consumo_serie");

      const r = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(r);
      const pZona = NG.panel({ titulo: "Consumo por zona", subtitulo: "Real frente a la referencia, en kWh." });
      r.append(pZona.raiz);
      NG.graf.tarjeta(pZona, (g) => NG.graf.columnas(g, { categorias: d.por_zona.map((z) => z.zona_nombre.replace(" (maqueta)", "")), alto: 260, formato: (v) => NG.fmt.compacto(v),
        series: [{ nombre: "Consumo real", valores: d.por_zona.map((z) => z.energia_kwh) }, { nombre: "Sin control adaptativo", valores: d.por_zona.map((z) => z.referencia_kwh), contexto: true }] }),
        { columnas: [{ clave: "zona_nombre", titulo: "Zona" }, { clave: "tipo_zona", titulo: "Tipo" }, { clave: "energia_kwh", titulo: "kWh", num: true, formato: (v) => NG.fmt.num(v, 1) },
          { clave: "referencia_kwh", titulo: "Referencia (kWh)", num: true, formato: (v) => NG.fmt.num(v, 1) }, { clave: "ahorro_pct", titulo: "Ahorro (%)", num: true, formato: (v) => NG.fmt.num(v, 1) },
          { clave: "horas_noche", titulo: "Horas / noche", num: true, formato: (v) => NG.fmt.num(v, 2) }, { clave: "brillo_noche", titulo: "Brillo noche (%)", num: true, formato: (v) => NG.fmt.num(v, 1) }],
          filas: d.por_zona }, null, "consumo_zona");
      const pAh = NG.panel({ titulo: "Ahorro por zona", subtitulo: "Las zonas con más tránsito suben más veces al 100 % y ahorran menos." });
      r.append(pAh.raiz);
      const zonasAh = d.por_zona.slice().sort((a, b) => (b.ahorro_pct || 0) - (a.ahorro_pct || 0));
      NG.graf.tarjeta(pAh, (g) => NG.graf.barras(g, { categorias: zonasAh.map((z) => z.zona_nombre), valores: zonasAh.map((z) => z.ahorro_pct), formato: (v) => NG.fmt.pct(v, 1), nombreValor: "de ahorro" }),
        { columnas: [{ clave: "zona_nombre", titulo: "Zona" }, { clave: "ahorro_pct", titulo: "Ahorro (%)", num: true, formato: (v) => NG.fmt.num(v, 1) }, { clave: "ahorro_kwh", titulo: "Ahorro (kWh)", num: true, formato: (v) => NG.fmt.num(v, 1) }], filas: zonasAh }, null, "ahorro_zona");

      const r2 = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(r2);
      const pTop = NG.panel({ titulo: "Luminarias que más consumen", subtitulo: "Diez mayores consumos del periodo (kWh)." });
      r2.append(pTop.raiz);
      NG.graf.tarjeta(pTop, (g) => NG.graf.barras(g, { categorias: d.top_consumo.map((x) => x.codigo), valores: d.top_consumo.map((x) => x.energia_kwh), formato: (v) => NG.fmt.num(v, 1) + " kWh",
        extra: d.top_consumo.map((x) => ({ tooltip: [{ valor: NG.fmt.pct(x.ahorro_pct), etiqueta: "de ahorro" }] })) }),
        { columnas: [{ clave: "codigo", titulo: "Luminaria" }, { clave: "zona_codigo", titulo: "Zona" }, { clave: "energia_kwh", titulo: "kWh", num: true, formato: (v) => NG.fmt.num(v, 2) },
          { clave: "ahorro_pct", titulo: "Ahorro (%)", num: true, formato: (v) => NG.fmt.num(v, 1) }], filas: d.top_consumo }, null, "top_consumo");
      const pMod = NG.panel({ titulo: "Eficiencia por modelo", subtitulo: "kWh por luminaria y por noche. El poste de maqueta es el gemelo de una luminaria de 60 W." });
      r2.append(pMod.raiz);
      NG.graf.tarjeta(pMod, (g) => NG.graf.barras(g, { categorias: d.por_modelo.map((m) => m.modelo_codigo + " · " + NG.fmt.num(m.potencia_nominal_w, 0) + " W"), valores: d.por_modelo.map((m) => m.kwh_luminaria_dia),
        formato: (v) => NG.fmt.num(v, 3) + " kWh" }),
        { columnas: [{ clave: "modelo_codigo", titulo: "Modelo" }, { clave: "potencia_nominal_w", titulo: "Potencia (W)", num: true }, { clave: "luminarias", titulo: "Luminarias", num: true },
          { clave: "kwh_luminaria_dia", titulo: "kWh / luminaria / noche", num: true, formato: (v) => NG.fmt.num(v, 3) }, { clave: "ahorro_pct", titulo: "Ahorro (%)", num: true, formato: (v) => NG.fmt.num(v, 1) }],
          filas: d.por_modelo }, null, "eficiencia_modelo");

      const pOrig = NG.panel({ titulo: "Datos físicos frente a simulados", subtitulo: "Mismos cálculos para los postes de la maqueta y para la ciudad simulada." });
      c.append(pOrig.raiz);
      pOrig.cuerpo.append(NG.tabla([{ clave: "codigo", titulo: "Origen", nodo: (v) => NG.etiquetaOrigen(v) }, { clave: "luminarias", titulo: "Luminarias", num: true },
        { clave: "dias", titulo: "Días con datos", num: true }, { clave: "intervalos", titulo: "Intervalos", num: true, formato: (v) => NG.fmt.num(v) },
        { clave: "energia_kwh", titulo: "Energía (kWh)", num: true, formato: (v) => NG.fmt.num(v, 2) }, { clave: "kwh_luminaria_dia", titulo: "kWh / luminaria / noche", num: true, formato: (v) => NG.fmt.num(v, 3) },
        { clave: "horas_noche", titulo: "Horas encendida / noche", num: true, formato: (v) => NG.fmt.num(v, 2) }, { clave: "ahorro_pct", titulo: "Ahorro (%)", num: true, formato: (v) => NG.fmt.num(v, 1) }],
        d.por_origen));
      pOrig.cuerpo.append(NG.el("p", { clase: "nota", estilo: "margin-top:8px", texto: "La maqueta no tiene medidor de corriente: su energía se calcula con el brillo PWM y la potencia del gemelo (60 W), por eso esos intervalos quedan marcados como imputados." }));
    },
  };

  // ================================================================== fallas y mantenimiento
  NG.vistas.fallas = {
    titulo: "Fallas y mantenimiento",
    async render(c) {
      c.append(NG.encabezado("Fallas y mantenimiento", "Fallas detectadas, tiempo hasta detectarlas y repararlas, y las órdenes de mantenimiento preventivo y correctivo. Fuente: fact_falla y fact_mantenimiento."));
      const d = await NG.api("fallas", NG.paramsFiltro());
      const k = d.kpi;
      c.append(NG.cifras([
        { etiqueta: "Fallas en el periodo", valor: NG.fmt.num(k.total), nota: NG.fmt.num(k.con_mantenimiento) + " con orden correctiva" },
        { etiqueta: "Abiertas ahora", valor: NG.fmt.num(k.abiertas) },
        { etiqueta: "Tiempo hasta detectar", valor: NG.fmt.num(k.mttd_h, 2), unidad: "h", nota: "Promedio (MTTD)" },
        { etiqueta: "Tiempo de reparación", valor: NG.fmt.num(k.mttr_h, 1), unidad: "h", nota: "Promedio de las resueltas (MTTR)" },
        { etiqueta: "Disponibilidad", valor: NG.fmt.num(k.disponibilidad_pct, 2), unidad: "%" },
        { etiqueta: "Costo correctivo", valor: NG.fmt.compacto(k.costo_cop), unidad: "COP" },
      ]));
      const r = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(r);
      const pTipo = NG.panel({ titulo: "Fallas por tipo", subtitulo: "Número de fallas detectadas en el periodo." });
      r.append(pTipo.raiz);
      NG.graf.tarjeta(pTipo, (g) => NG.graf.barras(g, { categorias: d.por_tipo.map((x) => x.nombre), valores: d.por_tipo.map((x) => x.n), formato: (v) => NG.fmt.num(v), nombreValor: "fallas",
        extra: d.por_tipo.map((x) => ({ tooltip: [{ valor: x.severidad, etiqueta: "severidad" }, { valor: NG.fmt.horas(x.horas_prom), etiqueta: "duración media" }, { valor: NG.fmt.horas(x.deteccion_prom), etiqueta: "hasta detectar" }] })) }),
        { columnas: [{ clave: "nombre", titulo: "Tipo" }, { clave: "severidad", titulo: "Severidad" }, { clave: "n", titulo: "Fallas", num: true }, { clave: "abiertas", titulo: "Abiertas", num: true },
          { clave: "horas_prom", titulo: "Duración media (h)", num: true }, { clave: "deteccion_prom", titulo: "Hasta detectar (h)", num: true }], filas: d.por_tipo }, null, "fallas_tipo");
      const pMes = NG.panel({ titulo: "Fallas por mes", subtitulo: "Según la fecha de detección." });
      r.append(pMes.raiz);
      NG.graf.tarjeta(pMes, (g) => NG.graf.columnas(g, { categorias: d.por_mes.map((x) => x.anio_mes), series: [{ nombre: "Fallas", valores: d.por_mes.map((x) => x.n) }], alto: 240, etiquetasValor: true, formato: (v) => NG.fmt.num(v) }),
        { columnas: [{ clave: "anio_mes", titulo: "Mes" }, { clave: "n", titulo: "Fallas", num: true }, { clave: "horas", titulo: "Horas fuera de servicio", num: true }], filas: d.por_mes }, null, "fallas_mes");

      const pAb = NG.panel({ titulo: "Fallas abiertas", subtitulo: "Pendientes de reparación al cierre de los datos." });
      c.append(pAb.raiz);
      pAb.cuerpo.append(NG.tabla([{ clave: "luminaria", titulo: "Luminaria" }, { clave: "zona_codigo", titulo: "Zona" }, { clave: "tipo", titulo: "Tipo" },
        { clave: "severidad", titulo: "Severidad", nodo: (v) => NG.etiqueta(v === "ALTA" ? "Alta" : v === "MEDIA" ? "Media" : "Baja", v === "ALTA" ? "critico" : v === "MEDIA" ? "serio" : "aviso") },
        { clave: "detectada", titulo: "Detectada" }, { clave: "horas_duracion", titulo: "Horas abierta", num: true, formato: (v) => NG.fmt.num(v, 1) },
        { clave: "tiene_mantenimiento", titulo: "Orden correctiva", formato: (v) => (v ? "Programada" : "Sin orden") }, { clave: "origen", titulo: "Origen", nodo: (v) => NG.etiquetaOrigen(v) }],
        d.abiertas, { alta: true, vacio: "No hay fallas abiertas.", alClic: (f) => { location.hash = "#/luminarias?id=" + f.luminaria_id; } }));

      const m = d.mantenimiento;
      const r2 = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(r2);
      const pMm = NG.panel({ titulo: "Órdenes de mantenimiento por mes", subtitulo: "Preventivas y correctivas según la fecha programada." });
      r2.append(pMm.raiz);
      NG.graf.tarjeta(pMm, (g) => NG.graf.columnas(g, { categorias: m.por_mes.map((x) => x.anio_mes), apilado: true, alto: 240, formato: (v) => NG.fmt.num(v),
        series: [{ nombre: "Preventivas", valores: m.por_mes.map((x) => x.preventivos) }, { nombre: "Correctivas", valores: m.por_mes.map((x) => x.correctivos) }] }),
        { columnas: [{ clave: "anio_mes", titulo: "Mes" }, { clave: "preventivos", titulo: "Preventivas", num: true }, { clave: "correctivos", titulo: "Correctivas", num: true },
          { clave: "costo_cop", titulo: "Costo (COP)", num: true, formato: (v) => NG.fmt.cop(v) }], filas: m.por_mes }, null, "mantenimiento_mes");
      const pEst = NG.panel({ titulo: "Estado de las órdenes", subtitulo: "Órdenes programadas en el periodo." });
      r2.append(pEst.raiz);
      const COLOR_EST = { REALIZADO: "--s1", PROGRAMADO: "--s2", EN_PROCESO: "--s4", CANCELADO: "--gris-contexto" };
      NG.graf.tarjeta(pEst, (g) => NG.graf.segmentada(g, { partes: m.por_estado.map((x) => ({ nombre: x.estado.charAt(0) + x.estado.slice(1).toLowerCase().replace("_", " "), valor: x.n, color: COLOR_EST[x.estado] })),
        formato: (v) => NG.fmt.num(v) + " órdenes" }), { columnas: [{ clave: "estado", titulo: "Estado" }, { clave: "n", titulo: "Órdenes", num: true }], filas: m.por_estado }, null, "estado_ordenes");
      pEst.cuerpo.append(NG.el("h3", { estilo: "margin:16px 0 8px", texto: "Por técnico (órdenes realizadas)" }),
        NG.tabla([{ clave: "nombre", titulo: "Técnico" }, { clave: "n", titulo: "Órdenes", num: true }, { clave: "horas", titulo: "Horas de trabajo", num: true, formato: (v) => NG.fmt.num(v, 1) },
          { clave: "retraso_prom", titulo: "Retraso medio (días)", num: true, formato: (v) => NG.fmt.num(v, 2) }], m.por_tecnico));

      const r3 = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(r3);
      const pTm = NG.panel({ titulo: "Mantenimiento por tipo", subtitulo: "Órdenes y costo total en pesos colombianos." });
      r3.append(pTm.raiz);
      NG.graf.tarjeta(pTm, (g) => NG.graf.barras(g, { categorias: m.por_tipo.map((x) => x.nombre), valores: m.por_tipo.map((x) => x.n), formato: (v) => NG.fmt.num(v), nombreValor: "órdenes",
        extra: m.por_tipo.map((x) => ({ color: x.es_correctivo ? "--s2" : "--s1", tooltip: [{ valor: NG.fmt.cop(x.costo_cop), etiqueta: "costo" }, { valor: x.es_correctivo ? "Correctivo" : "Preventivo", etiqueta: "" }] })) }),
        { columnas: [{ clave: "nombre", titulo: "Tipo" }, { clave: "es_correctivo", titulo: "Clase", formato: (v) => (v ? "Correctivo" : "Preventivo") }, { clave: "n", titulo: "Órdenes", num: true },
          { clave: "costo_cop", titulo: "Costo (COP)", num: true, formato: (v) => NG.fmt.cop(v) }, { clave: "duracion_prom", titulo: "Duración media (min)", num: true }], filas: m.por_tipo }, null, "mantenimiento_tipo");
      pTm.cuerpo.append(NG.el("ul", { clase: "leyenda", estilo: "margin-top:8px" }, NG.el("li", null, NG.el("span", { clase: "clave-barra", estilo: "background:" + NG.color("--s1") }), "Preventivo"),
        NG.el("li", null, NG.el("span", { clase: "clave-barra", estilo: "background:" + NG.color("--s2") }), "Correctivo")));
      const pPend = NG.panel({ titulo: "Órdenes pendientes", subtitulo: "Programadas o en proceso, en orden de fecha." });
      r3.append(pPend.raiz);
      pPend.cuerpo.append(NG.tabla([{ clave: "programada", titulo: "Programada" }, { clave: "luminaria", titulo: "Luminaria" }, { clave: "tipo", titulo: "Tipo" },
        { clave: "es_correctivo", titulo: "Clase", formato: (v) => (v ? "Correctivo" : "Preventivo") }, { clave: "tecnico", titulo: "Técnico" }], m.pendientes, { alta: true, vacio: "No hay órdenes pendientes." }));
    },
  };
})();
