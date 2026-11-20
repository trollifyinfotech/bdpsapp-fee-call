/* Permission checks (UI convenience only - the database enforces every rule) + Roles & Permissions page. */
(function () {
  const T = window.T;
  T.can = (code) => !!T.state.access && (T.state.access.permissions || []).includes(code);
  T.canAny = (...codes) => codes.some(T.can);
  T.role = () => T.state.access?.role;

  T.pages = T.pages || {};
  T.pages.permissions = async (root) => {
    root.innerHTML = `<div class="page-h"><div><h1>Roles &amp; Permissions</h1><div class="sub">Predefined roles plus custom per-user grants/denies. Enforced in the database (RLS + RPC checks).</div></div></div><div id="pm"></div>`;
    const pm = root.querySelector("#pm");
    T.loading(pm);
    const [perms, rp, users] = await Promise.all([
      T.q(window.sb.from("permissions").select("*").order("category").order("name")),
      T.q(window.sb.from("role_permissions").select("*")),
      T.rpc("list_school_users"),
    ]);
    const roles = Object.keys(T.ROLES);
    const has = (r, p) => rp.some((x) => x.role_code === r && x.permission_code === p);
    pm.innerHTML = `<ul class="nav nav-tabs mb-3"><li class="nav-item"><a class="nav-link active" data-v="users" href="#">User permissions</a></li><li class="nav-item"><a class="nav-link" data-v="matrix" href="#">Role matrix</a></li></ul><div id="pv"></div>`;
    const pv = pm.querySelector("#pv");
    const matrix = () => {
      let cat = "";
      pv.innerHTML = `<div class="card"><div class="tbl-wrap"><table class="table table-sm table-hover mb-0"><thead><tr><th>Permission</th>${roles.map((r) => `<th class="text-center">${T.ROLES[r]}</th>`).join("")}</tr></thead><tbody>${perms.map((p) => {
        const head = p.category !== cat ? `<tr class="table-light"><td colspan="${roles.length + 1}" class="fw-bold small text-uppercase">${T.esc((cat = p.category))}</td></tr>` : "";
        return head + `<tr><td>${T.esc(p.name)}</td>${roles.map((r) => `<td class="text-center">${has(r, p.code) ? '<i class="bi bi-check-circle-fill text-success"></i>' : '<i class="bi bi-dash text-muted"></i>'}</td>`).join("")}</tr>`;
      }).join("")}</tbody></table></div></div>`;
    };
    const usersView = () => {
      pv.innerHTML = `<div class="card"><div class="card-body"><div class="row g-2 align-items-end"><div class="col-md-5"><label class="form-label small fw-semibold">Select user</label><select class="form-select" id="pu"><option value="">— choose —</option>${users.map((u) => `<option value="${u.user_id}">${T.esc(u.full_name || u.email)} — ${T.esc(T.ROLES[u.role_code] || u.role_code)}${u.is_active ? "" : " (inactive)"}</option>`).join("")}</select></div></div><div id="pe" class="mt-3"></div></div></div>`;
      pv.querySelector("#pu").onchange = async (e) => {
        const uid = e.target.value, pe = pv.querySelector("#pe");
        if (!uid) { pe.innerHTML = ""; return; }
        T.loading(pe);
        try {
          const u = users.find((x) => x.user_id === uid);
          const ov = await T.q(window.sb.from("user_permissions").select("*").eq("user_id", uid));
          const self = uid === T.state.user.id;
          pe.innerHTML = (self ? `<div class="alert alert-warning py-2">You cannot change your own permissions.</div>` : "") +
            `<div class="tbl-wrap"><table class="table table-sm align-middle"><thead><tr><th>Permission</th><th>Role default (${T.esc(T.ROLES[u.role_code] || u.role_code)})</th><th style="width:200px">Override</th><th>Effective</th></tr></thead><tbody>${perms.map((p) => {
              const def = has(u.role_code, p.code), o = ov.find((x) => x.permission_code === p.code);
              const val = o ? (o.granted ? "grant" : "deny") : "";
              const eff = o ? o.granted : def;
              return `<tr><td>${T.esc(p.name)} <span class="text-muted small">(${T.esc(p.category)})</span></td><td>${def ? "Yes" : "No"}</td><td><select class="form-select form-select-sm ov" data-p="${p.code}" ${self ? "disabled" : ""}><option value="">Use role default</option><option value="grant" ${val === "grant" ? "selected" : ""}>Grant</option><option value="deny" ${val === "deny" ? "selected" : ""}>Deny</option></select></td><td>${T.badge(eff ? "active" : "inactive", eff ? "Allowed" : "Denied")}</td></tr>`;
            }).join("")}</tbody></table></div>`;
          pe.querySelectorAll(".ov").forEach((s) => (s.onchange = async () => {
            try {
              await T.rpc("set_user_permission", { p_user: uid, p_perm: s.dataset.p, p_granted: s.value === "" ? null : s.value === "grant" }, { mutates: true });
              T.ok("Permission updated"); document.querySelector("#pu").onchange({ target: { value: uid } });
            } catch (err) { T.fail(err); s.value = ""; }
          }));
        } catch (err) { pe.innerHTML = T.errorBox(err); }
      };
    };
    pm.querySelectorAll(".nav-link").forEach((a) => (a.onclick = (e) => {
      e.preventDefault(); pm.querySelectorAll(".nav-link").forEach((x) => x.classList.toggle("active", x === a));
      a.dataset.v === "matrix" ? matrix() : usersView();
    }));
    usersView();
  };
})();
