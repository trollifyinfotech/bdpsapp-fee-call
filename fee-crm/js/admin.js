/* Administration: users (via secured Edge Function), academic sessions, settings. */
(function () {
  const T = window.T;
  T.pages = T.pages || {};

  /** Create a login with a separate, non-persisting client so the admin stays signed in. */
  T.signUpOther = async (email, password, meta) => {
    const c = window.supabase.createClient(window.TCONFIG.SUPABASE_URL, window.TCONFIG.SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false, storageKey: "trollify-temp-signup" } });
    const { data, error } = await c.auth.signUp({ email, password, options: { data: meta } });
    if (error) throw new Error(/already/i.test(error.message) ? "A user with this email already exists" : error.message);
    if (!data.user || (data.user.identities && data.user.identities.length === 0)) throw new Error("A user with this email already exists");
    return data.user.id;
  };

  /* ---------------- USERS ---------------- */
  T.pages.users = async (root) => {
    if (!T.can("manage_users")) { root.innerHTML = T.errorBox(new Error("You need the “Manage Users” permission.")); return; }
    root.innerHTML = `<div class="page-h"><div><h1>Teachers &amp; Users</h1><div class="sub">Accounts are created only by school admins. There is no public staff registration.</div></div><button class="btn btn-primary" id="us-add"><i class="bi bi-person-plus me-1"></i>Add user</button></div><div class="card"><div id="us"></div></div>`;
    const load = async () => {
      const el = root.querySelector("#us"); T.loading(el);
      try {
        const rows = await T.rpc("list_school_users");
        el.innerHTML = T.table([
          { label: "Name", render: (u) => `<b>${T.esc(u.full_name || "—")}</b>${u.user_id === T.state.user.id ? ' <span class="badge-s b-info">you</span>' : ""}<div class="small text-muted">${T.esc(u.email || "")}</div>` }, { label: "Mobile", render: (u) => T.esc(u.mobile || "—") },
          { label: "Role", render: (u) => (u.user_id === T.state.user.id || u.role_code === "school_owner" ? T.esc(T.ROLES[u.role_code]) : `<select class="form-select form-select-sm role-sel" data-u="${u.user_id}" style="min-width:150px">${T.opts(Object.fromEntries(Object.entries(T.ROLES).filter(([k]) => k !== "school_owner" || T.role() === "school_owner")), u.role_code)}</select>`) },
          { label: "Custom perms", render: (u) => (u.overrides ? T.badge("info", u.overrides + " override(s)") : "—") }, { label: "Status", render: (u) => T.badge(u.is_active ? "active" : "inactive") },
          { label: "", cls: "text-end", render: (u) => (u.user_id === T.state.user.id ? "" : `<div class="btn-group btn-group-sm"><button class="btn btn-outline-secondary" data-pw="${u.user_id}" title="Reset password"><i class="bi bi-key"></i></button><button class="btn btn-outline-${u.is_active ? "danger" : "success"}" data-ac="${u.user_id}" data-on="${u.is_active ? 0 : 1}">${u.is_active ? "Deactivate" : "Activate"}</button></div>`) },
        ], rows);
        el.querySelectorAll(".role-sel").forEach((s) => (s.onchange = async () => { try { await T.rpc("set_member_role", { p_user: s.dataset.u, p_role: s.value }, { mutates: true }); T.ok("Role updated"); load(); } catch (e) { T.fail(e); load(); } }));
        el.querySelectorAll("[data-ac]").forEach((b) => (b.onclick = async () => { const on = b.dataset.on === "1"; if (!on && !(await T.confirm({ title: "Deactivate user", message: "The user is signed out and can no longer access this school. Their history is kept.", danger: true, okText: "Deactivate" }))) return; try { await T.rpc("set_member_active", { p_user: b.dataset.ac, p_active: on }, { mutates: true }); T.ok(on ? "User activated" : "User deactivated"); load(); } catch (e) { T.fail(e); } }));
        el.querySelectorAll("[data-pw]").forEach((b) => (b.onclick = () => {
          const m = T.modal({ title: "Reset password", size: "sm", scroll: false, body: `<label class="form-label">New password</label><input type="text" class="form-control" id="np" autocomplete="off"><div class="form-text">Min 8 characters with letters and numbers. Share it with the user securely; they can change it after signing in.</div>`, footer: `<button class="btn btn-primary" id="pg">Reset</button>` });
          m.el.querySelector("#pg").onclick = (ev) => T.busy(ev.currentTarget, async () => { try { await T.rpc("admin_reset_password", { p_user: b.dataset.pw, p_password: T.val(m.el, "#np") }, { mutates: true }); T.ok("Password reset"); m.close(); } catch (e) { T.fail(e); } });
        }));
      } catch (e) { el.innerHTML = T.errorBox(e); }
    };
    root.querySelector("#us-add").onclick = () => {
      const m = T.modal({ title: "Add user", size: "lg", static: true, body: `<form class="row g-3" id="uf" autocomplete="off">${T.field("Full name", `<input class="form-control" name="full_name">`, { req: true })}${T.field("Email (login)", `<input type="email" class="form-control" name="email">`, { req: true })}${T.field("Mobile", `<input class="form-control" name="mobile" maxlength="10">`)}${T.field("Role", `<select class="form-select" name="role">${T.opts(Object.fromEntries(Object.entries(T.ROLES).filter(([k]) => k !== "school_owner" && (k !== "principal" || T.role() === "school_owner"))), "teacher")}</select>`, { req: true })}${T.field("Designation", `<input class="form-control" name="designation" placeholder="e.g. Class teacher 5">`)}${T.field("Temporary password", `<input type="text" class="form-control" name="password" autocomplete="new-password">`, { req: true, hint: "Min 8 characters with letters and numbers" })}</form><div class="text-danger small mt-2 d-none" id="ue"></div>`, footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="usv">Create user</button>` });
      m.el.querySelector("#usv").onclick = (ev) => T.busy(ev.currentTarget, async () => {
        const f = m.el.querySelector("#uf").elements, ue = m.el.querySelector("#ue");
        try { const pw = f.password.value; if (pw.length < 8 || !/[A-Za-z]/.test(pw) || !/\d/.test(pw)) throw new Error("Password must be at least 8 characters with letters and numbers"); if (!f.full_name.value.trim()) throw new Error("Name is required"); const uid = await T.signUpOther(f.email.value.trim().toLowerCase(), pw, { full_name: f.full_name.value.trim(), mobile: f.mobile.value.trim() }); await T.rpc("admin_attach_user", { p_user: uid, p_full_name: f.full_name.value, p_mobile: f.mobile.value, p_role: f.role.value, p_designation: f.designation.value }, { mutates: true }); T.ok("User created. Share the login details securely."); m.close(); load(); } catch (e) { ue.textContent = T.errMsg(e); ue.classList.remove("d-none"); }
      });
    };
    load();
  };

  /* ---------------- ACADEMIC SESSIONS ---------------- */
  T.pages.sessions = async (root) => {
    if (!T.can("manage_sessions")) { root.innerHTML = T.errorBox(new Error("You need the “Manage Sessions” permission.")); return; }
    root.innerHTML = `<div class="page-h"><div><h1>Academic Sessions</h1><div class="sub">Fee records, receipts and reports never mix across sessions. Switch the session from the top bar to view any year.</div></div><div class="d-flex gap-2 flex-wrap"><button class="btn btn-outline-secondary" id="ss-cmp"><i class="bi bi-bar-chart me-1"></i>Compare</button><button class="btn btn-primary" id="ss-add"><i class="bi bi-plus-lg me-1"></i>New session</button></div></div><div class="card"><div id="ss"></div></div>`;
    const reload = async () => { await T.sessions.load(); T.app?.refreshSessionSelect(); draw(); };
    const draw = () => {
      root.querySelector("#ss").innerHTML = T.table([{ label: "Session", render: (s) => `<b>${T.esc(s.name)}</b>` }, { label: "Start", render: (s) => T.dmy(s.start_date) }, { label: "End", render: (s) => T.dmy(s.end_date) }, { label: "Status", render: (s) => (s.is_active ? T.badge("active", "Active") : "") + " " + T.badge(s.status === "open" ? "pending" : "inactive", T.label(s.status)) },
        { label: "", cls: "text-end", render: (s) => `<div class="btn-group btn-group-sm">${!s.is_active && s.status === "open" ? `<button class="btn btn-outline-success" data-act="${s.id}">Set active</button>` : ""}${s.status === "open" ? `<button class="btn btn-outline-secondary" data-cl="${s.id}">Close</button>` : `<button class="btn btn-outline-secondary" data-ro="${s.id}">Re-open</button>`}${s.status === "open" ? `<button class="btn btn-outline-primary" data-pr="${s.id}">Promote students into…</button>` : ""}</div>` }], T.state.sessions, { empty: "No sessions yet. Create one to begin." });
      const act = (sel, fn, msg, conf) => root.querySelectorAll(sel).forEach((b) => (b.onclick = async () => { if (conf && !(await T.confirm(conf))) return; try { await T.rpc(fn, { p_session: b.dataset[sel.replace(/[\[\]]/g, "").replace("data-", "")] }, { mutates: true }); T.ok(msg); reload(); } catch (e) { T.fail(e); } }));
      act("[data-act]", "set_active_session", "Session activated"); act("[data-ro]", "reopen_session", "Session re-opened");
      act("[data-cl]", "close_session", "Session closed", { title: "Close session", message: "Closed sessions are read-only: no new fees, payments or edits. You can re-open it later.", okText: "Close session" });
      root.querySelectorAll("[data-pr]").forEach((b) => (b.onclick = () => promote(b.dataset.pr)));
    };
    root.querySelector("#ss-add").onclick = () => {
      const y = new Date().getFullYear(), m = T.modal({ title: "New academic session", size: "md", static: true, body: `<div class="row g-3">${T.field("Session name", `<input class="form-control" id="sn" placeholder="${y}-${String(y + 1).slice(2)}">`, { col: "col-12", req: true })}${T.field("Start date", `<input type="date" class="form-control" id="sd" value="${y}-04-01">`, { col: "col-6" })}${T.field("End date", `<input type="date" class="form-control" id="se" value="${y + 1}-03-31">`, { col: "col-6" })}<div class="col-12"><div class="form-check"><input type="checkbox" class="form-check-input" id="sa"><label class="form-check-label" for="sa">Make this the active session</label></div></div></div>`, footer: `<button class="btn btn-primary" id="sv">Create</button>` });
      m.el.querySelector("#sv").onclick = (ev) => T.busy(ev.currentTarget, async () => { try { await T.rpc("create_session", { p_name: T.val(m.el, "#sn"), p_start: T.val(m.el, "#sd"), p_end: T.val(m.el, "#se"), p_make_active: m.el.querySelector("#sa").checked }, { mutates: true }); T.ok("Session created"); m.close(); reload(); } catch (e) { T.fail(e); } });
    };
    root.querySelector("#ss-cmp").onclick = () => {
      if (T.state.sessions.length < 2) return T.toast("Create at least two sessions to compare.", "warn");
      const m = T.modal({ title: "Compare sessions", size: "lg", body: `<div class="row g-2 mb-3"><div class="col-6"><select class="form-select" id="ca">${T.sessionOpts(T.state.sessions[0].id)}</select></div><div class="col-6"><select class="form-select" id="cb">${T.sessionOpts(T.state.sessions[1].id)}</select></div></div><div id="cr"></div>` });
      const go = async () => { const cr = m.el.querySelector("#cr"); T.loading(cr); try { const r = await T.rpc("session_compare", { p_a: T.val(m.el, "#ca"), p_b: T.val(m.el, "#cb") }); cr.innerHTML = T.table([{ label: "Metric", key: "m" }, { label: r[0].session, cls: "text-end money", render: (x) => x.a }, { label: r[1].session, cls: "text-end money", render: (x) => x.b }], [["Students", "students", 1], ["Total fee", "gross"], ["Discount", "discount"], ["Net fee", "net"], ["Collected", "collected"], ["Pending", "pending"]].map(([m2, k, n]) => ({ m: m2, a: n ? T.num(r[0][k]) : T.inr(r[0][k]), b: n ? T.num(r[1][k]) : T.inr(r[1][k]) }))); } catch (e) { cr.innerHTML = T.errorBox(e); } };
      m.el.querySelector("#ca").onchange = go; m.el.querySelector("#cb").onchange = go; go();
    };
    function promote(toId) {
      const others = T.state.sessions.filter((s) => s.id !== toId), to = T.state.sessions.find((s) => s.id === toId);
      if (!others.length) return T.toast("No other session to promote from.", "warn");
      const m = T.modal({ title: `Promote students into ${T.esc(to.name)}`, size: "lg", static: true, body: `<p class="small text-muted">Students keep their permanent ID; a new session enrollment is created in the next class. Old-session payments stay in the old session. Students already in this session are skipped.</p><div class="row g-3">${T.field("Promote from session", `<select class="form-select" id="pf">${T.sessionOpts(others[0].id)}</select>`, { col: "col-md-6" })}<div class="col-md-6 d-flex align-items-end"><div class="form-check"><input type="checkbox" class="form-check-input" id="pa" checked><label for="pa" class="form-check-label">Assign fees from the new session's fee structure</label></div></div></div>
        <hr><h6>Carry forward outstanding dues <span class="badge-s b-high">optional</span></h6><div class="form-check"><input type="checkbox" class="form-check-input" id="cf"><label for="cf" class="form-check-label">I explicitly approve carrying forward unpaid balances of the old session as a “Previous Dues” fee line in the new session</label></div><div id="pe" class="text-danger small mt-2 d-none"></div><div id="pr" class="mt-3"></div>`, footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="pg">Promote</button>` });
      m.el.querySelector("#pg").onclick = (ev) => T.busy(ev.currentTarget, async () => {
        const pe = m.el.querySelector("#pe"); pe.classList.add("d-none"); const from = T.val(m.el, "#pf");
        try {
          const r = await T.rpc("promote_students", { p_from: from, p_to: toId, p_student_ids: null, p_class_overrides: {}, p_assign_fees: m.el.querySelector("#pa").checked }, { mutates: true });
          let extra = ""; if (m.el.querySelector("#cf").checked) { const c = await T.rpc("carry_forward_dues", { p_from: from, p_to: toId, p_student_ids: null }, { mutates: true }); extra = ` · dues carried forward for ${c.carried_students} student(s)`; }
          m.el.querySelector("#pr").innerHTML = `<div class="alert alert-success mb-0">${r.created} student(s) promoted · ${r.skipped_existing} already present · ${r.no_next_class} finished (Class 12)${extra}</div>`;
        } catch (e) { pe.textContent = T.errMsg(e); pe.classList.remove("d-none"); }
      });
    }
    draw();
  };

  /* ---------------- SETTINGS ---------------- */
  T.pages.settings = async (root) => {
    const can = T.can("manage_settings");
    root.innerHTML = `<div class="page-h"><div><h1>Settings</h1><div class="sub">${can ? "" : "Read-only — you need “Manage Settings” to change these."}</div></div></div><div class="row g-3"><div class="col-lg-6" id="s1"></div><div class="col-lg-6" id="s2"></div><div class="col-12" id="s3"></div></div>`;
    let sc, st = {};
    try {
      sc = await T.q(window.sb.from("schools").select("*").eq("id", T.schoolId()).single());
      (await T.q(window.sb.from("school_settings").select("key,value"))).forEach((r) => (st[r.key] = r.value));
    } catch (e) { root.innerHTML = T.errorBox(e); return; }
    const logo = T.logoUrl(sc.logo_path), dis = can ? "" : "disabled";
    root.querySelector("#s1").innerHTML = `<div class="card h-100"><div class="card-header">School profile</div><div class="card-body"><div class="row g-3">
      ${T.field("School name", `<input class="form-control" id="sp-n" value="${T.esc(sc.name)}" ${dis}>`, { col: "col-12" })}${T.field("Phone (printed on receipts)", `<input class="form-control" id="sp-p" value="${T.esc(sc.phone || "")}" ${dis}>`, { col: "col-md-6" })}${T.field("School code", `<input class="form-control" value="${T.esc(sc.school_code)}" disabled>`, { col: "col-md-6" })}${T.field("Address", `<textarea class="form-control" id="sp-a" rows="2" ${dis}>${T.esc(sc.address || "")}</textarea>`, { col: "col-12" })}
      <div class="col-12 d-flex align-items-center gap-3">${logo ? `<img src="${logo}" style="height:56px">` : '<span class="text-muted small">No logo</span>'}${can ? `<input type="file" class="form-control" id="sp-l" accept="image/png,image/jpeg,image/webp">` : ""}</div></div>${can ? `<button class="btn btn-primary mt-3" id="sp-s">Save profile</button>` : ""}</div></div>`;
    const sp = root.querySelector("#sp-s");
    if (sp) sp.onclick = () => T.busy(sp, async () => {
      try {
        let path = sc.logo_path; const f = root.querySelector("#sp-l").files[0];
        if (f) { if (f.size > 2 * 1024 * 1024) throw new Error("Logo must be under 2 MB"); path = `${T.schoolId()}/logo-${Date.now()}.${(f.name.split(".").pop() || "png").toLowerCase()}`; const { error } = await window.sb.storage.from("school-logos").upload(path, f, { contentType: f.type, upsert: false }); if (error) throw new Error(T.errMsg(error)); }
        await T.mutate(window.sb.from("schools").update({ name: T.val(root, "#sp-n"), phone: T.val(root, "#sp-p"), address: T.val(root, "#sp-a"), logo_path: path }).eq("id", T.schoolId()));
        T.ok("Profile saved"); T.app?.refreshBrand(); T.pages.settings(root);
      } catch (e) { T.fail(e); }
    });
    const vr = st.verification_rules || {}, rc = st.receipt || {};
    root.querySelector("#s2").innerHTML = `<div class="card h-100"><div class="card-header">Fee &amp; payment rules</div><div class="card-body"><div class="fw-semibold small mb-1">Payment modes that need approval (principal / authorized approver)</div>${Object.entries(T.MODES).map(([k, l]) => `<div class="form-check form-check-inline"><input type="checkbox" class="form-check-input vr" value="${k}" id="v${k}" ${vr[k] ? "checked" : ""} ${dis}><label class="form-check-label" for="v${k}">${l}</label></div>`).join("")}<div class="form-text mb-3">Pending payments are saved as provisional and are not counted as collection until approved.</div>
      <div class="form-check form-switch mb-3"><input type="checkbox" class="form-check-input" id="adv" ${st.allow_advance_payment === true ? "checked" : ""} ${dis}><label for="adv" class="form-check-label">Allow advance payments (above outstanding balance)</label></div>
      <div class="row g-3">${T.field("Default due days after session start", `<input type="number" min="0" class="form-control" id="ddd" value="${st.default_due_days ?? 30}" ${dis}>`, { col: "col-md-6" })}${T.field("Receipt footer text", `<input class="form-control" id="rf" value="${T.esc(rc.footer || "")}" ${dis}>`, { col: "col-md-6" })}</div>${can ? `<button class="btn btn-primary mt-3" id="fr-s">Save rules</button>` : ""}</div></div>`;
    const fr = root.querySelector("#fr-s");
    if (fr) fr.onclick = () => T.busy(fr, async () => {
      try {
        const rules = {}; Object.keys(T.MODES).forEach((k) => (rules[k] = root.querySelector(`#v${k}`).checked));
        const up = (key, value) => ({ school_id: T.schoolId(), key, value, updated_by: T.state.user.id });
        await T.mutate(window.sb.from("school_settings").upsert([up("verification_rules", rules), up("allow_advance_payment", root.querySelector("#adv").checked), up("default_due_days", Number(T.val(root, "#ddd") || 30)), up("receipt", { ...rc, footer: T.val(root, "#rf") })], { onConflict: "school_id,key" }));
        T.ok("Rules saved");
      } catch (e) { T.fail(e); }
    });
    T.crm.settingsCard(root.querySelector("#s3"));
  };
})();
