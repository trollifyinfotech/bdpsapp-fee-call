/* Calling CRM / fee recovery.
 * Rules enforced here AND in the database:
 *  - Opening the phone dialer is NOT a completed call. Only a saved call-entry counts.
 *  - Teachers never receive fee amounts (the crm_* RPCs return NULL amounts without view_fee_amounts).
 */
(function () {
  const T = window.T;
  T.pages = T.pages || {};
  const isAdmin = () => T.canAny("assign_calling_tasks", "view_teacher_performance");
  const FLAG = { no_payment: ["unpaid", "No payment"], partial: ["partial", "Partially paid"], overdue: ["overdue", "Overdue"], promise_passed: ["urgent", "Promise date passed"], no_calling: ["info", "Not called yet"], repeat_not_answering: ["high", "Repeatedly not answering"] };
  const GROUPS = [["", "All"], ["no_payment", "No payment"], ["partial", "Partially paid"], ["overdue", "Overdue"], ["promise_passed", "Promise date passed"], ["no_calling", "No previous calling"], ["repeat_not_answering", "Not answering"]];

  T.crm = {
    /* ---- call entry form (mandatory after every dial) ---- */
    callModal(row, onSaved, { fromDialer = false } = {}) {
      const now = new Date(Date.now() + 5.5 * 3600 * 1000).toISOString();
      const m = T.modal({
        title: `<i class="bi bi-telephone me-2"></i>Call entry — ${T.esc(row.name)}`, size: "xl", static: true,
        body: `${fromDialer ? `<div class="alert alert-warning py-2 small"><i class="bi bi-info-circle me-1"></i>The phone dialer was opened. This does <b>not</b> record a call — please enter the outcome below after you finish the call. Entries are saved permanently with your name and time.</div>` : ""}
        <form id="cf" class="row g-3" novalidate>
          ${T.field("Student", `<input class="form-control" value="${T.esc(row.name)} (${T.esc(row.class_name || "")})" readonly>`, { col: "col-md-4" })}
          ${T.field("Parent name", `<input class="form-control" name="parent_name" value="${T.esc(row.father_name || "")}">`, { col: "col-md-4" })}
          ${T.field("Parent mobile", `<input class="form-control" name="parent_mobile" value="${T.esc(row.mobile || "")}" readonly>`, { col: "col-md-4" })}
          ${T.field("Call date", `<input type="date" class="form-control" name="cdate" value="${now.slice(0, 10)}" max="${now.slice(0, 10)}">`, { col: "col-md-3" })}
          ${T.field("Call time", `<input type="time" class="form-control" name="ctime" value="${now.slice(11, 16)}">`, { col: "col-md-3" })}
          ${T.field("Call status", `<select class="form-select" name="status">${T.opts(T.CALL_STATUS, "", "Select status")}</select>`, { col: "col-md-3", req: true })}
          ${T.field("Priority", `<select class="form-select" name="priority">${T.opts({ low: "Low", normal: "Normal", high: "High", urgent: "Urgent" }, row.task_priority || "normal")}</select>`, { col: "col-md-3" })}
          ${T.field("Call outcome", `<input class="form-control" name="outcome" placeholder="e.g. Will pay on 25th">`, { col: "col-md-6" })}
          ${T.field("Parent response", `<input class="form-control" name="response" placeholder="What did the parent say?">`, { col: "col-md-6" })}
          ${T.field("Teacher remark", `<textarea class="form-control" name="remark" rows="2" placeholder="Example: Father se baat hui. Unhone kaha ki 25 November tak ₹3,000 jama kar denge. Remaining amount ke liye next month follow-up karna hai."></textarea>`, { col: "col-12", req: true })}
          ${T.field("Promised payment date", `<input type="date" class="form-control" name="pdate" min="${now.slice(0, 10)}">`, { col: "col-md-3", hint: "Required if parent promised to pay" })}
          ${T.field("Promised amount (₹, optional)", `<input type="number" min="1" step="1" class="form-control" name="pamt">`, { col: "col-md-3", hint: "Visible only to authorized staff" })}
          ${T.field("Next follow-up date", `<input type="date" class="form-control" name="fdate" min="${now.slice(0, 10)}">`, { col: "col-md-3" })}
          ${T.field("Follow-up time", `<input type="time" class="form-control" name="ftime">`, { col: "col-md-3" })}
          ${T.field("Assigned teacher", `<input class="form-control" value="${T.esc(row.assigned_name || T.state.user.email)}" readonly>`, { col: "col-md-4" })}
          ${T.field("Additional notes", `<input class="form-control" name="notes">`, { col: "col-md-8" })}
        </form><div class="text-danger small mt-2 d-none" id="ce"></div>`,
        footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary btn-lg" id="csave"><i class="bi bi-check2-circle me-1"></i>Save call entry</button>`,
      });
      const fm = m.el.querySelector("#cf"), ce = m.el.querySelector("#ce");
      fm.elements.status.onchange = () => { if (fm.elements.status.value === "promised_to_pay" && !fm.elements.fdate.value && fm.elements.pdate.value) fm.elements.fdate.value = fm.elements.pdate.value; };
      fm.elements.pdate.onchange = () => { if (fm.elements.status.value === "promised_to_pay" && !fm.elements.fdate.value) fm.elements.fdate.value = fm.elements.pdate.value; };
      m.el.querySelector("#csave").onclick = (ev) => T.busy(ev.currentTarget, async () => {
        ce.classList.add("d-none");
        const g = (n) => fm.elements[n].value.trim(), bad = (t) => { ce.textContent = t; ce.classList.remove("d-none"); };
        if (!g("status")) return bad("Select the call status.");
        if (g("remark").length < 3) return bad("Teacher remark is required.");
        if (g("status") === "promised_to_pay" && !g("pdate")) return bad("Enter the promised payment date.");
        if (!g("cdate") || !g("ctime")) return bad("Call date and time are required.");
        if (g("ftime") && !g("fdate")) return bad("Choose a follow-up date for the follow-up time.");
        try {
          await T.rpc("log_call", {
            p_student: row.student_id, p_session: T.state.session, p_task: row.task_id || null, p_status: g("status"), p_remark: g("remark"), p_outcome: g("outcome") || null,
            p_parent_response: g("response") || null, p_parent_name: g("parent_name") || null, p_parent_mobile: g("parent_mobile") || null, p_called_at: `${g("cdate")}T${g("ctime")}:00+05:30`,
            p_promised_date: g("pdate") || null, p_promised_amount: g("pamt") ? Number(g("pamt")) : null, p_next_followup: g("fdate") || null, p_followup_time: g("ftime") || null, p_priority: g("priority") || null, p_notes: g("notes") || null,
          }, { mutates: true });
          T.ok("Call entry saved"); m.close(); onSaved && onSaved();
        } catch (e) { bad(T.errMsg(e)); }
      });
    },
    historyModal(row) {
      const m = T.modal({ title: `Call history — ${T.esc(row.name)}`, size: "lg", body: `<div class="loading">Loading…</div>` });
      T.rpc("calls_list", { p_session: T.state.session, p_student: row.student_id, p_limit: 100 }).then((j) => {
        m.body.innerHTML = T.table([{ label: "When", render: (c) => T.dmyTime(c.called_at) }, { label: "By", key: "teacher_name" }, { label: "Status", render: (c) => T.badge(c.connected ? "verified" : "pending", T.CALL_STATUS[c.call_status]) }, { label: "Remark", key: "remark", cls: "wrap" }, { label: "Promise", render: (c) => T.dmy(c.promised_date) }, { label: "Follow-up", render: (c) => T.dmy(c.next_followup_date) }], j.rows, { empty: "No calls recorded yet" });
      }).catch((e) => (m.body.innerHTML = T.errorBox(e)));
    },

    /** Student rows with CALL button */
    rowsTable(rows, { selectable = false, showTeacher = false } = {}) {
      const fin = rows.some((r) => r.pending_amount !== undefined && r.pending_amount !== null);
      return T.table([
        ...(selectable ? [{ label: `<input type="checkbox" class="form-check-input" id="sel-all">`, render: (r) => (r.assigned_to ? "" : `<input type="checkbox" class="form-check-input sel" value="${r.student_id}">`) }] : []),
        { label: "Student", render: (r) => `<div class="fw-semibold">${T.esc(r.name)}</div><div class="small text-muted">${T.esc(r.class_name || "")}${r.section ? "-" + T.esc(r.section) : ""}</div>` },
        { label: "Parent", render: (r) => `${T.esc(r.father_name || "—")}<div class="small text-muted">${T.esc(r.address || "")}</div>`, cls: "wrap" },
        { label: "Call", render: (r) => (r.mobile ? `<a class="btn btn-success btn-sm call-btn" href="tel:${T.phone(r.mobile)}" data-call="${r.student_id}"><i class="bi bi-telephone-fill me-1"></i>CALL</a><div class="small text-muted mt-1">${T.esc(r.mobile)}</div>` : '<span class="text-danger small">No mobile</span>') },
        { label: "Priority / status", render: (r) => (r.flags || []).map((f) => (FLAG[f] ? T.badge(FLAG[f][0], FLAG[f][1]) : "")).join(" ") || (r.priority ? T.badge(r.priority) : "—"), cls: "wrap" },
        ...(fin ? [{ label: "Pending", cls: "text-end money text-danger", render: (r) => T.inr(r.pending_amount) }] : []),
        { label: "Last call", render: (r) => (r.last_call_at ? `${T.dmy(r.last_call_at)}<div class="small">${T.esc(T.CALL_STATUS[r.last_status] || "")}</div><div class="small text-muted wrap" style="max-width:220px;white-space:normal">${T.esc((r.last_remark || "").slice(0, 70))}</div>` : "—") },
        { label: "Promise", render: (r) => (r.promised_date ? T.dmy(r.promised_date) + (r.promise_status === "overdue" ? " " + T.badge("overdue") : "") : "—") },
        { label: "Next follow-up", render: (r) => T.dmy(r.next_followup || r.due_date) },
        ...(showTeacher ? [{ label: "Assigned to", render: (r) => T.esc(r.assigned_name || (r.assigned_to ? "" : "— unassigned —")) }] : []),
        { label: "", cls: "text-end", render: (r) => `<div class="btn-group btn-group-sm"><button class="btn btn-outline-primary" data-log="${r.student_id}" title="Record call outcome"><i class="bi bi-journal-plus"></i></button><button class="btn btn-outline-secondary" data-hist="${r.student_id}" title="History"><i class="bi bi-clock-history"></i></button>${r.task_id && (r.assigned_to === T.state.user.id || T.can("assign_calling_tasks")) ? `<button class="btn btn-outline-success" data-done="${r.task_id}" title="Complete task"><i class="bi bi-check2-all"></i></button>` : ""}</div>` },
      ], rows, { empty: "Nothing here. 🎉" });
    },
    bindRows(el, rows, reload) {
      const find = (id) => rows.find((r) => r.student_id === id);
      el.querySelectorAll("[data-call]").forEach((a) => a.addEventListener("click", () => { const r = find(a.dataset.call); setTimeout(() => T.crm.callModal(r, reload, { fromDialer: true }), 600); }));
      el.querySelectorAll("[data-log]").forEach((b) => (b.onclick = () => T.crm.callModal(find(b.dataset.log), reload)));
      el.querySelectorAll("[data-hist]").forEach((b) => (b.onclick = () => T.crm.historyModal(find(b.dataset.hist))));
      el.querySelectorAll("[data-done]").forEach((b) => (b.onclick = async () => { if (!(await T.confirm({ title: "Complete task", message: "Mark this calling task as completed? Call history is kept.", okText: "Complete" }))) return; try { await T.rpc("complete_task", { p_task: b.dataset.done }, { mutates: true }); T.ok("Task completed"); reload(); } catch (e) { T.fail(e); } }));
      const all = el.querySelector("#sel-all"); if (all) all.onchange = () => el.querySelectorAll(".sel").forEach((c) => (c.checked = all.checked));
    },
    async staff() { const u = await T.rpc("list_school_users"); return u.filter((x) => x.is_active); },
  };

  const needCrm = (root) => { if (!T.can("view_calling_crm")) { root.innerHTML = T.errorBox(new Error("You need the “View Calling CRM” permission.")); return true; } return false; };
  const hdr = (t, sub, extra = "") => `<div class="page-h"><div><h1>${t}</h1><div class="sub">${sub || ""}</div></div><div class="d-flex gap-2 flex-wrap">${extra}</div></div>`;

  /* ---------------- DASHBOARD ---------------- */
  T.pages.crm = async (root) => {
    if (needCrm(root)) return;
    root.innerHTML = hdr("Calling Dashboard", `Session <b>${T.esc(T.sessions.current()?.name || "")}</b> · ${isAdmin() ? "whole school" : "your tasks only"}`) + `<div id="cd" class="row g-3 mb-3"></div><div id="cc" class="row g-3"></div>`;
    let d; try { d = await T.rpc("crm_dashboard", { p_session: T.state.session }); } catch (e) { root.querySelector("#cd").innerHTML = `<div class="col-12">${T.errorBox(e)}</div>`; return; }
    const C = [["people", "p", d.students_requiring_calls, "Students requiring calls"], ["list-task", "b", d.pending_tasks, "Pending calling tasks"], ["telephone-outbound", "g", d.calls_today, "Today's calls"], ["check2-all", "g", d.completed_tasks, "Completed tasks"], ["telephone-x", "o", d.not_called, "Not called yet"], ["telephone-inbound", "g", d.connected_calls, "Connected calls"], ["telephone-minus", "r", d.not_connected_calls, "Not connected calls"], ["hand-thumbs-up", "y", d.promised_pending, "Promised to pay"], ["exclamation-triangle", "r", d.promised_overdue, "Promised payment overdue"], ["alarm", "o", d.followups_today, "Follow-ups due today"], ["calendar-event", "b", d.followups_upcoming, "Follow-ups upcoming"], ["alarm-fill", "r", d.followups_overdue, "Follow-ups overdue"], ["hourglass-bottom", "r", d.tasks_overdue, "Tasks past deadline"]];
    root.querySelector("#cd").innerHTML = C.map(([i, c, v, l]) => `<div class="col-6 col-md-4 col-xl-3 col-xxl-2">${T.stat(i, c, T.num(v), l)}</div>`).join("") + `<div class="col-6 col-md-4 col-xl-3 col-xxl-2">${T.stat("percent", "p", d.followup_completion_rate == null ? "—" : d.followup_completion_rate + "%", "Follow-up completion")}</div>`;
    root.querySelector("#cc").innerHTML = `<div class="col-lg-6">${T.chartCard("Daily calls (14 days)", "k1")}</div><div class="col-lg-6">${T.chartCard("Weekly calls", "k2")}</div><div class="col-lg-6">${T.chartCard("Monthly calls", "k3")}</div><div class="col-lg-6">${T.chartCard("Connected vs not connected", "k4")}</div><div class="col-lg-6">${T.chartCard("Promise-to-payment conversion", "k5")}</div>${isAdmin() ? `<div class="col-lg-6">${T.chartCard("Teacher-wise calls", "k6")}</div>` : ""}`;
    const P = T.PALETTE, g = (i) => root.querySelector("#" + i);
    T.chart(g("k1"), { type: "bar", data: { labels: d.daily.map((x) => x.label), datasets: [{ label: "Calls", data: d.daily.map((x) => x.calls), backgroundColor: P[0] }] } });
    T.chart(g("k2"), { type: "line", data: { labels: d.weekly.map((x) => x.label), datasets: [{ label: "Calls", data: d.weekly.map((x) => x.calls), borderColor: P[3], tension: 0.3 }] } });
    T.chart(g("k3"), { type: "bar", data: { labels: d.monthly.map((x) => x.label), datasets: [{ label: "Calls", data: d.monthly.map((x) => x.calls), backgroundColor: P[2] }] } });
    T.chart(g("k4"), { type: "doughnut", data: { labels: ["Connected", "Not connected"], datasets: [{ data: [d.connected_calls, d.not_connected_calls], backgroundColor: [P[1], P[4]] }] } });
    T.chart(g("k5"), { type: "doughnut", data: { labels: ["Promises kept (paid)", "Not (yet) kept"], datasets: [{ data: [d.promise_kept, Math.max(d.promise_made - d.promise_kept, 0)], backgroundColor: [P[1], P[2]] }] } });
    if (isAdmin()) T.chart(g("k6"), { type: "bar", data: { labels: d.by_teacher.map((x) => x.teacher), datasets: [{ label: "Calls", data: d.by_teacher.map((x) => x.calls), backgroundColor: P[5] }] }, options: { indexAxis: "y" } });
  };

  /* ---------------- PENDING FEE CALLING ---------------- */
  T.pages["crm/pending"] = async (root) => {
    if (needCrm(root)) return;
    const f = { q: "", cls: "", group: "", scope: isAdmin() ? "all" : "mine" }; let page = 0; const size = 25;
    root.innerHTML = hdr("Pending Fee Calling", "Students with outstanding fee. RTE, zero-fee and fully paid students are never listed.", isAdmin() ? `<button class="btn btn-primary" id="as-sel"><i class="bi bi-person-plus me-1"></i>Assign selected</button>` : "") +
      `<div class="card mb-3"><div class="card-body filters row g-2"><div class="col-md-4"><input class="form-control" id="q" placeholder="Search student, father, mobile"></div><div class="col-6 col-md-2"><select class="form-select" id="cl">${T.classOpts("")}</select></div>
      ${isAdmin() ? `<div class="col-6 col-md-3"><select class="form-select" id="sc">${T.opts({ all: "All students", mine: "Assigned to me", unassigned: "Unassigned" }, "all")}</select></div>` : ""}</div>
      <div class="px-3 pb-3 d-flex flex-wrap gap-1" id="gr">${GROUPS.map(([k, l]) => `<button class="btn btn-sm ${k === "" ? "btn-primary" : "btn-outline-secondary"}" data-g="${k}">${l}</button>`).join("")}</div></div><div class="card"><div id="cl-list"></div><div id="cl-p"></div></div>`;
    let rows = [];
    const load = async () => {
      const el = root.querySelector("#cl-list"); T.loading(el);
      try {
        const j = await T.rpc("crm_list", { p_session: T.state.session, p_scope: f.scope, p_search: f.q || null, p_class: f.cls || null, p_group: f.group || null, p_limit: size, p_offset: page * size });
        rows = j.rows; el.innerHTML = T.crm.rowsTable(rows, { selectable: isAdmin(), showTeacher: isAdmin() });
        T.crm.bindRows(el, rows, load); T.pager(root.querySelector("#cl-p"), j.total, page, size, (p) => { page = p; load(); });
      } catch (e) { el.innerHTML = T.errorBox(e); }
    };
    const apply = T.debounce(() => { f.q = T.val(root, "#q"); f.cls = T.val(root, "#cl"); if (isAdmin()) f.scope = T.val(root, "#sc"); page = 0; load(); }, 350);
    ["#q", "#cl", "#sc"].forEach((s) => root.querySelector(s)?.addEventListener("input", apply));
    root.querySelectorAll("[data-g]").forEach((b) => (b.onclick = () => { f.group = b.dataset.g; page = 0; root.querySelectorAll("[data-g]").forEach((x) => { x.className = "btn btn-sm " + (x === b ? "btn-primary" : "btn-outline-secondary"); }); load(); }));
    const as = root.querySelector("#as-sel");
    if (as) as.onclick = async () => {
      const ids = [...root.querySelectorAll(".sel:checked")].map((c) => c.value);
      if (!ids.length) return T.toast("Tick unassigned students first (checkbox column).", "warn");
      T.crm.assignModal({ mode: "students", ids }, load);
    };
    load();
  };

  T.crm.assignModal = async ({ mode, ids = [], cls = null }, done) => {
    let staff = []; try { staff = await T.crm.staff(); } catch (e) { return T.fail(e); }
    const m = T.modal({ title: "Assign calling tasks", size: "md", static: true, body: `<p class="small text-muted">${mode === "students" ? `${ids.length} student(s) selected.` : mode === "class" ? `All students of ${T.esc(cls)} with pending fee.` : "All students with pending fee."} Tasks are distributed equally; students who already have an active task are skipped &mdash; unless you tick <b>Same student to every selected teacher</b>.</p><label class="form-label small fw-semibold">Teachers</label>${staff.filter((u) => u.role_code !== "viewer").map((u) => `<div class="form-check"><input type="checkbox" class="form-check-input tt" value="${u.user_id}" id="t${u.user_id}"><label class="form-check-label" for="t${u.user_id}">${T.esc(u.full_name || u.email)} <span class="text-muted small">(${T.esc(T.ROLES[u.role_code] || u.role_code)})</span></label></div>`).join("")}<div class="form-check mb-3"><input type="checkbox" class="form-check-input" id="ash"><label class="form-check-label" for="ash"><b>Same student to every selected teacher</b><div class="small text-muted">All selected teachers get the same student. When one of them completes the task (or the fee is fully paid) it disappears for all of them.</div></label></div><div class="row g-2 mt-2"><div class="col-6"><label class="form-label small fw-semibold">Priority</label><select class="form-select" id="ap">${T.opts({ low: "Low", normal: "Normal", high: "High", urgent: "Urgent" }, "normal")}</select></div><div class="col-6"><label class="form-label small fw-semibold">Deadline</label><input type="date" class="form-control" id="ad" min="${T.today()}"></div></div>`, footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="ago">Assign</button>` });
    m.el.querySelector("#ago").onclick = (ev) => T.busy(ev.currentTarget, async () => {
      const ts = [...m.el.querySelectorAll(".tt:checked")].map((c) => c.value); if (!ts.length) return T.toast("Choose at least one teacher", "warn");
      try { const r = await T.rpc("create_calling_tasks", { p_session: T.state.session, p_mode: mode, p_class: cls, p_student_ids: mode === "students" ? ids : null, p_teacher_ids: ts, p_priority: T.val(m.el, "#ap"), p_deadline: T.nullIfBlank(T.val(m.el, "#ad")), p_share: m.el.querySelector("#ash").checked }, { mutates: true }); T.ok(`${r.created} task(s) created · ${r.shared_added || 0} shared with extra teacher(s) · ${r.skipped_already_assigned} already assigned · ${r.skipped_no_pending_fee} had no pending fee`); m.close(); done && done(r); } catch (e) { T.fail(e); }
    });
  };

  /* ---------------- TODAY / FOLLOW-UPS ---------------- */
  function followPage(title, sub, when) {
    return async (root) => {
      if (needCrm(root)) return;
      let page = 0; const size = 30, f = { teacher: "" };
      let staff = []; if (isAdmin()) { try { staff = await T.crm.staff(); } catch (_) {} }
      root.innerHTML = hdr(title, sub) + (isAdmin() ? `<div class="card mb-3"><div class="card-body py-2"><select class="form-select" id="tf" style="max-width:260px"><option value="">All teachers</option>${staff.map((u) => `<option value="${u.user_id}">${T.esc(u.full_name || u.email)}</option>`).join("")}</select></div></div>` : "") +
        (when === "today" ? `<div id="tk" class="mb-4"></div><h5 class="mb-2">Follow-ups</h5>` : "") + `<div class="card"><div id="fl"></div><div id="fp"></div></div>`;
      const load = async () => {
        const el = root.querySelector("#fl"); T.loading(el);
        try {
          const j = await T.rpc("followups_list", { p_session: T.state.session, p_when: when, p_teacher: T.nullIfBlank(f.teacher), p_limit: size, p_offset: page * size });
          const rows = j.rows.map((r) => ({ ...r, task_priority: null }));
          el.innerHTML = T.table([
            { label: "Due", render: (r) => `<b>${T.dmy(r.due_date)}</b>${r.due_time ? " " + String(r.due_time).slice(0, 5) : ""}<div>${r.due_date < T.today() ? T.badge("overdue") : ""}</div>` },
            { label: "Type", render: (r) => T.badge(r.kind === "promise_overdue" ? "urgent" : r.kind === "promise_due" ? "promised" : "info", T.label(r.kind)) },
            { label: "Student", render: (r) => `<b>${T.esc(r.name)}</b><div class="small text-muted">${T.esc(r.class_name || "")}${r.section ? "-" + T.esc(r.section) : ""} · ${T.esc(r.father_name || "")}</div>` },
            { label: "Call", render: (r) => (r.mobile ? `<a class="btn btn-success btn-sm call-btn" href="tel:${T.phone(r.mobile)}" data-call="${r.student_id}"><i class="bi bi-telephone-fill me-1"></i>CALL</a><div class="small text-muted">${T.esc(r.mobile)}</div>` : "—") },
            { label: "Last remark", cls: "wrap", render: (r) => T.esc((r.last_remark || "—").slice(0, 90)) }, { label: "Promised date", render: (r) => T.dmy(r.promised_date) },
            ...(isAdmin() ? [{ label: "Teacher", key: "assigned_name" }] : []),
            { label: "", cls: "text-end", render: (r) => `<div class="btn-group btn-group-sm"><button class="btn btn-outline-primary" data-log="${r.student_id}"><i class="bi bi-journal-plus"></i></button><button class="btn btn-outline-secondary" data-hist="${r.student_id}"><i class="bi bi-clock-history"></i></button></div>` },
          ], rows, { empty: when === "overdue" ? "No overdue follow-ups 🎉" : "No follow-ups" });
          T.crm.bindRows(el, rows, load); T.pager(root.querySelector("#fp"), j.total, page, size, (p) => { page = p; load(); });
        } catch (e) { el.innerHTML = T.errorBox(e); }
      };
      const tf = root.querySelector("#tf"); if (tf) tf.onchange = () => { f.teacher = tf.value; page = 0; load(); };
      if (when === "today") {
        const tk = root.querySelector("#tk"); T.loading(tk);
        T.rpc("crm_list", { p_session: T.state.session, p_scope: "mine", p_group: "no_calling", p_limit: 50, p_offset: 0 }).then((j) => {
          tk.innerHTML = `<h5 class="mb-2">Assigned students not yet called (${j.total})</h5><div class="card">${T.crm.rowsTable(j.rows)}</div>`; T.crm.bindRows(tk, j.rows, () => T.pages["crm/today"](root));
        }).catch((e) => (tk.innerHTML = T.errorBox(e)));
      }
      load();
    };
  }
  T.pages["crm/today"] = followPage("Today's Tasks", "Your assigned students not yet called, and follow-ups due today", "today");
  T.pages["crm/overdue"] = followPage("Overdue Follow-ups", "Missed follow-up dates and broken payment promises", "overdue");
  T.pages["crm/followups"] = followPage("Upcoming Follow-ups", "Scheduled in the coming days", "upcoming");

  /* ---------------- CALL HISTORY ---------------- */
  T.pages["crm/history"] = async (root) => {
    if (needCrm(root)) return;
    const f = { from: "", to: "", teacher: "", status: "", q: "" }; let page = 0; const size = 30;
    let staff = []; if (isAdmin()) { try { staff = await T.crm.staff(); } catch (_) {} }
    root.innerHTML = hdr("Call History", isAdmin() ? "All calls recorded in this session" : "Your recorded calls") + `<div class="card mb-3"><div class="card-body filters row g-2"><div class="col-md-3"><input id="q" class="form-control" placeholder="Student, father or remark"></div><div class="col-6 col-md-2"><input type="date" id="df" class="form-control"></div><div class="col-6 col-md-2"><input type="date" id="dt" class="form-control"></div><div class="col-6 col-md-2"><select id="st" class="form-select">${T.opts(T.CALL_STATUS, "", "All outcomes")}</select></div>${isAdmin() ? `<div class="col-6 col-md-3"><select id="tc" class="form-select"><option value="">All teachers</option>${staff.map((u) => `<option value="${u.user_id}">${T.esc(u.full_name || u.email)}</option>`).join("")}</select></div>` : ""}</div></div><div class="card"><div id="hl"></div><div id="hp"></div></div>`;
    const load = async () => {
      const el = root.querySelector("#hl"); T.loading(el);
      try {
        const j = await T.rpc("calls_list", { p_session: T.state.session, p_from: f.from || null, p_to: f.to || null, p_teacher: T.nullIfBlank(f.teacher), p_status: f.status || null, p_search: f.q || null, p_limit: size, p_offset: page * size });
        el.innerHTML = T.table([{ label: "When", render: (c) => T.dmyTime(c.called_at), cls: "nowrap" }, { label: "Student", render: (c) => `<b>${T.esc(c.student_name)}</b><div class="small text-muted">${T.esc(c.class_name || "")} · ${T.esc(c.father_name || "")}</div>` }, { label: "Teacher", key: "teacher_name" }, { label: "Status", render: (c) => T.badge(c.connected ? "verified" : "pending", T.CALL_STATUS[c.call_status]) }, { label: "Remark", key: "remark", cls: "wrap" }, { label: "Promise", render: (c) => T.dmy(c.promised_date) }, { label: "Follow-up", render: (c) => T.dmy(c.next_followup_date) }], j.rows, { empty: "No calls found" });
        T.pager(root.querySelector("#hp"), j.total, page, size, (p) => { page = p; load(); });
      } catch (e) { el.innerHTML = T.errorBox(e); }
    };
    const apply = T.debounce(() => { f.q = T.val(root, "#q"); f.from = T.val(root, "#df"); f.to = T.val(root, "#dt"); f.status = T.val(root, "#st"); f.teacher = T.val(root, "#tc"); page = 0; load(); }, 300);
    ["#q", "#df", "#dt", "#st", "#tc"].forEach((s) => root.querySelector(s)?.addEventListener("input", apply));
    load();
  };

  /* ---------------- TEACHER PERFORMANCE ---------------- */
  T.pages["crm/teachers"] = async (root) => {
    if (needCrm(root)) return;
    const f = { from: T.addDays(T.today(), -29), to: T.today() };
    root.innerHTML = hdr("Teacher Performance", "Based only on saved call entries — opening the dialer is never counted.") +
      `<div class="card mb-3"><div class="card-body row g-2 align-items-end"><div class="col-6 col-md-2"><label class="small text-muted">From</label><input type="date" id="pf" class="form-control" value="${f.from}"></div><div class="col-6 col-md-2"><label class="small text-muted">To</label><input type="date" id="pt" class="form-control" value="${f.to}"></div><div class="col-md-2"><button class="btn btn-primary w-100" id="pg">Apply</button></div>
      <div class="col-md-6 small text-muted">Score = Coverage 40% (students called ÷ tasks assigned) + Follow-up adherence 30% (on-time ÷ (done + missed)) + Connect rate 10% + Promise recovery 20% (promises kept ÷ made). A component with no data is left out and the remaining weights are re-scaled; no score is shown when nothing is measurable.</div></div></div><div class="card"><div id="tp"></div></div>`;
    const load = async () => {
      const el = root.querySelector("#tp"); T.loading(el);
      try {
        const j = await T.rpc("teacher_performance", { p_session: T.state.session, p_from: f.from || null, p_to: f.to || null });
        T.crm._perf = j.rows;
        el.innerHTML = T.table([
          { label: "Teacher", render: (r) => `<a href="#" data-t="${r.teacher_id}" class="fw-semibold text-decoration-none">${T.esc(r.teacher_name)}</a>` },
          { label: "Score", render: (r) => (r.score == null ? '<span class="text-muted">n/a</span>' : `<span class="badge-s ${r.score >= 70 ? "b-paid" : r.score >= 40 ? "b-partial" : "b-unpaid"}">${r.score}</span>`) },
          { label: "Students", key: "assigned_students" }, { label: "Tasks", key: "assigned_tasks" }, { label: "Calls", key: "total_calls" }, { label: "Connected", key: "connected_calls" }, { label: "Not answered", key: "not_answered" }, { label: "Busy", key: "busy_calls" },
          { label: "Promises", key: "promised_payments" }, { label: "Follow-ups done", key: "followups_completed" }, { label: "Missed", render: (r) => (r.followups_missed ? `<span class="text-danger fw-semibold">${r.followups_missed}</span>` : 0) }, { label: "Overdue tasks", key: "overdue_tasks" },
          { label: "Last call", render: (r) => T.dmy(r.last_call_at) }, { label: "Today", key: "calls_today" }, { label: "7 days", key: "calls_week" }, { label: "30 days", key: "calls_month" }, { label: "Daily target", render: (r) => r.daily_target ?? "—" },
          { label: "Kept/made", render: (r) => `${r.promises_kept}/${r.promises_made}` },
        ], j.rows, { empty: "No teachers with calling access found" });
        el.querySelectorAll("[data-t]").forEach((a) => (a.onclick = (e) => { e.preventDefault(); const r = j.rows.find((x) => x.teacher_id === a.dataset.t); teacherDetail(r); }));
      } catch (e) { el.innerHTML = T.errorBox(e); }
    };
    const teacherDetail = (r) => {
      const m = T.modal({ title: `${T.esc(r.teacher_name)} — calling history`, size: "xl", body: `<div class="row g-2 mb-3">${[["Calls", r.total_calls], ["Connected", r.connected_calls], ["Coverage", r.coverage_pct == null ? "—" : r.coverage_pct + "%"], ["Follow-up on time", r.followup_pct == null ? "—" : r.followup_pct + "%"], ["Promise recovery", r.recovery_pct == null ? "—" : r.recovery_pct + "%"], ["Overdue tasks", r.overdue_tasks]].map(([l, v]) => `<div class="col-4 col-md-2"><div class="text-muted small">${l}</div><div class="fw-bold">${v}</div></div>`).join("")}</div><div id="td"><div class="loading">Loading…</div></div>` });
      T.rpc("calls_list", { p_session: T.state.session, p_from: f.from, p_to: f.to, p_teacher: r.teacher_id, p_limit: 200 }).then((j) => { m.el.querySelector("#td").innerHTML = T.table([{ label: "When", render: (c) => T.dmyTime(c.called_at) }, { label: "Student", key: "student_name" }, { label: "Status", render: (c) => T.badge(c.connected ? "verified" : "pending", T.CALL_STATUS[c.call_status]) }, { label: "Remark", key: "remark", cls: "wrap" }, { label: "Promise", render: (c) => T.dmy(c.promised_date) }], j.rows, { empty: "No calls in this period" }); }).catch((e) => (m.el.querySelector("#td").innerHTML = T.errorBox(e)));
    };
    root.querySelector("#pg").onclick = () => { f.from = T.val(root, "#pf"); f.to = T.val(root, "#pt"); load(); };
    load();
  };

  T.pages["crm/reports"] = async (root) => {
    root.innerHTML = hdr("Calling Reports", "All calling reports live in the Reporting Centre, with filters and CSV / Excel / PDF / print export.") + `<a class="btn btn-primary" href="#/reports?cat=crm"><i class="bi bi-graph-up me-1"></i>Open calling reports</a>`;
  };

  /* ---------------- TASK ASSIGNMENT ---------------- */
  T.pages["crm/assign"] = async (root) => {
    if (!T.can("assign_calling_tasks")) { root.innerHTML = T.errorBox(new Error("You need the “Assign Calling Tasks” permission.")); return; }
    let staff = []; try { staff = await T.crm.staff(); } catch (e) { root.innerHTML = T.errorBox(e); return; }
    const name = (id) => { const u = staff.find((x) => x.user_id === id); return u ? u.full_name || u.email : "—"; };
    const callers = staff.filter((u) => u.role_code !== "viewer");
    let tpage = 0; const tsize = 25, tf = { status: "active", teacher: "" };
    root.innerHTML = hdr("Task Assignment", "Assign pending-fee students to teachers, set targets and reassign work.") + `<div class="row g-3 mb-3"><div class="col-lg-6"><div class="card h-100"><div class="card-header">Create tasks</div><div class="card-body">
      <div class="btn-group w-100 mb-3"><input type="radio" class="btn-check" name="am" id="m1" value="all_pending" checked><label class="btn btn-outline-primary" for="m1">All pending-fee students</label><input type="radio" class="btn-check" name="am" id="m2" value="class"><label class="btn btn-outline-primary" for="m2">Entire class</label><input type="radio" class="btn-check" name="am" id="m3" value="students"><label class="btn btn-outline-primary" for="m3">Selected students</label></div>
      <div id="amc" class="mb-3 d-none"><select class="form-select" id="acl">${T.classOpts("", "Select class")}</select></div><div id="ams" class="mb-3 d-none"><div id="asp"></div><div id="asc" class="mt-2"></div></div>
      <label class="form-label small fw-semibold">Teachers</label><div class="mb-3">${callers.map((u) => `<div class="form-check"><input type="checkbox" class="form-check-input tt" value="${u.user_id}" id="x${u.user_id}"><label class="form-check-label" for="x${u.user_id}">${T.esc(u.full_name || u.email)} <span class="text-muted small">(${T.esc(T.ROLES[u.role_code] || u.role_code)})</span></label></div>`).join("")}</div>
      <div class="form-check mb-3"><input type="checkbox" class="form-check-input" id="ashp"><label class="form-check-label" for="ashp"><b>Same student to every selected teacher</b><div class="small text-muted">All selected teachers get the same student. When one of them completes the task (or the fee is fully paid) it disappears for all of them.</div></label></div><div class="row g-2 mb-3"><div class="col-6"><label class="form-label small fw-semibold">Priority</label><select class="form-select" id="ap">${T.opts({ low: "Low", normal: "Normal", high: "High", urgent: "Urgent" }, "normal")}</select></div><div class="col-6"><label class="form-label small fw-semibold">Deadline</label><input type="date" class="form-control" id="ad" min="${T.today()}"></div></div><button class="btn btn-primary" id="ago"><i class="bi bi-person-plus me-1"></i>Create tasks</button><div id="ares" class="mt-3"></div></div></div></div>
      <div class="col-lg-6"><div class="card h-100"><div class="card-header">Daily calling targets</div><div id="tg"></div></div></div></div>
      <div class="card"><div class="card-header d-flex flex-wrap justify-content-between gap-2"><span>Calling tasks</span><div class="d-flex gap-2"><select id="ts" class="form-select form-select-sm">${T.opts({ active: "Active", completed: "Completed", cancelled: "Cancelled", "": "All" }, "active")}</select><select id="tt" class="form-select form-select-sm"><option value="">All teachers</option>${callers.map((u) => `<option value="${u.user_id}">${T.esc(u.full_name || u.email)}</option>`).join("")}</select></div></div><div id="tl"></div><div id="tpg"></div></div>`;
    const chosen = new Map();
    root.querySelectorAll("[name=am]").forEach((r) => (r.onchange = () => { root.querySelector("#amc").classList.toggle("d-none", r.value !== "class" || !r.checked); root.querySelector("#ams").classList.toggle("d-none", r.value !== "students" || !r.checked); }));
    T.studentPicker(root.querySelector("#asp"), (s) => { chosen.set(s.student_id, s); root.querySelector("#asc").innerHTML = [...chosen.values()].map((s) => `<span class="badge text-bg-light border me-1">${T.esc(s.name)}</span>`).join(""); });
    root.querySelector("#ago").onclick = (ev) => T.busy(ev.currentTarget, async () => {
      const mode = root.querySelector("[name=am]:checked").value, ts = [...root.querySelectorAll(".tt:checked")].map((c) => c.value);
      if (!ts.length) return T.toast("Choose at least one teacher", "warn");
      if (mode === "class" && !T.val(root, "#acl")) return T.toast("Select a class", "warn"); if (mode === "students" && !chosen.size) return T.toast("Pick at least one student", "warn");
      try { const r = await T.rpc("create_calling_tasks", { p_session: T.state.session, p_mode: mode, p_class: mode === "class" ? T.val(root, "#acl") : null, p_student_ids: mode === "students" ? [...chosen.keys()] : null, p_teacher_ids: ts, p_priority: T.val(root, "#ap"), p_deadline: T.nullIfBlank(T.val(root, "#ad")), p_share: root.querySelector("#ashp").checked }, { mutates: true }); root.querySelector("#ares").innerHTML = `<div class="alert alert-success mb-0"><b>${r.created}</b> task(s) created · <b>${r.shared_added || 0}</b> shared with extra teacher(s) · ${r.skipped_already_assigned} skipped (already have an active task) · ${r.skipped_no_pending_fee} skipped (no pending fee)</div>`; loadTasks(); } catch (e) { T.fail(e); }
    });
    /* targets */
    const loadTargets = async () => {
      const el = root.querySelector("#tg");
      try {
        const rows = await T.q(window.sb.from("teacher_calling_targets").select("teacher_id,daily_target,effective_from").order("effective_from", { ascending: false }));
        const cur = (id) => rows.find((r) => r.teacher_id === id && r.effective_from <= T.today())?.daily_target ?? "";
        el.innerHTML = `<table class="table table-sm align-middle mb-0">${callers.map((u) => `<tr><td>${T.esc(u.full_name || u.email)}</td><td style="width:110px"><input type="number" min="0" class="form-control form-control-sm tg" data-u="${u.user_id}" value="${cur(u.user_id)}" placeholder="calls/day"></td><td style="width:70px"><button class="btn btn-sm btn-outline-primary" data-s="${u.user_id}">Set</button></td></tr>`).join("")}</table>`;
        el.querySelectorAll("[data-s]").forEach((b) => (b.onclick = async () => { const v = el.querySelector(`.tg[data-u="${b.dataset.s}"]`).value; if (v === "") return; try { await T.rpc("set_teacher_target", { p_teacher: b.dataset.s, p_daily: Number(v) }, { mutates: true }); T.ok("Target saved"); } catch (e) { T.fail(e); } }));
      } catch (e) { el.innerHTML = T.errorBox(e); }
    };
    /* tasks */
    const loadTasks = async () => {
      const el = root.querySelector("#tl"); T.loading(el);
      try {
        let q = window.sb.from("calling_tasks").select("id,status,priority,deadline,call_count,last_call_at,assigned_to,co_assignees,next_followup_date,students(name,father_name)", { count: "exact" }).eq("session_id", T.state.session).order("created_at", { ascending: false }).range(tpage * tsize, tpage * tsize + tsize - 1);
        if (tf.status === "active") q = q.in("status", ["pending", "in_progress", "promised"]); else if (tf.status) q = q.eq("status", tf.status);
        if (tf.teacher) q = q.or(`assigned_to.eq.${tf.teacher},co_assignees.cs.{${tf.teacher}}`);
        const { data, count } = await T.q(q);
        el.innerHTML = T.table([{ label: "Student", render: (t) => `<b>${T.esc(t.students?.name)}</b><div class="small text-muted">${T.esc(t.students?.father_name || "")}</div>` }, { label: "Assigned to", render: (t) => T.esc([name(t.assigned_to), ...(t.co_assignees || []).map(name)].join(", ")) }, { label: "Status", render: (t) => T.badge(t.status) }, { label: "Priority", render: (t) => T.badge(t.priority) }, { label: "Deadline", render: (t) => T.dmy(t.deadline) }, { label: "Calls", key: "call_count" }, { label: "Last call", render: (t) => T.dmy(t.last_call_at) }, { label: "Next follow-up", render: (t) => T.dmy(t.next_followup_date) },
          { label: "", cls: "text-end", render: (t) => `<div class="btn-group btn-group-sm"><button class="btn btn-outline-secondary" data-h="${t.id}" title="History"><i class="bi bi-clock-history"></i></button>${["pending", "in_progress", "promised"].includes(t.status) ? `<button class="btn btn-outline-primary" data-r="${t.id}" title="Reassign"><i class="bi bi-arrow-left-right"></i></button><button class="btn btn-outline-success" data-sh="${t.id}" data-has="${[t.assigned_to, ...(t.co_assignees || [])].join(",")}" title="Also give this student to another teacher"><i class="bi bi-person-plus"></i></button><button class="btn btn-outline-danger" data-c="${t.id}" title="Cancel"><i class="bi bi-x-lg"></i></button>` : ""}</div>` }], data, { empty: "No tasks" });
        T.pager(root.querySelector("#tpg"), count, tpage, tsize, (p) => { tpage = p; loadTasks(); });
        el.querySelectorAll("[data-r]").forEach((b) => (b.onclick = () => { const m = T.modal({ title: "Reassign task", size: "sm", scroll: false, body: `<label class="form-label">New teacher</label><select class="form-select mb-2" id="rt">${callers.map((u) => `<option value="${u.user_id}">${T.esc(u.full_name || u.email)}</option>`).join("")}</select><label class="form-label">Reason</label><input class="form-control" id="rr">`, footer: `<button class="btn btn-primary" id="rg">Reassign</button>` }); m.el.querySelector("#rg").onclick = async () => { try { await T.rpc("reassign_task", { p_task: b.dataset.r, p_to: T.val(m.el, "#rt"), p_reason: T.val(m.el, "#rr") || null }, { mutates: true }); T.ok("Task reassigned (history kept)"); m.close(); loadTasks(); } catch (e) { T.fail(e); } }; }));
        el.querySelectorAll("[data-sh]").forEach((b) => (b.onclick = () => {
          const has = b.dataset.has.split(","), opts = callers.filter((u) => !has.includes(u.user_id));
          if (!opts.length) return T.toast("Every eligible teacher already has this student", "warn");
          const m = T.modal({ title: "Give this student to another teacher", size: "sm", scroll: false, body: `<label class="form-label">Teacher</label><select class="form-select" id="st">${opts.map((u) => `<option value="${u.user_id}">${T.esc(u.full_name || u.email)}</option>`).join("")}</select><div class="form-text">Both teachers will see this student. When either completes the task, it disappears for both.</div>`, footer: `<button class="btn btn-primary" id="sg">Add teacher</button>` });
          m.el.querySelector("#sg").onclick = async () => { try { await T.rpc("add_task_assignee", { p_task: b.dataset.sh, p_user: T.val(m.el, "#st") }, { mutates: true }); T.ok("Teacher added to this task"); m.close(); loadTasks(); } catch (e) { T.fail(e); } };
        }));
        el.querySelectorAll("[data-c]").forEach((b) => (b.onclick = async () => { const r = await T.confirm({ title: "Cancel task", message: "The calling task is cancelled; its call history is kept.", reason: true, danger: true, okText: "Cancel task" }); if (!r) return; try { await T.rpc("cancel_calling_task", { p_task: b.dataset.c, p_reason: r }, { mutates: true }); T.ok("Task cancelled"); loadTasks(); } catch (e) { T.fail(e); } }));
        el.querySelectorAll("[data-h]").forEach((b) => (b.onclick = async () => { try { const h = await T.q(window.sb.from("task_assignment_history").select("*").eq("task_id", b.dataset.h).order("changed_at")); T.modal({ title: "Assignment history", size: "md", body: T.table([{ label: "When", render: (x) => T.dmyTime(x.changed_at) }, { label: "From", render: (x) => T.esc(x.from_user ? name(x.from_user) : "—") }, { label: "To", render: (x) => T.esc(name(x.to_user)) }, { label: "Reason", key: "reason", cls: "wrap" }], h) }); } catch (e) { T.fail(e); } }));
      } catch (e) { el.innerHTML = T.errorBox(e); }
    };
    root.querySelector("#ts").onchange = (e) => { tf.status = e.target.value; tpage = 0; loadTasks(); };
    root.querySelector("#tt").onchange = (e) => { tf.teacher = e.target.value; tpage = 0; loadTasks(); };
    loadTargets(); loadTasks();
  };

  /* ---------------- CRM SETTINGS (also used on Settings page) ---------------- */
  T.crm.settingsCard = async (el) => {
    let cfg = {}; try { const r = await T.q(window.sb.from("school_settings").select("value").eq("key", "crm").maybeSingle()); cfg = r?.value || {}; } catch (e) { el.innerHTML = T.errorBox(e); return; }
    const v = (k, d) => cfg[k] ?? d, can = T.can("manage_settings");
    el.innerHTML = `<div class="card"><div class="card-header">Calling CRM &amp; reminder rules</div><div class="card-body"><div class="row g-3">
      ${T.field("Remind if no call for (days)", `<input type="number" min="1" class="form-control cs" data-k="no_recent_call_days" value="${v("no_recent_call_days", 7)}" ${can ? "" : "disabled"}>`, { col: "col-md-4" })}
      ${T.field("Default follow-up interval (days)", `<input type="number" min="1" class="form-control cs" data-k="followup_interval_days" value="${v("followup_interval_days", 3)}" ${can ? "" : "disabled"}>`, { col: "col-md-4" })}
      ${T.field("Max reminders per follow-up", `<input type="number" min="1" class="form-control cs" data-k="max_reminders" value="${v("max_reminders", 3)}" ${can ? "" : "disabled"}>`, { col: "col-md-4" })}
      ${T.field("Escalate to Principal after (days overdue)", `<input type="number" min="1" class="form-control cs" data-k="escalate_principal_after_days" value="${v("escalate_principal_after_days", 3)}" ${can ? "" : "disabled"}>`, { col: "col-md-4" })}
      ${T.field("Escalate to Owner after (days overdue)", `<input type="number" min="1" class="form-control cs" data-k="escalate_owner_after_days" value="${v("escalate_owner_after_days", 7)}" ${can ? "" : "disabled"}>`, { col: "col-md-4" })}
      ${T.field("Default daily call target", `<input type="number" min="0" class="form-control cs" data-k="default_daily_target" value="${v("default_daily_target", 20)}" ${can ? "" : "disabled"}>`, { col: "col-md-4" })}</div>
      ${can ? `<button class="btn btn-primary mt-3" id="cs-save">Save CRM settings</button>` : `<div class="text-muted small mt-2">You need “Manage Settings” to change these.</div>`}<div class="form-text mt-2">Reminders run automatically whenever staff open the app (and every 30 minutes if pg_cron is enabled).</div></div></div>`;
    const sv = el.querySelector("#cs-save");
    if (sv) sv.onclick = () => T.busy(sv, async () => { const o = {}; el.querySelectorAll(".cs").forEach((i) => (o[i.dataset.k] = Number(i.value))); try { await T.mutate(window.sb.from("school_settings").upsert({ school_id: T.schoolId(), key: "crm", value: o, updated_by: T.state.user.id }, { onConflict: "school_id,key" })); T.ok("CRM settings saved"); } catch (e) { T.fail(e); } });
  };
  T.pages["crm/settings"] = async (root) => { root.innerHTML = hdr("CRM Settings", "Reminder frequency, escalation and targets") + `<div id="cs"></div>`; T.crm.settingsCard(root.querySelector("#cs")); };

  /* ---------------- TEACHER HOME ---------------- */
  T.crm.myDashboard = async (root) => {
    root.innerHTML = hdr("My Dashboard", `Welcome, ${T.esc(T.state.user.user_metadata?.full_name || T.state.user.email)} · Session ${T.esc(T.sessions.current()?.name || "")}`) + `<div id="md" class="row g-3 mb-3"></div><div class="row g-3"><div class="col-lg-7"><div class="card"><div class="card-header d-flex justify-content-between">Today's calling tasks<a href="#/crm/today" class="small">Open all</a></div><div id="mt"></div></div></div><div class="col-lg-5"><div class="card mb-3"><div class="card-header">My calling performance (30 days)</div><div id="mp" class="card-body"></div></div><div class="card"><div class="card-header">Recent calls</div><div id="mr"></div></div></div></div>`;
    try {
      const [d, perf, recent, tasks] = await Promise.all([
        T.rpc("crm_dashboard", { p_session: T.state.session }),
        T.rpc("teacher_performance", { p_session: T.state.session, p_from: T.addDays(T.today(), -29), p_to: T.today() }),
        T.rpc("calls_list", { p_session: T.state.session, p_limit: 6 }),
        T.rpc("crm_list", { p_session: T.state.session, p_scope: "mine", p_limit: 8 }),
      ]);
      const C = [["people", "p", d.students_requiring_calls, "My assigned students"], ["list-task", "b", d.pending_tasks, "Pending calls"], ["telephone-outbound", "g", d.calls_today, "Calls completed today"], ["alarm", "o", d.followups_today, "Follow-ups due today"], ["alarm-fill", "r", d.followups_overdue, "Overdue follow-ups"], ["hand-thumbs-up", "y", d.promised_pending + d.promised_overdue, "Promised payments"]];
      root.querySelector("#md").innerHTML = C.map(([i, c, v, l]) => `<div class="col-6 col-md-4 col-xl-2">${T.stat(i, c, T.num(v), l)}</div>`).join("");
      const me = perf.rows[0];
      root.querySelector("#mp").innerHTML = me ? `<div class="row text-center g-2"><div class="col-4"><div class="h4 mb-0">${me.total_calls}</div><div class="small text-muted">Calls</div></div><div class="col-4"><div class="h4 mb-0">${me.connected_calls}</div><div class="small text-muted">Connected</div></div><div class="col-4"><div class="h4 mb-0">${me.score ?? "n/a"}</div><div class="small text-muted">Score</div></div></div>${d.my_target ? `<div class="mt-3 small">Daily target: <b>${d.calls_today}/${d.my_target}</b> today</div><div class="progress"><div class="progress-bar" style="width:${Math.min(100, (100 * d.calls_today) / d.my_target)}%"></div></div>` : ""}` : "—";
      root.querySelector("#mr").innerHTML = T.table([{ label: "When", render: (c) => T.dmyTime(c.called_at) }, { label: "Student", key: "student_name" }, { label: "Status", render: (c) => T.badge(c.connected ? "verified" : "pending", T.CALL_STATUS[c.call_status]) }], recent.rows, { empty: "No calls yet" });
      root.querySelector("#mt").innerHTML = T.crm.rowsTable(tasks.rows); T.crm.bindRows(root.querySelector("#mt"), tasks.rows, () => T.crm.myDashboard(root));
    } catch (e) { root.querySelector("#md").innerHTML = `<div class="col-12">${T.errorBox(e)}</div>`; }
  };
})();