/* App shell: permission-aware navigation, hash router, session switcher, home dashboard. */
(function () {
  const T = window.T;
  T.pages = T.pages || {};

  const NAV = [
    { sec: "MAIN", items: [
      { id: "dashboard", label: "Dashboard", icon: "speedometer2", href: "#/dashboard" },
      { id: "students", label: "Students", icon: "mortarboard", href: "#/students", perm: "view_student_list" },
      { id: "families", label: "Families", icon: "people", href: "#/families", perm: "view_student_list" } ] },
    { sec: "FEE MANAGEMENT", items: [
      { id: "fees", label: "Fee Dashboard", icon: "graph-up-arrow", href: "#/fees", perm: "view_fee_details" },
      { id: "fee-structure", label: "Fee Structure", icon: "diagram-2", href: "#/fee-structure", perm: "view_fee_amounts" },
      { id: "collect", label: "Fee Collection", icon: "cash-coin", href: "#/collect", perm: "collect_fee" },
      { id: "transactions", label: "Transactions", icon: "arrow-left-right", href: "#/transactions", perm: "view_fee_amounts" },
      { id: "receipts", label: "Receipts", icon: "receipt", href: "#/receipts", perm: "view_fee_amounts" },
      { id: "discounts", label: "Discounts & Waivers", icon: "percent", href: "#/discounts", perm: "view_fee_amounts" },
      { id: "rte", label: "RTE & Scholarships", icon: "award", href: "#/rte", perm: "manage_rte" } ] },
    { sec: "CALLING CRM", items: [
      { id: "crm", label: "Calling Dashboard", icon: "telephone", href: "#/crm", perm: "view_calling_crm" },
      { id: "crm/pending", label: "Pending Fee Calls", icon: "telephone-outbound", href: "#/crm/pending", perm: "view_calling_crm" },
      { id: "crm/today", label: "Today's Tasks", icon: "list-check", href: "#/crm/today", perm: "view_calling_crm" },
      { id: "crm/followups", label: "Follow-ups", icon: "calendar-event", href: "#/crm/followups", perm: "view_calling_crm" },
      { id: "crm/overdue", label: "Overdue Follow-ups", icon: "alarm", href: "#/crm/overdue", perm: "view_calling_crm" },
      { id: "crm/history", label: "Call History", icon: "clock-history", href: "#/crm/history", perm: "view_calling_crm" },
      { id: "crm/teachers", label: "Teacher Performance", icon: "trophy", href: "#/crm/teachers", perm: "view_calling_crm" },
      { id: "crm/assign", label: "Task Assignment", icon: "person-check", href: "#/crm/assign", perm: "assign_calling_tasks" },
      { id: "crm/reports", label: "Calling Reports", icon: "file-earmark-bar-graph", href: "#/crm/reports", perm: "view_teacher_performance" } ] },
    { sec: "ADMINISTRATION", items: [
      { id: "users", label: "Teachers & Users", icon: "person-gear", href: "#/users", perm: "manage_users" },
      { id: "permissions", label: "Roles & Permissions", icon: "shield-lock", href: "#/permissions", perm: "manage_permissions" },
      { id: "sessions", label: "Academic Sessions", icon: "calendar3", href: "#/sessions", perm: "manage_sessions" },
      { id: "reports", label: "Reports", icon: "bar-chart-line", href: "#/reports", any: ["view_fee_reports", "view_calling_crm"] },
      { id: "notifications", label: "Notifications", icon: "bell", href: "#/notifications" },
      { id: "audit", label: "Audit Logs", icon: "journal-text", href: "#/audit", perm: "view_audit_logs" },
      { id: "settings", label: "Settings", icon: "gear", href: "#/settings" } ] },
  ];
  const NO_SESSION_OK = ["dashboard", "users", "permissions", "sessions", "notifications", "audit", "settings"];
  const allowed = (i) => (!i.perm || T.can(i.perm)) && (!i.any || T.canAny(...i.any));

  function resolve() {
    const raw = location.hash.replace(/^#\/?/, ""); const [path, qs] = raw.split("?");
    const parts = path.split("/").filter(Boolean); const query = Object.fromEntries(new URLSearchParams(qs || ""));
    let key = parts.join("/") || "dashboard", params = [];
    if (parts[0] === "students" && parts.length === 2 && parts[1] !== "import") { key = "students/profile"; params = [parts[1]]; }
    return { key, params, query };
  }

  function drawNav(active) {
    document.getElementById("nav").innerHTML = NAV.map((s) => {
      const items = s.items.filter(allowed); if (!items.length) return "";
      return `<div class="sec">${s.sec}</div>` + items.map((i) => `<a class="nav-i ${i.id === active ? "active" : ""}" href="${i.href}"><i class="bi bi-${i.icon}"></i><span>${i.label}</span></a>`).join("");
    }).join("");
  }

  T.app = {
    refreshSessionSelect() {
      const sel = document.getElementById("sess-sel"); if (!sel) return;
      sel.innerHTML = T.state.sessions.length ? T.sessionOpts(T.state.session) : `<option value="">No session</option>`;
    },
    refreshBrand() {
      const s = T.state.access.school || {}, logo = T.logoUrl(s.logo_path);
      document.getElementById("brand").innerHTML = `${logo ? `<img src="${logo}" style="height:30px;max-width:44px;object-fit:contain">` : '<i class="bi bi-mortarboard-fill"></i>'}<span class="d-none d-sm-inline text-truncate" style="max-width:240px">${T.esc(s.name || "Trollify")}</span>${s.is_demo ? '<span class="demo-pill">DEMO</span>' : ""}`;
    },
    async render() {
      const view = document.getElementById("view"), r = resolve();
      const navId = r.key === "students/profile" || r.key === "students/import" ? "students" : r.key === "reports/owner" ? "reports" : r.key;
      drawNav(navId); document.getElementById("side").classList.remove("open");
      const page = T.pages[r.key];
      view.innerHTML = ""; window.scrollTo(0, 0);
      if (!page) { view.innerHTML = `<div class="card"><div class="empty"><i class="bi bi-compass"></i>Page not found. <a href="#/dashboard">Go to dashboard</a></div></div>`; return; }
      if (!T.state.session && !NO_SESSION_OK.includes(r.key)) {
        view.innerHTML = `<div class="card"><div class="empty"><i class="bi bi-calendar-x"></i>No academic session exists yet. ${T.can("manage_sessions") ? `<a href="#/sessions">Create the first session</a> to begin.` : "Ask your administrator to create one."}</div></div>`; return;
      }
      try { await page(view, { params: r.params, query: r.query }); } catch (e) { console.error(e); view.innerHTML = T.errorBox(e); }
    },
    async start() {
      const access = await T.auth.guard();
      T.state.access = access;
      await T.sessions.load().catch((e) => T.fail(e));
      T.app.refreshBrand(); T.app.refreshSessionSelect();
      document.getElementById("u-name").textContent = T.state.user.user_metadata?.full_name || T.state.user.email;
      document.getElementById("u-role").textContent = T.ROLES[access.role] || access.role;
      document.getElementById("sess-sel").onchange = (e) => { T.sessions.set(e.target.value); T.app.render(); };
      document.getElementById("menu-btn").onclick = () => document.getElementById("side").classList.toggle("open");
      document.getElementById("logout").onclick = (e) => { e.preventDefault(); T.auth.logout(); };
      T.notif.initBell();
      window.sb.rpc("run_my_reminders").then(() => T.notif.refresh && T.notif.refresh(), () => {}); // throttled, idempotent; no external scheduler needed
      window.addEventListener("hashchange", T.app.render);
      if (!location.hash) location.hash = "#/dashboard"; else T.app.render();
    },
  };

  /* ---------------- Home dashboard ---------------- */
  T.pages.dashboard = async (root) => {
    const fin = T.canAny("view_financial_dashboard"), crm = T.can("view_calling_crm");
    if (!fin && crm && !T.canAny("assign_calling_tasks", "view_teacher_performance")) return T.crm.myDashboard(root);
    root.innerHTML = `<div class="page-h"><div><h1>Dashboard</h1><div class="sub">${T.esc(T.state.access.school?.name || "")} · Session <b>${T.esc(T.sessions.current()?.name || "—")}</b></div></div></div><div id="h1" class="row g-3 mb-3"></div><div id="h2" class="row g-3 mb-3"></div><div id="h3" class="row g-3"></div>`;
    if (!T.state.sessions.length) { root.querySelector("#h1").innerHTML = `<div class="col-12"><div class="alert alert-info"><b>Welcome!</b> Start by creating your first academic session${T.can("manage_sessions") ? ` — <a href="#/sessions">Academic Sessions</a>` : ""}, then set up the fee structure and add students.</div></div>`; return; }
    if (fin) {
      try {
        const s = await T.rpc("fee_summary", { p_session: T.state.session });
        const C = [["people", "p", T.num(s.total_students), "Students"], ["cash-stack", "g", T.inr(s.collected), "Total collected"], ["hourglass-split", "r", T.inr(s.pending), "Total pending"], ["calendar-day", "g", T.inr(s.today_collection), "Today's collection"], ["calendar-month", "p", T.inr(s.month_collection), "This month"], ["person-x", "r", T.num(s.unpaid_students), "Unpaid students"]];
        root.querySelector("#h1").innerHTML = C.map(([i, c, v, l]) => `<div class="col-6 col-md-4 col-xl-2">${T.stat(i, c, v, l)}</div>`).join("");
        root.querySelector("#h2").innerHTML = `<div class="col-lg-6">${T.chartCard("Monthly collection", "d1")}</div><div class="col-lg-6">${T.chartCard("Paid vs pending", "d2")}</div>`;
        T.chart(root.querySelector("#d1"), { type: "bar", data: { labels: s.charts.monthly.map((x) => x.label), datasets: [{ label: "₹", data: s.charts.monthly.map((x) => x.amount), backgroundColor: T.PALETTE[0] }] } });
        T.chart(root.querySelector("#d2"), { type: "doughnut", data: { labels: ["Collected", "Pending"], datasets: [{ data: [s.collected, s.pending], backgroundColor: [T.PALETTE[1], T.PALETTE[4]] }] } });
      } catch (e) { root.querySelector("#h1").innerHTML = `<div class="col-12">${T.errorBox(e)}</div>`; }
    }
    if (crm) {
      try {
        const d = await T.rpc("crm_dashboard", { p_session: T.state.session });
        const C = [["telephone-outbound", "g", d.calls_today, "Calls today"], ["list-task", "b", d.pending_tasks, "Pending calling tasks"], ["alarm", "o", d.followups_today, "Follow-ups due today"], ["alarm-fill", "r", d.followups_overdue, "Follow-ups overdue"], ["exclamation-triangle", "r", d.promised_overdue, "Promises overdue"]];
        root.querySelector("#h3").innerHTML = `<div class="col-12"><h6 class="text-muted text-uppercase small mb-0">Fee recovery (Calling CRM)</h6></div>` + C.map(([i, c, v, l]) => `<div class="col-6 col-md-4 col-xl-2">${T.stat(i, c, T.num(v), l)}</div>`).join("") + `<div class="col-6 col-md-4 col-xl-2 d-flex"><a class="btn btn-outline-primary w-100 align-self-center" href="#/crm">Open CRM →</a></div>`;
      } catch (_) {}
    }
    if (!fin && !crm) root.querySelector("#h1").innerHTML = `<div class="col-12"><div class="card"><div class="card-body">Use the menu to open the sections available to your role.</div></div></div>`;
  };
})();
