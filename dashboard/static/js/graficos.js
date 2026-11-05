/* NeoGrid · gráficos en SVG sin dependencias externas.
   Reglas: un solo eje Y, marcas delgadas (líneas 2px, barras <= 24px con extremo redondeado 4px),
   rejilla tenue, leyenda con 2 o más series, tooltip con todas las series y vista de tabla en cada gráfico. */
(function () {
  "use strict";
  const NG = window.NG;
  const G = (NG.graf = {});
  const observadores = new WeakMap();

  function alResize(contenedor, dibujar) {
    dibujar();
    let ancho = contenedor.clientWidth;
    if (observadores.has(contenedor)) observadores.get(contenedor).disconnect();
    let espera = null;
    const ob = new ResizeObserver(() => {
      if (Math.abs(contenedor.clientWidth - ancho) < 4) return;
      ancho = contenedor.clientWidth;
      clearTimeout(espera);
      espera = setTimeout(dibujar, 80);
    });
    ob.observe(contenedor);
    observadores.set(contenedor, ob);
  }

  function escalaBonita(min, max, n) {
    if (min === max) { max = min + 1; }
    const rango = max - min;
    const paso0 = rango / Math.max(1, n);
    const mag = Math.pow(10, Math.floor(Math.log10(paso0)));
    const norm = paso0 / mag;
    const paso = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag;
    const ini = Math.floor(min / paso) * paso;
    const fin = Math.ceil(max / paso) * paso;
    const ticks = [];
    for (let v = ini; v <= fin + paso / 2; v += paso) ticks.push(Math.round(v * 1e6) / 1e6);
    return { min: ini, max: fin, ticks };
  }
  G.escalaBonita = escalaBonita;

  function esc0(valores) { const e = escalaBonita(Math.min(0, ...valores), Math.max(...valores), 4); return Math.max(1e-9, e.max - e.min); }
  function color(c, i) { return NG.color(c || NG.SERIES[i % NG.SERIES.length]); }
  function anchoTexto(s, tam) { return String(s).length * (tam || 12) * 0.56; }

  function leyenda(series, tipo) {
    if (series.length < 2) return null;
    return NG.el("ul", { clase: "leyenda" }, series.map((s, i) =>
      NG.el("li", null, NG.el("span", { clase: tipo === "barra" ? "clave-barra" : "clave-linea", estilo: "background:" + (s.contexto ? NG.color("--gris-contexto") : color(s.color, i)) }), s.nombre)));
  }

  // ------------------------------------------------------------------ líneas
  G.linea = function (contenedor, spec) {
    const fy = spec.formatoY || ((v) => NG.fmt.compacto(v));
    const ft = spec.formatoTooltip || fy;
    const fx = spec.formatoX || ((v) => v);
    const series = spec.series.filter((s) => s && s.valores);
    function dibujar() {
      NG.vaciar(contenedor);
      const ley = leyenda(series, "linea");
      if (ley) contenedor.append(ley);
      const W = Math.max(280, contenedor.clientWidth);
      const H = spec.alto || 240;
      const todos = series.flatMap((s) => s.valores.filter((v) => v !== null && v !== undefined));
      if (!todos.length) { contenedor.append(NG.el("p", { clase: "nota", texto: "Sin datos para este filtro." })); return; }
      const esc = escalaBonita(spec.yMin !== undefined ? Math.min(spec.yMin, ...todos) : Math.min(0, ...todos), Math.max(...todos), 4);
      let etiquetasFin = series.length <= 4 && spec.etiquetasFin !== false && series.length > 1;
      if (etiquetasFin) {
        // si las etiquetas finales chocan, no se apilan: quedan la leyenda y el tooltip
        const finales = series.map((s) => { for (let i = s.valores.length - 1; i >= 0; i--) if (s.valores[i] !== null && s.valores[i] !== undefined) return s.valores[i]; return null; })
          .filter((v) => v !== null).sort((a, b) => a - b);
        const altoPlot = (spec.alto || 240) - 34;
        const rango = esc0(todos);
        for (let i = 1; i < finales.length; i++) if (((finales[i] - finales[i - 1]) / rango) * altoPlot < 15) etiquetasFin = false;
      }
      const mL = Math.max(...esc.ticks.map((t) => anchoTexto(fy(t)))) + 10;
      const mR = etiquetasFin ? Math.min(120, Math.max(...series.map((s) => anchoTexto(s.nombre))) + 16) : 14;
      const mT = 8, mB = 26;
      const iw = W - mL - mR, ih = H - mT - mB;
      const n = spec.x.length;
      const X = (i) => mL + (n <= 1 ? iw / 2 : (i * iw) / (n - 1));
      const Y = (v) => mT + ih - ((v - esc.min) / (esc.max - esc.min)) * ih;
      const svg = NG.svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": spec.titulo || "Gráfico de líneas" });
      esc.ticks.forEach((t) => {
        svg.append(NG.svg("line", { x1: mL, x2: W - mR, y1: Y(t), y2: Y(t), class: t === 0 ? "eje-linea" : "rejilla-linea" }));
        svg.append(NG.svg("text", { x: mL - 8, y: Y(t) + 4, "text-anchor": "end", texto: fy(t) }));
      });
      const maxTicks = Math.max(2, Math.floor(iw / 90));
      const pasoX = Math.max(1, Math.ceil(n / maxTicks));
      for (let i = 0; i < n; i += pasoX) {
        svg.append(NG.svg("text", { x: X(i), y: H - 6, "text-anchor": i === 0 ? "start" : "middle", texto: fx(spec.x[i], i) }));
      }
      series.forEach((s, si) => {
        const c = s.contexto ? NG.color("--gris-contexto") : color(s.color, si);
        let d = "", abierto = false, areaD = "", primero = null, ultimoI = null;
        s.valores.forEach((v, i) => {
          if (v === null || v === undefined) { abierto = false; return; }
          d += (abierto ? "L" : "M") + X(i).toFixed(1) + "," + Y(v).toFixed(1);
          if (primero === null) primero = i;
          ultimoI = i;
          abierto = true;
        });
        if (s.area && primero !== null) {
          areaD = d + `L${X(ultimoI).toFixed(1)},${Y(Math.max(esc.min, 0)).toFixed(1)}L${X(primero).toFixed(1)},${Y(Math.max(esc.min, 0)).toFixed(1)}Z`;
          svg.append(NG.svg("path", { d: areaD, fill: c, "fill-opacity": 0.1, stroke: "none" }));
        }
        svg.append(NG.svg("path", { d, fill: "none", stroke: c, "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round" }));
        if (ultimoI !== null && etiquetasFin) {
          svg.append(NG.svg("circle", { cx: X(ultimoI), cy: Y(s.valores[ultimoI]), r: 4, fill: c, class: "marca-hover" }));
          svg.append(NG.svg("text", { x: X(ultimoI) + 8, y: Y(s.valores[ultimoI]) + 4, class: "valor-etiqueta", texto: s.nombre }));
        }
      });
      // capa de interacción: la cruz encuentra la X
      const cruz = NG.svg("line", { y1: mT, y2: mT + ih, class: "cruz", visibility: "hidden" });
      const puntos = series.map((s, si) => NG.svg("circle", { r: 4, fill: s.contexto ? NG.color("--gris-contexto") : color(s.color, si), class: "marca-hover", visibility: "hidden" }));
      svg.append(cruz, ...puntos);
      const capa = NG.svg("rect", { x: mL, y: mT, width: iw, height: ih, fill: "transparent", tabindex: 0, "aria-label": "Recorrer los valores con el puntero o las flechas" });
      let actual = n - 1;
      function mostrar(i, ev) {
        actual = Math.max(0, Math.min(n - 1, i));
        cruz.setAttribute("x1", X(actual)); cruz.setAttribute("x2", X(actual)); cruz.setAttribute("visibility", "visible");
        const filas = [];
        series.forEach((s, si) => {
          const v = s.valores[actual];
          if (v === null || v === undefined) { puntos[si].setAttribute("visibility", "hidden"); return; }
          puntos[si].setAttribute("cx", X(actual)); puntos[si].setAttribute("cy", Y(v)); puntos[si].setAttribute("visibility", "visible");
          filas.push({ color: s.contexto ? NG.color("--gris-contexto") : color(s.color, si), valor: ft(v), etiqueta: s.nombre });
        });
        const caja = svg.getBoundingClientRect();
        const px = ev && ev.clientX !== undefined ? ev.clientX : caja.left + (X(actual) / W) * caja.width;
        const py = ev && ev.clientY !== undefined ? ev.clientY : caja.top + 20;
        NG.tooltip.mostrar(px, py, spec.formatoXTooltip ? spec.formatoXTooltip(spec.x[actual], actual) : fx(spec.x[actual], actual), filas);
      }
      function ocultar() { cruz.setAttribute("visibility", "hidden"); puntos.forEach((p) => p.setAttribute("visibility", "hidden")); NG.tooltip.ocultar(); }
      capa.addEventListener("pointermove", (ev) => {
        const caja = svg.getBoundingClientRect();
        const x = ((ev.clientX - caja.left) / caja.width) * W;
        mostrar(Math.round(((x - mL) / iw) * (n - 1)), ev);
      });
      capa.addEventListener("pointerleave", ocultar);
      capa.addEventListener("blur", ocultar);
      capa.addEventListener("focus", () => mostrar(actual));
      capa.addEventListener("keydown", (ev) => {
        if (ev.key === "ArrowLeft") { mostrar(actual - 1); ev.preventDefault(); }
        if (ev.key === "ArrowRight") { mostrar(actual + 1); ev.preventDefault(); }
      });
      svg.append(capa);
      contenedor.append(NG.el("div", { clase: "grafico" }, svg));
    }
    alResize(contenedor, dibujar);
  };

  // ------------------------------------------------------------------ columnas (verticales)
  function rutaColumna(x, y, w, h, r) {
    if (h <= 0) return "";
    const rr = Math.min(r, w / 2, h);
    return `M${x},${y + h}V${y + rr}Q${x},${y} ${x + rr},${y}H${x + w - rr}Q${x + w},${y} ${x + w},${y + rr}V${y + h}Z`;
  }
  function rutaFila(x, y, w, h, r) {
    if (w <= 0) return "";
    const rr = Math.min(r, h / 2, w);
    return `M${x},${y}H${x + w - rr}Q${x + w},${y} ${x + w},${y + rr}V${y + h - rr}Q${x + w},${y + h} ${x + w - rr},${y + h}H${x}Z`;
  }

  G.columnas = function (contenedor, spec) {
    const fy = spec.formato || ((v) => NG.fmt.compacto(v));
    const series = spec.series;
    function dibujar() {
      NG.vaciar(contenedor);
      const ley = leyenda(series, "barra");
      if (ley) contenedor.append(ley);
      const W = Math.max(280, contenedor.clientWidth);
      const H = spec.alto || 240;
      const n = spec.categorias.length;
      const totales = spec.categorias.map((_, i) => spec.apilado
        ? series.reduce((a, s) => a + Math.max(0, s.valores[i] || 0), 0)
        : Math.max(...series.map((s) => s.valores[i] || 0)));
      const esc = escalaBonita(0, Math.max(1e-9, ...totales), 4);
      const mL = Math.max(...esc.ticks.map((t) => anchoTexto(fy(t)))) + 10;
      const anchoEtiqueta = Math.max(...spec.categorias.map((cat, i) => anchoTexto(spec.formatoX ? spec.formatoX(cat, i) : cat)));
      const rotar = anchoEtiqueta > (W - 60) / Math.max(1, n) - 8;
      const mT = 16, mB = rotar ? Math.min(90, anchoEtiqueta * 0.7 + 18) : 26, mR = 8;
      const iw = W - mL - mR, ih = H - mT - mB;
      const banda = iw / Math.max(1, n);
      const Y = (v) => mT + ih - (v / esc.max) * ih;
      const svg = NG.svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": spec.titulo || "Gráfico de columnas" });
      esc.ticks.forEach((t) => {
        svg.append(NG.svg("line", { x1: mL, x2: W - mR, y1: Y(t), y2: Y(t), class: t === 0 ? "eje-linea" : "rejilla-linea" }));
        svg.append(NG.svg("text", { x: mL - 8, y: Y(t) + 4, "text-anchor": "end", texto: fy(t) }));
      });
      const grupos = spec.apilado ? 1 : series.length;
      const anchoBarra = Math.max(3, Math.min(24, (banda * 0.72 - (grupos - 1) * 2) / grupos));
      const pasoEtiqueta = Math.max(1, Math.ceil(n / Math.max(2, Math.floor(iw / (rotar ? 18 : 64)))));
      spec.categorias.forEach((cat, i) => {
        const x0 = mL + i * banda + banda / 2 - (grupos * anchoBarra + (grupos - 1) * 2) / 2;
        let acumulado = 0;
        series.forEach((s, si) => {
          const v = s.valores[i];
          if (v === null || v === undefined) return;
          const c = s.contexto ? NG.color("--gris-contexto") : color(s.color, si);
          let x, y, h;
          if (spec.apilado) {
            x = x0; y = Y(acumulado + v); h = Y(acumulado) - y - (acumulado > 0 ? 2 : 0);
            acumulado += Math.max(0, v);
          } else {
            x = x0 + si * (anchoBarra + 2); y = Y(Math.max(0, v)); h = Y(0) - y;
          }
          const esUltima = !spec.apilado || si === series.length - 1 || series.slice(si + 1).every((t) => !t.valores[i]);
          const p = NG.svg("path", { d: esUltima ? rutaColumna(x, y, anchoBarra, h, 4) : `M${x},${y}h${anchoBarra}v${Math.max(0, h)}h${-anchoBarra}Z`, fill: c, class: "barra", tabindex: 0 });
          const filas = spec.apilado ? series.map((t, ti) => ({ color: color(t.color, ti), valor: fy(t.valores[i]), etiqueta: t.nombre }))
            : [{ color: c, valor: fy(v), etiqueta: s.nombre }];
          const mostrar = (ev) => NG.tooltip.mostrar(ev.clientX ?? p.getBoundingClientRect().left, ev.clientY ?? p.getBoundingClientRect().top, cat, filas);
          p.addEventListener("pointermove", mostrar);
          p.addEventListener("pointerleave", NG.tooltip.ocultar);
          p.addEventListener("focus", mostrar);
          p.addEventListener("blur", NG.tooltip.ocultar);
          svg.append(p);
        });
        if (spec.etiquetasValor && series.length === 1 && banda > 34) {
          const v = series[0].valores[i];
          if (v !== null && v !== undefined) svg.append(NG.svg("text", { x: mL + i * banda + banda / 2, y: Y(v) - 5, "text-anchor": "middle", class: "valor-etiqueta", texto: fy(v) }));
        }
        if (i % pasoEtiqueta === 0) {
          const tx = mL + i * banda + banda / 2;
          const etiqueta = spec.formatoX ? spec.formatoX(cat, i) : cat;
          svg.append(rotar
            ? NG.svg("text", { x: tx, y: H - mB + 14, "text-anchor": "end", transform: `rotate(-40 ${tx} ${H - mB + 14})`, texto: etiqueta })
            : NG.svg("text", { x: tx, y: H - 6, "text-anchor": "middle", texto: etiqueta }));
        }
      });
      contenedor.append(NG.el("div", { clase: "grafico" }, svg));
    }
    alResize(contenedor, dibujar);
  };

  // ------------------------------------------------------------------ barras horizontales ordenadas
  G.barras = function (contenedor, spec) {
    const fv = spec.formato || ((v) => NG.fmt.num(v));
    const filas = spec.categorias.map((c, i) => ({ c, v: spec.valores[i], extra: spec.extra ? spec.extra[i] : null }));
    function dibujar() {
      NG.vaciar(contenedor);
      const W = Math.max(260, contenedor.clientWidth);
      const alto = 26;
      const H = filas.length * alto + 6;
      const mL = Math.min(W * 0.42, Math.max(...filas.map((f) => anchoTexto(f.c, 13))) + 12);
      const mR = Math.max(...filas.map((f) => anchoTexto(fv(f.v)))) + 12;
      const iw = Math.max(40, W - mL - mR);
      const max = Math.max(1e-9, ...filas.map((f) => Math.abs(f.v || 0)));
      const svg = NG.svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": spec.titulo || "Gráfico de barras" });
      svg.append(NG.svg("line", { x1: mL, x2: mL, y1: 0, y2: H - 4, class: "eje-linea" }));
      filas.forEach((f, i) => {
        const y = i * alto + 4;
        const w = ((f.v || 0) / max) * iw;
        const c = f.extra && f.extra.contexto ? NG.color("--gris-contexto") : color(spec.color || (f.extra && f.extra.color), 0);
        svg.append(NG.svg("text", { x: mL - 8, y: y + 13, "text-anchor": "end", class: "valor-etiqueta", texto: f.c }));
        const p = NG.svg("path", { d: rutaFila(mL, y + 2, Math.max(0, w), 16, 4), fill: c, class: "barra", tabindex: 0 });
        const mostrar = (ev) => NG.tooltip.mostrar(ev.clientX ?? p.getBoundingClientRect().right, ev.clientY ?? p.getBoundingClientRect().top, f.c,
          [{ color: c, valor: fv(f.v), etiqueta: spec.nombreValor || "" }].concat(f.extra && f.extra.tooltip ? f.extra.tooltip : []));
        p.addEventListener("pointermove", mostrar);
        p.addEventListener("pointerleave", NG.tooltip.ocultar);
        p.addEventListener("focus", mostrar);
        p.addEventListener("blur", NG.tooltip.ocultar);
        svg.append(p);
        svg.append(NG.svg("text", { x: mL + Math.max(0, w) + 6, y: y + 14, class: "valor-etiqueta", texto: fv(f.v) }));
      });
      contenedor.append(NG.el("div", { clase: "grafico" }, svg));
    }
    alResize(contenedor, dibujar);
  };

  // ------------------------------------------------------------------ mapa de calor (secuencial, un tono)
  G.mapaCalor = function (contenedor, spec) {
    const fv = spec.formato || ((v) => NG.fmt.num(v, 1));
    const rampa = ["--seq-0", "--seq-1", "--seq-2", "--seq-3", "--seq-4", "--seq-5", "--seq-6", "--seq-7"];
    function dibujar() {
      NG.vaciar(contenedor);
      const W = Math.max(300, contenedor.clientWidth);
      const nF = spec.filas.length, nC = spec.columnas.length;
      const mL = Math.max(...spec.filas.map((f) => anchoTexto(f, 12))) + 10, mT = 4, mB = 22;
      const cw = (W - mL - 4) / nC;
      const ch = Math.max(16, Math.min(30, cw * 0.9));
      const H = mT + nF * ch + mB;
      const vals = spec.valores.flat().filter((v) => v !== null && v !== undefined);
      const min = Math.min(...vals), max = Math.max(...vals);
      const svg = NG.svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": spec.titulo || "Mapa de calor" });
      spec.filas.forEach((f, i) => {
        svg.append(NG.svg("text", { x: mL - 8, y: mT + i * ch + ch / 2 + 4, "text-anchor": "end", texto: f }));
        spec.columnas.forEach((c, j) => {
          const v = spec.valores[i][j];
          const k = v === null || v === undefined ? -1 : Math.min(7, Math.floor(((v - min) / Math.max(1e-9, max - min)) * 7.999));
          const r = NG.svg("rect", { x: mL + j * cw + 1, y: mT + i * ch + 1, width: Math.max(1, cw - 2), height: ch - 2, rx: 2,
            fill: k < 0 ? NG.color("--superficie-2") : NG.color(rampa[k]), class: "celda", tabindex: -1 });
          const mostrar = (ev) => NG.tooltip.mostrar(ev.clientX, ev.clientY, f + " · " + (spec.formatoColumna ? spec.formatoColumna(c) : c),
            [{ valor: v === null || v === undefined ? "sin datos" : fv(v), etiqueta: spec.nombreValor || "" }]);
          r.addEventListener("pointermove", mostrar);
          r.addEventListener("pointerleave", NG.tooltip.ocultar);
          svg.append(r);
        });
      });
      const paso = Math.max(1, Math.ceil(nC / Math.floor((W - mL) / 34)));
      spec.columnas.forEach((c, j) => {
        if (j % paso === 0) svg.append(NG.svg("text", { x: mL + j * cw + cw / 2, y: H - 6, "text-anchor": "middle", texto: spec.formatoColumna ? spec.formatoColumna(c) : c }));
      });
      contenedor.append(NG.el("div", { clase: "grafico" }, svg));
      contenedor.append(NG.el("div", { clase: "escala" }, NG.el("span", { texto: fv(min) }),
        NG.el("span", { clase: "rampa" }, rampa.map((r) => NG.el("span", { estilo: "background:" + NG.color(r) }))),
        NG.el("span", { texto: fv(max) }), spec.nombreValor ? NG.el("span", { texto: spec.nombreValor }) : null));
    }
    alResize(contenedor, dibujar);
  };

  // ------------------------------------------------------------------ barra segmentada alta (una parte del todo)
  G.segmentada = function (contenedor, spec) {
    const total = spec.partes.reduce((a, p) => a + (p.valor || 0), 0);
    function dibujar() {
      NG.vaciar(contenedor);
      const W = Math.max(240, contenedor.clientWidth);
      const svg = NG.svg("svg", { viewBox: `0 0 ${W} 28`, role: "img", "aria-label": spec.partes.map((p) => p.nombre + " " + NG.fmt.pct(100 * p.valor / total)).join(", ") });
      let x = 0;
      spec.partes.forEach((p, i) => {
        if (!p.valor) return;
        const w = (p.valor / total) * W - (i < spec.partes.length - 1 ? 2 : 0);
        const c = color(p.color, i);
        const r = NG.svg("rect", { x, y: 0, width: Math.max(1, w), height: 28, rx: 4, fill: c, tabindex: 0 });
        const pct = NG.fmt.pct((100 * p.valor) / total, 1);
        const mostrar = (ev) => NG.tooltip.mostrar(ev.clientX ?? r.getBoundingClientRect().left, ev.clientY ?? r.getBoundingClientRect().top, p.nombre,
          [{ color: c, valor: pct, etiqueta: spec.formato ? spec.formato(p.valor) : NG.fmt.num(p.valor) }]);
        r.addEventListener("pointermove", mostrar); r.addEventListener("pointerleave", NG.tooltip.ocultar);
        r.addEventListener("focus", mostrar); r.addEventListener("blur", NG.tooltip.ocultar);
        svg.append(r);
        if (anchoTexto(pct, 12) + 16 < w) svg.append(NG.svg("text", { x: x + 8, y: 18, fill: p.tintaOscura ? "#0b0b0b" : "#ffffff", texto: pct, style: "fill:" + (p.tintaOscura ? "#0b0b0b" : "#fff") + ";font-weight:600" }));
        x += w + 2;
      });
      const ley = leyenda(spec.partes.map((p) => ({ nombre: p.nombre, color: p.color })), "barra");
      if (ley) contenedor.append(ley);
      contenedor.append(NG.el("div", { clase: "grafico" }, svg));
    }
    alResize(contenedor, dibujar);
  };

  // ------------------------------------------------------------------ tarjeta: gráfico + tabla + SQL + CSV
  G.tarjeta = function (panel, dibujarGrafico, tabla, sql, nombreArchivo) {
    const vistaGrafico = NG.el("div");
    const vistaTabla = NG.el("div", { hidden: true });
    const vistaSql = sql ? NG.el("pre", { clase: "sql codigo", hidden: true, texto: sql }) : null;
    panel.cuerpo.append(vistaGrafico, vistaTabla);
    if (vistaSql) panel.cuerpo.append(vistaSql);
    dibujarGrafico(vistaGrafico);
    if (tabla) {
      const bt = NG.el("button", { type: "button", "aria-pressed": "false" }, "Tabla");
      bt.addEventListener("click", () => {
        const ver = vistaTabla.hidden;
        if (ver && !vistaTabla.firstChild) vistaTabla.append(NG.tabla(tabla.columnas, tabla.filas, { alta: true }));
        vistaTabla.hidden = !ver; vistaGrafico.hidden = ver;
        bt.setAttribute("aria-pressed", String(ver));
      });
      const bc = NG.el("button", { type: "button", title: "Descargar CSV" }, "CSV");
      bc.addEventListener("click", () => NG.descargarCSV((nombreArchivo || "neogrid") + ".csv", tabla.columnas.map((c) => c.titulo),
        tabla.filas.map((f) => tabla.columnas.map((c) => f[c.clave]))));
      panel.acciones.append(bt, bc);
    }
    if (vistaSql) {
      const bs = NG.el("button", { type: "button", "aria-pressed": "false" }, "SQL");
      bs.addEventListener("click", () => { vistaSql.hidden = !vistaSql.hidden; bs.setAttribute("aria-pressed", String(!vistaSql.hidden)); });
      panel.acciones.append(bs);
    }
    return { vistaGrafico, vistaTabla };
  };
})();
