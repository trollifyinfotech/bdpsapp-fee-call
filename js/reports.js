/* Export helpers + Reporting Centre. Exports contain exactly the filtered rows and selected columns. */
(function () {
  const T = window.T;
  T.pages = T.pages || {};

  /* ---------------- export helpers ---------------- */
  const audit = (name, count) => { try { window.sb.rpc("log_audit", { p_action: "data_export", p_record_type: name, p_details: { rows: count } }).then(() => {}, () => {}); } catch (_) {} };
  const download = (blob, filename) => { const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = filename; document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 500); };
  const cell = (v) => { v = v === null || v === undefined ? "" : String(v); return /[",\n\r]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; };

  T.reports = {
    /** 5th argument true = do not write an audit entry (templates, rejected rows). */
    csv(filename, headers, rows, name, skipAudit) {
      const text = "﻿" + [headers, ...rows].map((r) => r.map(cell).join(",")).join("\r\n");
      download(new Blob([text], { type: "text/csv;charset=utf-8" }), filename);
      if (!skipAudit) audit(name || filename, rows.length);
    },
    xlsx(filename, headers, rows, name) {
      if (!window.XLSX) { T.toast("Excel library not loaded; downloading CSV instead.", "warn"); return T.reports.csv(filename.replace(/\.xlsx$/, ".csv"), headers, rows, name); }
      const ws = XLSX.utils.aoa_to_sheet([headers, ...rows]); const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, ws, "Report");
      XLSX.writeFile(wb, filename); audit(name || filename, rows.length);
    },
    /** opts: {title, columns[], rows[][], summary[], filters, landscape} */
    pdf(opts) {
      if (!window.jspdf) return T.toast("PDF library failed to load. Check your internet connection.", "err");
      const doc = new window.jspdf.jsPDF({ orientation: opts.landscape || opts.columns.length > 7 ? "landscape" : "portrait", unit: "mm", format: "a4" });
      const W = doc.internal.pageSize.getWidth(), school = T.state.access?.school?.name || "", sess = T.sessions.current()?.name || "";
      doc.setFont("helvetica", "bold"); doc.setFontSize(15); doc.text(school, W / 2, 13, { align: "center" });
      doc.setFontSize(12); doc.text(opts.title, W / 2, 20, { align: "center" });
      doc.setFont("helvetica", "normal"); doc.setFontSize(8.5);
      doc.text(`Session: ${sess}${opts.filters ? "   |   Filters: " + opts.filters : ""}${opts.range ? "   |   Period: " + opts.range : ""}`, W / 2, 26, { align: "center" });
      doc.text(`Generated: ${T.dmyTime(new Date())} by ${T.state.user?.email || ""}`, W / 2, 30.5, { align: "center" });
      let y = 35;
      if (opts.summary?.length) { doc.setFont("helvetica", "bold"); doc.setFontSize(9); doc.text(opts.summary.join("    •    "), 14, y, { maxWidth: W - 28 }); y += 4 + 4 * Math.floor(opts.summary.join("    •    ").length / 150); }
      doc.autoTable({ startY: y + 2, head: [opts.columns], body: opts.rows.map((r) => r.map((v) => (v === null || v === undefined ? "" : String(v)))), styles: { fontSize: 7.5, cellPadding: 1.5 }, headStyles: { fillColor: [79, 70, 229] }, margin: { left: 8, right: 8, bottom: 14 }, theme: "striped", didDrawPage: () => { const p = doc.internal.getCurrentPageInfo().pageNumber; doc.setFontSize(8); doc.text(`Page ${p} of {total}`, W / 2, doc.internal.pageSize.getHeight() - 6, { align: "center" }); } });
      if (doc.putTotalPages) doc.putTotalPages("{total}");
      doc.save((opts.title || "report").replace(/[^\w]+/g, "_").toLowerCase() + ".pdf"); audit(opts.title, opts.rows.length);
    },
    print(title, columns, rows, summary = []) {
      const m = T.modal({ title: T.esc(title), size: "xl", body: `<div id="pr-area"><div class="text-center mb-2"><h4 class="mb-0">${T.esc(T.state.access?.school?.name || "")}</h4><div class="fw-bold">${T.esc(title)}</div><div class="small text-muted">Session ${T.esc(T.sessions.current()?.name || "")} · Generated ${T.dmyTime(new Date())}</div></div>${summary.length ? `<div class="small mb-2"><b>${summary.map(T.esc).join(" • ")}</b></div>` : ""}<div class="tbl-wrap"><table class="table table-sm table-bordered"><thead><tr>${columns.map((c) => `<th>${T.esc(c)}</th>`).join("")}</tr></thead><tbody>${rows.map((r) => `<tr>${r.map((v) => `<td>${T.esc(v ?? "")}</td>`).join("")}</tr>`).join("")}</tbody></table></div></div>`, footer: `<button class="btn btn-light" data-bs-dismiss="modal">Close</button><button class="btn btn-primary" id="pr-go"><i class="bi bi-printer me-1"></i>Print</button>` });
      m.el.querySelector("#pr-go").onclick = () => { window.print(); audit("print:" + title, rows.length); };
    },
  };

  /* ---------------- data helpers ---------------- */
  async function fetchAll(fn, args, pageSize, cap = 5000) {
    let all = [], off = 0, total = 0;
    for (;;) {
      const j = await T.rpc(fn, { ...args, p_limit: pageSize, p_offset: off });
      all = all.concat(j.rows); total = j.total; off += pageSize;
      if (j.rows.length < pageSize || all.length >= total || all.length >= cap) return { rows: all, total, extra: j };
    }
  }
  const sess = () => T.state.session;
  const M = (k, label) => ({ k, label, type: "money" }), D = (k, label) => ({ k, label, type: "date" }), X = (k, label) => ({ k, label }), S = (k, label) => ({ k, label, type: "status" }), N = (k, label) => ({ k, label, type: "num" });
  const FEE_COLS = [X("admission_no", "Adm No"), X("name", "Student"), X("father_name", "Father"), X("class_name", "Class"), X("section", "Section"), X("mobile", "Mobile"), M("total_fee", "Total Fee"), M("discount", "Discount"), M("net_fee", "Net Fee"), M("paid_amount", "Paid"), M("pending_amount", "Pending"), S("pay_status", "Status"), { k: "category", label: "Category", map: T.CATEGORIES }];
  const feeStatus = (status, extra = {}) => async (f) => { const j = await fetchAll("fee_list", { p_session: sess(), p_search: f.q || null, p_class: f.cls || null, p_status: status, p_category: null, p_sibling: null, p_discounted: null, p_fee_head: null, p_adm_from: null, p_adm_to: null, p_due_from: null, p_due_to: null, ...extra }, 1000); return { rows: j.rows, summary: j.extra.totals ? [`Students: ${j.total}`, `Net: ${T.inrPlain(j.extra.totals.net)}`, `Paid: ${T.inrPlain(j.extra.totals.paid)}`, `Pending: ${T.inrPlain(j.extra.totals.pending)}`] : [`Students: ${j.total}`] }; };
  const PAY_COLS = [D("payment_date", "Date"), X("receipt_no", "Receipt No"), X("txn_id", "Txn ID"), X("student_name", "Student"), X("father_name", "Father"), X("class_name", "Class"), { k: "mode", label: "Mode", map: T.MODES }, X("reference", "Reference"), M("amount", "Amount"), S("status", "Status"), X("collector_name", "Collected By")];
  const payList = (status) => async (f) => { const j = await fetchAll("payments_list", { p_session: sess(), p_from: f.from || null, p_to: f.to || null, p_mode: f.mode || null, p_status: status || f.status || null, p_collector: null, p_search: f.q || null, p_student: null }, 1000); return { rows: j.rows, summary: [`Entries: ${j.total}`, `Verified total: ${T.inrPlain(j.extra.totals.verified)}`, ...(status === "cancelled" ? [`Cancelled total: ${T.inrPlain(j.extra.totals.cancelled)}`] : [])] }; };
  const paySum = (key, label, type = "text") => async (f) => { const j = await T.rpc("payments_summary", { p_session: sess(), p_from: f.from || null, p_to: f.to || null, p_mode: f.mode || null, p_collector: null }); const rows = j[key]; return { rows: rows, summary: [`Total: ${T.inrPlain(rows.reduce((a, r) => a + Number(r.amount), 0))}`, `Transactions: ${rows.reduce((a, r) => a + Number(r.count), 0)}`] }; };
  const callCols = [{ k: "called_at", label: "When", type: "datetime" }, X("student_name", "Student"), X("father_name", "Father"), X("class_name", "Class"), X("teacher_name", "Teacher"), { k: "call_status", label: "Status", map: T.CALL_STATUS }, X("remark", "Remark"), D("promised_date", "Promised Date"), D("next_followup_date", "Next Follow-up")];
  const calls = (pred, status) => async (f) => { const j = await fetchAll("calls_list", { p_session: sess(), p_from: f.from || null, p_to: f.to || null, p_teacher: f.teacher || null, p_status: status || null, p_search: f.q || null, p_student: null }, 500); const rows = pred ? j.rows.filter(pred) : j.rows; return { rows, summary: [`Calls: ${rows.length}`, `Connected: ${rows.filter((r) => r.connected).length}`] }; };
  const perf = async (f) => { const j = await T.rpc("teacher_performance", { p_session: sess(), p_from: f.from || null, p_to: f.to || null }); return { rows: j.rows, summary: [`Teachers: ${j.rows.length}`, `Total calls: ${j.rows.reduce((a, r) => a + r.total_calls, 0)}`] }; };
  const follow = (when) => async (f) => { const j = await fetchAll("followups_list", { p_session: sess(), p_when: when, p_teacher: f.teacher || null }, 200); return { rows: j.rows, summary: [`Follow-ups: ${j.total}`] }; };
  const promises = (status) => async (f) => { const j = await fetchAll("promises_list", { p_session: sess(), p_status: status }, 500); return { rows: j.rows, summary: [`Promises: ${j.total}`] }; };

  const REPORTS = [
    { id: "session", cat: "fee", title: "Session-wise Fee Report", perm: "view_financial_dashboard", uses: [], cols: [X("name", "Session"), N("students", "Students"), M("gross", "Total Fee"), M("discount", "Discount"), M("net", "Net Fee"), M("collected", "Collected"), M("pending", "Pending")], run: async () => ({ rows: await Promise.all(T.state.sessions.map(async (s) => { const r = await T.rpc("fee_summary", { p_session: s.id }); return { name: s.name, students: r.total_students, gross: r.gross, discount: r.discount, net: r.net, collected: r.collected, pending: r.pending }; })), summary: [] }) },
    { id: "class", cat: "fee", title: "Class-wise Fee Report", perm: "view_fee_reports", uses: [], cols: [X("class_name", "Class"), N("students", "Students"), M("gross", "Total Fee"), M("discount", "Discount"), M("net", "Net Fee"), M("paid", "Collected"), M("pending", "Pending")], run: async () => { const j = await feeStatus(null)({}); const g = {}; j.rows.forEach((r) => { const a = (g[r.class_name] ||= { class_name: r.class_name, students: 0, gross: 0, discount: 0, net: 0, paid: 0, pending: 0 }); a.students++; a.gross += +r.total_fee || 0; a.discount += +r.discount || 0; a.net += +r.net_fee || 0; a.paid += +r.paid_amount || 0; a.pending += +r.pending_amount || 0; }); return { rows: Object.values(g).sort((a, b) => T.classRank(a.class_name) - T.classRank(b.class_name)), summary: j.summary }; } },
    { id: "student", cat: "fee", title: "Student-wise Fee Report", perm: "view_fee_reports", uses: ["cls", "q"], cols: FEE_COLS, run: (f) => feeStatus(null)(f) },
    { id: "paid", cat: "fee", title: "Paid Fee Report", perm: "view_fee_reports", uses: ["cls", "q"], cols: FEE_COLS, run: (f) => feeStatus("paid")(f) },
    { id: "unpaid", cat: "fee", title: "Unpaid Fee Report", perm: "view_fee_reports", uses: ["cls", "q"], cols: FEE_COLS, run: (f) => feeStatus("unpaid")(f) },
    { id: "partial", cat: "fee", title: "Partial Payment Report", perm: "view_fee_reports", uses: ["cls", "q"], cols: FEE_COLS, run: (f) => feeStatus("partial")(f) },
    { id: "pending", cat: "fee", title: "Pending Fee Report", perm: "view_fee_reports", uses: ["cls", "q"], cols: FEE_COLS, run: (f) => feeStatus("pending")(f) },
    { id: "overdue", cat: "fee", title: "Overdue Fee Report", perm: "view_fee_reports", uses: ["cls", "q"], cols: [...FEE_COLS, M("overdue_amount", "Overdue Amount")], run: (f) => feeStatus("overdue")(f) },
    { id: "zero", cat: "fee", title: "Zero Fee Report", perm: "view_fee_reports", uses: ["cls", "q"], cols: FEE_COLS, run: (f) => feeStatus("zero_fee")(f) },
    { id: "rte", cat: "fee", title: "RTE Report", perm: "view_fee_reports", uses: ["cls", "q"], cols: FEE_COLS, run: async (f) => { const j = await fetchAll("fee_list", { p_session: sess(), p_search: f.q || null, p_class: f.cls || null, p_category: "rte" }, 1000); return { rows: j.rows, summary: [`RTE students: ${j.total}`] }; } },
    { id: "scholar", cat: "fee", title: "Scholarship Report", perm: "view_fee_reports", uses: ["cls", "q"], cols: FEE_COLS, run: async (f) => { const j = await fetchAll("fee_list", { p_session: sess(), p_search: f.q || null, p_class: f.cls || null, p_category: "scholarship" }, 1000); return { rows: j.rows, summary: [`Students: ${j.total}`] }; } },
    { id: "sibling", cat: "fee", title: "Sibling Concession Report", perm: "view_fee_reports", uses: ["cls", "q"], cols: FEE_COLS, run: async (f) => { const j = await fetchAll("fee_list", { p_session: sess(), p_search: f.q || null, p_class: f.cls || null, p_sibling: true, p_discounted: true }, 1000); return { rows: j.rows, summary: [`Students: ${j.total}`, `Total discount: ${T.inrPlain(j.extra.totals?.discount)}`] }; } },
    { id: "discount", cat: "fee", title: "Discount Report", perm: "view_fee_reports", uses: [], cols: [D("created_at", "Date"), X("student_name", "Student"), X("class_name", "Class"), S("discount_type", "Type"), N("value", "Value"), M("discount_amount", "Discount Amount"), X("reason", "Reason"), X("approved_by_name", "Approved By"), S("status", "Status")], run: async () => { const j = await fetchAll("discounts_list", { p_session: sess() }, 1000); return { rows: j.rows, summary: [`Concessions: ${j.total}`, `Active discount: ${T.inrPlain(j.rows.filter((r) => r.status === "active").reduce((a, r) => a + Number(r.discount_amount), 0))}`] }; } },
    { id: "daily", cat: "fee", title: "Daily Collection Report", perm: "view_fee_reports", uses: ["from", "to", "mode"], cols: [D("label", "Date"), N("count", "Receipts"), M("amount", "Amount")], run: paySum("by_day") },
    { id: "monthly", cat: "fee", title: "Monthly Collection Report", perm: "view_fee_reports", uses: ["from", "to", "mode"], cols: [X("label", "Month"), N("count", "Receipts"), M("amount", "Amount")], run: paySum("by_month") },
    { id: "datewise", cat: "fee", title: "Date-wise Collection Report", perm: "view_fee_reports", uses: ["from", "to", "mode", "q"], cols: PAY_COLS, run: payList("verified") },
    { id: "mode", cat: "fee", title: "Payment Mode Report", perm: "view_fee_reports", uses: ["from", "to"], cols: [{ k: "label", label: "Mode", map: T.MODES }, N("count", "Receipts"), M("amount", "Amount")], run: paySum("by_mode") },
    { id: "collector", cat: "fee", title: "Collector-wise Collection Report", perm: "view_fee_reports", uses: ["from", "to", "mode"], cols: [X("label", "Collector"), N("count", "Receipts"), M("amount", "Amount")], run: paySum("by_collector") },
    { id: "register", cat: "fee", title: "Receipt Register", perm: "view_fee_reports", uses: ["from", "to", "mode", "q"], cols: PAY_COLS, run: payList(null) },
    { id: "cancelled", cat: "fee", title: "Cancelled Transaction Report", perm: "view_fee_reports", uses: ["from", "to", "q"], cols: [...PAY_COLS, X("cancel_reason", "Cancel Reason"), D("cancelled_at", "Cancelled On"), X("cancelled_by_name", "Cancelled By")], run: payList("cancelled") },
    { id: "outstanding", cat: "fee", title: "Outstanding Balance Report", perm: "view_fee_reports", uses: ["cls", "q"], cols: FEE_COLS, run: (f) => feeStatus("pending")(f) },
    /* CRM */
    { id: "c-daily", cat: "crm", title: "Daily Calling Report", perm: "view_calling_crm", uses: ["teacher"], cols: callCols, run: (f) => calls()({ ...f, from: T.today(), to: T.today() }) },
    { id: "c-date", cat: "crm", title: "Date-wise Calling Report", perm: "view_calling_crm", uses: ["from", "to", "teacher", "q"], cols: callCols, run: calls() },
    { id: "c-teacher", cat: "crm", title: "Teacher-wise Calling Report", perm: "view_calling_crm", uses: ["from", "to"], cols: [X("teacher_name", "Teacher"), N("assigned_students", "Assigned Students"), N("assigned_tasks", "Assigned Tasks"), N("total_calls", "Total Calls"), N("connected_calls", "Connected"), N("not_answered", "Not Answered"), N("busy_calls", "Busy"), N("promised_payments", "Promises"), N("followups_completed", "Follow-ups Done"), N("overdue_tasks", "Overdue Tasks"), D("last_call_at", "Last Call"), N("calls_today", "Today"), N("calls_week", "Week"), N("calls_month", "Month")], run: perf },
    { id: "c-student", cat: "crm", title: "Student-wise Calling History", perm: "view_calling_crm", uses: ["from", "to", "teacher", "q"], cols: callCols, run: calls() },
    { id: "c-conn", cat: "crm", title: "Connected Calls Report", perm: "view_calling_crm", uses: ["from", "to", "teacher", "q"], cols: callCols, run: calls((r) => r.connected) },
    { id: "c-na", cat: "crm", title: "Not Answered Calls Report", perm: "view_calling_crm", uses: ["from", "to", "teacher", "q"], cols: callCols, run: calls(null, "not_answered") },
    { id: "c-prom", cat: "crm", title: "Promised Payment Report", perm: "view_calling_crm", uses: [], cols: [D("promised_date", "Promised Date"), X("student_name", "Student"), X("father_name", "Father"), X("class_name", "Class"), M("promised_amount", "Promised Amount"), S("status", "Status"), X("teacher_name", "Taken By")], run: promises(null) },
    { id: "c-povd", cat: "crm", title: "Overdue Promise Report", perm: "view_calling_crm", uses: [], cols: [D("promised_date", "Promised Date"), X("student_name", "Student"), X("father_name", "Father"), X("class_name", "Class"), M("promised_amount", "Promised Amount"), S("status", "Status"), X("teacher_name", "Taken By")], run: promises("overdue") },
    { id: "c-fdue", cat: "crm", title: "Follow-up Due Report", perm: "view_calling_crm", uses: ["teacher"], cols: [D("due_date", "Due"), S("kind", "Type"), X("name", "Student"), X("father_name", "Father"), X("class_name", "Class"), X("mobile", "Mobile"), X("assigned_name", "Teacher"), X("last_remark", "Last Remark")], run: follow("all") },
    { id: "c-missed", cat: "crm", title: "Missed Task Report", perm: "view_calling_crm", uses: ["teacher"], cols: [D("due_date", "Due"), S("kind", "Type"), X("name", "Student"), X("father_name", "Father"), X("class_name", "Class"), X("assigned_name", "Teacher"), X("last_remark", "Last Remark")], run: follow("overdue") },
    { id: "c-perf", cat: "crm", title: "Teacher Performance Report", perm: "view_calling_crm", uses: ["from", "to"], cols: [X("teacher_name", "Teacher"), N("score", "Score"), N("coverage_pct", "Coverage %"), N("followup_pct", "Follow-up on-time %"), N("connect_pct", "Connect %"), N("recovery_pct", "Promise recovery %"), N("total_calls", "Calls"), N("followups_missed", "Missed Follow-ups"), N("overdue_tasks", "Overdue Tasks")], run: perf },
    { id: "c-conv", cat: "crm", title: "Call Conversion Report", perm: "view_calling_crm", uses: ["from", "to"], cols: [X("teacher_name", "Teacher"), N("total_calls", "Calls"), N("connected_calls", "Connected"), N("connect_pct", "Connect %"), N("promises_made", "Promises Made"), N("promises_kept", "Promises Kept"), N("promises_overdue", "Promises Overdue"), N("recovery_pct", "Recovery %")], run: perf },
    { id: "c-task", cat: "crm", title: "Task Completion Report", perm: "view_calling_crm", uses: ["from", "to"], cols: [X("teacher_name", "Teacher"), N("assigned_tasks", "Tasks Assigned"), N("completed_tasks", "Completed"), N("overdue_tasks", "Overdue"), N("followups_completed", "Follow-ups Done"), N("followups_missed", "Follow-ups Missed")], run: perf },
  ];

  const val = (c, v, mode) => {
    if (v === null || v === undefined || v === "") return mode === "ui" ? "—" : "";
    if (c.map) return c.map[v] || T.label(v);
    switch (c.type) {
      case "money": return mode === "file" ? Number(v) : mode === "pdf" ? T.inrPlain(v) : T.inr(v);
      case "date": return T.dmy(v);
      case "datetime": return T.dmyTime(v);
      case "status": return T.label(v);
      default: return v;
    }
  };

  /* ---------------- Reporting Centre ---------------- */
  T.pages.reports = async (root, ctx) => {
    const avail = REPORTS.filter((r) => T.can(r.perm) && (r.cat !== "fee" || T.can("view_fee_reports")));
    let cat = ctx.query?.cat || (avail.some((r) => r.cat === "fee") ? "fee" : "crm"), cur = null, data = null, hidden = new Set(), page = 0; const size = 50;
    let staff = []; if (isAdminish()) { try { staff = await T.crm.staff(); } catch (_) {} }
    function isAdminish() { return T.canAny("assign_calling_tasks", "view_teacher_performance"); }
    root.innerHTML = `<div class="page-h"><div><h1>Reporting Centre</h1><div class="sub">Session <b>${T.esc(T.sessions.current()?.name || "")}</b>. Exports contain only the filtered data and chosen columns.</div></div>${T.can("view_teacher_performance") ? `<a href="#/reports/owner" class="btn btn-outline-primary"><i class="bi bi-person-badge me-1"></i>Owner summary</a>` : ""}</div>
      <div class="row g-3"><div class="col-lg-3"><div class="card"><div class="card-body p-2"><div class="btn-group w-100 mb-2"><button class="btn btn-sm btn-outline-primary" data-cat="fee">Fee</button><button class="btn btn-sm btn-outline-primary" data-cat="crm">Calling CRM</button></div><div id="rl" class="list-group list-group-flush"></div></div></div></div><div class="col-lg-9" id="rv"><div class="card">${T.empty("Choose a report from the list", "graph-up")}</div></div></div>`;
    const drawList = () => {
      root.querySelectorAll("[data-cat]").forEach((b) => b.classList.toggle("active", b.dataset.cat === cat));
      root.querySelector("#rl").innerHTML = avail.filter((r) => r.cat === cat).map((r) => `<a href="#" class="list-group-item list-group-item-action py-2 ${cur?.id === r.id ? "active" : ""}" data-r="${r.id}">${T.esc(r.title)}</a>`).join("") || `<div class="text-muted small p-2">No reports available for your role.</div>`;
      root.querySelectorAll("[data-r]").forEach((a) => (a.onclick = (e) => { e.preventDefault(); open(REPORTS.find((r) => r.id === a.dataset.r)); }));
    };
    root.querySelectorAll("[data-cat]").forEach((b) => (b.onclick = () => { cat = b.dataset.cat; drawList(); }));
    const visCols = () => cur.cols.filter((c) => !hidden.has(c.k));
    const tableRows = (mode) => data.rows.map((r) => visCols().map((c) => val(c, r[c.k], mode)));
    const open = (rep) => {
      cur = rep; hidden = new Set(); data = null; page = 0; drawList();
      const u = new Set(rep.uses);
      root.querySelector("#rv").innerHTML = `<div class="card"><div class="card-header d-flex flex-wrap justify-content-between gap-2"><span class="fw-semibold">${T.esc(rep.title)}</span><div class="d-flex flex-wrap gap-2" id="rx"></div></div>
        <div class="card-body border-bottom"><div class="row g-2 filters">${u.has("from") ? `<div class="col-6 col-md-3"><label class="small text-muted">From</label><input type="date" class="form-control" id="rf-from" value="${T.addDays(T.today(), -29)}"></div>` : ""}${u.has("to") ? `<div class="col-6 col-md-3"><label class="small text-muted">To</label><input type="date" class="form-control" id="rf-to" value="${T.today()}"></div>` : ""}${u.has("cls") ? `<div class="col-6 col-md-3"><label class="small text-muted">Class</label><select class="form-select" id="rf-cls">${T.classOpts("")}</select></div>` : ""}${u.has("mode") ? `<div class="col-6 col-md-3"><label class="small text-muted">Payment mode</label><select class="form-select" id="rf-mode">${T.opts(T.MODES, "", "All")}</select></div>` : ""}${u.has("teacher") && isAdminish() ? `<div class="col-6 col-md-3"><label class="small text-muted">Teacher</label><select class="form-select" id="rf-teacher"><option value="">All teachers</option>${staff.map((x) => `<option value="${x.user_id}">${T.esc(x.full_name || x.email)}</option>`).join("")}</select></div>` : ""}${u.has("q") ? `<div class="col-6 col-md-3"><label class="small text-muted">Search</label><input class="form-control" id="rf-q" placeholder="name, receipt…"></div>` : ""}<div class="col-6 col-md-3 d-flex align-items-end"><button class="btn btn-primary w-100" id="rf-go"><i class="bi bi-play-fill me-1"></i>Run report</button></div></div></div><div id="rb"></div><div id="rpg"></div></div>`;
      root.querySelector("#rf-go").onclick = run; run();
    };
    const filters = () => ({ from: T.val(root, "#rf-from"), to: T.val(root, "#rf-to"), cls: T.val(root, "#rf-cls"), mode: T.val(root, "#rf-mode"), teacher: T.val(root, "#rf-teacher"), q: T.val(root, "#rf-q") });
    const run = async () => {
      const rb = root.querySelector("#rb"); T.loading(rb, "Running report…");
      try { const f = filters(); data = await cur.run(f); data.f = f; page = 0; draw(); } catch (e) { rb.innerHTML = T.errorBox(e); }
    };
    const draw = () => {
      const rb = root.querySelector("#rb"), rx = root.querySelector("#rx");
      const cp = T.colPrefs("rep-" + cur.id, cur.cols.map((c) => ({ id: c.k, label: c.label })), cur.cols.map((c) => c.k));
      cur.cols.forEach((c) => { if (!cp.has(c.k)) hidden.add(c.k); });
      const filt = [data.f.cls && "Class " + data.f.cls, data.f.mode && T.MODES[data.f.mode], data.f.q && `"${data.f.q}"`].filter(Boolean).join(", ");
      const range = data.f.from || data.f.to ? `${T.dmy(data.f.from)} – ${T.dmy(data.f.to)}` : "";
      rx.innerHTML = `${cp.menu()}${T.can("export_csv") ? `<button class="btn btn-outline-secondary btn-sm" data-x="csv"><i class="bi bi-filetype-csv me-1"></i>CSV</button><button class="btn btn-outline-secondary btn-sm" data-x="xlsx"><i class="bi bi-file-earmark-excel me-1"></i>Excel</button>` : ""}${T.can("export_pdf") ? `<button class="btn btn-outline-secondary btn-sm" data-x="pdf"><i class="bi bi-file-earmark-pdf me-1"></i>PDF</button>` : ""}<button class="btn btn-outline-secondary btn-sm" data-x="print"><i class="bi bi-printer me-1"></i>Print</button>`;
      cp.bind(rx, () => { hidden = new Set(cur.cols.filter((c) => !cp.has(c.k)).map((c) => c.k)); draw(); });
      const heads = visCols().map((c) => c.label), fname = cur.id + "-" + T.today();
      rx.querySelectorAll("[data-x]").forEach((b) => (b.onclick = () => {
        if (!data.rows.length) return T.toast("Nothing to export", "warn");
        const x = b.dataset.x;
        if (x === "csv") T.reports.csv(fname + ".csv", heads, tableRows("file"), cur.title);
        if (x === "xlsx") T.reports.xlsx(fname + ".xlsx", heads, tableRows("file"), cur.title);
        if (x === "pdf") T.reports.pdf({ title: cur.title, columns: heads, rows: tableRows("pdf"), summary: data.summary, filters: filt, range });
        if (x === "print") T.reports.print(cur.title, heads, tableRows("pdf"), data.summary);
      }));
      const slice = data.rows.slice(page * size, page * size + size);
      rb.innerHTML = (data.summary?.length ? `<div class="px-3 py-2 small bg-light border-bottom"><b>${data.summary.map(T.esc).join(" &nbsp;•&nbsp; ")}</b></div>` : "") + T.table(visCols().map((c) => ({ label: c.label, cls: c.type === "money" || c.type === "num" ? "text-end money" : c.k === "remark" || c.k === "reason" ? "wrap" : "", render: (r) => (c.type === "status" ? T.badge(r[c.k] || "info", T.label(r[c.k])) : T.esc(val(c, r[c.k], "ui"))) })), slice, { empty: "No data for the selected filters" });
      T.pager(root.querySelector("#rpg"), data.rows.length, page, size, (p) => { page = p; draw(); });
    };
    drawList();
    if (ctx.query?.r) open(REPORTS.find((r) => r.id === ctx.query.r));
  };

  /* ---------------- Owner summary (daily / monthly) ---------------- */
  T.pages["reports/owner"] = async (root) => {
    if (!T.can("view_teacher_performance")) { root.innerHTML = T.errorBox(new Error("You need the “View Teacher Performance” permission.")); return; }
    let mode = "daily", day = T.today(), month = T.today().slice(0, 7), d = null;
    root.innerHTML = `<div class="page-h"><div><h1>Owner Summary Report</h1><div class="sub">Daily or monthly calling and recovery summary</div></div><div class="d-flex gap-2 flex-wrap"><select id="om" class="form-select" style="width:auto"><option value="daily">Daily</option><option value="monthly">Monthly</option></select><input type="date" id="od" class="form-control" style="width:auto" value="${day}"><input type="month" id="omo" class="form-control d-none" style="width:auto" value="${month}"><button class="btn btn-outline-secondary" id="opdf"><i class="bi bi-file-earmark-pdf me-1"></i>PDF</button><button class="btn btn-outline-secondary" id="opr"><i class="bi bi-printer me-1"></i>Print</button></div></div><div id="ob"></div>`;
    const range = () => { if (mode === "daily") return [day, day]; const [y, m] = month.split("-").map(Number); return [`${month}-01`, new Date(Date.UTC(y, m, 0)).toISOString().slice(0, 10)]; };
    const load = async () => {
      const ob = root.querySelector("#ob"); T.loading(ob);
      try {
        const [a, b] = range(); d = await T.rpc("owner_summary", { p_session: T.state.session, p_from: a, p_to: b });
        const K = [["Tasks assigned", d.tasks_assigned], ["Calls completed", d.calls_completed], ["Connected calls", d.connected_calls], ["Tasks not completed (open)", d.tasks_not_completed], ["Follow-ups due", d.followups_due], ["Parent promises received", d.promises_received], ["Overdue promises", d.promises_overdue], ["Payments recovered (students under calling)", d.payments_recovered === null ? "restricted" : T.inr(d.payments_recovered)]];
        ob.innerHTML = `<div class="card mb-3" id="oprint"><div class="card-header">${T.esc(T.state.access.school.name)} — ${mode === "daily" ? "Daily" : "Monthly"} owner report · ${T.dmy(a)}${a !== b ? " to " + T.dmy(b) : ""}</div><div class="card-body"><div class="row g-3">${K.map(([l, v]) => `<div class="col-6 col-md-3"><div class="text-muted small">${l}</div><div class="fs-4 fw-bold">${v}</div></div>`).join("")}</div></div></div>
          <div class="row g-3"><div class="col-lg-6"><div class="card"><div class="card-header">Teacher-wise calls</div>${T.table([{ label: "Teacher", key: "teacher" }, { label: "Calls", key: "calls" }, { label: "Connected", key: "connected" }], d.teacher_calls, { empty: "No calls in this period" })}</div></div>
          <div class="col-lg-6"><div class="card"><div class="card-header text-danger">Teachers who have not completed assigned calls</div>${T.table([{ label: "Teacher", key: "teacher" }, { label: "Open tasks", key: "open_tasks" }, { label: "Calls in period", key: "calls_in_period" }, { label: "Overdue follow-ups", key: "followups_overdue" }], d.teachers_incomplete, { empty: "Everyone is up to date" })}</div></div></div>`;
      } catch (e) { ob.innerHTML = T.errorBox(e); }
    };
    root.querySelector("#om").onchange = (e) => { mode = e.target.value; root.querySelector("#od").classList.toggle("d-none", mode !== "daily"); root.querySelector("#omo").classList.toggle("d-none", mode === "daily"); load(); };
    root.querySelector("#od").onchange = (e) => { day = e.target.value; load(); }; root.querySelector("#omo").onchange = (e) => { month = e.target.value; load(); };
    const rows = () => [["Tasks assigned", d.tasks_assigned], ["Calls completed", d.calls_completed], ["Connected calls", d.connected_calls], ["Open tasks", d.tasks_not_completed], ["Follow-ups due", d.followups_due], ["Promises received", d.promises_received], ["Overdue promises", d.promises_overdue], ["Payments recovered", d.payments_recovered === null ? "restricted" : T.inrPlain(d.payments_recovered)], ...d.teacher_calls.map((t) => ["Calls by " + t.teacher, `${t.calls} (connected ${t.connected})`]), ...d.teachers_incomplete.map((t) => ["INCOMPLETE: " + t.teacher, `${t.open_tasks} open tasks, ${t.followups_overdue} overdue follow-ups, ${t.calls_in_period} calls in period`])];
    root.querySelector("#opdf").onclick = () => d && T.reports.pdf({ title: (mode === "daily" ? "Daily" : "Monthly") + " Owner Summary", columns: ["Metric", "Value"], rows: rows(), summary: [], range: range().map(T.dmy).join(" – ") });
    root.querySelector("#opr").onclick = () => d && T.reports.print((mode === "daily" ? "Daily" : "Monthly") + " Owner Summary", ["Metric", "Value"], rows());
    load();
  };
})();
