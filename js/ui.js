/* UI kit: toast, modal, confirm, loading/empty states, tables, pagination, charts, tabs. */
(function () {
  const T = window.T;

  T.toast = (msg, type = "info", ms = 4500) => {
    let wrap = document.querySelector(".toast-wrap");
    if (!wrap) { wrap = document.createElement("div"); wrap.className = "toast-wrap"; document.body.appendChild(wrap); }
    const icon = { ok: "check-circle-fill text-success", err: "x-octagon-fill text-danger", warn: "exclamation-triangle-fill text-warning", info: "info-circle-fill text-info" }[type] || "info-circle-fill";
    const el = document.createElement("div");
    el.className = "t-toast " + type;
    el.innerHTML = `<i class="bi bi-${icon} mt-1"></i><div class="flex-grow-1">${T.esc(msg)}</div><button class="btn-close btn-sm" aria-label="Close"></button>`;
    el.querySelector(".btn-close").onclick = () => el.remove();
    wrap.appendChild(el);
    setTimeout(() => el.remove(), ms);
  };
  T.ok = (m) => T.toast(m, "ok");
  T.fail = (e) => { console.error(e); T.toast(T.errMsg(e), "err", 7000); };

  T.loading = (el, text = "Loading…") => { el.innerHTML = `<div class="loading"><div class="spinner-border spinner-border-sm me-2"></div>${T.esc(text)}</div>`; };
  T.empty = (text = "No records found", icon = "inbox") => `<div class="empty"><i class="bi bi-${icon}"></i>${T.esc(text)}</div>`;
  T.errorBox = (e) => `<div class="alert alert-danger m-3"><i class="bi bi-exclamation-octagon me-1"></i>${T.esc(T.errMsg(e))}</div>`;
  T.badge = (status, text) => `<span class="badge-s b-${T.esc(status)}">${T.esc(text ?? T.label(status))}</span>`;
  T.stat = (icon, cls, value, label) => `<div class="card h-100"><div class="stat"><div class="ic ic-${cls}"><i class="bi bi-${icon}"></i></div><div><div class="v">${value}</div><div class="l">${T.esc(label)}</div></div></div></div>`;

  /** Button busy helper: disables the button while an async fn runs */
  T.busy = async (btn, fn) => {
    if (!btn) return fn();
    const html = btn.innerHTML; btn.disabled = true;
    btn.innerHTML = `<span class="spinner-border spinner-border-sm me-1"></span>Please wait`;
    try { return await fn(); } finally { btn.disabled = false; btn.innerHTML = html; }
  };

  /* ---------- modal ---------- */
  T.modal = ({ title, body, size = "lg", footer = "", onShown, static: stat = false, scroll = true }) => {
    const el = document.createElement("div");
    el.className = "modal fade"; el.tabIndex = -1;
    if (stat) el.setAttribute("data-bs-backdrop", "static");
    el.innerHTML = `<div class="modal-dialog modal-${size} ${scroll ? "modal-dialog-scrollable" : ""} modal-fullscreen-sm-down"><div class="modal-content">
      <div class="modal-header"><h5 class="modal-title">${title}</h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div>
      <div class="modal-body">${body}</div>${footer ? `<div class="modal-footer">${footer}</div>` : ""}</div></div>`;
    document.body.appendChild(el);
    const m = new bootstrap.Modal(el);
    el.addEventListener("hidden.bs.modal", () => { m.dispose(); el.remove(); });
    if (onShown) el.addEventListener("shown.bs.modal", () => onShown(el, m));
    m.show();
    return { el, modal: m, close: () => m.hide(), body: el.querySelector(".modal-body") };
  };

  /** confirm dialog. opts.reason -> requires text; resolves reason string / true / false */
  T.confirm = ({ title = "Please confirm", message = "", okText = "Confirm", danger = false, reason = false, reasonLabel = "Reason", minLen = 3 }) =>
    new Promise((resolve) => {
      let done = false;
      const mm = T.modal({
        title, size: "md", scroll: false,
        body: `<p class="mb-2">${message}</p>${reason ? `<label class="form-label">${T.esc(reasonLabel)} <span class="text-danger">*</span></label><textarea class="form-control" rows="2" id="cf-reason"></textarea><div class="text-danger small mt-1 d-none" id="cf-err">Minimum ${minLen} characters required.</div>` : ""}`,
        footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-${danger ? "danger" : "primary"}" id="cf-ok">${T.esc(okText)}</button>`,
      });
      mm.el.querySelector("#cf-ok").onclick = () => {
        let val = true;
        if (reason) {
          val = mm.el.querySelector("#cf-reason").value.trim();
          if (val.length < minLen) { mm.el.querySelector("#cf-err").classList.remove("d-none"); return; }
        }
        done = true; resolve(val); mm.close();
      };
      mm.el.addEventListener("hidden.bs.modal", () => { if (!done) resolve(false); });
    });

  /* ---------- forms ---------- */
  T.field = (label, input, { col = "col-md-6", req = false, hint = "" } = {}) =>
    `<div class="${col}"><label class="form-label small fw-semibold mb-1">${label}${req ? ' <span class="text-danger">*</span>' : ""}</label>${input}${hint ? `<div class="form-text">${hint}</div>` : ""}</div>`;
  T.opts = (map, sel, blank) => (blank !== undefined ? `<option value="">${T.esc(blank)}</option>` : "") +
    (Array.isArray(map) ? map.map((v) => [v, v]) : Object.entries(map)).map(([k, v]) => `<option value="${T.esc(k)}" ${String(k) === String(sel) ? "selected" : ""}>${T.esc(v)}</option>`).join("");
  T.classOpts = (sel, blank = "All classes") => T.opts(T.CLASSES, sel, blank);
  T.sessionOpts = (sel) => T.state.sessions.map((s) => `<option value="${s.id}" ${s.id === sel ? "selected" : ""}>${T.esc(s.name)}${s.is_active ? " (active)" : ""}${s.status === "closed" ? " [closed]" : ""}</option>`).join("");
  T.val = (root, sel) => { const e = root.querySelector(sel); return e ? e.value.trim() : ""; };
  T.nullIfBlank = (v) => (v === "" || v === undefined ? null : v);

  /* ---------- tables ---------- */
  /** columns: [{key|render, label, cls, hidden}] */
  T.table = (columns, rows, { empty = "No records found", rowAttrs } = {}) => {
    if (!rows || !rows.length) return T.empty(empty);
    const cols = columns.filter((c) => !c.hidden);
    return `<div class="tbl-wrap"><table class="table table-hover align-middle mb-0"><thead><tr>${cols.map((c) => `<th class="${c.cls || ""}">${c.label}</th>`).join("")}</tr></thead><tbody>${rows
      .map((r, i) => `<tr ${rowAttrs ? rowAttrs(r, i) : ""}>${cols.map((c) => `<td class="${c.cls || ""}">${c.render ? c.render(r, i) : T.esc(r[c.key] ?? "—")}</td>`).join("")}</tr>`)
      .join("")}</tbody></table></div>`;
  };

  /** Server-side pager. Calls onChange(page) (0-based). */
  T.pager = (el, total, page, size, onChange) => {
    const pages = Math.max(1, Math.ceil(total / size));
    const from = total ? page * size + 1 : 0, to = Math.min(total, (page + 1) * size);
    el.innerHTML = `<div class="pager d-flex flex-wrap justify-content-between align-items-center gap-2 p-2 border-top small">
      <span class="text-muted">Showing ${from}–${to} of ${T.num(total)}</span>
      <div class="btn-group btn-group-sm"><button class="btn btn-outline-secondary" data-p="first" ${page === 0 ? "disabled" : ""}><i class="bi bi-chevron-double-left"></i></button>
      <button class="btn btn-outline-secondary" data-p="prev" ${page === 0 ? "disabled" : ""}><i class="bi bi-chevron-left"></i></button>
      <span class="btn btn-light disabled">Page ${page + 1} / ${pages}</span>
      <button class="btn btn-outline-secondary" data-p="next" ${page >= pages - 1 ? "disabled" : ""}><i class="bi bi-chevron-right"></i></button>
      <button class="btn btn-outline-secondary" data-p="last" ${page >= pages - 1 ? "disabled" : ""}><i class="bi bi-chevron-double-right"></i></button></div></div>`;
    el.querySelectorAll("button[data-p]").forEach((b) => (b.onclick = () => {
      const t = b.dataset.p;
      onChange(t === "first" ? 0 : t === "prev" ? page - 1 : t === "next" ? page + 1 : pages - 1);
    }));
  };

  /** Tabs helper: tabs = [{id,label,icon,render(el)}], lazy-renders each tab once */
  T.tabs = (root, tabs, active) => {
    const id = "tb" + Math.random().toString(36).slice(2, 7);
    root.innerHTML = `<ul class="nav nav-tabs flex-nowrap overflow-auto mb-3" style="white-space:nowrap">${tabs.map((t, i) => `<li class="nav-item"><a class="nav-link ${i === (active || 0) ? "active" : ""}" href="#" data-t="${i}">${t.icon ? `<i class="bi bi-${t.icon} me-1"></i>` : ""}${t.label}</a></li>`).join("")}</ul><div id="${id}"></div>`;
    const pane = root.querySelector("#" + id), done = {};
    const show = async (i) => {
      root.querySelectorAll(".nav-link").forEach((a, j) => a.classList.toggle("active", i === j));
      pane.innerHTML = ""; T.loading(pane);
      try { await tabs[i].render(pane); } catch (e) { pane.innerHTML = T.errorBox(e); }
    };
    root.querySelectorAll(".nav-link").forEach((a) => (a.onclick = (e) => { e.preventDefault(); show(+a.dataset.t); }));
    show(active || 0);
  };

  /* ---------- charts ---------- */
  const charts = new WeakMap();
  T.chart = (canvas, cfg) => {
    if (!canvas || !window.Chart) return;
    if (charts.get(canvas)) charts.get(canvas).destroy();
    cfg.options = Object.assign({ responsive: true, maintainAspectRatio: false, plugins: { legend: { display: cfg.type !== "bar" && cfg.type !== "line" } } }, cfg.options || {});
    charts.set(canvas, new Chart(canvas, cfg));
  };
  T.PALETTE = ["#4f46e5", "#16a34a", "#f59e0b", "#0ea5e9", "#dc2626", "#8b5cf6", "#14b8a6", "#64748b"];
  T.chartCard = (title, id, extra = "") => `<div class="card h-100"><div class="card-header d-flex justify-content-between align-items-center"><span>${title}</span>${extra}</div><div class="card-body"><div class="chart-box"><canvas id="${id}"></canvas></div></div></div>`;

  /** searchable student picker -> calls onPick(student) */
  T.studentPicker = (root, onPick, { placeholder = "Search student by name / admission no / father / mobile…" } = {}) => {
    root.innerHTML = `<input class="form-control" placeholder="${T.esc(placeholder)}"><div class="list-group mt-1 position-absolute w-100 shadow-sm" style="z-index:50;max-height:260px;overflow:auto"></div>`;
    root.style.position = "relative";
    const inp = root.querySelector("input"), list = root.querySelector(".list-group");
    const run = T.debounce(async () => {
      const q = inp.value.trim().replace(/[%,()]/g, " ");
      if (q.length < 2) { list.innerHTML = ""; return; }
      try {
        const rows = await T.q(window.sb.from("student_session_enrollments")
          .select("id,class_name,section,students!inner(id,name,father_name,admission_no,student_code,mobile,status)")
          .eq("session_id", T.state.session).eq("students.status", "active")
          .or(`name.ilike.%${q}%,father_name.ilike.%${q}%,admission_no.ilike.%${q}%,mobile.ilike.%${q}%,student_code.ilike.%${q}%`, { referencedTable: "students" })
          .limit(8));
        list.innerHTML = rows.length ? rows.map((r) => `<button type="button" class="list-group-item list-group-item-action py-2" data-id="${r.id}"><b>${T.esc(r.students.name)}</b> <span class="text-muted small">· ${T.esc(r.class_name)}${r.section ? "-" + T.esc(r.section) : ""} · ${T.esc(r.students.father_name || "")} · ${T.esc(r.students.admission_no)}</span></button>`).join("") : `<div class="list-group-item text-muted small">No student found</div>`;
        list.querySelectorAll("button").forEach((b) => (b.onclick = () => {
          const r = rows.find((x) => x.id === b.dataset.id);
          list.innerHTML = ""; inp.value = r.students.name + " (" + r.class_name + ")";
          onPick({ enrollment_id: r.id, student_id: r.students.id, name: r.students.name, class_name: r.class_name, section: r.section, father_name: r.students.father_name, mobile: r.students.mobile });
        }));
      } catch (e) { list.innerHTML = `<div class="list-group-item text-danger small">${T.esc(T.errMsg(e))}</div>`; }
    }, 300);
    inp.addEventListener("input", run);
    return { clear() { inp.value = ""; list.innerHTML = ""; } };
  };

  /** Column-visibility dropdown persisted per user (UI preference only) */
  T.colPrefs = (key, all, defaults) => {
    const k = `trollify:${T.state.user?.id}:cols:${key}`;
    let saved = null; try { saved = JSON.parse(localStorage.getItem(k)); } catch (_) {}
    const vis = new Set(saved || defaults || all.map((c) => c.id));
    return {
      has: (id) => vis.has(id),
      menu: () => `<div class="dropdown d-inline-block"><button class="btn btn-outline-secondary btn-sm dropdown-toggle" data-bs-toggle="dropdown" data-bs-auto-close="outside"><i class="bi bi-layout-three-columns me-1"></i>Columns</button><div class="dropdown-menu p-2" style="max-height:320px;overflow:auto;min-width:210px">${all.map((c) => `<label class="dropdown-item-text d-flex gap-2 small"><input type="checkbox" class="form-check-input colchk" value="${c.id}" ${vis.has(c.id) ? "checked" : ""}>${T.esc(c.label)}</label>`).join("")}</div></div>`,
      bind: (root, onChange) => root.querySelectorAll(".colchk").forEach((c) => (c.onchange = () => {
        c.checked ? vis.add(c.value) : vis.delete(c.value);
        try { localStorage.setItem(k, JSON.stringify([...vis])); } catch (_) {}
        onChange();
      })),
    };
  };
})();
