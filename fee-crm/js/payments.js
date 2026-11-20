/* Fee collection form, transactions register, approvals and cancellations. */
(function () {
  const T = window.T;
  T.pages = T.pages || {};

  T.payments = {
    async collect(enrollmentId, done) {
      let en, bal, lines, allocs, prior, rules, advOK = false;
      try {
        [en, bal, lines, allocs, prior] = await Promise.all([
          T.q(window.sb.from("student_session_enrollments").select("id,class_name,section,session_id,academic_sessions(name,status),students(id,name,father_name,admission_no,student_code,mobile)").eq("id", enrollmentId).single()),
          T.q(window.sb.from("v_enrollment_balances").select("*").eq("enrollment_id", enrollmentId).single()),
          T.q(window.sb.from("student_fee_assignments").select("id,amount,fee_heads(name),fee_installments(due_date,amount,installment_no)").eq("enrollment_id", enrollmentId).eq("status", "active")),
          T.q(window.sb.from("payment_allocations").select("assignment_id,amount,payments!inner(status,enrollment_id)").eq("payments.enrollment_id", enrollmentId).in("payments.status", ["verified", "pending"])),
          T.q(window.sb.from("payments").select("receipt_no,amount,payment_date,mode,status").eq("enrollment_id", enrollmentId).order("created_at", { ascending: false }).limit(5)),
        ]);
        const st = await T.q(window.sb.from("school_settings").select("key,value").in("key", ["verification_rules", "allow_advance_payment"]));
        rules = (st.find((x) => x.key === "verification_rules") || {}).value || {};
        advOK = (st.find((x) => x.key === "allow_advance_payment") || {}).value === true;
      } catch (e) { return T.fail(e); }
      if (en.academic_sessions.status !== "open") return T.toast(`Session ${en.academic_sessions.name} is closed. Re-open it to collect fees.`, "warn");
      const paidBy = {}; allocs.forEach((a) => { if (a.assignment_id) paidBy[a.assignment_id] = (paidBy[a.assignment_id] || 0) + Number(a.amount); });
      const open = lines.map((l) => ({ id: l.id, head: l.fee_heads?.name, remaining: Math.max(Number(l.amount) - (paidBy[l.id] || 0), 0), due: (l.fee_installments || []).map((i) => i.due_date).sort()[0] })).filter((l) => l.remaining > 0);
      const payable = Math.max(Number(bal.pending) - Number(bal.awaiting_verification), 0);
      const s = en.students, idem = T.uuid();
      const m = T.modal({
        title: `<i class="bi bi-cash-coin me-2"></i>Collect fee`, size: "xl", static: true,
        body: `<div class="row g-3"><div class="col-lg-5">
          <div class="card"><div class="card-body"><div class="fw-bold fs-6">${T.esc(s.name)}</div><div class="text-muted small">${T.esc(s.student_code)} · Adm ${T.esc(s.admission_no)}<br>Father: ${T.esc(s.father_name || "—")} · ${T.esc(en.class_name)}${en.section ? "-" + T.esc(en.section) : ""}<br>Session: <b>${T.esc(en.academic_sessions.name)}</b></div>
            <hr class="my-2"><table class="table table-sm mb-0"><tr><td>Total fee</td><td class="text-end money">${T.inr(bal.gross)}</td></tr><tr><td>Discount</td><td class="text-end money">− ${T.inr(bal.discount)}</td></tr><tr><td><b>Net fee</b></td><td class="text-end money"><b>${T.inr(bal.net)}</b></td></tr><tr><td>Previous payments</td><td class="text-end money">${T.inr(bal.paid)}</td></tr>${Number(bal.awaiting_verification) ? `<tr class="table-warning"><td>Awaiting approval</td><td class="text-end money">${T.inr(bal.awaiting_verification)}</td></tr>` : ""}<tr class="table-light"><td><b>Outstanding</b></td><td class="text-end money fs-6"><b>${T.inr(bal.pending)}</b></td></tr></table></div></div>
          ${open.length ? `<div class="card mt-3"><div class="card-header small">Fee heads outstanding</div><table class="table table-sm mb-0">${open.map((o) => `<tr><td>${T.esc(o.head)}<div class="small text-muted">due ${T.dmy(o.due)}</div></td><td class="text-end money">${T.inr(o.remaining)}</td></tr>`).join("")}</table></div>` : ""}
          ${prior.length ? `<div class="card mt-3"><div class="card-header small">Recent payments</div><table class="table table-sm mb-0">${prior.map((p) => `<tr><td>${T.dmy(p.payment_date)}<div class="small text-muted">${T.esc(p.receipt_no)}</div></td><td class="text-end money">${T.inr(p.amount)}<div>${T.badge(p.status)}</div></td></tr>`).join("")}</table></div>` : ""}</div>
          <div class="col-lg-7">${payable <= 0 && !advOK ? `<div class="alert alert-success"><i class="bi bi-check-circle me-1"></i>No outstanding balance for this student in this session.</div>` : ""}
          <form id="pf" class="row g-3" novalidate>
            ${T.field("Fee head", `<select class="form-select" name="head"><option value="">Auto — oldest due first</option>${open.map((o) => `<option value="${o.id}">${T.esc(o.head)} (max ${T.inr(o.remaining)})</option>`).join("")}</select>`, { hint: "Optional: apply the payment to one fee head" })}
            ${T.field("Payment amount (₹)", `<input type="number" step="0.01" min="0.01" max="${advOK ? "" : payable}" class="form-control form-control-lg" name="amount" value="${payable || ""}" required>`, { req: true, hint: `Maximum ${T.inr(payable)}` })}
            ${T.field("Payment date", `<input type="date" class="form-control" name="date" value="${T.today()}" max="${T.today()}" required>`, { col: "col-md-4", req: true })}
            ${T.field("Payment mode", `<select class="form-select" name="mode">${T.opts(T.MODES, "cash")}</select>`, { col: "col-md-4", req: true })}
            ${T.field("Hard copy receipt no", `<input class="form-control" name="hard">`, { col: "col-md-4" })}
            ${T.field("Transaction reference", `<input class="form-control" name="ref" placeholder="UPI ref / cheque no / UTR">`, { col: "col-md-6" })}
            ${T.field("Receipt attachment", `<input type="file" class="form-control" name="file" accept="image/png,image/jpeg,application/pdf">`, { col: "col-md-6" })}
            ${T.field("Remarks", `<input class="form-control" name="remarks">`, { col: "col-12" })}
            ${advOK ? `<div class="col-12"><div class="form-check"><input type="checkbox" class="form-check-input" name="adv" id="adv"><label for="adv" class="form-check-label">Allow amount above outstanding to be recorded as advance credit</label></div></div>` : ""}
            <div class="col-12"><div class="alert alert-info py-2 mb-0 small d-none" id="pf-note"></div><div class="text-danger small d-none" id="pf-err"></div></div></form></div></div>`,
        footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-success btn-lg" id="pf-save"><i class="bi bi-check2-circle me-1"></i>Save payment</button>`,
      });
      const fm = m.el.querySelector("#pf"), err = m.el.querySelector("#pf-err"), note = m.el.querySelector("#pf-note");
      const upd = () => { const need = rules[fm.elements.mode.value] === true && !T.can("approve_payment"); note.classList.toggle("d-none", !need); note.textContent = need ? "This payment mode needs approval. It will be saved as PENDING (provisional) and is not counted as collection until approved." : ""; };
      fm.elements.mode.onchange = upd; upd();
      m.el.querySelector("#pf-save").onclick = (ev) => T.busy(ev.currentTarget, async () => {
        err.classList.add("d-none");
        const amount = Number(fm.elements.amount.value);
        const bad = (t) => { err.textContent = t; err.classList.remove("d-none"); };
        if (!(amount > 0)) return bad("Enter a payment amount greater than zero.");
        if (Math.round(amount * 100) !== amount * 100) return bad("Amount can have at most 2 decimals.");
        const headId = fm.elements.head.value, adv = !!fm.elements.adv?.checked;
        const target = headId ? open.find((o) => o.id === headId).remaining : payable;
        if (amount > target && !adv) return bad(`Amount exceeds the ${headId ? "selected fee head balance" : "outstanding balance"} of ${T.inr(target)}.`);
        try {
          let att = null; const file = fm.elements.file.files[0];
          if (file) { if (file.size > 5 * 1024 * 1024) return bad("Attachment must be under 5 MB."); att = await T.upload("receipt-attachments", file, enrollmentId); }
          const r = await T.rpc("collect_payment", {
            p_enrollment: enrollmentId, p_amount: amount, p_date: fm.elements.date.value, p_mode: fm.elements.mode.value,
            p_reference: fm.elements.ref.value.trim() || null, p_hard_receipt: fm.elements.hard.value.trim() || null, p_remarks: fm.elements.remarks.value.trim() || null,
            p_idempotency_key: idem, p_attachment: att, p_allocations: headId && !adv ? [{ assignment_id: headId, amount }] : null, p_allow_advance: adv,
          }, { mutates: true });
          m.close();
          T.ok(r.status === "pending" ? `Saved as pending approval (provisional receipt ${r.receipt_no})` : `Payment saved. Receipt ${r.receipt_no}`);
          done && done(r);
          if (T.can("print_receipt")) T.receipts.show(r.payment_id);
        } catch (e) { bad(T.errMsg(e)); }
      });
    },
  };

  /* ---------- Fee Collection page ---------- */
  T.pages.collect = async (root) => {
    root.innerHTML = `<div class="page-h"><div><h1>Fee Collection</h1><div class="sub">Session: <b>${T.esc(T.sessions.current()?.name || "—")}</b></div></div></div>
      <div class="card mb-3"><div class="card-body"><label class="form-label fw-semibold">Find student</label><div id="cp"></div><div class="form-text">Type at least 2 letters of name, father name, admission no or mobile.</div></div></div>
      <div class="card"><div class="card-header">Today's collection</div><div id="cl"></div></div>`;
    T.studentPicker(root.querySelector("#cp"), (s) => T.payments.collect(s.enrollment_id, loadToday));
    const loadToday = async () => {
      const cl = root.querySelector("#cl"); T.loading(cl);
      try {
        const j = await T.rpc("payments_list", { p_session: T.state.session, p_from: T.today(), p_to: T.today(), p_limit: 50, p_offset: 0 });
        cl.innerHTML = `<div class="px-3 pt-2 small text-muted">Verified: <b>${T.inr(j.totals.verified)}</b> · Pending approval: <b>${T.inr(j.totals.pending)}</b></div>` + T.table([{ label: "Receipt", key: "receipt_no" }, { label: "Student", key: "student_name" }, { label: "Class", key: "class_name" }, { label: "Mode", render: (p) => T.esc(T.MODES[p.mode]) }, { label: "Amount", cls: "text-end money", render: (p) => T.inr(p.amount) }, { label: "Status", render: (p) => T.badge(p.status) }, { label: "By", key: "collector_name" }], j.rows, { empty: "No payments recorded today" });
      } catch (e) { cl.innerHTML = T.errorBox(e); }
    };
    loadToday();
  };

  /* ---------- Transactions page ---------- */
  T.pages.transactions = async (root) => {
    if (!T.can("view_fee_amounts")) { root.innerHTML = T.errorBox(new Error("You need the “View Fee Amounts” permission to see transactions.")); return; }
    const f = { from: "", to: "", mode: "", status: "", q: "", collector: "" }; let page = 0; const size = 25;
    let collectors = []; try { collectors = (await T.rpc("list_school_users")).filter((u) => T.can("collect_fee") || true); } catch (_) {}
    root.innerHTML = `<div class="page-h"><div><h1>Transactions</h1><div class="sub">Append-only ledger. Cancelled and rejected entries are never deleted.</div></div>${T.can("export_csv") ? `<button class="btn btn-outline-secondary" id="tx-exp"><i class="bi bi-download me-1"></i>Export CSV</button>` : ""}</div>
      <div class="card mb-3"><div class="card-body filters row g-2"><div class="col-md-3"><input id="tq" class="form-control" placeholder="Receipt, txn id, student, father"></div>
      <div class="col-6 col-md-2"><input type="date" id="tf" class="form-control"></div><div class="col-6 col-md-2"><input type="date" id="tt" class="form-control"></div>
      <div class="col-6 col-md-1"><select id="tm" class="form-select">${T.opts(T.MODES, "", "Mode")}</select></div>
      <div class="col-6 col-md-2"><select id="ts" class="form-select">${T.opts({ verified: "Verified", pending: "Pending", rejected: "Rejected", cancelled: "Cancelled" }, "", "All status")}</select></div>
      <div class="col-md-2"><select id="tc" class="form-select"><option value="">All collectors</option>${collectors.map((u) => `<option value="${u.user_id}">${T.esc(u.full_name || u.email)}</option>`).join("")}</select></div></div></div>
      <div id="tx-tot" class="row g-3 mb-3"></div><div class="card"><div id="tx"></div><div id="txp"></div></div>`;
    const args = (x = {}) => ({ p_session: T.state.session, p_from: f.from || null, p_to: f.to || null, p_mode: f.mode || null, p_status: f.status || null, p_collector: f.collector || null, p_search: f.q || null, ...x });
    const load = async () => {
      const el = root.querySelector("#tx"); T.loading(el);
      try {
        const j = await T.rpc("payments_list", args({ p_limit: size, p_offset: page * size }));
        root.querySelector("#tx-tot").innerHTML = [["check2-circle", "g", j.totals.verified, "Verified collection"], ["hourglass-split", "y", j.totals.pending, "Pending approval (not counted)"], ["slash-circle", "r", j.totals.cancelled, "Cancelled"], ["x-circle", "s", j.totals.rejected, "Rejected"]].map(([i, c, v, l]) => `<div class="col-6 col-lg-3">${T.stat(i, c, T.inr(v), l)}</div>`).join("");
        el.innerHTML = T.table([
          { label: "Date", render: (p) => T.dmy(p.payment_date) }, { label: "Receipt / Txn", render: (p) => `<b>${T.esc(p.receipt_no)}</b><div class="small text-muted">${T.esc(p.txn_id)}</div>` },
          { label: "Student", render: (p) => `<a href="#/students/${p.student_id}">${T.esc(p.student_name)}</a><div class="small text-muted">${T.esc(p.class_name)} · ${T.esc(p.father_name || "")}</div>` },
          { label: "Mode", render: (p) => T.esc(T.MODES[p.mode]) + (p.reference ? `<div class="small text-muted">${T.esc(p.reference)}</div>` : "") },
          { label: "Amount", cls: "text-end money", render: (p) => T.inr(p.amount) }, { label: "Status", render: (p) => T.badge(p.status) + (p.cancel_reason ? `<div class="small text-danger wrap" title="${T.esc(p.cancel_reason)}">${T.esc(p.cancel_reason).slice(0, 40)}</div>` : p.review_reason && p.status === "rejected" ? `<div class="small text-danger">${T.esc(p.review_reason)}</div>` : "") },
          { label: "Collected by", key: "collector_name" },
          { label: "", cls: "text-end", render: (p) => `<div class="btn-group btn-group-sm">${T.can("print_receipt") && p.status !== "rejected" ? `<button class="btn btn-outline-primary" data-rc="${p.payment_id}" title="Receipt"><i class="bi bi-receipt"></i></button>` : ""}${p.status === "pending" && T.can("approve_payment") ? `<button class="btn btn-outline-success" data-ap="${p.payment_id}" title="Approve"><i class="bi bi-check2"></i></button><button class="btn btn-outline-danger" data-rj="${p.payment_id}" title="Reject"><i class="bi bi-x"></i></button>` : ""}${p.status === "verified" && T.can("cancel_receipt") ? `<button class="btn btn-outline-danger" data-cn="${p.payment_id}" title="Cancel (reversal)"><i class="bi bi-slash-circle"></i></button>` : ""}</div>` },
        ], j.rows, { empty: "No transactions found" });
        T.pager(root.querySelector("#txp"), j.total, page, size, (p) => { page = p; load(); });
        el.querySelectorAll("[data-rc]").forEach((b) => (b.onclick = () => T.receipts.show(b.dataset.rc)));
        el.querySelectorAll("[data-ap]").forEach((b) => (b.onclick = async () => { if (!(await T.confirm({ title: "Approve payment", message: "Approving moves this payment into the verified ledger and issues the receipt." , okText: "Approve" }))) return; try { await T.rpc("review_payment", { p_payment: b.dataset.ap, p_approve: true }, { mutates: true }); T.ok("Payment approved"); load(); } catch (e) { T.fail(e); } }));
        el.querySelectorAll("[data-rj]").forEach((b) => (b.onclick = async () => { const r = await T.confirm({ title: "Reject payment", message: "The attempt is kept in the ledger with your reason.", reason: true, danger: true, okText: "Reject" }); if (!r) return; try { await T.rpc("review_payment", { p_payment: b.dataset.rj, p_approve: false, p_reason: r }, { mutates: true }); T.ok("Payment rejected"); load(); } catch (e) { T.fail(e); } }));
        el.querySelectorAll("[data-cn]").forEach((b) => (b.onclick = async () => { const r = await T.confirm({ title: "Cancel transaction", message: "A reversal record is created, the original transaction is preserved, the student balance is recalculated and Admin is notified.", reason: true, reasonLabel: "Cancellation reason (min 5 characters)", minLen: 5, danger: true, okText: "Cancel transaction" }); if (!r) return; try { await T.rpc("cancel_payment", { p_payment: b.dataset.cn, p_reason: r }, { mutates: true }); T.ok("Transaction cancelled and reversed"); load(); } catch (e) { T.fail(e); } }));
      } catch (e) { el.innerHTML = T.errorBox(e); }
    };
    const apply = T.debounce(() => { f.q = T.val(root, "#tq"); f.from = T.val(root, "#tf"); f.to = T.val(root, "#tt"); f.mode = T.val(root, "#tm"); f.status = T.val(root, "#ts"); f.collector = T.val(root, "#tc"); page = 0; load(); }, 300);
    ["#tq", "#tf", "#tt", "#tm", "#ts", "#tc"].forEach((s) => root.querySelector(s).addEventListener("input", apply));
    const ex = root.querySelector("#tx-exp");
    if (ex) ex.onclick = () => T.busy(ex, async () => { try { const j = await T.rpc("payments_list", args({ p_limit: 5000, p_offset: 0 })); T.reports.csv("transactions.csv", ["Date", "Receipt", "Txn ID", "Student", "Father", "Class", "Mode", "Reference", "Amount", "Status", "Collected by", "Cancel reason"], j.rows.map((p) => [p.payment_date, p.receipt_no, p.txn_id, p.student_name, p.father_name, p.class_name, T.MODES[p.mode], p.reference, p.amount, p.status, p.collector_name, p.cancel_reason]), "transactions"); } catch (e) { T.fail(e); } });
    load();
  };
})();
