/* Families & siblings. Relationships are always confirmed by an admin - never assumed from matching names/phones. */
(function () {
  const T = window.T;
  T.pages = T.pages || {};

  T.pages.families = async (root) => {
    if (!T.can("view_student_list")) { root.innerHTML = T.errorBox(new Error("You need the “View Student List” permission.")); return; }
    const canEdit = T.can("manage_families"), fin = T.can("view_fee_amounts");
    root.innerHTML = `<div class="page-h"><div><h1>Families</h1><div class="sub">Session <b>${T.esc(T.sessions.current()?.name || "—")}</b>. Sibling concessions are recorded separately for each student.</div></div>
      <div class="d-flex gap-2">${canEdit ? `<button class="btn btn-outline-secondary" id="fm-sug"><i class="bi bi-lightbulb me-1"></i>Suggested siblings</button><button class="btn btn-primary" id="fm-add"><i class="bi bi-plus-lg me-1"></i>Create family</button>` : ""}</div></div>
      <div class="card mb-3"><div class="card-body py-2"><input class="form-control" id="fm-q" placeholder="Filter by family or student name"></div></div><div id="fm"></div>`;
    let fams = [];
    const draw = () => {
      const q = T.val(root, "#fm-q").toLowerCase();
      const list = fams.filter((f) => !q || f.name.toLowerCase().includes(q) || f.members.some((m) => m.name.toLowerCase().includes(q)));
      root.querySelector("#fm").innerHTML = list.length ? list.map((f) => {
        const tot = f.members.reduce((a, m) => ({ net: a.net + Number(m.net || 0), paid: a.paid + Number(m.paid || 0), pend: a.pend + Number(m.pending || 0), disc: a.disc + Number(m.discount || 0) }), { net: 0, paid: 0, pend: 0, disc: 0 });
        return `<div class="card mb-3"><div class="card-header d-flex flex-wrap justify-content-between gap-2"><span><i class="bi bi-people me-1"></i>${T.esc(f.name)} ${f.family_ref ? `<span class="text-muted small">(${T.esc(f.family_ref)})</span>` : ""} ${f.policy ? T.badge("info", "Policy: " + T.label(f.policy.type)) : ""}</span>
          <div class="btn-group btn-group-sm">${canEdit ? `<button class="btn btn-outline-primary" data-add="${f.family_id}">Add student</button>` : ""}${T.can("apply_discount") ? `<button class="btn btn-outline-success" data-pol="${f.family_id}">Concession policy</button>` : ""}</div></div>
          ${T.table([{ label: "Student", render: (m) => `<a href="#/students/${m.student_id}">${T.esc(m.name)}</a> ${m.verified ? "" : T.badge("pending", "Unverified")}` }, { label: "Class", render: (m) => T.esc(m.class_name || "— (not in this session)") },
            ...(fin ? [{ label: "Fee", cls: "text-end money", render: (m) => T.inr(m.gross) }, { label: "Discount", cls: "text-end money", render: (m) => T.inr(m.discount) }, { label: "Net", cls: "text-end money", render: (m) => T.inr(m.net) }, { label: "Paid", cls: "text-end money", render: (m) => T.inr(m.paid) }, { label: "Pending", cls: "text-end money text-danger", render: (m) => T.inr(m.pending) }] : []),
            { label: "", cls: "text-end", render: (m) => (canEdit ? `<div class="btn-group btn-group-sm">${m.verified ? "" : `<button class="btn btn-outline-success" data-vf="${m.member_id}">Verify</button>`}<button class="btn btn-outline-danger" data-rm="${m.member_id}">Remove</button></div>` : "") }], f.members, { empty: "No members" })}
          ${fin ? `<div class="card-footer small">Family total — Net <b>${T.inr(tot.net)}</b> · Discount <b>${T.inr(tot.disc)}</b> · Paid <b class="text-success">${T.inr(tot.paid)}</b> · Pending <b class="text-danger">${T.inr(tot.pend)}</b></div>` : ""}</div>`;
      }).join("") : `<div class="card">${T.empty("No families yet", "people")}</div>`;
      root.querySelectorAll("[data-vf]").forEach((b) => (b.onclick = async () => { try { await T.rpc("verify_family_member", { p_member: b.dataset.vf }, { mutates: true }); T.ok("Relationship verified"); load(); } catch (e) { T.fail(e); } }));
      root.querySelectorAll("[data-rm]").forEach((b) => (b.onclick = async () => { const r = await T.confirm({ title: "Remove from family", message: "The relationship is removed and the change is audit-logged. Existing concessions linked to the family stay in the history; revoke them under Discounts if no longer valid.", reason: true, danger: true, okText: "Remove" }); if (!r) return; try { await T.rpc("remove_family_member", { p_member: b.dataset.rm, p_reason: r }, { mutates: true }); T.ok("Removed"); load(); } catch (e) { T.fail(e); } }));
      root.querySelectorAll("[data-add]").forEach((b) => (b.onclick = () => addMember(b.dataset.add)));
      root.querySelectorAll("[data-pol]").forEach((b) => (b.onclick = () => policy(fams.find((f) => f.family_id === b.dataset.pol))));
    };
    const load = async () => { const el = root.querySelector("#fm"); T.loading(el); try { fams = await T.rpc("family_overview", { p_session: T.state.session }); draw(); } catch (e) { el.innerHTML = T.errorBox(e); } };

    async function pickStudents(title, onSave) {
      const chosen = new Map();
      const m = T.modal({ title, size: "lg", static: true, body: `<div id="sp" class="mb-3"></div><div id="ch"></div>`, footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="sv">Save</button>` });
      const redraw = () => (m.el.querySelector("#ch").innerHTML = chosen.size ? [...chosen.values()].map((s) => `<span class="badge text-bg-light border me-1 mb-1">${T.esc(s.name)} (${T.esc(s.class_name)}) <a href="#" data-x="${s.student_id}" class="text-danger ms-1">×</a></span>`).join("") : `<span class="text-muted small">No student selected yet</span>`);
      T.studentPicker(m.el.querySelector("#sp"), (s) => { chosen.set(s.student_id, s); redraw(); m.el.querySelector("#sp input").value = ""; });
      m.el.addEventListener("click", (e) => { const x = e.target.closest("[data-x]"); if (x) { e.preventDefault(); chosen.delete(x.dataset.x); redraw(); } });
      redraw();
      return { m, chosen, bindSave: (fn) => (m.el.querySelector("#sv").onclick = (ev) => T.busy(ev.currentTarget, async () => { if (!chosen.size) return T.toast("Select at least one student", "warn"); try { await fn([...chosen.keys()]); m.close(); load(); } catch (e) { T.fail(e); } })) };
    }
    async function addMember(familyId) {
      const p = await pickStudents("Add students to family");
      p.bindSave(async (ids) => { for (const id of ids) await T.rpc("link_student_family", { p_family: familyId, p_student: id, p_rel: "sibling" }, { mutates: true }); T.ok("Students linked and verified by you"); });
    }
    const add = root.querySelector("#fm-add");
    if (add) add.onclick = async () => {
      const p = await pickStudents("Create family");
      p.m.body.insertAdjacentHTML("afterbegin", `<div class="row g-2 mb-3"><div class="col-md-5"><label class="form-label small fw-semibold">Family name *</label><input id="fn" class="form-control" placeholder="e.g. Janghela Family"></div><div class="col-md-4"><label class="form-label small fw-semibold">Primary mobile</label><input id="fp" class="form-control" maxlength="10"></div><div class="col-md-3"><label class="form-label small fw-semibold">Notes</label><input id="fo" class="form-control"></div></div>`);
      p.bindSave(async (ids) => { const n = T.val(p.m.el, "#fn"); if (n.length < 2) throw new Error("Enter a family name"); await T.rpc("create_family", { p_name: n, p_mobile: T.val(p.m.el, "#fp"), p_notes: T.val(p.m.el, "#fo"), p_student_ids: ids }, { mutates: true }); T.ok("Family created"); });
    };
    const sug = root.querySelector("#fm-sug");
    if (sug) sug.onclick = async () => {
      try {
        const rows = await T.rpc("suggest_siblings");
        const m = T.modal({ title: "Suggested siblings (please verify)", size: "lg", body: `<div class="alert alert-warning small">These are only suggestions from matching mobile numbers. Nothing is linked until you confirm.</div>${T.table([{ label: "Student A", key: "name_a" }, { label: "Student B", key: "name_b" }, { label: "Why", key: "reason" }, { label: "", render: (r) => `<button class="btn btn-sm btn-outline-primary" data-a="${r.student_a}" data-b="${r.student_b}" data-n="${T.esc(r.name_a)}">Confirm as siblings</button>` }], rows, { empty: "No suggestions found" })}` });
        m.el.querySelectorAll("[data-a]").forEach((b) => (b.onclick = async () => { try { await T.rpc("create_family", { p_name: b.dataset.n.split(" ").slice(-1)[0] + " Family", p_mobile: null, p_notes: "Confirmed from sibling suggestion", p_student_ids: [b.dataset.a, b.dataset.b] }, { mutates: true }); T.ok("Family created and verified"); m.close(); load(); } catch (e) { T.fail(e); } }));
      } catch (e) { T.fail(e); }
    };
    function policy(f) {
      const TYPES = { first_pays_rest_free: "First child pays full fee, others free (100% waiver)", first_pays_rest_percent: "First child pays full fee, others get a % discount", percent_each: "Percentage discount for every child except the payer", fixed_each: "Fixed ₹ discount for every child except the payer", selected_free: "Selected children get a full waiver", custom: "Custom ₹ concession for selected children" };
      const m = T.modal({ title: `Concession policy — ${T.esc(f.name)}`, size: "lg", static: true, body: `<div class="alert alert-info small">Applying a policy replaces any earlier active policy for this family in this session. A separate discount record is created for each student with your name as approver.</div>
        <div class="row g-3">${T.field("Policy", `<select class="form-select" id="pt">${T.opts(TYPES, f.policy?.type || "first_pays_rest_free")}</select>`, { col: "col-12" })}
        ${T.field("Student who pays full fee", `<select class="form-select" id="pp"><option value="">First admitted (auto)</option>${f.members.map((x) => `<option value="${x.student_id}">${T.esc(x.name)}</option>`).join("")}</select>`, { col: "col-md-6" })}${T.field("Value (% or ₹)", `<input type="number" min="0" step="0.01" class="form-control" id="pv" value="0">`, { col: "col-md-6" })}
        <div class="col-12" id="sel"><label class="form-label small fw-semibold">Selected students</label>${f.members.map((x) => `<div class="form-check"><input type="checkbox" class="form-check-input sc" value="${x.student_id}" id="s${x.student_id}"><label class="form-check-label" for="s${x.student_id}">${T.esc(x.name)}</label></div>`).join("")}</div>
        ${T.field("Reason / approval note", `<input class="form-control" id="pr" maxlength="200">`, { col: "col-12", req: true })}</div><div class="text-danger small mt-2 d-none" id="pe"></div>`,
        footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="pgo">Apply policy</button>` });
      const sync = () => { const t = T.val(m.el, "#pt"); m.el.querySelector("#sel").style.display = ["selected_free", "custom"].includes(t) ? "" : "none"; };
      m.el.querySelector("#pt").onchange = sync; sync();
      m.el.querySelector("#pgo").onclick = (ev) => T.busy(ev.currentTarget, async () => {
        const pe = m.el.querySelector("#pe"); pe.classList.add("d-none");
        try {
          const r = await T.rpc("apply_family_policy", { p_family: f.family_id, p_session: T.state.session, p_policy: T.val(m.el, "#pt"), p_payer: T.nullIfBlank(T.val(m.el, "#pp")), p_value: Number(T.val(m.el, "#pv") || 0), p_reason: T.val(m.el, "#pr"), p_selected: [...m.el.querySelectorAll(".sc:checked")].map((c) => c.value) }, { mutates: true });
          T.ok(`${r.discounts_created} student concession(s) recorded`); m.close(); load();
        } catch (e) { pe.textContent = T.errMsg(e); pe.classList.remove("d-none"); }
      });
    }
    root.querySelector("#fm-q").addEventListener("input", T.debounce(draw, 200));
    load();
  };
})();
