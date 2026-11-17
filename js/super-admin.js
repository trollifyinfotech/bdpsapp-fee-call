/* Super Admin console: registrations, schools, subscriptions, platform payments, users. */
(function () {
  const T = window.T, view = document.getElementById("view");
  const badge = (s) => `<span class="badge-s b-${T.esc(s)}">${T.esc(s)}</span>`;
  const rpc = (n, a) => T.rpc(n, a || {}, { mutates: true });

  async function render() {
    view.innerHTML = `<div class="page-h"><div><h1>Platform Console</h1><div class="sub">Manage schools, approvals and subscriptions</div></div></div>
      <div class="row g-3 mb-3" id="stats"></div>
      <ul class="nav nav-tabs mb-3" id="tabs"><li class="nav-item"><button class="nav-link active" data-t="reg">Registrations</button></li><li class="nav-item"><button class="nav-link" data-t="sch">Schools</button></li><li class="nav-item"><button class="nav-link" data-t="usr">Users</button></li></ul>
      <div id="pane"></div>`;
    try {
      const s = await rpc("platform_stats");
      const C = [["building", "p", s.total_schools, "Schools"], ["check-circle", "g", s.active_schools, "Active"], ["hourglass-split", "o", s.pending_schools, "Pending approval"], ["mortarboard", "b", s.total_students, "Students"], ["person-badge", "s", s.total_teachers, "Teachers"], ["receipt", "g", T.inr(s.total_collection), "Total collection"]];
      document.getElementById("stats").innerHTML = C.map(([i, c, v, l]) => `<div class="col-6 col-md-4 col-xl-2">${T.stat(i, c, typeof v === "number" ? T.num(v) : v, l)}</div>`).join("");
    } catch (e) { document.getElementById("stats").innerHTML = `<div class="col-12">${T.errorBox(e)}</div>`; }
    const tabs = { reg: registrations, sch: schools, usr: users };
    document.getElementById("tabs").onclick = (e) => { const b = e.target.closest("[data-t]"); if (!b) return; document.querySelectorAll("#tabs .nav-link").forEach((x) => x.classList.toggle("active", x === b)); tabs[b.dataset.t](document.getElementById("pane")); };
    registrations(document.getElementById("pane"));
  }

  async function registrations(el) {
    el.innerHTML = `<div class="loading">Loading…</div>`;
    const { data, error } = await window.sb.from("school_registration_requests").select("*").order("created_at", { ascending: false });
    if (error) { el.innerHTML = T.errorBox(error); return; }
    if (!data.length) { el.innerHTML = `<div class="card"><div class="empty"><i class="bi bi-inbox"></i>No registration requests yet.</div></div>`; return; }
    el.innerHTML = `<div class="card"><div class="tbl-wrap"><table class="table table-hover mb-0"><thead><tr><th>Submitted</th><th>School</th><th>Code</th><th>Owner</th><th>Contact</th><th>Location</th><th>Status</th><th></th></tr></thead><tbody>${data.map((r) => `<tr>
      <td>${T.dmy(r.created_at)}</td><td class="fw-semibold">${T.esc(r.school_name)}</td><td>${T.esc(r.school_code)}</td><td>${T.esc(r.owner_name)}</td>
      <td>${T.esc(r.mobile)}<br><small class="text-muted">${T.esc(r.email)}</small></td><td>${T.esc([r.city, r.district, r.state].filter(Boolean).join(", "))}</td>
      <td>${badge(r.status)}${r.reject_reason ? `<br><small class="text-muted">${T.esc(r.reject_reason)}</small>` : ""}</td>
      <td class="text-end">${r.status === "pending" ? `<button class="btn btn-sm btn-success" data-ap="${r.id}">Approve</button> <button class="btn btn-sm btn-outline-danger" data-rj="${r.id}">Reject</button>` : ""}</td></tr>`).join("")}</tbody></table></div></div>`;
    el.querySelectorAll("[data-ap]").forEach((b) => (b.onclick = () => approve(b.dataset.ap)));
    el.querySelectorAll("[data-rj]").forEach((b) => (b.onclick = async () => {
      const reason = await T.confirm({ title: "Reject registration", message: "The applicant will not be able to sign in.", reason: true, reasonLabel: "Reason", danger: true, okText: "Reject" });
      if (!reason) return;
      try { await rpc("sa_review_registration", { p_request: b.dataset.rj, p_decision: "reject", p_reason: reason }); T.ok("Registration rejected"); render(); } catch (e) { T.fail(e); }
    }));
  }

  async function approve(id) {
    const { data: plans } = await window.sb.from("subscription_plans").select("*").eq("is_active", true).order("max_students");
    const m = T.modal({ title: "Approve registration", size: "md", scroll: false, body: `<div class="row g-3">${T.field("Plan", `<select class="form-select" id="pl">${(plans || []).map((p) => `<option value="${T.esc(p.code)}">${T.esc(p.name)} (${p.max_students} students / ${p.max_users} users)</option>`).join("")}</select>`, { col: "col-12" })}${T.field("Subscription expires on", `<input type="date" class="form-control" id="ex">`, { col: "col-12", hint: "Leave empty for no expiry" })}</div>`, footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-success" id="ok">Approve &amp; create school</button>` });
    m.el.querySelector("#ok").onclick = (ev) => T.busy(ev.currentTarget, async () => {
      try { await rpc("sa_review_registration", { p_request: id, p_decision: "approve", p_plan: T.val(m.el, "#pl"), p_expires: T.val(m.el, "#ex") || null }); T.ok("School approved. The owner can now sign in."); m.close(); render(); } catch (e) { T.fail(e); }
    });
  }

  async function schools(el) {
    el.innerHTML = `<div class="loading">Loading…</div>`;
    let rows; try { rows = await rpc("sa_school_stats"); } catch (e) { el.innerHTML = T.errorBox(e); return; }
    if (!rows.length) { el.innerHTML = `<div class="card"><div class="empty"><i class="bi bi-building"></i>No schools yet.</div></div>`; return; }
    el.innerHTML = `<div class="card"><div class="tbl-wrap"><table class="table table-hover mb-0"><thead><tr><th>School</th><th>Code</th><th>Status</th><th>Plan</th><th>Expires</th><th class="text-end">Students</th><th class="text-end">Users</th><th class="text-end">Collection</th><th></th></tr></thead><tbody>${rows.map((s) => `<tr>
      <td class="fw-semibold">${T.esc(s.name)}${s.is_demo ? ' <span class="demo-pill">DEMO</span>' : ""}</td><td>${T.esc(s.school_code)}</td><td>${badge(s.status)}</td><td>${T.esc(s.plan_code || "—")}</td><td>${s.expires_on ? T.dmy(s.expires_on) : "—"}</td>
      <td class="text-end">${T.num(s.students)} / ${T.num(s.max_students)}</td><td class="text-end">${T.num(s.users)} / ${T.num(s.max_users)}</td><td class="text-end">${T.inr(s.collection)}</td>
      <td class="text-end text-nowrap"><button class="btn btn-sm btn-outline-primary" data-sub="${s.school_id}">Subscription</button> <button class="btn btn-sm btn-outline-secondary" data-pay="${s.school_id}">Payment</button> <button class="btn btn-sm btn-outline-${s.status === "active" ? "danger" : "success"}" data-st="${s.school_id}" data-to="${s.status === "active" ? "suspended" : "active"}">${s.status === "active" ? "Suspend" : "Activate"}</button></td></tr>`).join("")}</tbody></table></div></div>`;
    const byId = Object.fromEntries(rows.map((s) => [s.school_id, s]));
    el.querySelectorAll("[data-st]").forEach((b) => (b.onclick = async () => {
      const to = b.dataset.to, r = await T.confirm({ title: to === "active" ? "Activate school" : "Suspend school", message: to === "active" ? "Users regain access." : "All users of this school lose access immediately. No data is deleted.", reason: true, danger: to !== "active", okText: to === "active" ? "Activate" : "Suspend" });
      if (!r) return; try { await rpc("sa_set_school_status", { p_school: b.dataset.st, p_status: to, p_reason: r }); T.ok("School status updated"); schools(el); } catch (e) { T.fail(e); }
    }));
    el.querySelectorAll("[data-sub]").forEach((b) => (b.onclick = () => {
      const s = byId[b.dataset.sub];
      const m = T.modal({ title: `Subscription — ${s.name}`, size: "md", scroll: false, body: `<div class="row g-3">${T.field("Plan code", `<input class="form-control" id="pc" value="${T.esc(s.plan_code || "")}">`, { col: "col-12" })}${T.field("Max students", `<input type="number" min="1" class="form-control" id="ms" value="${s.max_students || 1000}">`)}${T.field("Max users", `<input type="number" min="1" class="form-control" id="mu" value="${s.max_users || 25}">`)}${T.field("Expires on", `<input type="date" class="form-control" id="ex" value="${s.expires_on || ""}">`, { col: "col-12" })}</div>`, footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="ok">Save</button>` });
      m.el.querySelector("#ok").onclick = (ev) => T.busy(ev.currentTarget, async () => { try { await rpc("sa_set_subscription", { p_school: s.school_id, p_plan: T.val(m.el, "#pc"), p_max_students: +T.val(m.el, "#ms"), p_max_users: +T.val(m.el, "#mu"), p_expires: T.val(m.el, "#ex") || null }); T.ok("Subscription saved"); m.close(); schools(el); } catch (e) { T.fail(e); } });
    }));
    el.querySelectorAll("[data-pay]").forEach((b) => (b.onclick = () => {
      const s = byId[b.dataset.pay];
      const m = T.modal({ title: `Record subscription payment — ${s.name}`, size: "md", scroll: false, body: `<div class="row g-3">${T.field("Amount (₹)", `<input type="number" min="1" step="0.01" class="form-control" id="am">`)}${T.field("Paid on", `<input type="date" class="form-control" id="dt" value="${new Date().toISOString().slice(0, 10)}">`)}${T.field("Mode", `<select class="form-select" id="md"><option>cash</option><option>upi</option><option>bank</option><option>cheque</option></select>`)}${T.field("Reference", `<input class="form-control" id="rf">`)}${T.field("Note", `<input class="form-control" id="nt">`, { col: "col-12" })}</div>`, footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="ok">Record</button>` });
      m.el.querySelector("#ok").onclick = (ev) => T.busy(ev.currentTarget, async () => { try { const a = +T.val(m.el, "#am"); if (!(a > 0)) throw new Error("Enter a valid amount"); await rpc("sa_record_payment", { p_school: s.school_id, p_amount: a, p_paid_on: T.val(m.el, "#dt") || null, p_mode: T.val(m.el, "#md"), p_reference: T.val(m.el, "#rf"), p_note: T.val(m.el, "#nt") }); T.ok("Payment recorded"); m.close(); } catch (e) { T.fail(e); } });
    }));
  }

  async function users(el) {
    el.innerHTML = `<div class="loading">Loading…</div>`;
    let rows; try { rows = await rpc("sa_list_users"); } catch (e) { el.innerHTML = T.errorBox(e); return; }
    el.innerHTML = `<div class="card"><div class="tbl-wrap"><table class="table table-hover mb-0"><thead><tr><th>Name</th><th>Email</th><th>School</th><th>Role</th><th>Status</th></tr></thead><tbody>${rows.map((u) => `<tr><td>${T.esc(u.full_name)}</td><td>${T.esc(u.email)}</td><td>${T.esc(u.school_name)}</td><td>${T.esc(T.ROLES[u.role_code] || u.role_code)}</td><td>${badge(u.is_active ? "active" : "inactive")}</td></tr>`).join("") || `<tr><td colspan="5" class="text-center text-muted py-4">No users</td></tr>`}</tbody></table></div></div>`;
  }

  (async function () {
    try {
      await T.auth.guard({ superAdminPage: true });
      document.getElementById("logout").onclick = () => T.auth.logout();
      await render();
    } catch (e) { if (e.message !== "redirect") view.innerHTML = T.errorBox(e); }
  })();
})();
