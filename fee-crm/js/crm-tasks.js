/* Calling CRM: task filters, bulk transfer / add / remove teachers, manage one task, renew expired tasks.
 * All permission and school checks are enforced again by the database functions. */
(function () {
  const T = window.T;
  T.crm = T.crm || {};
  const isAdmin = () => T.canAny("assign_calling_tasks", "view_teacher_performance");
  const canAssign = () => T.can("assign_calling_tasks");
  const callersOf = (staff) => staff.filter((u) => u.role_code !== "viewer");
  const uname = (u) => T.esc(u.full_name || u.email);
  const plusDays = (n) => { const d = new Date(Date.now() + 5.5 * 3600 * 1000 + n * 86400000); return d.toISOString().slice(0, 10); };

  /** Deadlines are enforced by the database; this just makes sure it ran before a page lists tasks. */
  let lastExpire = 0;
  T.crm.expire = async () => {
    if (Date.now() - lastExpire < 60000) return;
    lastExpire = Date.now();
    try { await window.sb.rpc("expire_my_tasks"); } catch (_) { /* older database: ignore */ }
  };
  T.crm.resetExpire = () => { lastExpire = 0; };

  const skipModal = (title, skipped) => {
    if (!skipped || !skipped.length) return;
    T.modal({ title, size: "md", body: `<p class="small text-muted">These were not changed:</p>${T.table([{ label: "Student", render: (x) => T.esc(x.student) }, { label: "Reason", render: (x) => T.esc(x.reason), cls: "wrap" }], skipped)}` });
  };

  /* ---------- Transfer / add / remove teachers for many tasks ---------- */
  T.crm.bulkModal = (ids, staff, done) => {
    const callers = callersOf(staff);
    const m = T.modal({
      title: `Change teachers — ${ids.length} task(s)`, size: "md", static: true, scroll: false,
      body: `<div class="btn-group-vertical w-100 mb-3">
        <input type="radio" class="btn-check" name="bm" id="bm1" value="set" checked><label class="btn btn-outline-primary text-start" for="bm1"><b>Transfer</b> — give these tasks to the teacher(s) below. Current teachers are replaced.</label>
        <input type="radio" class="btn-check" name="bm" id="bm2" value="add"><label class="btn btn-outline-primary text-start" for="bm2"><b>Also give to</b> — add the teacher(s) below. Current teachers keep the task.</label>
        <input type="radio" class="btn-check" name="bm" id="bm3" value="remove"><label class="btn btn-outline-primary text-start" for="bm3"><b>Remove</b> — take these tasks away from the teacher(s) below.</label></div>
        <label class="form-label small fw-semibold">Teachers</label>
        <div class="mb-2" style="max-height:220px;overflow:auto">${callers.map((u) => `<div class="form-check"><input type="checkbox" class="form-check-input bt" value="${u.user_id}" id="b${u.user_id}"><label class="form-check-label" for="b${u.user_id}">${uname(u)} <span class="text-muted small">(${T.esc(T.ROLES[u.role_code] || u.role_code)})</span></label></div>`).join("")}</div>
        <div class="small text-muted mb-2" id="bhint"></div>
        <label class="form-label small fw-semibold">Reason (optional)</label><input class="form-control" id="br" placeholder="e.g. teacher on leave">`,
      footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="bgo">Apply</button>`,
    });
    const hint = () => {
      const mode = m.el.querySelector("[name=bm]:checked").value;
      m.el.querySelector("#bhint").textContent = mode === "set" ? "If you tick several teachers they all share the same task; the first one in the list is the main teacher." : mode === "add" ? "Every ticked teacher will also see and call these students." : "A task always keeps at least one teacher — use Transfer to give it to someone else.";
    };
    m.el.querySelectorAll("[name=bm]").forEach((r) => (r.onchange = hint)); hint();
    m.el.querySelector("#bgo").onclick = (ev) => T.busy(ev.currentTarget, async () => {
      const users = [...m.el.querySelectorAll(".bt:checked")].map((c) => c.value), mode = m.el.querySelector("[name=bm]:checked").value;
      if (!users.length) return T.toast("Tick at least one teacher", "warn");
      try {
        const r = await T.rpc("bulk_assign_tasks", { p_tasks: ids, p_mode: mode, p_users: users, p_reason: T.nullIfBlank(T.val(m.el, "#br")) }, { mutates: true });
        T.ok(`${r.updated} task(s) updated${r.unchanged ? ` · ${r.unchanged} already as requested` : ""}${r.skipped.length ? ` · ${r.skipped.length} skipped` : ""}`);
        m.close(); skipModal("Some tasks were not changed", r.skipped); done && done(r);
      } catch (e) { T.fail(e); }
    });
  };

  /* ---------- Manage ONE task: who has it, who is the main teacher ---------- */
  T.crm.manageModal = (task, staff, done) => {
    const callers = callersOf(staff), cur = [task.assigned_to, ...(task.co_assignees || [])];
    const m = T.modal({
      title: `Teachers for ${T.esc(task.students?.name || task.name || "this student")}`, size: "md", static: true, scroll: false,
      body: `<p class="small text-muted mb-2">Every ticked teacher sees this <b>same</b> task and can call. When one of them completes it (or the fee is fully paid) it disappears for all. Untick a teacher to remove it from them. Choose who is the <b>main</b> teacher.</p>
        <table class="table table-sm align-middle mb-2"><thead><tr><th>Teacher</th><th class="text-center">Has this task</th><th class="text-center">Main</th></tr></thead><tbody>${callers.map((u) => `<tr><td>${uname(u)}</td><td class="text-center"><input type="checkbox" class="form-check-input mt" value="${u.user_id}" ${cur.includes(u.user_id) ? "checked" : ""}></td><td class="text-center"><input type="radio" class="form-check-input mm" name="mainT" value="${u.user_id}" ${u.user_id === task.assigned_to ? "checked" : ""}></td></tr>`).join("")}</tbody></table>
        <label class="form-label small fw-semibold">Reason (optional)</label><input class="form-control" id="mr" placeholder="e.g. changed class teacher">`,
      footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="mgo">Save</button>`,
    });
    m.el.querySelector("#mgo").onclick = (ev) => T.busy(ev.currentTarget, async () => {
      const ticked = [...m.el.querySelectorAll(".mt:checked")].map((c) => c.value), main = (m.el.querySelector(".mm:checked") || {}).value;
      if (!ticked.length) return T.toast("Keep at least one teacher on the task (or cancel the task)", "warn");
      if (!main || !ticked.includes(main)) return T.toast("The main teacher must be one of the ticked teachers", "warn");
      const users = [main, ...ticked.filter((x) => x !== main)];
      if (users.join() === cur.join()) return T.toast("No change", "info");
      try {
        const r = await T.rpc("bulk_assign_tasks", { p_tasks: [task.id], p_mode: "set", p_users: users, p_reason: T.nullIfBlank(T.val(m.el, "#mr")) }, { mutates: true });
        if (r.skipped.length) { skipModal("Not changed", r.skipped); } else T.ok("Teachers updated (history kept)");
        m.close(); done && done(r);
      } catch (e) { T.fail(e); }
    });
  };

  /* ---------- Renew expired tasks (new deadline, same or new teachers) ---------- */
  T.crm.renewModal = (ids, staff, done) => {
    const callers = callersOf(staff);
    const m = T.modal({
      title: `Assign again — ${ids.length} expired task(s)`, size: "md", static: true, scroll: false,
      body: `<p class="small text-muted">The deadline of these tasks is over. A <b>new task</b> is created for each student whose fee is still pending. The old task stays in history.</p>
        <div class="row g-2 mb-2"><div class="col-6"><label class="form-label small fw-semibold">New deadline *</label><input type="date" class="form-control" id="rd" min="${T.today()}" value="${plusDays(7)}"></div>
        <div class="col-6"><label class="form-label small fw-semibold">Priority</label><select class="form-select" id="rp"><option value="">Keep same</option>${T.opts({ low: "Low", normal: "Normal", high: "High", urgent: "Urgent" }, "")}</select></div></div>
        <label class="form-label small fw-semibold mb-0">Teachers</label><div class="small text-muted mb-1">Leave all unticked to give it to the <b>same teachers as before</b>, or tick the teacher(s) who should get it now.</div>
        <div style="max-height:200px;overflow:auto">${callers.map((u) => `<div class="form-check"><input type="checkbox" class="form-check-input rt" value="${u.user_id}" id="r${u.user_id}"><label class="form-check-label" for="r${u.user_id}">${uname(u)}</label></div>`).join("")}</div>`,
      footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-success" id="rgo">Create new task(s)</button>`,
    });
    m.el.querySelector("#rgo").onclick = (ev) => T.busy(ev.currentTarget, async () => {
      const ts = [...m.el.querySelectorAll(".rt:checked")].map((c) => c.value), dl = T.val(m.el, "#rd");
      if (!dl || dl < T.today()) return T.toast("Choose a deadline of today or later", "warn");
      try {
        const r = await T.rpc("renew_tasks", { p_tasks: ids, p_deadline: dl, p_users: ts.length ? ts : null, p_priority: T.nullIfBlank(T.val(m.el, "#rp")) }, { mutates: true });
        T.ok(`${r.renewed} new task(s) created${r.skipped.length ? ` · ${r.skipped.length} skipped` : ""}`);
        m.close(); skipModal("Some tasks were not renewed", r.skipped); done && done(r);
      } catch (e) { T.fail(e); }
    });
  };

  /* ---------- Today's Tasks: filters + select + bulk transfer ---------- */
  const CALL_GROUPS = [["", "All"], ["no_calling", "Not called yet"], ["no_payment", "No payment"], ["partial", "Partially paid"], ["overdue", "Fee overdue"], ["promise_passed", "Promise date passed"], ["repeat_not_answering", "Not answering repeatedly"]];
  T.crm.tasksBlock = async (el) => {
    await T.crm.expire();
    const admin = isAdmin(), assign = canAssign();
    let staff = []; if (admin) { try { staff = await T.crm.staff(); } catch (_) {} }
    const callers = callersOf(staff);
    const f = { q: "", cls: "", sec: "", group: "", prio: "", due: "", who: admin ? "all" : "mine" };
    let page = 0, size = 25, total = 0, rows = []; const sel = new Set();
    el.innerHTML = `<h5 class="mb-2">Assigned students <span class="text-muted fs-6" id="tk-n"></span></h5>
      <div class="card mb-2"><div class="card-body filters row g-2">
        <div class="col-12 col-md-3"><input class="form-control" id="tq" placeholder="Search name, father, mobile, ID"></div>
        <div class="col-6 col-md-2"><select class="form-select" id="tcl">${T.classOpts("")}</select></div>
        <div class="col-6 col-md-1"><select class="form-select" id="tsec">${T.opts(["A", "B", "C", "D", "E", "F", "G", "H"], "", "Section")}</select></div>
        <div class="col-6 col-md-2"><select class="form-select" id="tgr">${CALL_GROUPS.map(([k, l]) => `<option value="${k}">${l}</option>`).join("")}</select></div>
        <div class="col-6 col-md-2"><select class="form-select" id="tpr">${T.opts({ low: "Low", normal: "Normal", high: "High", urgent: "Urgent" }, "", "Any priority")}</select></div>
        <div class="col-6 col-md-2"><select class="form-select" id="tdu">${T.opts({ soon: "Deadline in 3 days", overdue: "Deadline passed", nodeadline: "No deadline" }, "", "Any deadline")}</select></div>
        ${admin ? `<div class="col-6 col-md-3"><select class="form-select" id="twho"><option value="all">All teachers</option><option value="mine">Assigned to me</option>${callers.map((u) => `<option value="${u.user_id}">${uname(u)}</option>`).join("")}</select></div>` : ""}
        <div class="col-6 col-md-2"><select class="form-select" id="tsz">${T.opts({ 25: "25 per page", 50: "50 per page", 100: "100 per page", 200: "200 per page" }, 25)}</select></div>
      </div></div>
      ${assign ? `<div id="tbar" class="d-flex flex-wrap align-items-center gap-2 mb-2"></div>` : ""}
      <div class="card"><div id="tlist"></div><div id="tpg"></div></div>`;
    const params = (limit, offset) => ({
      p_session: T.state.session, p_scope: f.who === "mine" ? "mine" : admin ? "tasks" : "mine", p_search: f.q || null, p_class: f.cls || null, p_group: f.group || null,
      p_limit: limit, p_offset: offset, p_section: f.sec || null, p_teacher: admin && f.who !== "all" && f.who !== "mine" ? f.who : null, p_priority: f.prio || null, p_due: f.due || null });
    const bar = () => {
      const b = el.querySelector("#tbar"); if (!b) return;
      b.innerHTML = `<span class="fw-semibold">${sel.size} selected</span>
        <button class="btn btn-sm btn-outline-secondary" id="ball" ${total ? "" : "disabled"}>Select all ${T.num(total)} matching</button>
        <button class="btn btn-sm btn-primary" id="bchg" ${sel.size ? "" : "disabled"}><i class="bi bi-people me-1"></i>Transfer / add / remove teachers</button>
        <button class="btn btn-sm btn-link" id="bclr" ${sel.size ? "" : "disabled"}>Clear selection</button>`;
      b.querySelector("#bclr").onclick = () => { sel.clear(); paint(); };
      b.querySelector("#bchg").onclick = () => T.crm.bulkModal([...sel], staff, () => { sel.clear(); load(); });
      b.querySelector("#ball").onclick = (ev) => T.busy(ev.currentTarget, async () => {
        try {
          for (let off = 0; off < Math.min(total, 1000); off += 200) { const j = await T.rpc("crm_list", params(200, off)); j.rows.forEach((r) => r.task_id && sel.add(r.task_id)); }
          if (total > 1000) T.toast("The first 1000 matching tasks were selected", "warn");
          paint();
        } catch (e) { T.fail(e); }
      });
    };
    const paint = () => {
      const list = el.querySelector("#tlist");
      list.innerHTML = T.crm.rowsTable(rows, { selectTasks: assign, showTeacher: admin, showDeadline: true });
      T.crm.bindRows(list, rows, load);
      list.querySelectorAll(".selt").forEach((c) => { c.checked = sel.has(c.value); c.onchange = () => { c.checked ? sel.add(c.value) : sel.delete(c.value); bar(); syncAll(); }; });
      const syncAll = () => { const a = list.querySelector("#sel-all-t"); if (a) { const boxes = [...list.querySelectorAll(".selt")]; a.checked = boxes.length > 0 && boxes.every((c) => c.checked); } };
      const all = list.querySelector("#sel-all-t"); if (all) all.onchange = () => { list.querySelectorAll(".selt").forEach((c) => { c.checked = all.checked; all.checked ? sel.add(c.value) : sel.delete(c.value); }); bar(); };
      syncAll(); bar();
    };
    const load = async () => {
      const list = el.querySelector("#tlist"); T.loading(list);
      try {
        const j = await T.rpc("crm_list", params(size, page * size));
        rows = j.rows; total = j.total; el.querySelector("#tk-n").textContent = `(${T.num(total)})`;
        paint(); T.pager(el.querySelector("#tpg"), total, page, size, (p) => { page = p; load(); });
      } catch (e) { list.innerHTML = T.errorBox(e); }
    };
    const apply = T.debounce(() => {
      f.q = T.val(el, "#tq"); f.cls = T.val(el, "#tcl"); f.sec = T.val(el, "#tsec"); f.group = T.val(el, "#tgr"); f.prio = T.val(el, "#tpr"); f.due = T.val(el, "#tdu");
      if (admin) f.who = T.val(el, "#twho"); size = Number(T.val(el, "#tsz")) || 25; page = 0; sel.clear(); load();
    }, 300);
    ["#tq", "#tcl", "#tsec", "#tgr", "#tpr", "#tdu", "#twho", "#tsz"].forEach((s) => { const x = el.querySelector(s); if (x) { x.addEventListener("input", apply); x.addEventListener("change", apply); } });
    load();
  };
})();
