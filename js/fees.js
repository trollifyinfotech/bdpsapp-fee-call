/* Fee dashboard + student fee table, fee structure, edit-fee, discounts & waivers, RTE & scholarships. */
(function () {
  const T = window.T;
  T.pages = T.pages || {};
  T.fees = {};

  /* ---------------- FEE DASHBOARD ---------------- */
  const COLS = [
    { id: "code", label: "Student ID" }, { id: "adm", label: "Admission No" }, { id: "name", label: "Student Name" }, { id: "father", label: "Father Name" }, { id: "mother", label: "Mother Name" },
    { id: "cls", label: "Class" }, { id: "sec", label: "Section" }, { id: "roll", label: "Roll No" }, { id: "mobile", label: "Mobile" }, { id: "addr", label: "Address" }, { id: "adate", label: "Admission Date" },
    { id: "total", label: "Total Fee" }, { id: "disc", label: "Discount" }, { id: "net", label: "Net Fee" }, { id: "paid", label: "Paid" }, { id: "pend", label: "Pending" }, { id: "status", label: "Payment Status" },
    { id: "cat", label: "Fee Category" }, { id: "remark", label: "Calling Remark" }, { id: "lcall", label: "Last Call Date" }, { id: "next", label: "Next Follow-up" },
  ];
  const DEFAULT_COLS = ["adm", "name", "father", "cls", "sec", "mobile", "total", "disc", "net", "paid", "pend", "status", "cat", "lcall", "next"];

  T.pages.fees = async (root) => {
    if (!T.can("view_fee_details")) { root.innerHTML = T.errorBox(new Error("You need the “View Fee Details” permission.")); return; }
    const fin = T.can("view_fee_amounts");
    const f = { q: "", cls: "", section: "", status: "", category: "", sibling: "", head: "", af: "", at: "", df: "", dt: "" };
    let page = 0; const size = window.TCONFIG.PAGE_SIZE;
    const prefs = T.colPrefs("feetable", COLS.filter((c) => fin || !["total", "disc", "net", "paid", "pend"].includes(c.id)), DEFAULT_COLS);
    let heads = []; try { heads = await T.q(window.sb.from("fee_heads").select("id,name").eq("is_active", true).order("name")); } catch (_) {}

    root.innerHTML = `<div class="page-h"><div><h1>Fee Dashboard</h1><div class="sub">All figures are for session <b>${T.esc(T.sessions.current()?.name || "—")}</b> and calculated from verified payments only.</div></div></div>
      <div id="fd-cards" class="row g-3 mb-3"></div><div id="fd-charts" class="row g-3 mb-4"></div>
      <div class="card"><div class="card-header d-flex flex-wrap justify-content-between align-items-center gap-2"><span>Student fee register</span><div class="d-flex gap-2">${prefs.menu()}${T.can("export_csv") ? `<button class="btn btn-outline-secondary btn-sm" id="fd-csv"><i class="bi bi-filetype-csv me-1"></i>CSV</button>` : ""}${T.can("export_pdf") ? `<button class="btn btn-outline-secondary btn-sm" id="fd-pdf"><i class="bi bi-file-earmark-pdf me-1"></i>PDF</button>` : ""}</div></div>
      <div class="card-body border-bottom filters row g-2">
        <div class="col-md-3"><input id="q" class="form-control" placeholder="Name, father, student ID, admission no, mobile"></div>
        <div class="col-6 col-md-2"><select id="cls" class="form-select">${T.classOpts("")}</select></div><div class="col-6 col-md-1"><input id="sec" class="form-control" placeholder="Section"></div>
        <div class="col-6 col-md-2"><select id="st" class="form-select">${T.opts({ paid: "Paid", unpaid: "Unpaid", partial: "Partially paid", pending: "Pending (any)", overdue: "Overdue", zero_fee: "Zero fee" }, "", "All payment status")}</select></div>
        <div class="col-6 col-md-2"><select id="cat" class="form-select">${T.opts(T.CATEGORIES, "", "All categories (RTE, Scholarship…)")}</select></div>
        <div class="col-6 col-md-2"><select id="sib" class="form-select">${T.opts({ true: "Sibling: yes", false: "Sibling: no" }, "", "Sibling: any")}</select></div>
        <div class="col-6 col-md-2"><select id="head" class="form-select"><option value="">All fee heads</option>${heads.map((h) => `<option value="${h.id}">${T.esc(h.name)}</option>`).join("")}</select></div>
        <div class="col-6 col-md-2"><label class="small text-muted">Admitted from</label><input type="date" id="af" class="form-control"></div><div class="col-6 col-md-2"><label class="small text-muted">Admitted to</label><input type="date" id="at" class="form-control"></div>
        <div class="col-6 col-md-2"><label class="small text-muted">Due from</label><input type="date" id="df" class="form-control"></div><div class="col-6 col-md-2"><label class="small text-muted">Due to</label><input type="date" id="dt" class="form-control"></div>
        <div class="col-12 col-md-2 d-flex align-items-end"><button class="btn btn-outline-secondary w-100" id="reset">Reset filters</button></div></div>
      <div id="fl"></div><div id="flp"></div></div>`;

    /* summary cards + charts */
    (async () => {
      const cards = root.querySelector("#fd-cards"), ch = root.querySelector("#fd-charts");
      let s; try { s = await T.rpc("fee_summary", { p_session: T.state.session }); } catch (e) { cards.innerHTML = `<div class="col-12"><div class="alert alert-secondary mb-0">Financial summary is not available for your role (${T.esc(T.errMsg(e))}).</div></div>`; return; }
      const C = [["people", "p", T.num(s.total_students), "Total students"], ["receipt", "b", T.inr(s.gross), "Total assigned fee"], ["percent", "o", T.inr(s.discount), "Total discount"], ["calculator", "s", T.inr(s.net), "Total net fee"], ["cash-stack", "g", T.inr(s.collected), "Total collected"], ["hourglass-split", "r", T.inr(s.pending), "Total pending"],
        ["pie-chart", "y", T.num(s.partial_students), "Partially paid students"], ["patch-check", "g", T.num(s.paid_students), "Fully paid students"], ["person-x", "r", T.num(s.unpaid_students), "Unpaid students"], ["slash-circle", "s", T.num(s.zero_fee_students), "Zero-fee students"], ["mortarboard", "b", T.num(s.rte_students), "RTE students"],
        ["calendar-day", "g", T.inr(s.today_collection), "Today's collection"], ["calendar-month", "p", T.inr(s.month_collection), "This month collection"]];
      cards.innerHTML = C.map(([i, c, v, l]) => `<div class="col-6 col-md-4 col-xl-3 col-xxl-2">${T.stat(i, c, v, l)}</div>`).join("") + (Number(s.awaiting_verification) ? `<div class="col-12"><div class="alert alert-warning py-2 mb-0"><i class="bi bi-hourglass-split me-1"></i>${T.inr(s.awaiting_verification)} is awaiting approval and is <b>not</b> counted in collection.</div></div>` : "");
      ch.innerHTML = [["Monthly fee collection", "c1"], ["Class-wise collection", "c2"], ["Paid vs pending", "c3"], ["Payment mode distribution", "c4"], ["Collection trend (30 days)", "c5"], ["Fee recovery trend (% of net fee)", "c6"]].map(([t, id]) => `<div class="col-md-6 col-xl-4">${T.chartCard(t, id)}</div>`).join("");
      const c = s.charts, P = T.PALETTE, g = (id) => ch.querySelector("#" + id);
      T.chart(g("c1"), { type: "bar", data: { labels: c.monthly.map((x) => x.label), datasets: [{ label: "Collected (₹)", data: c.monthly.map((x) => x.amount), backgroundColor: P[0] }] } });
      T.chart(g("c2"), { type: "bar", data: { labels: c.by_class.map((x) => x.label), datasets: [{ label: "Collected", data: c.by_class.map((x) => x.collected), backgroundColor: P[1] }, { label: "Pending", data: c.by_class.map((x) => x.pending), backgroundColor: P[4] }] }, options: { plugins: { legend: { display: true } }, scales: { x: { stacked: true }, y: { stacked: true } } } });
      T.chart(g("c3"), { type: "doughnut", data: { labels: ["Collected", "Pending"], datasets: [{ data: [s.collected, s.pending], backgroundColor: [P[1], P[4]] }] } });
      T.chart(g("c4"), { type: "doughnut", data: { labels: c.by_mode.map((x) => T.MODES[x.label] || x.label), datasets: [{ data: c.by_mode.map((x) => x.amount), backgroundColor: P }] } });
      T.chart(g("c5"), { type: "line", data: { labels: c.trend.map((x) => x.label), datasets: [{ label: "₹", data: c.trend.map((x) => x.amount), borderColor: P[0], backgroundColor: "rgba(79,70,229,.12)", fill: true, tension: 0.3 }] } });
      T.chart(g("c6"), { type: "line", data: { labels: c.recovery.map((x) => x.label), datasets: [{ label: "% recovered", data: c.recovery.map((x) => x.pct), borderColor: P[1], tension: 0.3 }] }, options: { scales: { y: { min: 0, max: 100 } } } });
    })();

    const args = (x = {}) => ({ p_session: T.state.session, p_search: f.q || null, p_class: f.cls || null, p_section: f.section || null, p_status: f.status || null, p_category: f.category || null, p_sibling: f.sibling === "" ? null : f.sibling === "true", p_fee_head: f.head || null, p_adm_from: f.af || null, p_adm_to: f.at || null, p_due_from: f.df || null, p_due_to: f.dt || null, ...x });
    const colDefs = () => [
      { k: "code", label: "Student ID", render: (r) => `<span class="small text-muted">${T.esc(r.student_code)}</span>` }, { k: "adm", label: "Adm No", render: (r) => T.esc(r.admission_no) },
      { k: "name", label: "Student", cls: "sticky-col", render: (r) => `<a href="#/students/${r.student_id}" class="fw-semibold text-decoration-none">${T.esc(r.name)}</a>${r.family_id ? ' <i class="bi bi-people-fill text-muted" title="Family linked"></i>' : ""}` },
      { k: "father", label: "Father", render: (r) => T.esc(r.father_name || "—") }, { k: "mother", label: "Mother", render: (r) => T.esc(r.mother_name || "—") }, { k: "cls", label: "Class", render: (r) => T.esc(r.class_name) },
      { k: "sec", label: "Sec", render: (r) => T.esc(r.section || "—") }, { k: "roll", label: "Roll", render: (r) => T.esc(r.roll_no || "—") }, { k: "mobile", label: "Mobile", render: (r) => T.esc(r.mobile || "—") }, { k: "addr", label: "Address", cls: "wrap", render: (r) => T.esc(r.address || "—") },
      { k: "adate", label: "Admission", render: (r) => T.dmy(r.admission_date) }, { k: "total", label: "Total Fee", cls: "text-end money", render: (r) => T.inr(r.total_fee) }, { k: "disc", label: "Discount", cls: "text-end money", render: (r) => T.inr(r.discount) },
      { k: "net", label: "Net Fee", cls: "text-end money", render: (r) => T.inr(r.net_fee) }, { k: "paid", label: "Paid", cls: "text-end money text-success", render: (r) => T.inr(r.paid_amount) }, { k: "pend", label: "Pending", cls: "text-end money text-danger fw-semibold", render: (r) => T.inr(r.pending_amount) },
      { k: "status", label: "Status", render: (r) => T.badge(r.pay_status) + (r.is_overdue ? " " + T.badge("overdue") : "") }, { k: "cat", label: "Category", render: (r) => T.esc(T.CATEGORIES[r.category] || r.category) },
      { k: "remark", label: "Calling Remark", cls: "wrap", render: (r) => T.esc((r.last_remark || "—").slice(0, 80)) }, { k: "lcall", label: "Last Call", render: (r) => T.dmy(r.last_call_at) }, { k: "next", label: "Next Follow-up", render: (r) => T.dmy(r.next_followup) },
    ];
    const load = async () => {
      const el = root.querySelector("#fl"); T.loading(el);
      try {
        const j = await T.rpc("fee_list", args({ p_limit: size, p_offset: page * size }));
        const cols = colDefs().filter((c) => prefs.has(c.k) && (fin || !["total", "disc", "net", "paid", "pend"].includes(c.k)));
        cols.push({ label: "Actions", cls: "text-end", render: (r) => `<div class="dropdown"><button class="btn btn-sm btn-outline-primary dropdown-toggle" data-bs-toggle="dropdown" data-bs-boundary="viewport">Actions</button><ul class="dropdown-menu dropdown-menu-end">
          <li><a class="dropdown-item" href="#/students/${r.student_id}"><i class="bi bi-eye me-2"></i>View</a></li>
          ${T.can("collect_fee") ? `<li><a class="dropdown-item" href="#" data-act="pay" data-e="${r.enrollment_id}"><i class="bi bi-cash-coin me-2"></i>Collect Fee</a></li>` : ""}
          ${T.can("view_fee_amounts") ? `<li><a class="dropdown-item" href="#/students/${r.student_id}?tab=6"><i class="bi bi-receipt me-2"></i>View Receipt</a></li><li><a class="dropdown-item" href="#/students/${r.student_id}?tab=5"><i class="bi bi-list-check me-2"></i>View Transactions</a></li>` : ""}
          ${T.can("view_calling_crm") ? `<li><a class="dropdown-item" href="#/students/${r.student_id}?tab=7"><i class="bi bi-telephone me-2"></i>Calling History</a></li>` : ""}
          ${T.can("edit_fee_structure") ? `<li><a class="dropdown-item" href="#" data-act="edit" data-e="${r.enrollment_id}"><i class="bi bi-pencil me-2"></i>Edit Fee</a></li>` : ""}
          ${T.can("apply_discount") ? `<li><a class="dropdown-item" href="#" data-act="disc" data-e="${r.enrollment_id}"><i class="bi bi-percent me-2"></i>Apply Discount</a></li>` : ""}</ul></div>` });
        el.innerHTML = (j.totals ? `<div class="px-3 py-2 small border-bottom bg-light">Filtered totals — Fee <b>${T.inr(j.totals.gross)}</b> · Discount <b>${T.inr(j.totals.discount)}</b> · Net <b>${T.inr(j.totals.net)}</b> · Paid <b class="text-success">${T.inr(j.totals.paid)}</b> · Pending <b class="text-danger">${T.inr(j.totals.pending)}</b></div>` : "") + T.table(cols.map((c) => ({ ...c, label: c.label })), j.rows, { empty: "No students match the filters" });
        T.pager(root.querySelector("#flp"), j.total, page, size, (p) => { page = p; load(); });
        el.querySelectorAll("[data-act]").forEach((a) => (a.onclick = (e) => { e.preventDefault(); const id = a.dataset.e, act = a.dataset.act; act === "pay" ? T.payments.collect(id, () => { load(); }) : act === "edit" ? T.fees.editFee(id, load) : T.fees.discountForm(id, load); }));
      } catch (e) { el.innerHTML = T.errorBox(e); }
    };
    const apply = T.debounce(() => { Object.assign(f, { q: T.val(root, "#q"), cls: T.val(root, "#cls"), section: T.val(root, "#sec"), status: T.val(root, "#st"), category: T.val(root, "#cat"), sibling: T.val(root, "#sib"), head: T.val(root, "#head"), af: T.val(root, "#af"), at: T.val(root, "#at"), df: T.val(root, "#df"), dt: T.val(root, "#dt") }); page = 0; load(); }, 350);
    ["#q", "#cls", "#sec", "#st", "#cat", "#sib", "#head", "#af", "#at", "#df", "#dt"].forEach((s) => root.querySelector(s).addEventListener("input", apply));
    root.querySelector("#reset").onclick = () => { root.querySelectorAll(".filters input,.filters select").forEach((x) => (x.value = "")); apply(); };
    prefs.bind(root, load);
    const exportRows = async () => { const j = await T.rpc("fee_list", args({ p_limit: 5000, p_offset: 0 })); return j; };
    const head = () => ["Student ID", "Admission No", "Student", "Father", "Mother", "Class", "Section", "Roll", "Mobile", "Address", "Admission Date", "Total Fee", "Discount", "Net Fee", "Paid", "Pending", "Status", "Category", "Last Calling Remark", "Last Call", "Next Follow-up"];
    const line = (r) => [r.student_code, r.admission_no, r.name, r.father_name, r.mother_name, r.class_name, r.section, r.roll_no, r.mobile, r.address, T.dmy(r.admission_date), r.total_fee, r.discount, r.net_fee, r.paid_amount, r.pending_amount, T.label(r.pay_status), T.CATEGORIES[r.category], r.last_remark, T.dmy(r.last_call_at), T.dmy(r.next_followup)];
    const csv = root.querySelector("#fd-csv"); if (csv) csv.onclick = () => T.busy(csv, async () => { try { const j = await exportRows(); T.reports.csv("fee-register.csv", head(), j.rows.map(line), "fee_register"); } catch (e) { T.fail(e); } });
    const pdf = root.querySelector("#fd-pdf"); if (pdf) pdf.onclick = () => T.busy(pdf, async () => { try { const j = await exportRows(); const idx = [1, 2, 3, 5, 8, 11, 12, 13, 14, 15, 16]; T.reports.pdf({ title: "Student Fee Register", columns: idx.map((i) => head()[i]), rows: j.rows.map((r) => idx.map((i) => line(r)[i])), summary: j.totals ? [`Students: ${j.total}`, `Net fee: ${T.inrPlain(j.totals.net)}`, `Paid: ${T.inrPlain(j.totals.paid)}`, `Pending: ${T.inrPlain(j.totals.pending)}`] : [`Students: ${j.total}`], filters: [f.cls && "Class " + f.cls, f.status && T.label(f.status)].filter(Boolean).join(", ") }); } catch (e) { T.fail(e); } });
    load();
  };

  /* ---------------- EDIT FEE (per student, audited) ---------------- */
  T.fees.editFee = async (enrollmentId, done) => {
    let en, lines, heads;
    try {
      [en, lines, heads] = await Promise.all([
        T.q(window.sb.from("student_session_enrollments").select("id,class_name,academic_sessions(name,status),students(name)").eq("id", enrollmentId).single()),
        T.q(window.sb.from("student_fee_assignments").select("id,amount,source,fee_head_id,fee_heads(name)").eq("enrollment_id", enrollmentId).eq("status", "active").order("created_at")),
        T.q(window.sb.from("fee_heads").select("id,name").eq("is_active", true).order("name")),
      ]);
    } catch (e) { return T.fail(e); }
    if (en.academic_sessions.status !== "open") return T.toast("This session is closed.", "warn");
    const used = new Set(lines.map((l) => l.fee_head_id));
    const m = T.modal({
      title: `Edit fee — ${T.esc(en.students.name)} (${T.esc(en.class_name)}, ${T.esc(en.academic_sessions.name)})`, size: "lg", static: true,
      body: `<p class="small text-muted">Every change needs a reason and is recorded in the fee adjustment history and audit log. Amounts cannot go below what is already paid.</p>
        ${lines.length ? `<div class="tbl-wrap"><table class="table table-sm align-middle"><thead><tr><th>Fee head</th><th>Source</th><th style="width:150px">Amount (₹)</th></tr></thead><tbody>${lines.map((l) => `<tr><td>${T.esc(l.fee_heads?.name)}</td><td class="small text-muted">${T.label(l.source)}</td><td><input type="number" min="0" step="0.01" class="form-control form-control-sm ef" data-id="${l.id}" data-old="${l.amount}" value="${l.amount}"></td></tr>`).join("")}</tbody></table></div>` : T.empty("No fee lines yet. Add one below or apply the fee structure.")}
        <div class="row g-2 align-items-end border-top pt-3"><div class="col-md-5"><label class="form-label small mb-0">Add / set fee head</label><select class="form-select form-select-sm" id="nh"><option value="">— choose fee head —</option>${heads.filter((h) => !used.has(h.id)).map((h) => `<option value="${h.id}">${T.esc(h.name)}</option>`).join("")}</select></div><div class="col-md-4"><label class="form-label small mb-0">Amount (₹)</label><input type="number" min="0" step="0.01" class="form-control form-control-sm" id="na"></div></div>
        <div class="mt-3"><label class="form-label small fw-semibold">Reason for change <span class="text-danger">*</span></label><input class="form-control" id="er"></div><div class="text-danger small mt-2 d-none" id="ee"></div>`,
      footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="es">Save changes</button>`,
    });
    m.el.querySelector("#es").onclick = (ev) => T.busy(ev.currentTarget, async () => {
      const ee = m.el.querySelector("#ee"), reason = T.val(m.el, "#er"); ee.classList.add("d-none");
      const changes = [...m.el.querySelectorAll(".ef")].filter((i) => Number(i.value) !== Number(i.dataset.old));
      const nh = T.val(m.el, "#nh"), na = T.val(m.el, "#na");
      if (!changes.length && !nh) { ee.textContent = "Nothing was changed."; ee.classList.remove("d-none"); return; }
      if (reason.length < 3) { ee.textContent = "Please enter a reason."; ee.classList.remove("d-none"); return; }
      try {
        for (const i of changes) await T.rpc("adjust_fee", { p_assignment: i.dataset.id, p_new: Number(i.value), p_reason: reason }, { mutates: true });
        if (nh) { if (na === "" || Number(na) < 0) throw new Error("Enter an amount for the new fee head."); await T.rpc("set_student_fee", { p_enrollment: enrollmentId, p_head: nh, p_amount: Number(na), p_reason: reason }, { mutates: true }); }
        T.ok("Fee updated"); m.close(); done && done();
      } catch (e) { ee.textContent = T.errMsg(e); ee.classList.remove("d-none"); }
    });
  };

  /* ---------------- FEE STRUCTURE ---------------- */
  T.pages["fee-structure"] = async (root) => {
    if (!T.can("view_fee_amounts")) { root.innerHTML = T.errorBox(new Error("You need the “View Fee Amounts” permission.")); return; }
    const sess = T.sessions.current(); const canEdit = T.can("edit_fee_structure") && sess?.status === "open";
    let heads = [], rows = [], cls = "";
    root.innerHTML = `<div class="page-h"><div><h1>Fee Structure</h1><div class="sub">Session <b>${T.esc(sess?.name || "—")}</b>${sess?.status === "closed" ? " — closed (read only)" : ""}</div></div>
      <div class="d-flex flex-wrap gap-2">${canEdit ? `<button class="btn btn-outline-secondary" id="fs-copy"><i class="bi bi-files me-1"></i>Copy from session</button><button class="btn btn-outline-primary" id="fs-apply"><i class="bi bi-people me-1"></i>Assign to students</button><button class="btn btn-primary" id="fs-add"><i class="bi bi-plus-lg me-1"></i>Add fee</button>` : ""}</div></div>
      <div class="row g-3"><div class="col-lg-8"><div class="card"><div class="card-header d-flex justify-content-between align-items-center">Fee structure<select id="fs-cls" class="form-select form-select-sm" style="max-width:170px">${T.classOpts("")}</select></div><div id="fs-body"></div></div></div>
      <div class="col-lg-4"><div class="card"><div class="card-header d-flex justify-content-between">Fee heads ${canEdit ? `<button class="btn btn-sm btn-outline-primary" id="fh-add">Add</button>` : ""}</div><div id="fh-body"></div></div>
      <div class="card mt-3"><div class="card-header">Class totals (standard fees)</div><div id="fs-tot"></div></div></div></div>`;
    const draw = () => {
      const list = rows.filter((r) => !cls || r.class_name === cls);
      root.querySelector("#fs-body").innerHTML = T.table([{ label: "Class", render: (r) => T.esc(r.class_name) + (r.section ? "-" + T.esc(r.section) : "") }, { label: "Category", render: (r) => T.esc(r.category ? T.CATEGORIES[r.category] || r.category : "All") }, { label: "Fee head", render: (r) => T.esc(heads.find((h) => h.id === r.fee_head_id)?.name) }, { label: "Amount", cls: "text-end money", render: (r) => T.inr(r.amount) }, { label: "Frequency", render: (r) => T.label(r.frequency) + (r.installments_count > 1 && r.frequency === "installment" ? ` ×${r.installments_count}` : "") + (r.is_optional ? " (optional)" : "") }, { label: "First due", render: (r) => T.dmy(r.first_due_date) },
        { label: "", cls: "text-end", render: (r) => (canEdit ? `<div class="btn-group btn-group-sm"><button class="btn btn-outline-secondary" data-ed="${r.id}"><i class="bi bi-pencil"></i></button><button class="btn btn-outline-danger" data-del="${r.id}"><i class="bi bi-trash"></i></button></div>` : "") }], list, { empty: "No fees configured yet. Click “Add fee”." });
      root.querySelector("#fh-body").innerHTML = T.table([{ label: "Head", render: (h) => T.esc(h.name) + (h.is_active ? "" : " " + T.badge("inactive")) }, { label: "", cls: "text-end", render: (h) => (canEdit ? `<button class="btn btn-sm btn-outline-secondary" data-tg="${h.id}">${h.is_active ? "Disable" : "Enable"}</button>` : "") }], heads);
      const tot = {}; rows.filter((r) => !r.is_optional && !r.category && !r.section).forEach((r) => (tot[r.class_name] = (tot[r.class_name] || 0) + Number(r.amount)));
      root.querySelector("#fs-tot").innerHTML = Object.keys(tot).length ? `<table class="table table-sm mb-0">${Object.keys(tot).sort((a, b) => T.classRank(a) - T.classRank(b)).map((c) => `<tr><td>${T.esc(c)}</td><td class="text-end money fw-bold">${T.inr(tot[c])}</td></tr>`).join("")}</table>` : T.empty("—");
      root.querySelectorAll("[data-ed]").forEach((b) => (b.onclick = () => form(rows.find((r) => r.id === b.dataset.ed))));
      root.querySelectorAll("[data-del]").forEach((b) => (b.onclick = async () => { if (!(await T.confirm({ title: "Delete fee line", message: "Removes this line from the structure. Fees already assigned to students are not affected.", danger: true, okText: "Delete" }))) return; try { await T.mutate(window.sb.from("fee_structures").delete().eq("id", b.dataset.del)); T.ok("Deleted"); load(); } catch (e) { T.fail(e); } }));
      root.querySelectorAll("[data-tg]").forEach((b) => (b.onclick = async () => { const h = heads.find((x) => x.id === b.dataset.tg); try { await T.mutate(window.sb.from("fee_heads").update({ is_active: !h.is_active }).eq("id", h.id)); load(); } catch (e) { T.fail(e); } }));
    };
    const load = async () => { try { [heads, rows] = await Promise.all([T.q(window.sb.from("fee_heads").select("*").order("name")), T.q(window.sb.from("fee_structures").select("*").eq("session_id", T.state.session).order("class_name").order("created_at"))]); rows.sort((a, b) => T.classRank(a.class_name) - T.classRank(b.class_name)); draw(); } catch (e) { root.querySelector("#fs-body").innerHTML = T.errorBox(e); } };
    const form = (r) => {
      const m = T.modal({ title: r ? "Edit fee" : "Add fee", size: "lg", static: true, body: `<form id="ff" class="row g-3">
        ${T.field("Class", `<select class="form-select" name="class_name" ${r ? "disabled" : ""}>${T.opts(T.CLASSES, r?.class_name || cls, "Select")}</select>`, { col: "col-md-4", req: true })}
        ${T.field("Section (optional)", `<input class="form-control" name="section" value="${T.esc(r?.section || "")}" ${r ? "disabled" : ""}>`, { col: "col-md-4" })}
        ${T.field("Student category (optional)", `<select class="form-select" name="category" ${r ? "disabled" : ""}>${T.opts(T.CATEGORIES, r?.category || "", "All categories")}</select>`, { col: "col-md-4" })}
        ${T.field("Fee head", `<select class="form-select" name="fee_head_id" ${r ? "disabled" : ""}>${T.opts(Object.fromEntries(heads.filter((h) => h.is_active || r?.fee_head_id === h.id).map((h) => [h.id, h.name])), r?.fee_head_id, "Select")}</select>`, { col: "col-md-4", req: true })}
        ${T.field("Amount (₹)", `<input type="number" min="0" step="0.01" class="form-control" name="amount" value="${r?.amount ?? ""}">`, { col: "col-md-4", req: true })}
        ${T.field("Frequency", `<select class="form-select" name="frequency">${T.opts({ annual: "Annual", monthly: "Monthly", quarterly: "Quarterly", half_yearly: "Half-yearly", installment: "Custom installments", one_time: "One-time" }, r?.frequency || "annual")}</select>`, { col: "col-md-4" })}
        ${T.field("Installments (custom)", `<input type="number" min="1" max="36" class="form-control" name="installments_count" value="${r?.installments_count || 1}">`, { col: "col-md-4" })}
        ${T.field("First due date", `<input type="date" class="form-control" name="first_due_date" value="${r?.first_due_date || ""}">`, { col: "col-md-4" })}
        <div class="col-md-4 d-flex align-items-end"><div class="form-check"><input type="checkbox" class="form-check-input" name="is_optional" id="io" ${r?.is_optional ? "checked" : ""}><label for="io" class="form-check-label">Optional fee (not auto-assigned)</label></div></div></form><div class="text-danger small d-none" id="fe"></div>`,
        footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="fsave">Save</button>` });
      m.el.querySelector("#fsave").onclick = (ev) => T.busy(ev.currentTarget, async () => {
        const fm = m.el.querySelector("#ff"), g = (n) => fm.elements[n].value.trim(), fe = m.el.querySelector("#fe");
        const bad = (t) => { fe.textContent = t; fe.classList.remove("d-none"); };
        if (!r && (!g("class_name") || !g("fee_head_id"))) return bad("Class and fee head are required.");
        if (g("amount") === "" || Number(g("amount")) < 0) return bad("Enter a valid amount.");
        const payload = { amount: Number(g("amount")), frequency: g("frequency"), installments_count: Number(g("installments_count") || 1), first_due_date: g("first_due_date") || null, is_optional: fm.elements.is_optional.checked };
        try {
          if (r) await T.mutate(window.sb.from("fee_structures").update(payload).eq("id", r.id));
          else await T.mutate(window.sb.from("fee_structures").insert({ ...payload, school_id: T.schoolId(), session_id: T.state.session, class_name: g("class_name"), section: g("section") || null, category: g("category") || null, fee_head_id: g("fee_head_id"), created_by: T.state.user.id }));
          T.ok("Saved. Use “Assign to students” to apply new/changed fees to existing students."); m.close(); load();
        } catch (e) { bad(T.errMsg(e).includes("uq_fee_structure") || /duplicate/i.test(T.errMsg(e)) ? "This fee head is already defined for that class/section/category." : T.errMsg(e)); }
      });
    };
    root.querySelector("#fs-cls").onchange = (e) => { cls = e.target.value; draw(); };
    const add = root.querySelector("#fs-add"); if (add) add.onclick = () => form(null);
    const fhAdd = root.querySelector("#fh-add"); if (fhAdd) fhAdd.onclick = async () => {
      const m = T.modal({ title: "New fee head", size: "sm", scroll: false, body: `<label class="form-label">Name</label><input class="form-control" id="hn" maxlength="60">`, footer: `<button class="btn btn-primary" id="hs">Add</button>` });
      m.el.querySelector("#hs").onclick = async () => { const n = T.val(m.el, "#hn"); if (n.length < 2) return; try { await T.mutate(window.sb.from("fee_heads").insert({ school_id: T.schoolId(), name: n })); m.close(); load(); } catch (e) { T.fail(e); } };
    };
    const apply = root.querySelector("#fs-apply"); if (apply) apply.onclick = async () => {
      if (!(await T.confirm({ title: "Assign fee structure", message: "Creates fee lines for every enrolled student from this structure. Existing fee lines and payments are not changed; students whose class has no structure get nothing.", okText: "Assign now" }))) return;
      try { const r = await T.rpc("apply_structure_to_session", { p_session: T.state.session, p_class: cls || null }, { mutates: true }); T.ok(`${r.fee_lines_created} fee lines created for ${r.enrollments} students`); } catch (e) { T.fail(e); }
    };
    const copy = root.querySelector("#fs-copy"); if (copy) copy.onclick = () => {
      const others = T.state.sessions.filter((s) => s.id !== T.state.session);
      if (!others.length) return T.toast("No other session to copy from.", "warn");
      const m = T.modal({ title: "Copy fee structure", size: "md", scroll: false, body: `<label class="form-label">Copy from session</label><select class="form-select" id="cs">${T.sessionOpts(others[0].id).split("</option>").filter((o) => !o.includes(`value="${T.state.session}"`)).join("</option>")}</select><div class="form-text">Existing lines in this session are kept; only missing lines are added.</div>`, footer: `<button class="btn btn-primary" id="cgo">Copy</button>` });
      m.el.querySelector("#cgo").onclick = (ev) => T.busy(ev.currentTarget, async () => {
        try {
          const src = await T.q(window.sb.from("fee_structures").select("*").eq("session_id", T.val(m.el, "#cs")));
          const have = new Set(rows.map((r) => [r.class_name, r.section || "", r.category || "", r.fee_head_id].join("|")));
          const add = src.filter((r) => !have.has([r.class_name, r.section || "", r.category || "", r.fee_head_id].join("|"))).map((r) => ({ school_id: T.schoolId(), session_id: T.state.session, class_name: r.class_name, section: r.section, category: r.category, fee_head_id: r.fee_head_id, amount: r.amount, frequency: r.frequency, installments_count: r.installments_count, is_optional: r.is_optional, created_by: T.state.user.id }));
          if (add.length) await T.mutate(window.sb.from("fee_structures").insert(add));
          T.ok(`${add.length} fee lines copied. Review due dates, then assign.`); m.close(); load();
        } catch (e) { T.fail(e); }
      });
    };
    load();
  };

  /* ---------------- DISCOUNTS & WAIVERS ---------------- */
  T.fees.discountForm = (enrollmentId, done) => {
    let pick = enrollmentId ? { enrollment_id: enrollmentId } : null;
    const m = T.modal({ title: "Apply discount / waiver", size: "md", static: true, body: `${enrollmentId ? "" : `<div class="mb-3"><label class="form-label small fw-semibold">Student</label><div id="dp"></div></div>`}
      <div class="row g-3">${T.field("Type", `<select class="form-select" id="dt">${T.opts({ fixed: "Fixed amount (₹)", percentage: "Percentage (%)", full_waiver: "100% waiver" }, "fixed")}</select>`, { col: "col-6" })}${T.field("Value", `<input type="number" min="0" step="0.01" class="form-control" id="dv">`, { col: "col-6" })}${T.field("Reason / approval note", `<input class="form-control" id="dr" maxlength="200">`, { col: "col-12", req: true, hint: "Recorded with your name as approver and the session." })}</div><div class="text-danger small mt-2 d-none" id="de"></div>`,
      footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="dgo">Apply</button>` });
    if (!enrollmentId) T.studentPicker(m.el.querySelector("#dp"), (s) => (pick = s));
    m.el.querySelector("#dt").onchange = (e) => { const v = m.el.querySelector("#dv"); v.disabled = e.target.value === "full_waiver"; if (v.disabled) v.value = ""; };
    m.el.querySelector("#dgo").onclick = (ev) => T.busy(ev.currentTarget, async () => {
      const de = m.el.querySelector("#de"); de.classList.add("d-none");
      const t = T.val(m.el, "#dt"), v = T.val(m.el, "#dv"), r = T.val(m.el, "#dr");
      const bad = (x) => { de.textContent = x; de.classList.remove("d-none"); };
      if (!pick) return bad("Select a student."); if (r.length < 3) return bad("Reason is required."); if (t !== "full_waiver" && !(Number(v) > 0)) return bad("Enter a value greater than zero.");
      try { await T.rpc("apply_discount", { p_enrollment: pick.enrollment_id, p_type: t, p_value: t === "full_waiver" ? 100 : Number(v), p_reason: r }, { mutates: true }); T.ok("Discount applied"); m.close(); done && done(); } catch (e) { bad(T.errMsg(e)); }
    });
  };

  T.pages.discounts = async (root) => {
    if (!T.can("view_fee_amounts")) { root.innerHTML = T.errorBox(new Error("You need the “View Fee Amounts” permission.")); return; }
    root.innerHTML = `<div class="page-h"><div><h1>Discounts &amp; Waivers</h1><div class="sub">Every concession is recorded per student with approver, reason and session. Family policies are configured under Families.</div></div>${T.can("apply_discount") ? `<button class="btn btn-primary" id="dc-add"><i class="bi bi-plus-lg me-1"></i>Apply discount</button>` : ""}</div><div class="card"><div id="dc"></div></div>`;
    const load = async () => {
      const el = root.querySelector("#dc"); T.loading(el);
      try {
        const j = await T.rpc("discounts_list", { p_session: T.state.session, p_limit: 500 });
        el.innerHTML = T.table([{ label: "Date", render: (d) => T.dmy(d.created_at) }, { label: "Student", render: (d) => T.esc(d.student_name) + `<div class="small text-muted">${T.esc(d.class_name || "")}</div>` }, { label: "Type", render: (d) => T.label(d.discount_type) + (d.family_name ? `<div class="small text-muted">Family: ${T.esc(d.family_name)}</div>` : d.scholarship_id ? '<div class="small text-muted">Scholarship</div>' : "") }, { label: "Value", render: (d) => (d.discount_type === "percentage" ? d.value + "%" : d.discount_type === "full_waiver" ? "100%" : T.inr(d.value)) }, { label: "Discount amount", cls: "text-end money", render: (d) => T.inr(d.discount_amount) }, { label: "Reason", key: "reason", cls: "wrap" }, { label: "Approved by", key: "approved_by_name" }, { label: "Status", render: (d) => T.badge(d.status) },
          { label: "", render: (d) => (d.status === "active" && T.can("apply_discount") ? `<button class="btn btn-sm btn-outline-danger" data-rv="${d.discount_id}">Revoke</button>` : "") }], j.rows, { empty: "No discounts in this session" });
        el.querySelectorAll("[data-rv]").forEach((b) => (b.onclick = async () => { const r = await T.confirm({ title: "Revoke discount", message: "The concession stops applying; history is kept.", reason: true, danger: true, okText: "Revoke" }); if (!r) return; try { await T.rpc("revoke_discount", { p_discount: b.dataset.rv, p_reason: r }, { mutates: true }); T.ok("Revoked"); load(); } catch (e) { T.fail(e); } }));
      } catch (e) { el.innerHTML = T.errorBox(e); }
    };
    const add = root.querySelector("#dc-add"); if (add) add.onclick = () => T.fees.discountForm(null, load);
    load();
  };

  /* ---------------- RTE & SCHOLARSHIPS ---------------- */
  T.pages.rte = async (root) => {
    if (!T.can("manage_rte")) { root.innerHTML = T.errorBox(new Error("You need the “Manage RTE & Scholarships” permission.")); return; }
    root.innerHTML = `<div class="page-h"><div><h1>RTE &amp; Scholarships</h1><div class="sub">RTE students have zero parent fee and never appear in recovery calling lists. Government reimbursement is tracked separately and <b>never</b> counted as parent collection.</div></div></div><div id="rt"></div>`;
    const load = async () => {
      let data; try { data = await T.rpc("rte_list", { p_session: T.state.session }); } catch (e) { root.querySelector("#rt").innerHTML = T.errorBox(e); return; }
      T.tabs(root.querySelector("#rt"), [
        { label: `RTE students (${data.rte.length})`, icon: "mortarboard", render: (el) => {
          el.innerHTML = `<div class="d-flex justify-content-end mb-2"><button class="btn btn-primary btn-sm" id="rte-add"><i class="bi bi-plus-lg me-1"></i>Add RTE record</button></div><div class="card">${T.table([{ label: "Student", render: (r) => `<a href="#/students/${r.student_id}">${T.esc(r.student_name)}</a>` }, { label: "Class", key: "class_name" }, { label: "Certificate", render: (r) => T.esc(r.certificate_no || "—") }, { label: "Valid", render: (r) => `${T.dmy(r.valid_from)} – ${T.dmy(r.valid_to)}` }, { label: "Status", render: (r) => T.badge(r.status) }, { label: "Reimbursement expected", cls: "text-end money", render: (r) => T.inr(r.expected) }, { label: "Received (govt.)", cls: "text-end money", render: (r) => T.inr(r.received) }, { label: "", render: (r) => `<button class="btn btn-sm btn-outline-primary" data-rb="${r.id}">Record reimbursement</button>` }], data.rte, { empty: "No RTE records in this session" })}</div>`;
          el.querySelector("#rte-add").onclick = () => {
            let pick; const m = T.modal({ title: "RTE record", size: "lg", static: true, body: `<div class="mb-3"><label class="form-label small fw-semibold">Student</label><div id="rp"></div></div><div class="row g-3">${T.field("Certificate no", `<input class="form-control" id="rc">`, { col: "col-md-4" })}${T.field("Valid from", `<input type="date" class="form-control" id="rf">`, { col: "col-md-4" })}${T.field("Valid to", `<input type="date" class="form-control" id="rto">`, { col: "col-md-4" })}${T.field("Reimbursement expected (₹)", `<input type="number" min="0" class="form-control" id="re" value="0">`, { col: "col-md-6" })}${T.field("Document", `<input type="file" class="form-control" id="rd" accept="image/*,application/pdf">`, { col: "col-md-6" })}${T.field("Remarks", `<input class="form-control" id="rm">`, { col: "col-12" })}</div><div class="alert alert-info small mt-3 mb-0">Saving sets the student's category to RTE and removes unpaid structure-based parent fees (zero parent fee).</div>`, footer: `<button class="btn btn-primary" id="rs">Save</button>` });
            T.studentPicker(m.el.querySelector("#rp"), (s) => (pick = s));
            m.el.querySelector("#rs").onclick = (ev) => T.busy(ev.currentTarget, async () => { if (!pick) return T.toast("Select a student", "warn"); try { const f = m.el.querySelector("#rd").files[0]; const doc = f ? await T.upload("rte-documents", f, pick.student_id) : null; await T.rpc("save_rte", { p_student: pick.student_id, p_session: T.state.session, p_cert: T.val(m.el, "#rc"), p_from: T.nullIfBlank(T.val(m.el, "#rf")), p_to: T.nullIfBlank(T.val(m.el, "#rto")), p_expected: Number(T.val(m.el, "#re") || 0), p_remarks: T.val(m.el, "#rm"), p_doc: doc }, { mutates: true }); T.ok("RTE record saved"); m.close(); load(); } catch (e) { T.fail(e); } });
          };
          el.querySelectorAll("[data-rb]").forEach((b) => (b.onclick = () => {
            const m = T.modal({ title: "Government reimbursement received", size: "sm", scroll: false, body: `<div class="mb-2"><label class="form-label">Amount (₹)</label><input type="number" min="1" class="form-control" id="ra"></div><div class="mb-2"><label class="form-label">Date received</label><input type="date" class="form-control" id="rdt" value="${T.today()}"></div><div><label class="form-label">Reference</label><input class="form-control" id="rrf"></div>`, footer: `<button class="btn btn-primary" id="rg">Save</button>` });
            m.el.querySelector("#rg").onclick = async () => { try { await T.rpc("record_rte_reimbursement", { p_rte: b.dataset.rb, p_amount: Number(T.val(m.el, "#ra")), p_date: T.val(m.el, "#rdt"), p_ref: T.val(m.el, "#rrf") }, { mutates: true }); T.ok("Recorded (tracked separately from parent collection)"); m.close(); load(); } catch (e) { T.fail(e); } };
          }));
        } },
        { label: `Scholarships (${data.scholarships.length})`, icon: "award", render: (el) => {
          el.innerHTML = `<div class="d-flex justify-content-end mb-2"><button class="btn btn-primary btn-sm" id="sc-add"><i class="bi bi-plus-lg me-1"></i>Add scholarship</button></div><div class="card">${T.table([{ label: "Student", key: "student_name" }, { label: "Class", key: "class_name" }, { label: "Scholarship", key: "name" }, { label: "Amount / %", render: (s) => (s.percentage != null ? s.percentage + "%" : T.inr(s.amount)) }, { label: "Status", render: (s) => T.badge(s.status) }, { label: "Remarks", key: "remarks", cls: "wrap" }, { label: "", render: (s) => (s.status === "pending" && T.can("apply_discount") ? `<div class="btn-group btn-group-sm"><button class="btn btn-outline-success" data-ok="${s.id}">Approve</button><button class="btn btn-outline-danger" data-no="${s.id}">Reject</button></div>` : "") }], data.scholarships, { empty: "No scholarships in this session" })}</div>`;
          el.querySelector("#sc-add").onclick = () => {
            let pick; const m = T.modal({ title: "Scholarship", size: "lg", static: true, body: `<div class="mb-3"><label class="form-label small fw-semibold">Student</label><div id="sp"></div></div><div class="row g-3">${T.field("Scholarship name", `<input class="form-control" id="sn">`, { req: true })}${T.field("Supporting document", `<input type="file" class="form-control" id="sd" accept="image/*,application/pdf">`)}${T.field("Amount (₹)", `<input type="number" min="0" class="form-control" id="sa">`, { col: "col-md-3" })}${T.field("or Percentage", `<input type="number" min="0" max="100" class="form-control" id="sp2">`, { col: "col-md-3" })}${T.field("Remarks", `<input class="form-control" id="sr">`, { col: "col-md-6" })}</div><div class="form-text">Approval creates a recorded discount for this session.</div>`, footer: `<button class="btn btn-primary" id="ss">Save</button>` });
            T.studentPicker(m.el.querySelector("#sp"), (s) => (pick = s));
            m.el.querySelector("#ss").onclick = (ev) => T.busy(ev.currentTarget, async () => { const a = T.val(m.el, "#sa"), p = T.val(m.el, "#sp2"); if (!pick) return T.toast("Select a student", "warn"); if (!T.val(m.el, "#sn")) return T.toast("Enter scholarship name", "warn"); if (!a && !p) return T.toast("Enter amount or percentage", "warn"); try { const f = m.el.querySelector("#sd").files[0]; const doc = f ? await T.upload("rte-documents", f, pick.student_id) : null; await T.rpc("save_scholarship", { p_student: pick.student_id, p_session: T.state.session, p_name: T.val(m.el, "#sn"), p_amount: a ? Number(a) : null, p_percentage: p ? Number(p) : null, p_remarks: T.val(m.el, "#sr"), p_doc: doc }, { mutates: true }); T.ok("Scholarship saved (pending approval)"); m.close(); load(); } catch (e) { T.fail(e); } });
          };
          const rev = (sel, ok) => el.querySelectorAll(sel).forEach((b) => (b.onclick = async () => { try { await T.rpc("review_scholarship", { p_id: b.dataset[ok ? "ok" : "no"], p_approve: ok }, { mutates: true }); T.ok(ok ? "Approved — discount recorded" : "Rejected"); load(); } catch (e) { T.fail(e); } }));
          rev("[data-ok]", true); rev("[data-no]", false);
        } },
      ]);
    };
    load();
  };
})();
