/* Students: list, add/edit, profile (10 tabs), bulk CSV/XLSX import. */
(function () {
  const T = window.T;
  T.pages = T.pages || {};
  const SEL = "id,student_code,admission_no,name,father_name,mother_name,mobile,alt_mobile,whatsapp,address,village,district,parent_email,gender,dob,admission_date,status,remarks,photo_path,student_session_enrollments!inner(id,class_name,section,roll_no,category,session_id,status)";

  const cleanSearch = (s) => s.replace(/[%,()*]/g, " ").trim();
  function applyFilters(q, f) {
    q = q.eq("student_session_enrollments.session_id", T.state.session);
    if (f.cls) q = q.eq("student_session_enrollments.class_name", f.cls);
    if (f.section) q = q.eq("student_session_enrollments.section", f.section);
    if (f.category) q = q.eq("student_session_enrollments.category", f.category);
    if (f.status) q = q.eq("status", f.status);
    if (f.q) { const s = cleanSearch(f.q); q = q.or(`name.ilike.%${s}%,father_name.ilike.%${s}%,admission_no.ilike.%${s}%,student_code.ilike.%${s}%,mobile.ilike.%${s}%`); }
    return q;
  }
  const enr = (s) => (Array.isArray(s.student_session_enrollments) ? s.student_session_enrollments[0] : s.student_session_enrollments) || {};

  /* ---------------- LIST ---------------- */
  T.pages.students = async (root) => {
    const f = { q: "", cls: "", section: "", status: "active", category: "" };
    let page = 0; const size = window.TCONFIG.PAGE_SIZE;
    root.innerHTML = `<div class="page-h"><div><h1>Students</h1><div class="sub">Session: <b>${T.esc(T.sessions.current()?.name || "—")}</b></div></div>
      <div class="d-flex flex-wrap gap-2">${T.can("export_csv") ? `<button class="btn btn-outline-secondary" id="st-exp"><i class="bi bi-download me-1"></i>Export</button>` : ""}
      ${T.can("import_students") ? `<a class="btn btn-outline-primary" href="#/students/import"><i class="bi bi-file-earmark-arrow-up me-1"></i>Import</a>` : ""}
      ${T.can("add_student") ? `<button class="btn btn-primary" id="st-add"><i class="bi bi-person-plus me-1"></i>Add Student</button>` : ""}</div></div>
      <div class="card mb-3"><div class="card-body filters row g-2">
        <div class="col-md-4"><input class="form-control" id="f-q" placeholder="Search name, father, admission no, student ID, mobile"></div>
        <div class="col-6 col-md-2"><select class="form-select" id="f-c">${T.classOpts("")}</select></div>
        <div class="col-6 col-md-1"><input class="form-control" id="f-s" placeholder="Sec"></div>
        <div class="col-6 col-md-2"><select class="form-select" id="f-cat">${T.opts(T.CATEGORIES, "", "All categories")}</select></div>
        <div class="col-6 col-md-2"><select class="form-select" id="f-st">${T.opts({ active: "Active", archived: "Archived", transferred: "Transferred", passed_out: "Passed out" }, "active", "All status")}</select></div></div></div>
      <div class="card"><div id="st-list"></div><div id="st-pg"></div></div>`;
    const list = root.querySelector("#st-list");
    const load = async () => {
      T.loading(list);
      try {
        const { data, count } = await T.q(applyFilters(window.sb.from("students").select(SEL, { count: "exact" }), f).order("name").range(page * size, page * size + size - 1));
        list.innerHTML = T.table([
          { label: "Student ID", render: (s) => `<span class="text-muted small">${T.esc(s.student_code)}</span>` },
          { label: "Adm No", key: "admission_no" },
          { label: "Name", render: (s) => `<a href="#/students/${s.id}" class="fw-semibold text-decoration-none">${T.esc(s.name)}</a>${s.status !== "active" ? " " + T.badge(s.status) : ""}` },
          { label: "Father", key: "father_name" },
          { label: "Class", render: (s) => T.esc(enr(s).class_name) + (enr(s).section ? "-" + T.esc(enr(s).section) : "") },
          { label: "Roll", render: (s) => T.esc(enr(s).roll_no || "—") },
          { label: "Mobile", render: (s) => s.mobile ? `<a href="tel:${T.phone(s.mobile)}" class="text-decoration-none">${T.esc(s.mobile)}</a>` : "—" },
          { label: "Category", render: (s) => (enr(s).category === "general" ? "" : T.badge(enr(s).category === "rte" ? "rte" : "info", T.CATEGORIES[enr(s).category])) },
          { label: "", cls: "text-end", render: (s) => `<div class="btn-group btn-group-sm"><a class="btn btn-outline-primary" href="#/students/${s.id}" title="View"><i class="bi bi-eye"></i></a>${T.can("edit_student") ? `<button class="btn btn-outline-secondary" data-edit="${s.id}" title="Edit"><i class="bi bi-pencil"></i></button>` : ""}${T.can("collect_fee") && s.status === "active" ? `<button class="btn btn-outline-success" data-pay="${enr(s).id}" title="Collect fee"><i class="bi bi-cash-coin"></i></button>` : ""}${T.can("archive_student") ? (s.status === "active" ? `<button class="btn btn-outline-danger" data-arch="${s.id}" title="Archive"><i class="bi bi-archive"></i></button>` : `<button class="btn btn-outline-success" data-restore="${s.id}" title="Restore"><i class="bi bi-arrow-counterclockwise"></i></button>`) : ""}</div>` },
        ], data, { empty: "No students found for the selected filters" });
        T.pager(root.querySelector("#st-pg"), count, page, size, (p) => { page = p; load(); });
        list.querySelectorAll("[data-edit]").forEach((b) => (b.onclick = () => T.students.form(b.dataset.edit, load)));
        list.querySelectorAll("[data-pay]").forEach((b) => (b.onclick = () => T.payments.collect(b.dataset.pay, load)));
        list.querySelectorAll("[data-arch]").forEach((b) => (b.onclick = async () => {
          const r = await T.confirm({ title: "Archive student", message: "The student is hidden from active lists and open calling tasks are cancelled. Fee history is preserved.", reason: true, danger: true, okText: "Archive" });
          if (!r) return;
          try { await T.rpc("archive_student", { p_student: b.dataset.arch, p_reason: r }, { mutates: true }); T.ok("Student archived"); load(); } catch (e) { T.fail(e); }
        }));
        list.querySelectorAll("[data-restore]").forEach((b) => (b.onclick = async () => { try { await T.rpc("restore_student", { p_student: b.dataset.restore }, { mutates: true }); T.ok("Student restored"); load(); } catch (e) { T.fail(e); } }));
      } catch (e) { list.innerHTML = T.errorBox(e); }
    };
    const apply = T.debounce(() => { f.q = T.val(root, "#f-q"); f.cls = T.val(root, "#f-c"); f.section = T.val(root, "#f-s"); f.status = T.val(root, "#f-st"); f.category = T.val(root, "#f-cat"); page = 0; load(); }, 350);
    ["#f-q", "#f-c", "#f-s", "#f-st", "#f-cat"].forEach((s) => root.querySelector(s).addEventListener("input", apply));
    const add = root.querySelector("#st-add"); if (add) add.onclick = () => T.students.form(null, load);
    const exp = root.querySelector("#st-exp");
    if (exp) exp.onclick = () => T.busy(exp, async () => {
      try {
        let all = [], from = 0;
        for (;;) { const { data } = await T.q(applyFilters(window.sb.from("students").select(SEL, { count: "exact" }), f).order("name").range(from, from + 999)); all = all.concat(data); if (data.length < 1000) break; from += 1000; }
        T.reports.csv("students.csv", ["Student ID", "Admission No", "Name", "Father", "Mother", "Class", "Section", "Roll", "Mobile", "Address", "Admission Date", "Category", "Status"],
          all.map((s) => [s.student_code, s.admission_no, s.name, s.father_name, s.mother_name, enr(s).class_name, enr(s).section, enr(s).roll_no, s.mobile, s.address, s.admission_date, T.CATEGORIES[enr(s).category], s.status]), "students");
      } catch (e) { T.fail(e); }
    });
    load();
  };

  /* ---------------- ADD / EDIT FORM ---------------- */
  T.students = {
    async form(studentId, done) {
      let s = {}, e = {};
      if (studentId) {
        try {
          s = await T.q(window.sb.from("students").select(SEL).eq("id", studentId).eq("student_session_enrollments.session_id", T.state.session).single());
          e = enr(s);
        } catch (err) { return T.fail(err); }
      }
      const sess = T.sessions.current();
      if (!sess || sess.status !== "open") return T.toast("Select an open academic session first.", "warn");
      const V = (k) => T.esc(s[k] ?? "");
      const m = T.modal({
        title: studentId ? "Edit student" : "Add student", size: "xl", static: true,
        body: `<form id="sf" class="row g-3" novalidate>
          ${T.field("Student name", `<input class="form-control" name="name" value="${V("name")}" required>`, { req: true })}
          ${T.field("Admission number", `<input class="form-control" name="admission_no" value="${V("admission_no")}" required>`, { req: true })}
          ${T.field("Father name", `<input class="form-control" name="father_name" value="${V("father_name")}">`)}
          ${T.field("Mother name", `<input class="form-control" name="mother_name" value="${V("mother_name")}">`)}
          ${T.field("Gender", `<select class="form-select" name="gender">${T.opts({ male: "Male", female: "Female", other: "Other" }, s.gender, "Select")}</select>`, { col: "col-md-3" })}
          ${T.field("Date of birth", `<input type="date" class="form-control" name="dob" value="${V("dob")}">`, { col: "col-md-3" })}
          ${T.field("Admission date", `<input type="date" class="form-control" name="admission_date" value="${s.admission_date || T.today()}">`, { col: "col-md-3" })}
          ${T.field("Class", `<select class="form-select" name="class_name" required>${T.opts(T.CLASSES, e.class_name, "Select class")}</select>`, { col: "col-md-3", req: true })}
          ${T.field("Section", `<input class="form-control" name="section" value="${T.esc(e.section || "")}">`, { col: "col-md-3" })}
          ${T.field("Roll number", `<input class="form-control" name="roll_no" value="${T.esc(e.roll_no || "")}">`, { col: "col-md-3" })}
          ${T.field("Category / status", `<select class="form-select" name="category">${T.opts(T.CATEGORIES, e.category || "general")}</select>`, { col: "col-md-3", hint: "RTE = zero parent fee" })}
          ${studentId || !T.can("edit_fee_structure") ? "" : T.field("Annual fee override (₹)", `<input type="number" min="0" step="0.01" class="form-control" name="annual_fee" placeholder="Leave blank to use fee structure">`, { col: "col-md-3" })}
          ${T.field("Parent mobile", `<input class="form-control" name="mobile" inputmode="numeric" maxlength="10" value="${V("mobile")}" required>`, { col: "col-md-3", req: true, hint: "10-digit; used for the Call button" })}
          ${T.field("Alternate mobile", `<input class="form-control" name="alt_mobile" inputmode="numeric" maxlength="10" value="${V("alt_mobile")}">`, { col: "col-md-3" })}
          ${T.field("WhatsApp number", `<input class="form-control" name="whatsapp" inputmode="numeric" maxlength="10" value="${V("whatsapp")}">`, { col: "col-md-3" })}
          ${T.field("Parent email", `<input type="email" class="form-control" name="parent_email" value="${V("parent_email")}">`, { col: "col-md-3" })}
          ${T.field("Address", `<input class="form-control" name="address" value="${V("address")}">`, { col: "col-md-6" })}
          ${T.field("Village", `<input class="form-control" name="village" value="${V("village")}">`, { col: "col-md-3" })}
          ${T.field("District", `<input class="form-control" name="district" value="${V("district")}">`, { col: "col-md-3" })}
          ${T.field("Student photo", `<input type="file" class="form-control" name="photo" accept="image/png,image/jpeg,image/webp">`, { col: "col-md-6" })}
          ${T.field("Remarks", `<input class="form-control" name="remarks" value="${V("remarks")}">`, { col: "col-md-6" })}
        </form><div class="text-danger small mt-2 d-none" id="sf-err"></div>`,
        footer: `<button class="btn btn-light" data-bs-dismiss="modal">Cancel</button><button class="btn btn-primary" id="sf-save"><i class="bi bi-check2 me-1"></i>Save</button>`,
      });
      const err = (t) => { const x = m.el.querySelector("#sf-err"); x.textContent = t; x.classList.remove("d-none"); };
      m.el.querySelector("#sf-save").onclick = (ev) => T.busy(ev.currentTarget, async () => {
        const fm = m.el.querySelector("#sf"), v = (n) => fm.elements[n]?.value.trim() ?? "";
        const digits = (x) => x.replace(/\D/g, "");
        if (!v("name")) return err("Student name is required.");
        if (!v("admission_no")) return err("Admission number is required.");
        if (!v("class_name")) return err("Class is required.");
        for (const k of ["mobile", "alt_mobile", "whatsapp"]) { if (v(k) && !/^[6-9]\d{9}$/.test(digits(v(k)))) return err("Enter valid 10-digit mobile numbers (starting 6-9)."); }
        if (!v("mobile")) return err("Parent mobile number is required.");
        try {
          const data = { name: v("name"), admission_no: v("admission_no"), father_name: v("father_name"), mother_name: v("mother_name"), gender: v("gender"), dob: v("dob"), admission_date: v("admission_date"), mobile: digits(v("mobile")), alt_mobile: digits(v("alt_mobile")), whatsapp: digits(v("whatsapp")), address: v("address"), village: v("village"), district: v("district"), parent_email: v("parent_email"), remarks: v("remarks") };
          let id = studentId;
          if (studentId) {
            const upd = { ...data, gender: data.gender || null, dob: data.dob || null, admission_date: data.admission_date || null };
            await T.mutate(window.sb.from("students").update(upd).eq("id", studentId));
            if (e.id && (v("class_name") !== e.class_name || v("section") !== (e.section || "") || v("category") !== e.category || v("roll_no") !== (e.roll_no || ""))) {
              let reassign = false;
              if (v("class_name") !== e.class_name || v("category") !== e.category) {
                reassign = T.can("edit_fee_structure") && (await T.confirm({ title: "Class / category changed", message: "Re-assign fees from the fee structure of the new class? Fee lines that already have payments are kept untouched.", okText: "Re-assign fees" }));
              }
              await T.rpc("change_class", { p_enrollment: e.id, p_class: v("class_name"), p_section: v("section"), p_roll: v("roll_no"), p_category: v("category"), p_reassign_fees: !!reassign }, { mutates: true });
            }
          } else {
            id = await T.rpc("add_student", { p_data: data, p_session: T.state.session, p_class: v("class_name"), p_section: v("section"), p_roll: v("roll_no"), p_category: v("category"), p_annual_fee: v("annual_fee") === "" ? null : Number(v("annual_fee")), p_family: null }, { mutates: true });
          }
          const photo = fm.elements.photo.files[0];
          if (photo && id) {
            if (photo.size > 2 * 1024 * 1024) T.toast("Photo larger than 2 MB was skipped", "warn");
            else { const path = await T.upload("student-photos", photo, id); await T.mutate(window.sb.from("students").update({ photo_path: path }).eq("id", id)); }
          }
          T.ok(studentId ? "Student updated" : "Student added"); m.close(); done && done(id);
        } catch (ex) { err(T.errMsg(ex)); }
      });
    },
  };

  /* ---------------- PROFILE ---------------- */
  T.pages["students/profile"] = async (root, ctx) => {
    const id = ctx.params[0];
    T.loading(root);
    let s;
    try { s = await T.q(window.sb.from("students").select("*").eq("id", id).single()); } catch (e) { root.innerHTML = T.errorBox(e); return; }
    const enrolls = await T.q(window.sb.from("student_session_enrollments").select("*, academic_sessions(name)").eq("student_id", id).order("created_at", { ascending: false }));
    const cur = enrolls.find((x) => x.session_id === T.state.session) || enrolls[0] || {};
    let photo = "";
    if (s.photo_path) { try { photo = await T.signedUrl("student-photos", s.photo_path); } catch (_) {} }
    root.innerHTML = `<div class="page-h"><div class="d-flex align-items-center gap-3">${photo ? `<img src="${photo}" class="rounded-circle" style="width:56px;height:56px;object-fit:cover">` : `<div class="ic ic-p rounded-circle" style="width:56px;height:56px;display:grid;place-items:center;font-size:1.6rem"><i class="bi bi-person"></i></div>`}
      <div><h1>${T.esc(s.name)} ${T.badge(s.status)}</h1><div class="sub">${T.esc(s.student_code)} · Adm ${T.esc(s.admission_no)} · ${T.esc(cur.class_name || "—")}${cur.section ? "-" + T.esc(cur.section) : ""}</div></div></div>
      <div class="d-flex gap-2"><a href="#/students" class="btn btn-light"><i class="bi bi-arrow-left me-1"></i>Back</a>${T.can("edit_student") ? `<button class="btn btn-outline-secondary" id="pf-edit"><i class="bi bi-pencil me-1"></i>Edit</button>` : ""}${T.can("collect_fee") && cur.id ? `<button class="btn btn-success" id="pf-pay"><i class="bi bi-cash-coin me-1"></i>Collect Fee</button>` : ""}</div></div><div id="pf-tabs"></div>`;
    const reload = () => T.pages["students/profile"](root, ctx);
    const ed = root.querySelector("#pf-edit"); if (ed) ed.onclick = () => T.students.form(id, reload);
    const pay = root.querySelector("#pf-pay"); if (pay) pay.onclick = () => T.payments.collect(cur.id, reload);
    const kv = (rows) => `<div class="row g-3">${rows.map(([k, v]) => `<div class="col-6 col-md-4"><div class="text-muted small">${k}</div><div class="fw-semibold">${v === null || v === undefined || v === "" ? "—" : v}</div></div>`).join("")}</div>`;
    const noPerm = (p) => `<div class="alert alert-secondary">You do not have the “${p}” permission to view this section.</div>`;
    const tabs = [
      { label: "Personal Details", icon: "person", render: (el) => (el.innerHTML = `<div class="card"><div class="card-body">${kv([["Student name", T.esc(s.name)], ["Gender", T.label(s.gender)], ["Date of birth", T.dmy(s.dob)], ["Admission date", T.dmy(s.admission_date)], ["Admission no", T.esc(s.admission_no)], ["Student ID", T.esc(s.student_code)], ["Class / Section", T.esc(cur.class_name) + (cur.section ? "-" + T.esc(cur.section) : "")], ["Roll no", T.esc(cur.roll_no)], ["Category", T.esc(T.CATEGORIES[cur.category])], ["Status", T.badge(s.status)]])}</div></div>`) },
      { label: "Parent Details", icon: "people", render: (el) => (el.innerHTML = `<div class="card"><div class="card-body">${kv([["Father", T.esc(s.father_name)], ["Mother", T.esc(s.mother_name)], ["Mobile", s.mobile ? `<a href="tel:${T.phone(s.mobile)}">${T.esc(s.mobile)}</a>` : ""], ["Alternate mobile", T.esc(s.alt_mobile)], ["WhatsApp", T.esc(s.whatsapp)], ["Email", T.esc(s.parent_email)], ["Address", T.esc(s.address)], ["Village", T.esc(s.village)], ["District", T.esc(s.district)]])}</div></div>`) },
      { label: "Family Members", icon: "diagram-3", render: async (el) => {
        const fm = await T.q(window.sb.from("family_members").select("family_id,verified,families(name,family_ref)").eq("student_id", id).is("removed_at", null).maybeSingle());
        if (!fm) { el.innerHTML = `<div class="card"><div class="card-body">${T.empty("Not linked to any family", "diagram-3")}${T.can("manage_families") ? `<div class="text-center"><a href="#/families" class="btn btn-outline-primary btn-sm">Open Families</a></div>` : ""}</div></div>`; return; }
        const mem = await T.q(window.sb.from("family_members").select("verified,relationship,students(id,name,admission_no)").eq("family_id", fm.family_id).is("removed_at", null));
        el.innerHTML = `<div class="card"><div class="card-header">${T.esc(fm.families.name)} ${fm.verified ? T.badge("verified", "Verified") : T.badge("pending", "Unverified")}</div>${T.table([{ label: "Student", render: (r) => `<a href="#/students/${r.students.id}">${T.esc(r.students.name)}</a>${r.students.id === id ? " <span class='badge-s b-info'>this student</span>" : ""}` }, { label: "Adm No", render: (r) => T.esc(r.students.admission_no) }, { label: "Relationship", render: (r) => T.label(r.relationship) }, { label: "Verified", render: (r) => (r.verified ? "Yes" : "No") }], mem)}</div>`;
      } },
      { label: "Session History", icon: "calendar3", render: (el) => (el.innerHTML = `<div class="card">${T.table([{ label: "Session", render: (r) => T.esc(r.academic_sessions?.name) }, { label: "Class", render: (r) => T.esc(r.class_name) + (r.section ? "-" + T.esc(r.section) : "") }, { label: "Roll", render: (r) => T.esc(r.roll_no || "—") }, { label: "Category", render: (r) => T.esc(T.CATEGORIES[r.category]) }, { label: "Status", render: (r) => T.badge(r.status === "active" ? "active" : "info", T.label(r.status)) }], enrolls)}</div>`) },
      { label: "Fee Details", icon: "currency-rupee", render: async (el) => {
        if (!T.can("view_fee_amounts")) { el.innerHTML = noPerm("View Fee Amounts"); return; }
        const [bal, lines, disc] = await Promise.all([
          T.q(window.sb.from("v_enrollment_balances").select("*").eq("student_id", id)),
          T.q(window.sb.from("student_fee_assignments").select("amount,status,source,reason,session_id,enrollment_id,fee_heads(name),fee_installments(installment_no,due_date,amount)").eq("student_id", id).eq("status", "active")),
          T.q(window.sb.from("student_discounts").select("*").eq("student_id", id).order("created_at", { ascending: false })),
        ]);
        el.innerHTML = enrolls.map((en) => {
          const b = bal.find((x) => x.enrollment_id === en.id) || {};
          const ls = lines.filter((l) => l.enrollment_id === en.id);
          return `<div class="card mb-3"><div class="card-header d-flex justify-content-between"><span>${T.esc(en.academic_sessions?.name)} · ${T.esc(en.class_name)}</span>${T.badge(b.pay_status || "zero_fee")}</div><div class="card-body">
            <div class="row g-2 mb-3 text-center">${[["Gross", b.gross], ["Discount", b.discount], ["Net", b.net], ["Paid", b.paid], ["Pending", b.pending]].map(([l, v]) => `<div class="col"><div class="text-muted small">${l}</div><div class="fw-bold money">${T.inr(v)}</div></div>`).join("")}</div>
            ${T.table([{ label: "Fee head", render: (l) => T.esc(l.fee_heads?.name) }, { label: "Amount", cls: "text-end money", render: (l) => T.inr(l.amount) }, { label: "Installments / due", render: (l) => (l.fee_installments || []).sort((a, b) => a.installment_no - b.installment_no).map((i) => `${T.dmy(i.due_date)}: ${T.inr(i.amount)}`).join("<br>") }, { label: "Source", render: (l) => T.label(l.source) }], ls, { empty: "No fee assigned for this session" })}
            ${T.can("edit_fee_structure") ? `<button class="btn btn-sm btn-outline-secondary mt-2" data-editfee="${en.id}"><i class="bi bi-pencil me-1"></i>Edit fee</button>` : ""}</div></div>`;
        }).join("") + (disc.length ? `<div class="card"><div class="card-header">Concessions</div>${T.table([{ label: "Type", render: (d) => T.label(d.discount_type) }, { label: "Value", render: (d) => (d.discount_type === "percentage" ? d.value + "%" : d.discount_type === "full_waiver" ? "100%" : T.inr(d.value)) }, { label: "Reason", key: "reason", cls: "wrap" }, { label: "Status", render: (d) => T.badge(d.status) }, { label: "Date", render: (d) => T.dmy(d.created_at) }], disc)}</div>` : "");
        el.querySelectorAll("[data-editfee]").forEach((b) => (b.onclick = () => T.fees.editFee(b.dataset.editfee, reload)));
      } },
      { label: "Transactions", icon: "receipt", render: async (el) => {
        if (!T.can("view_fee_amounts")) { el.innerHTML = noPerm("View Fee Amounts"); return; }
        const rows = await T.q(window.sb.from("payments").select("id,receipt_no,txn_id,amount,payment_date,mode,status,reference,academic_sessions(name)").eq("student_id", id).order("created_at", { ascending: false }));
        el.innerHTML = `<div class="card">${T.table([{ label: "Date", render: (p) => T.dmy(p.payment_date) }, { label: "Session", render: (p) => T.esc(p.academic_sessions?.name) }, { label: "Receipt", key: "receipt_no" }, { label: "Txn ID", key: "txn_id" }, { label: "Mode", render: (p) => T.esc(T.MODES[p.mode]) }, { label: "Amount", cls: "text-end money", render: (p) => T.inr(p.amount) }, { label: "Status", render: (p) => T.badge(p.status) }], rows, { empty: "No transactions" })}</div>`;
      } },
      { label: "Receipts", icon: "file-earmark-text", render: async (el) => {
        if (!T.can("print_receipt") || !T.can("view_fee_amounts")) { el.innerHTML = noPerm("Print Receipt"); return; }
        const rows = await T.q(window.sb.from("payments").select("id,receipt_no,amount,payment_date,status").eq("student_id", id).neq("status", "rejected").order("created_at", { ascending: false }));
        el.innerHTML = `<div class="card">${T.table([{ label: "Receipt", key: "receipt_no" }, { label: "Date", render: (p) => T.dmy(p.payment_date) }, { label: "Amount", cls: "text-end money", render: (p) => T.inr(p.amount) }, { label: "Status", render: (p) => T.badge(p.status) }, { label: "", render: (p) => `<button class="btn btn-sm btn-outline-primary" data-rc="${p.id}"><i class="bi bi-printer me-1"></i>View</button>` }], rows, { empty: "No receipts" })}</div>`;
        el.querySelectorAll("[data-rc]").forEach((b) => (b.onclick = () => T.receipts.show(b.dataset.rc)));
      } },
      { label: "Calling History", icon: "telephone", render: async (el) => {
        if (!T.can("view_calling_crm")) { el.innerHTML = noPerm("View Calling CRM"); return; }
        const j = await T.rpc("calls_list", { p_session: T.state.session, p_student: id, p_limit: 100 });
        el.innerHTML = `<div class="card">${T.table([{ label: "When", render: (c) => T.dmyTime(c.called_at) }, { label: "Teacher", key: "teacher_name" }, { label: "Status", render: (c) => T.badge(c.connected ? "verified" : "pending", T.CALL_STATUS[c.call_status]) }, { label: "Remark", key: "remark", cls: "wrap" }, { label: "Promise", render: (c) => T.dmy(c.promised_date) }, { label: "Next follow-up", render: (c) => T.dmy(c.next_followup_date) }], j.rows, { empty: "No calls recorded in this session" })}</div>`;
      } },
      { label: "Remarks", icon: "chat-left-text", render: (el) => (el.innerHTML = `<div class="card"><div class="card-body">${s.remarks ? T.esc(s.remarks) : '<span class="text-muted">No remarks.</span>'}</div></div>`) },
      { label: "Audit History", icon: "clock-history", render: async (el) => {
        if (!T.can("view_audit_logs")) { el.innerHTML = noPerm("View Audit Logs"); return; }
        const rows = await T.q(window.sb.from("audit_logs").select("*").eq("record_id", id).order("created_at", { ascending: false }).limit(100));
        el.innerHTML = `<div class="card">${T.table([{ label: "When", render: (r) => T.dmyTime(r.created_at) }, { label: "Action", render: (r) => `<code>${T.esc(r.action)}</code>` }, { label: "Reason", key: "reason" }, { label: "Changed", cls: "wrap", render: (r) => { const o = r.old_values || {}, n = r.new_values || {}; const ch = Object.keys(n).filter((k) => JSON.stringify(o[k]) !== JSON.stringify(n[k]) && !["updated_at"].includes(k)); return r.old_values ? ch.map((k) => `<span class="small"><b>${T.esc(k)}</b>: ${T.esc(o[k] ?? "∅")} → ${T.esc(n[k] ?? "∅")}</span>`).join("<br>") : "created"; } }], rows, { empty: "No audit entries" })}</div>`;
      } },
    ];
    T.tabs(root.querySelector("#pf-tabs"), tabs, Number(ctx.query?.tab) || 0);
  };

  /* ---------------- BULK IMPORT ---------------- */
  const IMPORT_FIELDS = [
    ["name", "Student Name", ["student name", "name", "student"], true], ["father_name", "Father Name", ["father name", "father", "fathers name"]],
    ["mother_name", "Mother Name", ["mother name", "mother"]], ["admission_no", "Admission No", ["admission no", "admission number", "adm no", "admno", "admission_no"], true],
    ["class_name", "Class", ["class", "class name", "grade"], true], ["section", "Section", ["section", "sec"]], ["roll_no", "Roll No", ["roll no", "roll", "roll number"]],
    ["mobile", "Mobile", ["mobile", "mobile number", "phone", "contact"], true], ["address", "Address", ["address"]], ["admission_date", "Admission Date", ["admission date", "doa", "date of admission"]],
    ["rte_status", "RTE Status", ["rte status", "rte"]], ["family_ref", "Family ID", ["family id", "family", "family ref"]], ["annual_fee", "Annual Fee", ["annual fee", "fee", "total fee"]],
  ];
  const CLASS_OK = (c) => { const x = String(c || "").toLowerCase().trim(); if (["nursery", "nur", "lkg", "ukg"].includes(x)) return true; const n = parseInt(x.replace(/\D/g, ""), 10); return n >= 1 && n <= 12; };
  const normMobile = (m) => { let d = String(m || "").replace(/\D/g, ""); if (d.length === 12 && d.startsWith("91")) d = d.slice(2); if (d.length === 11 && d.startsWith("0")) d = d.slice(1); return d; };
  const excelDate = (v) => { if (v instanceof Date) return v.toISOString().slice(0, 10); if (typeof v === "number" && v > 20000) return new Date(Math.round((v - 25569) * 86400 * 1000)).toISOString().slice(0, 10); const m = String(v || "").trim().match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/); return m ? `${m[3]}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}` : String(v || "").trim(); };

  T.pages["students/import"] = async (root) => {
    if (!T.can("import_students")) { root.innerHTML = T.errorBox(new Error("You do not have permission to import students.")); return; }
    let raw = [], headers = [], map = {}, rows = [], fileInfo = null;
    root.innerHTML = `<div class="page-h"><div><h1>Import Students</h1><div class="sub">CSV or Excel (.xlsx). Session: <b>${T.esc(T.sessions.current()?.name || "—")}</b></div></div><a href="#/students" class="btn btn-light"><i class="bi bi-arrow-left me-1"></i>Back</a></div>
      <div class="card mb-3"><div class="card-body"><ol class="mb-3"><li>Download the template and fill one student per row.</li><li>Upload the file, check column mapping and fix any highlighted rows.</li><li>Import. Re-uploading the same file never creates duplicates.</li></ol>
        <div class="d-flex flex-wrap gap-2 align-items-center"><button class="btn btn-outline-primary" id="im-tpl"><i class="bi bi-download me-1"></i>Download CSV template</button><input type="file" id="im-file" class="form-control" style="max-width:340px" accept=".csv,.xlsx,.xls"></div></div></div><div id="im-body"></div>`;
    const body = root.querySelector("#im-body");
    root.querySelector("#im-tpl").onclick = () => T.reports.csv("students-import-template.csv", IMPORT_FIELDS.map((f) => f[1]), [["Prem Janghela", "Ramesh Janghela", "Sunita Janghela", "A-1001", "Class 8", "A", "12", "9876543210", "Gumgaon", "2026-04-10", "No", "FAM-001", "9000"], ["Rahul", "Vijay Singh", "", "A-1002", "Class 4", "A", "5", "9876543211", "Bhuni", "2026-04-12", "Yes", "", ""]], "template", true);

    const autoMap = () => { map = {}; IMPORT_FIELDS.forEach(([k, , alias]) => { const h = headers.find((x) => alias.includes(String(x).toLowerCase().trim().replace(/\s+/g, " "))); if (h !== undefined) map[k] = h; }); };
    const build = () => { rows = raw.map((r, i) => { const o = { _row: i + 2 }; IMPORT_FIELDS.forEach(([k]) => { let v = map[k] !== undefined ? r[map[k]] : ""; if (k === "admission_date") v = excelDate(v); o[k] = v === undefined || v === null ? "" : String(v).trim(); }); return o; }); };
    const validate = (r, seen) => {
      const e = [];
      if (!r.name) e.push("Student Name is required");
      if (!r.admission_no) e.push("Admission No is required");
      if (!r.class_name || !CLASS_OK(r.class_name)) e.push("Invalid class");
      const m = normMobile(r.mobile);
      if (!m) e.push("Parent mobile is required"); else if (!/^[6-9]\d{9}$/.test(m)) e.push("Invalid mobile");
      if (r.annual_fee !== "" && !/^\d+(\.\d+)?$/.test(String(r.annual_fee).replace(/[₹,\s]/g, ""))) e.push("Invalid annual fee");
      if (r.admission_date && !/^\d{4}-\d{2}-\d{2}$/.test(r.admission_date)) e.push("Admission date must be YYYY-MM-DD");
      if (r.admission_no) { if (seen.has(r.admission_no.toLowerCase())) e.push("Duplicate admission no inside file"); seen.add(r.admission_no.toLowerCase()); }
      return e;
    };
    const render = () => {
      const seen = new Set(); rows.forEach((r) => (r._err = validate(r, seen)));
      const bad = rows.filter((r) => r._err.length), good = rows.length - bad.length;
      body.innerHTML = `<div class="card mb-3"><div class="card-header">1. Column mapping</div><div class="card-body row g-2">${IMPORT_FIELDS.map(([k, l, , req]) => `<div class="col-6 col-md-3"><label class="form-label small mb-0">${l}${req ? " *" : ""}</label><select class="form-select form-select-sm mp" data-k="${k}"><option value="">— not mapped —</option>${headers.map((h) => `<option ${map[k] === h ? "selected" : ""}>${T.esc(h)}</option>`).join("")}</select></div>`).join("")}</div></div>
        <div class="card"><div class="card-header d-flex flex-wrap justify-content-between gap-2"><span>2. Preview &amp; correct — <span class="text-success">${good} valid</span>, <span class="text-danger">${bad.length} with errors</span> of ${rows.length}</span><div class="d-flex gap-2"><button class="btn btn-sm btn-outline-danger" id="im-dl-bad" ${bad.length ? "" : "disabled"}><i class="bi bi-download me-1"></i>Rejected rows</button><button class="btn btn-sm btn-success" id="im-go" ${good ? "" : "disabled"}><i class="bi bi-cloud-upload me-1"></i>Import ${good} valid rows</button></div></div>
        <div class="tbl-wrap" style="max-height:480px"><table class="table table-sm table-hover mb-0"><thead><tr><th>#</th>${IMPORT_FIELDS.map((f) => `<th>${f[1]}</th>`).join("")}<th>Problems</th></tr></thead><tbody>${rows.slice(0, 500).map((r, i) => `<tr class="${r._err.length ? "table-danger" : ""}"><td>${r._row}</td>${IMPORT_FIELDS.map(([k]) => `<td><input class="form-control form-control-sm ce" style="min-width:${k === "name" || k === "address" ? 150 : 90}px" data-i="${i}" data-k="${k}" value="${T.esc(r[k])}"></td>`).join("")}<td class="wrap small text-danger">${T.esc(r._err.join("; "))}</td></tr>`).join("")}</tbody></table></div>${rows.length > 500 ? `<div class="p-2 small text-muted">Showing first 500 rows for editing; all ${rows.length} rows are validated and imported.</div>` : ""}</div><div id="im-result" class="mt-3"></div>`;
      body.querySelectorAll(".mp").forEach((s) => (s.onchange = () => { s.value ? (map[s.dataset.k] = s.value) : delete map[s.dataset.k]; build(); render(); }));
      body.querySelectorAll(".ce").forEach((inp) => (inp.onchange = () => { rows[+inp.dataset.i][inp.dataset.k] = inp.value.trim(); render(); }));
      body.querySelector("#im-dl-bad").onclick = () => T.reports.csv("rejected-rows.csv", ["Row", ...IMPORT_FIELDS.map((f) => f[1]), "Reason"], bad.map((r) => [r._row, ...IMPORT_FIELDS.map(([k]) => r[k]), r._err.join("; ")]), "rejected", true);
      body.querySelector("#im-go").onclick = (ev) => T.busy(ev.currentTarget, doImport);
    };
    const doImport = async () => {
      const sess = T.sessions.current();
      if (!sess || sess.status !== "open") return T.toast("Select an open session first", "warn");
      const valid = rows.filter((r) => !r._err.length), invalid = rows.filter((r) => r._err.length);
      const out = body.querySelector("#im-result"); out.innerHTML = `<div class="alert alert-info">Importing…</div>`;
      try {
        const start = await T.rpc("start_import", { p_session: T.state.session, p_filename: fileInfo.name, p_file_hash: fileInfo.hash, p_total: rows.length });
        if (start.previous_import_at && !(await T.confirm({ title: "This file was imported before", message: `The same file was already imported on ${T.dmyTime(start.previous_import_at)}. Existing students will be skipped (no duplicates will be created). Continue?` }))) { out.innerHTML = ""; return; }
        let imp = 0, skip = 0, fail = 0;
        for (let i = 0; i < valid.length; i += 100) {
          const chunk = valid.slice(i, i + 100).map((r) => ({ ...r, mobile: normMobile(r.mobile), annual_fee: String(r.annual_fee).replace(/[₹,\s]/g, ""), _err: undefined }));
          const res = await T.rpc("import_students_batch", { p_batch: start.batch_id, p_rows: chunk }, { mutates: true });
          imp += res.imported; skip += res.skipped; fail += res.failed;
          out.innerHTML = `<div class="alert alert-info">Imported ${Math.min(i + 100, valid.length)} / ${valid.length}…</div>`;
        }
        const sum = await T.rpc("finish_import", { p_batch: start.batch_id });
        const errs = await T.q(window.sb.from("import_errors").select("row_no,errors,kind,raw").eq("batch_id", start.batch_id).order("row_no"));
        out.innerHTML = `<div class="card"><div class="card-header">Import summary</div><div class="card-body"><div class="row g-3 text-center"><div class="col"><div class="h3 text-success">${imp}</div>Imported</div><div class="col"><div class="h3 text-warning">${skip}</div>Skipped (already present)</div><div class="col"><div class="h3 text-danger">${fail + invalid.length}</div>Rejected</div><div class="col"><div class="h3">${rows.length}</div>Total rows</div></div>
          ${errs.length + invalid.length ? `<button class="btn btn-outline-danger mt-3" id="im-rej"><i class="bi bi-download me-1"></i>Download rejected / skipped rows with reasons</button>` : ""}<a href="#/students" class="btn btn-primary mt-3 ms-2">View students</a></div></div>`;
        const rej = out.querySelector("#im-rej");
        if (rej) rej.onclick = () => T.reports.csv("import-rejected.csv", ["Row", "Student Name", "Admission No", "Class", "Result", "Reason"],
          [...invalid.map((r) => [r._row, r.name, r.admission_no, r.class_name, "Rejected", r._err.join("; ")]), ...errs.map((e) => [e.row_no, e.raw?.name, e.raw?.admission_no, e.raw?.class_name, e.kind === "duplicate" ? "Skipped" : "Rejected", e.errors.join("; ")])], "rejected", true);
        T.ok("Import finished");
      } catch (e) { out.innerHTML = T.errorBox(e); }
    };
    root.querySelector("#im-file").onchange = async (ev) => {
      const file = ev.target.files[0]; if (!file) return;
      if (!window.XLSX) return T.toast("Spreadsheet library failed to load. Check your internet connection.", "err");
      if (file.size > 8 * 1024 * 1024) return T.toast("File is larger than 8 MB.", "warn");
      try {
        const buf = await file.arrayBuffer();
        const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", buf))).map((b) => b.toString(16).padStart(2, "0")).join("");
        const wb = XLSX.read(buf, { type: "array", cellDates: true, raw: false, dateNF: "yyyy-mm-dd" });
        const ws = wb.Sheets[wb.SheetNames[0]];
        raw = XLSX.utils.sheet_to_json(ws, { defval: "", raw: false });
        if (!raw.length) return T.toast("The file has no data rows.", "warn");
        if (raw.length > 5000) return T.toast("Please import at most 5,000 rows per file.", "warn");
        headers = Object.keys(raw[0]); fileInfo = { name: file.name, hash };
        autoMap(); build(); render();
      } catch (e) { T.fail(e); }
    };
  };
})();
