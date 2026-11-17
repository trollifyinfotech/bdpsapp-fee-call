/* In-app notification centre (bell + full page). External providers (email/SMS/WhatsApp) are NOT configured:
   the notifications.channel / delivery_status columns exist so they can be added later; nothing external is claimed as sent. */
(function () {
  const T = window.T;
  T.notif = {
    timer: null,
    async count() {
      const { count } = await window.sb.from("notifications").select("id", { count: "exact", head: true }).eq("user_id", T.state.user.id).eq("is_read", false);
      return count || 0;
    },
    async refreshBell() {
      try {
        const c = await T.notif.count();
        const b = document.getElementById("bell-count");
        if (b) { b.textContent = c > 99 ? "99+" : c; b.classList.toggle("d-none", !c); }
      } catch (_) {}
    },
    iconFor: (t) => ({ new_calling_task: "telephone-plus", follow_up_due: "alarm", follow_up_overdue: "alarm-fill", promise_overdue: "exclamation-triangle", fee_payment_received: "cash-coin", online_payment_pending: "hourglass-split", online_payment_approved: "check2-circle", online_payment_rejected: "x-circle", transaction_cancelled: "slash-circle", new_student: "person-plus", task_reassigned: "arrow-left-right", daily_report: "file-earmark-bar-graph", school_approved: "building-check", school_registration: "building-add" }[t] || "bell"),
    async list(limit = 20, offset = 0, unreadOnly = false) {
      let q = window.sb.from("notifications").select("*", { count: "exact" }).eq("user_id", T.state.user.id).order("created_at", { ascending: false }).range(offset, offset + limit - 1);
      if (unreadOnly) q = q.eq("is_read", false);
      return T.q(q);
    },
    item(n) {
      return `<div class="notif-item ${n.is_read ? "" : "unread"}" data-id="${n.id}" data-link="${T.esc(n.link || "")}"><div class="d-flex gap-2"><i class="bi bi-${T.notif.iconFor(n.type)} mt-1 text-primary"></i><div class="flex-grow-1"><div class="fw-semibold small">${T.esc(n.title)}</div><div class="small text-muted">${T.esc(n.body || "")}</div><div class="small text-muted">${T.dmyTime(n.created_at)}</div></div></div></div>`;
    },
    async open(n) {
      if (!n.is_read) { await T.rpc("mark_notifications_read", { p_ids: [n.id] }).catch(() => {}); }
      T.notif.refreshBell();
      if (n.link) { const h = n.link.includes("#") ? n.link.split("#")[1] : ""; if (h) location.hash = h; }
    },
    initBell() {
      const menu = document.getElementById("bell-menu"), btn = document.getElementById("bell-btn");
      if (!btn) return;
      btn.addEventListener("show.bs.dropdown", async () => {
        menu.innerHTML = `<div class="loading">Loading…</div>`;
        try {
          const { data } = await T.notif.list(12);
          menu.innerHTML = `<div class="d-flex justify-content-between align-items-center px-3 py-2 border-bottom"><b>Notifications</b><a href="#" id="mark-all" class="small">Mark all read</a></div>` + (data.length ? data.map(T.notif.item).join("") : T.empty("No notifications", "bell")) + `<div class="text-center p-2"><a href="#/notifications">View all</a></div>`;
          menu.querySelectorAll(".notif-item").forEach((el) => (el.onclick = () => T.notif.open(data.find((x) => x.id === el.dataset.id))));
          menu.querySelector("#mark-all").onclick = async (e) => { e.preventDefault(); await T.rpc("mark_notifications_read", {}); T.notif.refreshBell(); menu.querySelectorAll(".unread").forEach((x) => x.classList.remove("unread")); };
        } catch (e) { menu.innerHTML = T.errorBox(e); }
      });
      T.notif.refreshBell();
      clearInterval(T.notif.timer);
      T.notif.timer = setInterval(T.notif.refreshBell, 60000);
    },
  };
  T.pages = T.pages || {};
  T.pages.notifications = async (root) => {
    let page = 0, unread = false; const size = 20;
    root.innerHTML = `<div class="page-h"><div><h1>Notifications</h1></div><div class="d-flex gap-2"><div class="form-check form-switch pt-1"><input class="form-check-input" type="checkbox" id="nu"><label class="form-check-label" for="nu">Unread only</label></div><button class="btn btn-outline-primary btn-sm" id="nall">Mark all read</button></div></div><div class="card"><div id="nl"></div><div id="np"></div></div>`;
    const load = async () => {
      const nl = root.querySelector("#nl"); T.loading(nl);
      try {
        const { data, count } = await T.notif.list(size, page * size, unread);
        nl.innerHTML = data.length ? data.map(T.notif.item).join("") : T.empty("No notifications", "bell");
        nl.querySelectorAll(".notif-item").forEach((el) => (el.onclick = () => T.notif.open(data.find((x) => x.id === el.dataset.id))));
        T.pager(root.querySelector("#np"), count, page, size, (p) => { page = p; load(); });
      } catch (e) { nl.innerHTML = T.errorBox(e); }
    };
    root.querySelector("#nu").onchange = (e) => { unread = e.target.checked; page = 0; load(); };
    root.querySelector("#nall").onclick = async () => { try { await T.rpc("mark_notifications_read", {}); T.notif.refreshBell(); load(); } catch (e) { T.fail(e); } };
    load();
  };
})();
