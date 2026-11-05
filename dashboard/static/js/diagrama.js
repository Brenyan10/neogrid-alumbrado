/* NeoGrid · diagrama interactivo de tablas (entidad-relación o estrella) en SVG.
   Arrastre el fondo para desplazar, la rueda o los botones para acercar, arrastre una tabla
   para moverla y haga clic en ella para resaltar sus relaciones. */
(function () {
  "use strict";
  const NG = window.NG;

  const COLOR_CATEGORIA = {
    CATALOGO: "#52627a", MAESTRA: "#2a78d6", TRANSACCIONAL: "#b5501f", CALCULADA: "#12805a", CONTROL: "#6250d6",
    DIMENSION: "#2a78d6", HECHO: "#b5501f", HECHO_AGREGADO: "#12805a", ETL: "#52627a",
  };
  const NOMBRE_CATEGORIA = {
    CATALOGO: "Catálogo", MAESTRA: "Maestra", TRANSACCIONAL: "Transaccional", CALCULADA: "Calculada", CONTROL: "Control",
    DIMENSION: "Dimensión", HECHO: "Hecho", HECHO_AGREGADO: "Hecho agregado", ETL: "Control del ETL",
  };
  const ANCHO = 216, CABEZA = 34, FILA = 18;

  function columnasVisibles(nodo, modo) {
    if (modo === "todas") return nodo.columnas;
    const c = nodo.columnas.filter((x) => x.pk || x.fk);
    return c.length ? c : nodo.columnas.slice(0, 1);
  }
  function alto(nodo, modo) { return CABEZA + columnasVisibles(nodo, modo).length * FILA + 8; }

  function disponer(datos, modo) {
    const pos = {};
    const porId = Object.fromEntries(datos.nodos.map((n) => [n.id, n]));
    const vecinos = {};
    datos.nodos.forEach((n) => (vecinos[n.id] = new Set()));
    datos.aristas.forEach((a) => { if (vecinos[a.origen] && vecinos[a.destino]) { vecinos[a.origen].add(a.destino); vecinos[a.destino].add(a.origen); } });
    let columnas;
    if (datos.tipo === "estrella") {
      const hechos = datos.nodos.filter((n) => n.categoria === "HECHO" || n.categoria === "HECHO_AGREGADO")
        .sort((a, b) => (b.categoria === "HECHO") - (a.categoria === "HECHO") || vecinos[b.id].size - vecinos[a.id].size);
      // el hecho principal al centro
      const principal = hechos.findIndex((h) => h.id === "fact_operacion_luminaria");
      if (principal >= 0) { const [h] = hechos.splice(principal, 1); hechos.splice(Math.floor(hechos.length / 2), 0, h); }
      const dims = datos.nodos.filter((n) => n.categoria === "DIMENSION");
      const etl = datos.nodos.filter((n) => n.categoria === "ETL" || !n.categoria);
      const idx = Object.fromEntries(hechos.map((h, i) => [h.id, i]));
      dims.forEach((d) => {
        const r = [...vecinos[d.id]].filter((v) => idx[v] !== undefined).map((v) => idx[v]);
        d._b = r.length ? r.reduce((a, b) => a + b, 0) / r.length : hechos.length / 2;
        d._g = r.length;
      });
      dims.sort((a, b) => a._b - b._b || b._g - a._g);
      // Estrella en filas: dimensiones arriba y abajo, hechos en el centro, control del ETL a la derecha
      const arriba = [], abajo = [];
      dims.forEach((d, i) => (i % 2 ? abajo : arriba).push(d));
      const sepX = 36, sepFila = 96;
      const anchoFila = (fila) => fila.length * (ANCHO + sepX) - sepX;
      const maxAncho = Math.max(anchoFila(arriba), anchoFila(hechos), anchoFila(abajo));
      const colocar = (fila, y, haciaArriba) => {
        let x = (maxAncho - anchoFila(fila)) / 2;
        fila.forEach((n) => { pos[n.id] = { x, y: haciaArriba ? y - alto(n, modo) : y }; x += ANCHO + sepX; });
      };
      colocar(arriba, 0, true);
      colocar(hechos, sepFila, false);
      const altoHechos = Math.max(0, ...hechos.map((h) => alto(h, modo)));
      colocar(abajo, sepFila + altoHechos + sepFila, false);
      let yEtl = sepFila;
      etl.forEach((n) => { pos[n.id] = { x: maxAncho + 70, y: yEtl }; yEtl += alto(n, modo) + 18; });
      Object.keys(porId).forEach((id) => { if (!pos[id]) pos[id] = { x: maxAncho + 110, y: yEtl }; });
      return pos;
    } else {
      const orden = ["CATALOGO", "MAESTRA", "TRANSACCIONAL", "CALCULADA", "CONTROL"];
      const grupos = orden.map((c) => datos.nodos.filter((n) => n.categoria === c));
      const otros = datos.nodos.filter((n) => !orden.includes(n.categoria));
      if (otros.length) grupos.push(otros);
      columnas = [];
      grupos.forEach((g) => {
        if (!g.length) return;
        const max = 6;
        for (let i = 0; i < g.length; i += max) columnas.push(g.slice(i, i + max));
      });
      // reordenar por baricentro para reducir cruces
      for (let it = 0; it < 4; it++) {
        const fila = {};
        columnas.forEach((col) => col.forEach((n, i) => (fila[n.id] = i)));
        columnas.forEach((col) => {
          col.forEach((n) => {
            const r = [...vecinos[n.id]].map((v) => fila[v]).filter((x) => x !== undefined);
            n._b = r.length ? r.reduce((a, b) => a + b, 0) / r.length : fila[n.id];
          });
          col.sort((a, b) => a._b - b._b);
        });
      }
    }
    const sepX = 96, sepY = 22;
    let x = 0;
    columnas.forEach((col) => {
      if (!col.length) return;
      const total = col.reduce((a, n) => a + alto(n, modo) + sepY, -sepY);
      let y = -total / 2;
      col.forEach((n) => { pos[n.id] = { x, y }; y += alto(n, modo) + sepY; });
      x += ANCHO + sepX;
    });
    Object.keys(porId).forEach((id) => { if (!pos[id]) pos[id] = { x, y: 0 }; });
    return pos;
  }

  NG.diagrama = function (contenedor, datos, opciones) {
    const op = Object.assign({ alto: 620, modo: "claves" }, opciones || {});
    NG.vaciar(contenedor);
    const caja = NG.el("div", { clase: "diagrama", estilo: "height:" + op.alto + "px" });
    const svg = NG.svg("svg", { role: "application", "aria-label": "Diagrama de tablas. Use Tab para recorrer las tablas y Enter para resaltar sus relaciones." });
    const vista = NG.svg("g");
    const capaAristas = NG.svg("g");
    const capaNodos = NG.svg("g");
    vista.append(capaAristas, capaNodos);
    svg.append(vista);
    caja.append(svg);
    contenedor.append(caja);

    let modo = op.modo;
    let pos = disponer(datos, modo);
    let tx = 0, ty = 0, esc = 1;
    let seleccion = null;
    const nodosSvg = {};
    const aristasSvg = [];
    const porId = Object.fromEntries(datos.nodos.map((n) => [n.id, n]));

    function aplicar() { vista.setAttribute("transform", `translate(${tx},${ty}) scale(${esc})`); }

    function yColumna(id, columna) {
      const n = porId[id];
      const cols = columnasVisibles(n, modo);
      const i = cols.findIndex((c) => c.nombre === columna);
      return pos[id].y + CABEZA + (i < 0 ? 0 : i * FILA + FILA / 2 + 2);
    }

    function rutaArista(a) {
      if (!pos[a.origen] || !pos[a.destino]) return "";
      const po = pos[a.origen], pd = pos[a.destino];
      const y1 = yColumna(a.origen, a.col_origen), y2 = yColumna(a.destino, a.col_destino);
      let x1, x2, c1, c2;
      if (Math.abs(po.x - pd.x) < 10) {
        x1 = po.x + ANCHO; x2 = pd.x + ANCHO; c1 = x1 + 60; c2 = x2 + 60;
      } else if (pd.x > po.x) {
        x1 = po.x + ANCHO; x2 = pd.x; const d = Math.max(40, (x2 - x1) / 2); c1 = x1 + d; c2 = x2 - d;
      } else {
        x1 = po.x; x2 = pd.x + ANCHO; const d = Math.max(40, (x1 - x2) / 2); c1 = x1 - d; c2 = x2 + d;
      }
      // pata de gallo (muchos) en el lado de la clave foránea; barra (uno) en el lado de la clave primaria
      const s1 = c1 > x1 ? 1 : -1, s2 = c2 > x2 ? 1 : -1;
      const muchos = `M${x1 + s1 * 10},${y1}L${x1},${y1 - 5}M${x1 + s1 * 10},${y1}L${x1},${y1 + 5}M${x1 + s1 * 10},${y1}L${x1},${y1}`;
      const uno = `M${x2 + s2 * 7},${y2 - 5}L${x2 + s2 * 7},${y2 + 5}`;
      return `M${x1 + s1 * 10},${y1}C${c1},${y1} ${c2},${y2} ${x2},${y2}` + muchos + uno;
    }

    function dibujarAristas() {
      aristasSvg.forEach((a) => a.el.setAttribute("d", rutaArista(a.datos)));
    }

    function dibujar() {
      NG.vaciar(capaNodos); NG.vaciar(capaAristas); aristasSvg.length = 0;
      datos.aristas.forEach((a) => {
        const el = NG.svg("path", { class: "arista" });
        const titulo = NG.svg("title", { texto: `${a.origen}.${a.col_origen} → ${a.destino}.${a.col_destino}` });
        el.append(titulo);
        capaAristas.append(el);
        aristasSvg.push({ el, datos: a });
      });
      datos.nodos.forEach((n) => {
        const g = NG.svg("g", { class: "nodo", tabindex: 0, "data-id": n.id, role: "button", "aria-label": `Tabla ${n.id}, ${NG.fmt.num(n.filas)} filas` });
        const h = alto(n, modo);
        const colorCab = COLOR_CATEGORIA[n.categoria] || "#52627a";
        g.append(NG.svg("rect", { class: "nodo-caja", width: ANCHO, height: h, rx: 6 }));
        g.append(NG.svg("path", { class: "nodo-cabeza", fill: colorCab, d: `M0,6Q0,0 6,0H${ANCHO - 6}Q${ANCHO},0 ${ANCHO},6V${CABEZA}H0Z` }));
        g.append(NG.svg("text", { class: "nodo-titulo", x: 10, y: 16, texto: n.id.length > 26 ? n.id.slice(0, 25) + "…" : n.id }));
        g.append(NG.svg("text", { class: "nodo-filas", x: 10, y: 29, texto: NG.fmt.num(n.filas) + " filas" }));
        columnasVisibles(n, modo).forEach((c, i) => {
          const y = CABEZA + i * FILA + 14;
          const marca = c.pk && c.fk ? "PK FK" : c.pk ? "PK" : c.fk ? "FK" : "";
          g.append(NG.svg("text", { class: "nodo-col" + (c.pk ? " pk" : ""), x: 10, y, texto: (marca ? marca + "  " : "") + c.nombre }));
          g.append(NG.svg("text", { class: "nodo-tipo", x: ANCHO - 8, y, "text-anchor": "end", texto: c.tipo }));
        });
        g.append(NG.svg("title", { texto: (NOMBRE_CATEGORIA[n.categoria] || "") + (n.descripcion ? ": " + n.descripcion : "") }));
        capaNodos.append(g);
        nodosSvg[n.id] = g;
        g.setAttribute("transform", `translate(${pos[n.id].x},${pos[n.id].y})`);
        g.addEventListener("keydown", (e) => {
          if (e.key === "Enter" || e.key === " ") { e.preventDefault(); seleccionar(n.id, true); }
          if (e.key === "Escape") seleccionar(null);
        });
      });
      dibujarAristas();
      resaltar();
    }

    function resaltar() {
      const activos = new Set();
      if (seleccion) {
        activos.add(seleccion);
        datos.aristas.forEach((a) => { if (a.origen === seleccion) activos.add(a.destino); if (a.destino === seleccion) activos.add(a.origen); });
      }
      Object.entries(nodosSvg).forEach(([id, g]) => {
        g.classList.toggle("atenuado", !!seleccion && !activos.has(id));
        g.classList.toggle("activo", id === seleccion);
      });
      aristasSvg.forEach((a) => {
        const toca = seleccion && (a.datos.origen === seleccion || a.datos.destino === seleccion);
        a.el.classList.toggle("activa", !!toca);
        a.el.classList.toggle("atenuada", !!seleccion && !toca);
      });
    }

    function seleccionar(id, avisar) {
      seleccion = id === seleccion ? null : id;
      resaltar();
      if (avisar && op.alSeleccionar && seleccion) op.alSeleccionar(seleccion);
    }

    function ajustar() {
      const ids = Object.keys(pos);
      if (!ids.length) return;
      const minX = Math.min(...ids.map((i) => pos[i].x)), maxX = Math.max(...ids.map((i) => pos[i].x + ANCHO));
      const minY = Math.min(...ids.map((i) => pos[i].y)), maxY = Math.max(...ids.map((i) => pos[i].y + alto(porId[i], modo)));
      const W = caja.clientWidth || 800, H = caja.clientHeight || op.alto;
      esc = Math.min(1.2, Math.max(0.2, Math.min((W - 40) / (maxX - minX + 140), (H - 60) / (maxY - minY + 40))));
      tx = (W - (maxX - minX) * esc) / 2 - minX * esc;
      ty = (H - (maxY - minY) * esc) / 2 - minY * esc;
      aplicar();
    }

    function zoom(factor, cx, cy) {
      const W = caja.clientWidth, H = caja.clientHeight;
      const px = cx === undefined ? W / 2 : cx, py = cy === undefined ? H / 2 : cy;
      const nuevo = Math.min(2.5, Math.max(0.15, esc * factor));
      tx = px - ((px - tx) * nuevo) / esc; ty = py - ((py - ty) * nuevo) / esc; esc = nuevo;
      aplicar();
    }

    // ------------------------------------------------------- puntero: desplazar, mover tablas, seleccionar
    let arrastre = null;
    svg.addEventListener("pointerdown", (e) => {
      const g = e.target.closest && e.target.closest(".nodo");
      const r = caja.getBoundingClientRect();
      if (g) {
        const id = g.getAttribute("data-id");
        arrastre = { tipo: "nodo", id, x0: e.clientX, y0: e.clientY, px: pos[id].x, py: pos[id].y, movido: false };
      } else {
        arrastre = { tipo: "vista", x0: e.clientX, y0: e.clientY, tx0: tx, ty0: ty, movido: false, rx: r.left, ry: r.top };
        svg.classList.add("arrastrando");
      }
      svg.setPointerCapture(e.pointerId);
    });
    svg.addEventListener("pointermove", (e) => {
      if (!arrastre) return;
      const dx = e.clientX - arrastre.x0, dy = e.clientY - arrastre.y0;
      if (Math.abs(dx) + Math.abs(dy) > 3) arrastre.movido = true;
      if (arrastre.tipo === "nodo") {
        pos[arrastre.id] = { x: arrastre.px + dx / esc, y: arrastre.py + dy / esc };
        nodosSvg[arrastre.id].setAttribute("transform", `translate(${pos[arrastre.id].x},${pos[arrastre.id].y})`);
        dibujarAristas();
      } else {
        tx = arrastre.tx0 + dx; ty = arrastre.ty0 + dy; aplicar();
      }
    });
    function soltar() {
      if (arrastre && !arrastre.movido) {
        if (arrastre.tipo === "nodo") seleccionar(arrastre.id, true);
        else seleccionar(null);
      }
      arrastre = null;
      svg.classList.remove("arrastrando");
    }
    svg.addEventListener("pointerup", soltar);
    svg.addEventListener("pointercancel", () => { arrastre = null; svg.classList.remove("arrastrando"); });
    svg.addEventListener("wheel", (e) => {
      e.preventDefault();
      const r = caja.getBoundingClientRect();
      zoom(e.deltaY < 0 ? 1.12 : 1 / 1.12, e.clientX - r.left, e.clientY - r.top);
    }, { passive: false });

    const btnModo = NG.el("button", { type: "button", title: "Mostrar todas las columnas o solo las claves" }, modo === "todas" ? "Solo claves" : "Todas las columnas");
    btnModo.addEventListener("click", () => {
      modo = modo === "todas" ? "claves" : "todas";
      btnModo.textContent = modo === "todas" ? "Solo claves" : "Todas las columnas";
      pos = disponer(datos, modo); dibujar(); ajustar();
    });
    const controles = NG.el("div", { clase: "diagrama-controles" },
      NG.el("button", { type: "button", "aria-label": "Acercar", onclick: () => zoom(1.25) }, "+"),
      NG.el("button", { type: "button", "aria-label": "Alejar", onclick: () => zoom(0.8) }, "−"),
      NG.el("button", { type: "button", onclick: ajustar }, "Ajustar"),
      NG.el("button", { type: "button", onclick: () => { pos = disponer(datos, modo); dibujar(); ajustar(); } }, "Reordenar"),
      btnModo);
    caja.append(controles);
    const categorias = [...new Set(datos.nodos.map((n) => n.categoria))];
    caja.append(NG.el("p", { clase: "diagrama-ayuda" }, categorias.map((c) =>
      NG.el("span", { estilo: "margin-right:12px;white-space:nowrap" },
        NG.el("span", { estilo: `display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px;background:${COLOR_CATEGORIA[c] || "#52627a"}` }),
        NOMBRE_CATEGORIA[c] || c))));

    dibujar();
    requestAnimationFrame(ajustar);
    return { seleccionar: (id) => { seleccion = null; seleccionar(id, false); }, ajustar };
  };
})();
