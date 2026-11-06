/* NeoGrid · Vista general: la red de noche (repetición intervalo a intervalo), cifras clave,
   energía diaria y la maqueta física en vivo. */
(function () {
  "use strict";
  const NG = window.NG;
  NG.vistas = NG.vistas || {};

  // Plano esquemático: cada tramo es una polilínea; las luminarias se reparten a lo largo de ella.
  const PLANO = {
    "OES-T1": { pts: [[78, 46], [78, 206]], lado: -1, maqueta: true },
    "OES-T2": { pts: [[78, 206], [78, 366]], lado: -1, maqueta: true },
    "EST-T1": { pts: [[178, 46], [178, 206]], lado: 1, maqueta: true },
    "EST-T2": { pts: [[178, 206], [178, 366]], lado: 1, maqueta: true },
    "NRT-T1": { pts: [[330, 70], [640, 70]], lado: -1 },
    "NRT-T2": { pts: [[330, 128], [640, 128]], lado: 1 },
    "AVC-T1": { pts: [[300, 196], [840, 196]], lado: -1 },
    "AVC-T2": { pts: [[300, 232], [840, 232]], lado: 1 },
    "AVC-T3": { circulo: [895, 214, 38] },
    "HOS-T1": { pts: [[340, 300], [500, 300]], lado: -1 },
    "HOS-T2": { pts: [[500, 300], [500, 392], [380, 392]], lado: 1 },
    "PLZ-T1": { rect: [690, 290, 110, 84] },
    "PLZ-T2": { pts: [[600, 404], [960, 404]], lado: -1 },
  };
  const ETIQUETAS = [
    { x: 128, y: 24, t: "Maqueta física", ancla: "middle", fuerte: true },
    { x: 60, y: 386, t: "Oeste", ancla: "middle" }, { x: 196, y: 386, t: "Este", ancla: "middle" },
    { x: 330, y: 50, t: "Barrio Norte", ancla: "start" },
    { x: 300, y: 176, t: "Avenida Central", ancla: "start" },
    { x: 340, y: 282, t: "Zona Hospitalaria", ancla: "start" },
    { x: 690, y: 278, t: "Plaza Central", ancla: "start" },
  ];

  function longitud(pts) { let l = 0; for (let i = 1; i < pts.length; i++) l += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]); return l; }
  function puntoEn(pts, d) {
    for (let i = 1; i < pts.length; i++) {
      const seg = Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
      if (d <= seg || i === pts.length - 1) {
        const t = seg ? Math.min(1, d / seg) : 0;
        const dx = (pts[i][0] - pts[i - 1][0]) / (seg || 1), dy = (pts[i][1] - pts[i - 1][1]) / (seg || 1);
        return { x: pts[i - 1][0] + dx * seg * t, y: pts[i - 1][1] + dy * seg * t, nx: -dy, ny: dx };
      }
      d -= seg;
    }
    return { x: pts[0][0], y: pts[0][1], nx: 0, ny: 1 };
  }

  function posiciones(luminarias) {
    const porTramo = {};
    luminarias.forEach((l) => (porTramo[l.ubicacion] = porTramo[l.ubicacion] || []).push(l));
    const pos = {};
    Object.entries(porTramo).forEach(([tramo, lista]) => {
      const p = PLANO[tramo];
      if (!p) return;
      lista.sort((a, b) => (a.posicion_cm || 0) - (b.posicion_cm || 0) || a.luminaria_id - b.luminaria_id);
      if (p.circulo) {
        const [cx, cy, r] = p.circulo;
        lista.forEach((l, i) => { const a = -Math.PI / 2 + (i * 2 * Math.PI) / lista.length; pos[l.luminaria_id] = { x: cx + (r + 10) * Math.cos(a), y: cy + (r + 10) * Math.sin(a) }; });
      } else if (p.rect) {
        const [x, y, w, h] = p.rect;
        const per = [[x, y], [x + w, y], [x + w, y + h], [x, y + h], [x, y]];
        const L = longitud(per);
        lista.forEach((l, i) => { const q = puntoEn(per, (i + 0.5) * L / lista.length); pos[l.luminaria_id] = { x: q.x, y: q.y }; });
      } else {
        const L = longitud(p.pts);
        lista.forEach((l, i) => {
          const d = p.maqueta && l.posicion_cm !== null ? ((l.posicion_cm - (tramo.endsWith("T2") ? 50 : 0)) / 50) * L : (i + 0.5) * L / lista.length;
          const q = puntoEn(p.pts, Math.max(4, Math.min(L - 4, d)));
          pos[l.luminaria_id] = { x: q.x + q.nx * 12 * p.lado, y: q.y + q.ny * 12 * p.lado };
        });
      }
    });
    return pos;
  }

  const ESTADO_TXT = { APAGADA: "Apagada", NOCHE_BASE: "Nivel base", MADRUGADA: "Madrugada", PRESENCIA: "Presencia (100 %)",
    AHORRO: "Presencia en modo ahorro", ENCENDIDA_DIA: "Encendida de día (falla de LDR)", FALLA: "En falla", MANTENIMIENTO: "En mantenimiento" };
  NG.ESTADO_TXT = ESTADO_TXT;

  /* Un tablero de la maqueta está "en vivo" si su última LECTURA (no el último envío del puente)
     tiene menos de 2 minutos: edad del envío + antigüedad de la lectura cuando se envió. */
  const LIMITE_VIVO_S = 120;
  function edadLectura(vivo, t) {
    return (vivo && vivo.edad_segundos || 0) + (t.segundos_desde_lectura == null ? 0 : t.segundos_desde_lectura);
  }
  function tableroFresco(vivo, t) { return edadLectura(vivo, t) <= LIMITE_VIVO_S; }
  function hayVivoFresco(vivo) { return !!(vivo && vivo.tableros && vivo.tableros.some((t) => tableroFresco(vivo, t))); }

  function heroNoche(destino, datos, vivo) {
    const lums = datos.luminarias;
    const pos = posiciones(lums);
    const slots = datos.intervalos;
    const ancho = 1000, alto = 420;
    const svg = NG.svg("svg", { viewBox: `0 0 ${ancho} ${alto}`, role: "img", "aria-label": "Plano de la red de alumbrado con el brillo de cada luminaria en el intervalo elegido" });
    const defs = NG.svg("defs");
    const grad = NG.svg("radialGradient", { id: "halo" });
    grad.append(NG.svg("stop", { offset: "0%", "stop-color": "#ffd88a", "stop-opacity": "0.95" }),
      NG.svg("stop", { offset: "45%", "stop-color": "#f3b54a", "stop-opacity": "0.35" }),
      NG.svg("stop", { offset: "100%", "stop-color": "#f3b54a", "stop-opacity": "0" }));
    defs.append(grad);
    svg.append(defs);
    // manzanas y calles
    svg.append(NG.svg("rect", { x: 30, y: 34, width: 196, height: 344, rx: 10, fill: "#16213a", stroke: "#2c3a59" }));
    Object.entries(PLANO).forEach(([tramo, p]) => {
      const estilo = { fill: "none", stroke: "#2c3a59", "stroke-width": p.maqueta ? 10 : 14, "stroke-linecap": "round", "stroke-linejoin": "round" };
      if (p.circulo) svg.append(NG.svg("circle", Object.assign({ cx: p.circulo[0], cy: p.circulo[1], r: p.circulo[2] }, estilo)));
      else if (p.rect) svg.append(NG.svg("rect", Object.assign({ x: p.rect[0], y: p.rect[1], width: p.rect[2], height: p.rect[3], rx: 6 }, estilo)));
      else svg.append(NG.svg("polyline", Object.assign({ points: p.pts.map((q) => q.join(",")).join(" ") }, estilo)));
    });
    svg.append(NG.svg("line", { x1: 840, y1: 214, x2: 857, y2: 214, stroke: "#2c3a59", "stroke-width": 50 }));
    [[78, 206], [178, 206]].forEach(([x, y]) => svg.append(NG.svg("line", { x1: x - 9, x2: x + 9, y1: y, y2: y, stroke: "#3f4f74", "stroke-width": 2 })));
    ETIQUETAS.forEach((e) => svg.append(NG.svg("text", { x: e.x, y: e.y, "text-anchor": e.ancla, fill: e.fuerte ? "#e5eaf1" : "#8d99ad", "font-size": e.fuerte ? 14 : 13, "font-weight": e.fuerte ? 600 : 500, texto: e.t })));
    const etiquetaVivo = NG.svg("text", { x: 128, y: 400, "text-anchor": "middle", fill: "#f3b54a", "font-size": 12.5, "font-weight": 600, texto: "" });
    svg.append(etiquetaVivo);

    const capa = NG.svg("g");
    svg.append(capa);
    const nodos = {};
    lums.forEach((l) => {
      const p = pos[l.luminaria_id];
      if (!p) return;
      const g = NG.svg("g", { class: "lum", tabindex: 0, role: "button", transform: `translate(${p.x.toFixed(1)},${p.y.toFixed(1)})` });
      const halo = NG.svg("circle", { r: 0, fill: "url(#halo)" });
      const nucleo = NG.svg("circle", { r: 4.5, class: "lum-nucleo" });
      const marca = NG.svg("path", { d: "M-3,-3L3,3M3,-3L-3,3", stroke: "#ffffff", "stroke-width": 1.6, visibility: "hidden" });
      g.append(halo, nucleo, marca, NG.svg("circle", { r: 13, fill: "transparent" }));
      capa.append(g);
      nodos[l.luminaria_id] = { g, halo, nucleo, marca, info: l };
      const abrir = () => { location.hash = "#/luminarias?id=" + l.luminaria_id; };
      g.addEventListener("click", abrir);
      g.addEventListener("keydown", (e) => { if (e.key === "Enter") abrir(); });
    });

    const lecturas = NG.el("div", { clase: "noche-lecturas" });
    const hora = NG.el("p", { clase: "lectura-hora", texto: "--:--" });
    const fecha = NG.el("p", { clase: "lectura-fecha" });
    const crearLectura = (etq) => { const v = NG.el("p", { clase: "l-valor" }); lecturas.append(NG.el("div", { clase: "lectura" }, NG.el("p", { clase: "l-etiqueta", texto: etq }), v)); return v; };
    lecturas.append(NG.el("div", null, hora, fecha));
    const vEnc = crearLectura("Luminarias encendidas");
    const vBri = crearLectura("Brillo promedio de las encendidas");
    const vPot = crearLectura("Potencia de la red");
    const vDet = crearLectura("Detecciones de movimiento");

    let actual = Math.max(0, slots.findIndex((s) => s.hora === "21:00"));
    let enVivo = false;

    function valoresVivo() {
      const r = {};
      (vivo && vivo.tableros || []).forEach((t) => {
        if (!tableroFresco(vivo, t)) return;   // lectura vieja: esos 8 postes quedan "sin datos recientes"
        const desde = t.tablero === "OESTE" ? 1 : 9;
        const est = t.estado === "DIA" ? "APAGADA" : t.estado === "PERSONA" ? (t.ahorro ? "AHORRO" : "PRESENCIA") : (t.brillo_pct <= 15 ? "MADRUGADA" : "NOCHE_BASE");
        for (let k = 0; k < 8; k++) r[desde + k] = [t.brillo_pct, est, t.pir ? 1 : 0, t.nivel_luz_lux, 60 * (t.brillo_pct || 0) / 100 + 1.5, "FISICO"];
      });
      return r;
    }

    function pintar(i) {
      actual = Math.max(0, Math.min(slots.length - 1, i));
      const s = slots[actual];
      if (!s) return;
      const vivos = enVivo ? valoresVivo() : {};
      let enc = 0, sumaB = 0, pot = 0, det = 0, n = 0;
      Object.entries(nodos).forEach(([id, nd]) => {
        // En vivo, los 16 postes físicos muestran solo el dato real; nunca la simulación de esa noche.
        const v = enVivo && Number(id) <= 16 ? vivos[id] : (vivos[id] || s.luminarias[id]);
        if (!v) {
          nd.nucleo.setAttribute("fill", "#2a3550"); nd.nucleo.setAttribute("stroke", "#5b6886"); nd.nucleo.setAttribute("stroke-dasharray", enVivo ? "2 2" : "");
          nd.halo.setAttribute("r", 0); nd.marca.setAttribute("visibility", "hidden"); nd.datos = null;
          nd.g.setAttribute("aria-label", `${nd.info.codigo}: sin datos recientes`);
          return;
        }
        nd.nucleo.setAttribute("stroke-dasharray", "");
        const [brillo, estado, d, , p] = v;
        n++;
        det += d || 0; pot += p || 0;
        const falla = estado === "FALLA", mant = estado === "MANTENIMIENTO";
        if (brillo > 0) { enc++; sumaB += brillo; }
        const k = Math.max(0, Math.min(1, (brillo || 0) / 100));
        nd.halo.setAttribute("r", brillo > 0 ? (8 + 26 * Math.sqrt(k)).toFixed(1) : 0);
        nd.halo.setAttribute("opacity", (0.35 + 0.65 * k).toFixed(2));
        nd.nucleo.setAttribute("fill", falla ? "#d03b3b" : mant ? "#7b8595" : brillo > 0 ? `hsl(40, ${70 + 25 * k}%, ${58 + 22 * k}%)` : "#2a3550");
        nd.nucleo.setAttribute("stroke", brillo > 0 || falla ? "none" : "#5b6886");
        nd.nucleo.setAttribute("stroke-width", 1.2);
        nd.marca.setAttribute("visibility", falla ? "visible" : "hidden");
        nd.g.setAttribute("aria-label", `${nd.info.codigo}: ${ESTADO_TXT[estado] || estado}, brillo ${NG.fmt.num(brillo, 0)} %`);
        nd.datos = v;
      });
      hora.textContent = s.hora;
      fecha.textContent = NG.fmt.fecha(s.fecha) + (enVivo ? " · maqueta en vivo" : "");
      vEnc.textContent = ""; vEnc.append(String(enc), NG.el("small", { texto: "de " + n }));
      vBri.textContent = ""; vBri.append(enc ? NG.fmt.num(sumaB / enc, 0) : "0", NG.el("small", { texto: "%" }));
      vPot.textContent = ""; vPot.append(NG.fmt.num(pot / 1000, 2), NG.el("small", { texto: "kW" }));
      vDet.textContent = ""; vDet.append(NG.fmt.num(det), NG.el("small", { texto: "en 15 min" }));
      rango.value = actual;
      etiquetaVivo.textContent = enVivo ? (hayVivoFresco(vivo) ? "En vivo" : "Sin datos recientes") : "";
    }

    Object.values(nodos).forEach((nd) => {
      const mostrar = (ev) => {
        const v = nd.datos;
        const r = nd.g.getBoundingClientRect();
        NG.tooltip.mostrar(ev.clientX ?? r.right, ev.clientY ?? r.top, nd.info.codigo + " · " + nd.info.ubicacion_nombre,
          v ? [{ valor: NG.fmt.num(v[0], 0) + " %", etiqueta: ESTADO_TXT[v[1]] || v[1] }, { valor: NG.fmt.num(v[2]), etiqueta: "detecciones" },
            { valor: NG.fmt.num(v[4], 1) + " W", etiqueta: "potencia" }, { valor: v[5] === "FISICO" ? "Físico" : "Simulado", etiqueta: "origen del dato" }]
            : [{ valor: "Sin datos", etiqueta: "" }]);
      };
      nd.g.addEventListener("pointermove", mostrar);
      nd.g.addEventListener("pointerleave", NG.tooltip.ocultar);
      nd.g.addEventListener("focus", mostrar);
      nd.g.addEventListener("blur", NG.tooltip.ocultar);
    });

    const rango = NG.el("input", { type: "range", min: 0, max: Math.max(0, slots.length - 1), step: 1, value: actual, "aria-label": "Hora de la noche" });
    rango.addEventListener("input", () => pintar(parseInt(rango.value, 10)));
    let temporizador = null;
    const botonPlay = NG.el("button", { type: "button", clase: "boton-noche", "aria-pressed": "false" }, "Reproducir la noche");
    botonPlay.addEventListener("click", () => {
      if (temporizador) { clearInterval(temporizador); temporizador = null; botonPlay.textContent = "Reproducir la noche"; botonPlay.setAttribute("aria-pressed", "false"); return; }
      if (actual >= slots.length - 1) pintar(0);
      botonPlay.textContent = "Pausar"; botonPlay.setAttribute("aria-pressed", "true");
      temporizador = setInterval(() => {
        if (!document.body.contains(svg) || actual >= slots.length - 1) { clearInterval(temporizador); temporizador = null; botonPlay.textContent = "Reproducir la noche"; return; }
        pintar(actual + 1);
      }, 420);
    });
    const fechaInput = NG.el("input", { type: "date", value: datos.fecha, min: datos.extension.desde, max: datos.extension.hasta, "aria-label": "Noche a mostrar" });
    fechaInput.addEventListener("change", () => { if (fechaInput.value) NG.vistas.general.noche = fechaInput.value; NG.recargar(); });
    const botonVivo = NG.el("button", { type: "button", clase: "boton-noche", "aria-pressed": "false" }, "Maqueta en vivo");
    function estadoBoton() {
      const hay = hayVivoFresco(vivo);
      botonVivo.disabled = !hay && !enVivo;
      botonVivo.title = hay ? "Mostrar el estado actual de los 16 postes físicos" : "La maqueta no está enviando lecturas recientes";
    }
    estadoBoton();
    botonVivo.addEventListener("click", () => { enVivo = !enVivo; botonVivo.setAttribute("aria-pressed", String(enVivo)); estadoBoton(); pintar(actual); });

    const leyenda = NG.el("ul", { clase: "noche-leyenda" },
      NG.el("li", null, (() => { const s = NG.svg("svg", { width: 26, height: 18, viewBox: "-13 -9 26 18" }); s.append(NG.svg("circle", { r: 9, fill: "url(#halo)" }), NG.svg("circle", { r: 4.5, fill: "hsl(40, 95%, 80%)" })); return s; })(), "Encendida (el halo crece con el brillo)"),
      NG.el("li", null, (() => { const s = NG.svg("svg", { width: 14, height: 14, viewBox: "-7 -7 14 14" }); s.append(NG.svg("circle", { r: 4.5, fill: "#2a3550", stroke: "#5b6886", "stroke-width": 1.2 })); return s; })(), "Apagada por luz natural"),
      NG.el("li", null, (() => { const s = NG.svg("svg", { width: 14, height: 14, viewBox: "-7 -7 14 14" }); s.append(NG.svg("circle", { r: 4.5, fill: "#d03b3b" }), NG.svg("path", { d: "M-3,-3L3,3M3,-3L-3,3", stroke: "#fff", "stroke-width": 1.6 })); return s; })(), "En falla"),
      NG.el("li", null, (() => { const s = NG.svg("svg", { width: 14, height: 14, viewBox: "-7 -7 14 14" }); s.append(NG.svg("circle", { r: 4.5, fill: "#7b8595" })); return s; })(), "En mantenimiento"),
      NG.el("li", { texto: "Haga clic en una luminaria para ver su detalle." }));

    destino.append(
      NG.el("div", { clase: "noche-encabezado" },
        NG.el("h1", { texto: "La red, intervalo a intervalo" }),
        NG.el("p", { texto: "Las 64 luminarias de NeoGrid durante una noche, cada 15 minutos, desde el hecho principal del data warehouse. Los 16 postes de la izquierda son los de la maqueta física." })),
      NG.el("div", { clase: "noche-plano" }, svg),
      lecturas,
      NG.el("div", { clase: "noche-control" }, botonPlay, rango, fechaInput, botonVivo),
      leyenda);
    pintar(actual);
    // El panel "Maqueta en vivo" consulta cada 10 s y entrega aquí el estado nuevo.
    return {
      actualizarVivo(nuevo) {
        if (!nuevo) return;
        vivo = nuevo;
        estadoBoton();
        if (enVivo) pintar(actual);
      },
    };
  }

  // ------------------------------------------------------------------ maqueta en vivo
  function panelVivo(panel, vivo) {
    NG.vaciar(panel.cuerpo);
    if (!vivo || !vivo.tableros || !vivo.tableros.length) {
      panel.cuerpo.append(NG.el("p", { clase: "nota", texto: vivo && vivo.mensaje ? vivo.mensaje + " " : "" },
        "Cuando el computador de la maqueta ejecuta el puente (puente_nube.py), aquí aparece cada 10 segundos el estado de los tableros oeste y este."));
      return;
    }
    const envioViejo = vivo.edad_segundos !== undefined && vivo.edad_segundos > LIMITE_VIVO_S;
    const algunoFresco = hayVivoFresco(vivo);
    const edadMin = Math.min(...vivo.tableros.map((t) => edadLectura(vivo, t)));
    const fmtEdad = (s) => s < 120 ? NG.fmt.num(s, 0) + " s" : s < 7200 ? NG.fmt.num(s / 60, 0) + " min" : NG.fmt.num(s / 3600, 1) + " h";
    const nota = envioViejo ? "El puente no envía datos desde hace " + fmtEdad(vivo.edad_segundos) + " (el computador de la maqueta puede estar apagado). "
      : !algunoFresco ? "El puente está conectado, pero la última lectura de los ESP32 es de hace " + fmtEdad(edadMin) + ": revise que la maqueta esté encendida y en la misma red. "
      : "Actualizado hace " + NG.fmt.num(vivo.edad_segundos || 0) + " s. ";
    panel.cuerpo.append(NG.el("p", { clase: "nota", texto: nota + "Fuente: " + vivo.fuente + "." }));
    const tableros = NG.el("div", { clase: "vivo-tableros" });
    vivo.tableros.forEach((t) => {
      const enLinea = (t.conexion || "").toLowerCase() === "en_linea";
      const fresco = tableroFresco(vivo, t);
      tableros.append(NG.el("div", { clase: "tablero-vivo" },
        NG.el("h3", null, "Tablero " + (t.tablero === "OESTE" ? "oeste" : "este"),
          !fresco ? NG.etiqueta("Sin datos recientes", "aviso") : NG.etiqueta(enLinea ? "En línea" : "Sin conexión", enLinea ? "bueno" : "critico")),
        NG.el("dl", null,
          NG.el("dt", { texto: "Estado" }), NG.el("dd", { texto: t.estado === "PERSONA" ? "Persona detectada" : t.estado === "NOCHE" ? "Noche" : t.estado === "DIA" ? "Día" : "—" }),
          NG.el("dt", { texto: "Brillo de los 8 postes" }), NG.el("dd", { texto: NG.fmt.num(t.brillo_pct, 0) + " %" }),
          NG.el("dt", { texto: "Luz ambiente" }), NG.el("dd", { texto: NG.fmt.num(t.nivel_luz_lux, 1) + " lux (LDR " + NG.fmt.num(t.lectura_ldr) + ")" }),
          NG.el("dt", { texto: "Movimiento (PIR)" }), NG.el("dd", { texto: t.pir ? "Sí" : "No" }),
          NG.el("dt", { texto: "Modo ahorro" }), NG.el("dd", { texto: t.ahorro ? "Activo" : "No" }),
          NG.el("dt", { texto: "LDR" }), NG.el("dd", { texto: t.ldr_falla ? "En falla (respaldo por horario)" : "Normal" }),
          NG.el("dt", { texto: "Luces de casas" }), NG.el("dd", { texto: NG.fmt.num(t.luces_casas_encendidas) + " de " + NG.fmt.num((t.luces_casas_encendidas || 0) + (t.luces_casas_apagadas || 0)) + " encendidas" }),
          NG.el("dt", { texto: "Última lectura" }), NG.el("dd", { texto: NG.fmt.fechaHora(t.fecha_hora) }))));
    });
    panel.cuerpo.append(tableros);
    if (vivo.eventos && vivo.eventos.length) {
      panel.cuerpo.append(NG.el("h3", { estilo: "margin-top:14px", texto: "Últimos eventos de los postes" }),
        NG.el("ul", { clase: "lista-eventos" }, vivo.eventos.slice(0, 12).map((e) =>
          NG.el("li", null, NG.el("time", { texto: String(e.fecha_hora || "").slice(11, 19) }), NG.el("span", { texto: (e.tablero || "").toLowerCase() }),
            NG.el("span", { texto: e.tipo + (e.antes || e.ahora ? ": " + (e.antes || "") + " → " + (e.ahora || "") : "") })))));
    }
  }

  NG.vistas.general = {
    titulo: "Vista general",
    noche: null,
    async render(c) {
      const [noche, res, vivo] = await Promise.all([
        NG.api("red/noche", { fecha: this.noche }),
        NG.api("resumen", NG.paramsFiltro()),
        NG.api("maqueta/estado").catch(() => null),
      ]);
      const hero = NG.el("section", { clase: "noche", "aria-label": "La red de noche" });
      c.append(hero);
      const plano = heroNoche(hero, noche, vivo);

      const k = res.kpi;
      c.append(NG.cifras([
        { etiqueta: "Energía consumida", valor: NG.fmt.num(k.energia_kwh, 0), unidad: "kWh", nota: NG.fmt.num(res.filtros.dias) + " días · " + NG.fmt.num(k.luminarias) + " luminarias" },
        { etiqueta: "Ahorro frente a encendido fijo", valor: NG.fmt.num(k.ahorro_pct, 1), unidad: "%", nota: NG.fmt.num(k.ahorro_kwh, 0) + " kWh menos que al 100 % toda la noche" },
        { etiqueta: "Disponibilidad", valor: NG.fmt.num(k.disponibilidad_pct, 2), unidad: "%", nota: "Intervalos sin falla ni mantenimiento" },
        { etiqueta: "Fallas abiertas", valor: NG.fmt.num(k.fallas_abiertas), nota: NG.fmt.num(k.fallas_periodo) + " detectadas en el periodo · reparación media " + NG.fmt.horas(k.mttr_h) },
        { etiqueta: "Registros", valor: NG.fmt.compacto(res.volumen.medicion), nota: "mediciones en el modelo relacional · " + NG.fmt.compacto(res.volumen.fact_operacion_luminaria) + " hechos en el DW" },
      ]));

      const fila = NG.el("div", { clase: "rejilla rejilla-2-1" });
      c.append(fila);
      const ext = (NG.estado.catalogos || {}).extension || {};
      const notaFisico = ext.fisico_desde && ext.simulado_hasta && ext.fisico_desde > ext.simulado_hasta
        ? " Desde el " + NG.fmt.fecha(ext.fisico_desde) + " solo hay datos de la maqueta (16 postes)." : "";
      const pEnergia = NG.panel({ titulo: "Energía diaria", subtitulo: "Consumo real frente a la referencia sin control adaptativo (100 % toda la noche). Fuente: fact_consumo_diario." + notaFisico });
      fila.append(pEnergia.raiz);
      NG.graf.tarjeta(pEnergia, (d) => NG.graf.linea(d, {
        x: res.serie.map((s) => s.fecha), alto: 340, formatoX: (v) => NG.fmt.fechaCorta(v), formatoXTooltip: (v) => NG.fmt.fecha(v),
        formatoY: (v) => NG.fmt.num(v, 0), formatoTooltip: (v) => NG.fmt.num(v, 1) + " kWh",
        series: [{ nombre: "Consumo real", valores: res.serie.map((s) => s.energia_kwh), area: true },
          { nombre: "Sin control adaptativo", valores: res.serie.map((s) => s.referencia_kwh), contexto: true }],
      }), { columnas: [{ clave: "fecha", titulo: "Fecha" }, { clave: "energia_kwh", titulo: "Consumo real (kWh)", num: true, formato: (v) => NG.fmt.num(v, 3) },
        { clave: "referencia_kwh", titulo: "Sin control (kWh)", num: true, formato: (v) => NG.fmt.num(v, 3) }], filas: res.serie }, null, "energia_diaria");

      const lado = NG.el("div", { clase: "rejilla" });
      fila.append(lado);
      const pVivo = NG.panel({ titulo: "Maqueta en vivo", subtitulo: "Los dos ESP32 de la maqueta, vía MQTT, SQL Server y el puente." });
      lado.append(pVivo.raiz);
      panelVivo(pVivo, vivo);
      this._vivo = setInterval(async () => {
        if (!document.body.contains(pVivo.raiz)) { clearInterval(this._vivo); return; }
        try {
          const nuevo = await NG.api("maqueta/estado", null, { signal: undefined });
          panelVivo(pVivo, nuevo);
          plano.actualizarVivo(nuevo);
        } catch (e) { /* se reintenta en 10 s */ }
      }, 3000);   // cada 3 s: el estado de la maqueta se ve casi al instante

      const fila2 = NG.el("div", { clase: "rejilla rejilla-2" });
      c.append(fila2);
      const pOrigen = NG.panel({ titulo: "Origen de los datos", subtitulo: "Intervalos de 15 minutos en el periodo, por origen." });
      fila2.append(pOrigen.raiz);
      const partes = res.por_origen.map((o) => ({ nombre: o.nombre, valor: o.intervalos, color: o.codigo === "FISICO" ? "--s2" : o.codigo === "SIMULADO" ? "--s1" : "--s3" }));
      NG.graf.tarjeta(pOrigen, (d) => NG.graf.segmentada(d, { partes, formato: (v) => NG.fmt.num(v) + " intervalos" }),
        { columnas: [{ clave: "nombre", titulo: "Origen" }, { clave: "intervalos", titulo: "Intervalos", num: true, formato: (v) => NG.fmt.num(v) },
          { clave: "energia_kwh", titulo: "Energía (kWh)", num: true, formato: (v) => NG.fmt.num(v, 1) }], filas: res.por_origen }, null, "origen_datos");

      const e = res.ultima_etl || {};
      const pEtl = NG.panel({ titulo: "Última carga del ETL", subtitulo: e.ejecucion_id ? "Ejecución " + e.ejecucion_id + " con " + (e.herramienta === "SSIS" ? "SSIS" : "T-SQL") : "Aún no hay ejecuciones registradas." });
      fila2.append(pEtl.raiz);
      if (e.ejecucion_id) {
        pEtl.cuerpo.append(NG.el("p", null, NG.etiqueta(e.estado === "EXITOSA" ? "Exitosa" : e.estado === "CON_RECHAZOS" ? "Con rechazos" : e.estado, e.estado === "FALLIDA" ? "critico" : e.estado === "CON_RECHAZOS" ? "aviso" : "bueno"),
          " ", NG.fmt.fechaHora(e.fin || e.inicio)),
          NG.el("p", { clase: "nota", texto: `Leídas ${NG.fmt.num(e.filas_leidas)} · insertadas ${NG.fmt.num(e.filas_insertadas)} · rechazadas ${NG.fmt.num(e.filas_rechazadas)} · imputadas ${NG.fmt.num(e.filas_imputadas)}` }),
          NG.el("a", { href: "#/etl", texto: "Ver el monitor del ETL" }));
      }
    },
    salir() { clearInterval(this._vivo); },
  };
})();
