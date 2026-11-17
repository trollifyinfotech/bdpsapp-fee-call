/* Receipts: on-screen receipt, print, PDF download, bulk PDF, receipt register page. */
(function () {
  const T = window.T;
  T.pages = T.pages || {};

  const logoData = async (path) => {
    const url = T.logoUrl(path); if (!url) return null;
    try {
      const blob = await (await fetch(url)).blob();
      return await new Promise((res) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = () => res(null); r.readAsDataURL(blob); });
    } catch (_) { return null; }
  };
  const mark = (d) => (d.is_cancelled ? "CANCELLED" : d.is_provisional ? "PROVISIONAL – NOT A RECEIPT" : d.print_count > 0 ? "DUPLICATE COPY" : "");

  function html(d) {
    const wm = mark(d);
    const logo = T.logoUrl(d.school.logo_path);
    return `<div class="receipt" id="receipt-area">${wm ? `<div class="wm">${T.esc(wm)}</div>` : ""}
      <div class="d-flex align-items-center gap-3 border-bottom pb-2 mb-2">${logo ? `<img src="${logo}" style="height:64px;max-width:90px;object-fit:contain" crossorigin="anonymous">` : ""}
        <div class="text-center flex-grow-1"><h2>${T.esc(d.school.name)}</h2><div class="small">${T.esc(d.school.address || "")}</div><div class="small">${d.school.phone ? "Phone: " + T.esc(d.school.phone) : ""}${d.school.email ? " · " + T.esc(d.school.email) : ""}</div></div></div>
      <div class="text-center fw-bold mb-2" style="letter-spacing:.1em">${d.is_provisional ? "PROVISIONAL ACKNOWLEDGEMENT" : "FEE RECEIPT"}</div>
      <table class="w-100 mb-2"><tr><td><b>Receipt No:</b> ${T.esc(d.receipt_no)}</td><td class="text-end"><b>Date:</b> ${T.dmy(d.date)}</td></tr>
        <tr><td><b>Digital Txn ID:</b> ${T.esc(d.txn_id)}</td><td class="text-end"><b>Session:</b> ${T.esc(d.session)}</td></tr>
        ${d.hard_copy_receipt_no ? `<tr><td colspan="2"><b>Hard copy receipt no:</b> ${T.esc(d.hard_copy_receipt_no)}</td></tr>` : ""}</table>
      <table class="w-100 mb-2 border-top border-bottom"><tr><td><b>Student:</b> ${T.esc(d.student.name)}</td><td><b>Class:</b> ${T.esc(d.class_name)}${d.section ? "-" + T.esc(d.section) : ""}</td></tr>
        <tr><td><b>Father:</b> ${T.esc(d.student.father_name || "—")}</td><td><b>Admission No:</b> ${T.esc(d.student.admission_no)}</td></tr></table>
      <table class="table table-sm table-bordered mb-2"><thead><tr><th>Fee Head</th><th class="text-end">Amount Paid</th></tr></thead><tbody>${(d.heads || []).map((h) => `<tr><td>${T.esc(h.head || "Advance payment (credit)")}</td><td class="text-end money">${T.inr(h.amount)}</td></tr>`).join("")}</tbody></table>
      <table class="w-100 mb-2"><tr><td>Previous balance</td><td class="text-end money">${T.inr(d.previous_balance)}</td></tr><tr><td><b>Current payment</b></td><td class="text-end money"><b>${T.inr(d.amount)}</b></td></tr>
        <tr><td>Total paid (this session)</td><td class="text-end money">${T.inr(d.total_paid)}</td></tr><tr><td>Remaining balance</td><td class="text-end money">${T.inr(d.remaining_balance)}</td></tr>
        <tr><td>Payment mode</td><td class="text-end">${T.esc(T.MODES[d.mode] || d.mode)}${d.reference ? " (" + T.esc(d.reference) + ")" : ""}</td></tr></table>
      <div class="small mb-3"><b>Amount in words:</b> ${T.esc(T.words(d.amount))}</div>
      <div class="d-flex justify-content-between align-items-end mt-4"><div class="small">Collected by:<br><b>${T.esc(d.collector || "—")}</b></div><div class="text-center small" style="width:30%"><div class="sig"></div>School Stamp</div><div class="text-center small" style="width:30%"><div class="sig"></div>Authorized Signature</div></div>
      <div class="text-center text-muted small mt-3">${T.esc(d.footer || "")}</div></div>`;
  }

  function drawPdf(doc, d, logo) {
    const W = doc.internal.pageSize.getWidth();
    doc.setDrawColor(51, 65, 85); doc.setLineWidth(0.5); doc.rect(8, 8, W - 16, 192);
    let y = 16, x0 = 13;
    if (logo) { try { doc.addImage(logo, logo.includes("image/png") ? "PNG" : "JPEG", x0, 12, 20, 20); } catch (_) {} }
    doc.setFont("helvetica", "bold"); doc.setFontSize(14); doc.text(String(d.school.name), W / 2, y + 2, { align: "center", maxWidth: W - 60 });
    doc.setFont("helvetica", "normal"); doc.setFontSize(8.5);
    doc.text(String(d.school.address || ""), W / 2, y + 9, { align: "center", maxWidth: W - 60 });
    doc.text([d.school.phone ? "Phone: " + d.school.phone : "", d.school.email || ""].filter(Boolean).join("  |  "), W / 2, y + 14, { align: "center" });
    doc.line(10, 34, W - 10, 34);
    doc.setFont("helvetica", "bold"); doc.setFontSize(11);
    doc.text(d.is_provisional ? "PROVISIONAL ACKNOWLEDGEMENT" : "FEE RECEIPT", W / 2, 41, { align: "center" });
    doc.setFontSize(9);
    const kv = (l, v, x, yy, right) => { doc.setFont("helvetica", "bold"); doc.text(l, x, yy, right ? { align: "left" } : undefined); doc.setFont("helvetica", "normal"); doc.text(String(v ?? "—"), x + doc.getTextWidth(l) + 1.5, yy); };
    y = 49;
    kv("Receipt No:", d.receipt_no, x0, y); kv("Date:", T.dmy(d.date), W / 2 + 8, y); y += 6;
    kv("Txn ID:", d.txn_id, x0, y); kv("Session:", d.session, W / 2 + 8, y); y += 6;
    if (d.hard_copy_receipt_no) { kv("Hard copy no:", d.hard_copy_receipt_no, x0, y); y += 6; }
    doc.line(10, y - 2, W - 10, y - 2); y += 3;
    kv("Student:", d.student.name, x0, y); kv("Class:", d.class_name + (d.section ? "-" + d.section : ""), W / 2 + 8, y); y += 6;
    kv("Father:", d.student.father_name || "—", x0, y); kv("Adm No:", d.student.admission_no, W / 2 + 8, y); y += 4;
    doc.autoTable({ startY: y, head: [["Fee Head", "Amount Paid"]], body: (d.heads || []).map((h) => [h.head || "Advance payment (credit)", T.inrPlain(h.amount)]), margin: { left: x0, right: x0 }, styles: { fontSize: 9 }, headStyles: { fillColor: [51, 65, 85] }, columnStyles: { 1: { halign: "right" } } });
    y = doc.lastAutoTable.finalY + 7;
    const row = (l, v, b) => { doc.setFont("helvetica", b ? "bold" : "normal"); doc.text(l, x0, y); doc.text(v, W - x0, y, { align: "right" }); y += 6; };
    row("Previous balance", T.inrPlain(d.previous_balance)); row("Current payment", T.inrPlain(d.amount), true); row("Total paid (this session)", T.inrPlain(d.total_paid)); row("Remaining balance", T.inrPlain(d.remaining_balance));
    row("Payment mode", (T.MODES[d.mode] || d.mode) + (d.reference ? " (" + d.reference + ")" : ""));
    doc.setFont("helvetica", "bold"); doc.text("Amount in words:", x0, y); doc.setFont("helvetica", "normal"); doc.text(T.words(d.amount), x0 + 30, y, { maxWidth: W - x0 * 2 - 30 }); y += 14;
    doc.setFontSize(8.5); doc.text("Collected by: " + (d.collector || "—"), x0, 168);
    doc.line(W / 2 - 18, 178, W / 2 + 12, 178); doc.text("School Stamp", W / 2 - 3, 182, { align: "center" });
    doc.line(W - 52, 178, W - 13, 178); doc.text("Authorized Signature", W - 32, 182, { align: "center" });
    doc.setFontSize(7.5); doc.setTextColor(100); doc.text(String(d.footer || ""), W / 2, 194, { align: "center" }); doc.setTextColor(0);
    const wm = mark(d);
    if (wm) {
      doc.saveGraphicsState(); doc.setGState(new doc.GState({ opacity: 0.14 })); doc.setTextColor(220, 38, 38); doc.setFontSize(32); doc.setFont("helvetica", "bold");
      doc.text(wm, W / 2, 110, { align: "center", angle: 28, maxWidth: 150 }); doc.restoreGraphicsState(); doc.setTextColor(0);
    }
  }

  T.receipts = {
    async fetch(paymentId) { return T.rpc("get_receipt", { p_payment: paymentId }); },
    async show(paymentId) {
      let d;
      try { d = await T.receipts.fetch(paymentId); } catch (e) { return T.fail(e); }
      const m = T.modal({
        title: "Receipt " + T.esc(d.receipt_no), size: "lg",
        body: html(d) + (d.print_count > 0 ? `<div class="text-muted small text-center mt-2 no-print">Printed ${d.print_count} time(s) before. Further copies are marked DUPLICATE.</div>` : ""),
        footer: `<button class="btn btn-light" data-bs-dismiss="modal">Close</button><button class="btn btn-outline-primary" id="rc-pdf"><i class="bi bi-file-earmark-pdf me-1"></i>Download PDF</button><button class="btn btn-primary" id="rc-print"><i class="bi bi-printer me-1"></i>Print</button>`,
      });
      const bump = async () => { try { const r = await T.rpc("mark_receipt_printed", { p_payment: paymentId }); d.print_count = (r.previous_prints || 0) + 1; } catch (_) {} };
      m.el.querySelector("#rc-print").onclick = async () => { window.print(); await bump(); m.body.innerHTML = html(d); };
      m.el.querySelector("#rc-pdf").onclick = (ev) => T.busy(ev.currentTarget, async () => {
        try { await T.receipts.pdf([d]); await bump(); m.body.innerHTML = html(d); } catch (e) { T.fail(e); }
      });
    },
    /** Builds one PDF with one receipt per page (A5). */
    async pdf(list, filename) {
      if (!window.jspdf) throw new Error("PDF library failed to load. Check your internet connection.");
      const doc = new window.jspdf.jsPDF({ unit: "mm", format: "a5" });
      const logo = list.length ? await logoData(list[0].school.logo_path) : null;
      list.forEach((d, i) => { if (i) doc.addPage(); drawPdf(doc, d, logo); });
      doc.save(filename || (list.length === 1 ? `receipt-${list[0].receipt_no.replace(/[^\w-]+/g, "_")}.pdf` : "receipts.pdf"));
    },
    async bulkPdf(ids, onProgress) {
      const out = [];
      for (let i = 0; i < ids.length; i++) { out.push(await T.receipts.fetch(ids[i])); onProgress && onProgress(i + 1, ids.length); }
      await T.receipts.pdf(out, "receipts-bulk.pdf");
    },
  };

  /* ---------- Receipt register page ---------- */
  T.pages.receipts = async (root) => {
    if (!T.can("view_fee_amounts")) { root.innerHTML = T.errorBox(new Error("You need the “View Fee Amounts” permission.")); return; }
    const f = { from: "", to: "", q: "", status: "verified" }; let page = 0; const size = 25;
    root.innerHTML = `<div class="page-h"><div><h1>Receipts</h1><div class="sub">Search, reprint and export receipts</div></div>${T.can("export_pdf") ? `<button class="btn btn-outline-primary" id="rc-bulk"><i class="bi bi-file-earmark-pdf me-1"></i>Download PDF for date range</button>` : ""}</div>
      <div class="card mb-3"><div class="card-body filters row g-2"><div class="col-md-4"><input id="rq" class="form-control" placeholder="Receipt no, txn id, student, father"></div>
        <div class="col-6 col-md-2"><input type="date" id="rf" class="form-control" title="From"></div><div class="col-6 col-md-2"><input type="date" id="rt" class="form-control" title="To"></div>
        <div class="col-md-2"><select id="rs" class="form-select">${T.opts({ verified: "Issued", pending: "Provisional (pending)", cancelled: "Cancelled" }, "verified")}</select></div><div class="col-md-2"><button class="btn btn-primary w-100" id="rgo">Search</button></div></div></div>
      <div class="card"><div id="rl"></div><div id="rp"></div></div>`;
    const args = (extra = {}) => ({ p_session: T.state.session, p_from: f.from || null, p_to: f.to || null, p_status: f.status || null, p_search: f.q || null, ...extra });
    const load = async () => {
      const rl = root.querySelector("#rl"); T.loading(rl);
      try {
        const j = await T.rpc("payments_list", args({ p_limit: size, p_offset: page * size }));
        rl.innerHTML = T.table([{ label: "Receipt No", render: (p) => `<b>${T.esc(p.receipt_no)}</b>` }, { label: "Date", render: (p) => T.dmy(p.payment_date) }, { label: "Student", render: (p) => T.esc(p.student_name) + `<div class="small text-muted">${T.esc(p.father_name || "")}</div>` }, { label: "Class", render: (p) => T.esc(p.class_name) }, { label: "Mode", render: (p) => T.esc(T.MODES[p.mode]) }, { label: "Amount", cls: "text-end money", render: (p) => T.inr(p.amount) }, { label: "Status", render: (p) => T.badge(p.status) }, { label: "", render: (p) => (T.can("print_receipt") ? `<button class="btn btn-sm btn-outline-primary" data-id="${p.payment_id}"><i class="bi bi-printer me-1"></i>View / Print</button>` : "") }], j.rows, { empty: "No receipts found" });
        rl.querySelectorAll("[data-id]").forEach((b) => (b.onclick = () => T.receipts.show(b.dataset.id)));
        T.pager(root.querySelector("#rp"), j.total, page, size, (p) => { page = p; load(); });
      } catch (e) { rl.innerHTML = T.errorBox(e); }
    };
    root.querySelector("#rgo").onclick = () => { f.q = T.val(root, "#rq"); f.from = T.val(root, "#rf"); f.to = T.val(root, "#rt"); f.status = T.val(root, "#rs"); page = 0; load(); };
    root.querySelector("#rq").addEventListener("keydown", (e) => { if (e.key === "Enter") root.querySelector("#rgo").click(); });
    const bulk = root.querySelector("#rc-bulk");
    if (bulk) bulk.onclick = () => T.busy(bulk, async () => {
      try {
        const j = await T.rpc("payments_list", args({ p_limit: 300, p_offset: 0, p_status: "verified" }));
        if (!j.rows.length) return T.toast("No issued receipts in this range", "warn");
        if (j.total > 300) T.toast(`Exporting the first 300 of ${j.total} receipts. Narrow the date range for the rest.`, "warn");
        await T.receipts.bulkPdf(j.rows.map((r) => r.payment_id));
        T.rpc("log_audit", { p_action: "data_export", p_record_type: "receipts_bulk_pdf", p_details: { count: j.rows.length, from: f.from, to: f.to } }).catch(() => {});
      } catch (e) { T.fail(e); }
    });
    load();
  };
})();
