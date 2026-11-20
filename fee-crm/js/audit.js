/* Audit log viewer (read-only). Rows are written by database triggers and are immutable. */
(function () {
  const T = window.T;
  T.pages = T.pages || {};
  T.pages.audit = async (root) => {
    let page = 0; const size = 30;
    const f = { q: "", action: "", from: "", to: "" };
    root.innerHTML = `<div class="page-h"><div><h1>Audit Logs</h1><div class="sub">Append-only history of logins, financial actions, permission changes and more.</div></div></div>
      <div class="card mb-3"><div class="card-body filters row g-2">
        <div class="col-md-3"><input class="form-control" id="aq" placeholder="Action / record type contains…"></div>
        <div class="col-md-3"><select class="form-select" id="aa"><option value="">All actions</option>${["login", "logout", "payments.insert", "payments.update", "transaction_reversals.insert", "students.insert", "students.update", "student_discounts.insert", "student_discounts.update", "fee_structures.insert", "fee_structures.update", "fee_adjustments.insert", "school_memberships.update", "user_permissions.insert", "user_permissions.update", "academic_sessions.insert", "academic_sessions.update", "data_import", "data_export", "family_members.insert", "family_members.update", "calling_tasks.update", "task_assignment_history.insert", "rte_records.insert", "rte_records.update"].map((a) => `<option>${a}</option>`).join("")}</select></div>
        <div class="col-md-2"><input type="date" class="form-control" id="af"></div><div class="col-md-2"><input type="date" class="form-control" id="at"></div>
        <div class="col-md-2"><button class="btn btn-primary w-100" id="ago"><i class="bi bi-search me-1"></i>Filter</button></div></div></div>
      <div class="card"><div id="al"></div><div id="ap"></div></div>`;
    const load = async () => {
      const al = root.querySelector("#al"); T.loading(al);
      try {
        let q = window.sb.from("audit_logs").select("*", { count: "exact" }).order("created_at", { ascending: false }).range(page * size, page * size + size - 1);
        if (f.action) q = q.eq("action", f.action);
        if (f.q) q = q.or(`action.ilike.%${f.q.replace(/[%,()]/g, " ")}%,record_type.ilike.%${f.q.replace(/[%,()]/g, " ")}%`);
        if (f.from) q = q.gte("created_at", f.from + "T00:00:00+05:30");
        if (f.to) q = q.lte("created_at", f.to + "T23:59:59+05:30");
        const { data, count } = await T.q(q);
        const ids = [...new Set(data.map((r) => r.user_id).filter(Boolean))];
        const names = {};
        if (ids.length) (await window.sb.from("user_profiles").select("id,full_name,email").in("id", ids)).data?.forEach((u) => (names[u.id] = u.full_name || u.email));
        al.innerHTML = T.table([
          { label: "When", render: (r) => T.dmyTime(r.created_at), cls: "nowrap" },
          { label: "User", render: (r) => T.esc(names[r.user_id] || (r.user_id ? r.user_id.slice(0, 8) : "system")) },
          { label: "Action", render: (r) => `<code>${T.esc(r.action)}</code>` },
          { label: "Record", render: (r) => T.esc(r.record_type || "") + (r.record_id ? ` <span class="text-muted small">${T.esc(String(r.record_id).slice(0, 8))}…</span>` : "") },
          { label: "Reason", render: (r) => T.esc(r.reason || "—"), cls: "wrap" },
          { label: "Details", render: (r) => `<button class="btn btn-sm btn-outline-secondary" data-id="${r.id}">View</button>` },
        ], data, { empty: "No audit entries match" });
        al.querySelectorAll("button[data-id]").forEach((b) => (b.onclick = () => {
          const r = data.find((x) => String(x.id) === b.dataset.id);
          T.modal({ title: "Audit entry #" + r.id, size: "lg", body: `<div class="row"><div class="col-md-6"><h6>Previous values</h6><pre class="small bg-light p-2 rounded" style="max-height:340px;overflow:auto">${T.esc(JSON.stringify(r.old_values, null, 2) || "—")}</pre></div><div class="col-md-6"><h6>New values</h6><pre class="small bg-light p-2 rounded" style="max-height:340px;overflow:auto">${T.esc(JSON.stringify(r.new_values, null, 2) || "—")}</pre></div></div>` });
        }));
        T.pager(root.querySelector("#ap"), count, page, size, (p) => { page = p; load(); });
      } catch (e) { al.innerHTML = T.errorBox(e); }
    };
    root.querySelector("#ago").onclick = () => { f.q = T.val(root, "#aq"); f.action = T.val(root, "#aa"); f.from = T.val(root, "#af"); f.to = T.val(root, "#at"); page = 0; load(); };
    load();
  };
})();
