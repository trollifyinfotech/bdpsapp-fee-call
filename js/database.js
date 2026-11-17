/* Core helpers: namespace, formatting, database access (all through Supabase RPC / RLS). */
(function () {
  const T = (window.T = window.T || {});
  T.state = { access: null, session: null, sessions: [], user: null };

  /* ---------- formatting ---------- */
  T.esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const inrFmt = new Intl.NumberFormat("en-IN", { minimumFractionDigits: 0, maximumFractionDigits: 2 });
  T.num = (n) => inrFmt.format(Number(n || 0));
  T.inr = (n) => (n === null || n === undefined ? "—" : "₹" + inrFmt.format(Number(n)));
  T.inrPlain = (n) => "Rs. " + inrFmt.format(Number(n || 0)); // PDFs: default fonts lack the ₹ glyph
  T.dmy = (d) => {
    if (!d) return "—";
    const x = typeof d === "string" && /^\d{4}-\d{2}-\d{2}$/.test(d) ? new Date(d + "T00:00:00") : new Date(d);
    if (isNaN(x)) return "—";
    return String(x.getDate()).padStart(2, "0") + "/" + String(x.getMonth() + 1).padStart(2, "0") + "/" + x.getFullYear();
  };
  T.dmyTime = (d) => {
    if (!d) return "—";
    const x = new Date(d);
    return T.dmy(x) + " " + x.toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit", hour12: true });
  };
  T.today = () => {
    const x = new Date(Date.now() + 5.5 * 3600 * 1000); // India date regardless of device zone
    return x.toISOString().slice(0, 10);
  };
  T.addDays = (iso, n) => { const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  T.label = (s) => String(s ?? "").replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
  T.debounce = (fn, ms = 350) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
  T.uuid = () => (crypto.randomUUID ? crypto.randomUUID() : "k" + Date.now() + Math.random().toString(16).slice(2));
  T.phone = (m) => { const d = String(m || "").replace(/\D/g, ""); return d.length === 10 ? "+91" + d : d.length > 10 ? "+" + d : d; };

  const ones = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen"];
  const tens = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"];
  const two = (n) => (n < 20 ? ones[n] : tens[Math.floor(n / 10)] + (n % 10 ? " " + ones[n % 10] : ""));
  const three = (n) => (n >= 100 ? ones[Math.floor(n / 100)] + " Hundred" + (n % 100 ? " " + two(n % 100) : "") : two(n));
  T.words = (amount) => {
    let n = Math.floor(Number(amount || 0));
    const paise = Math.round((Number(amount || 0) - n) * 100);
    if (n === 0 && !paise) return "Zero Rupees Only";
    const parts = [];
    const cr = Math.floor(n / 1e7); n %= 1e7;
    const lk = Math.floor(n / 1e5); n %= 1e5;
    const th = Math.floor(n / 1e3); n %= 1e3;
    if (cr) parts.push(three(cr) + " Crore");
    if (lk) parts.push(two(lk) + " Lakh");
    if (th) parts.push(two(th) + " Thousand");
    if (n) parts.push(three(n));
    let s = parts.join(" ") + " Rupees";
    if (paise) s += " and " + two(paise) + " Paise";
    return s + " Only";
  };

  /* ---------- per-user, per-session cache (cleared on logout, session switch and every mutation) ---------- */
  const cache = new Map();
  T.cache = {
    key: (k) => (T.state.user?.id || "anon") + "|" + (T.state.session || "") + "|" + k,
    async get(k, fn, ttl = 30000) {
      const key = T.cache.key(k), hit = cache.get(key);
      if (hit && Date.now() - hit.t < ttl) return hit.v;
      const v = await fn();
      cache.set(key, { t: Date.now(), v });
      return v;
    },
    clear() { cache.clear(); },
  };

  /* ---------- database ---------- */
  T.errMsg = (e) => {
    let m = (e && (e.message || e.error_description || e.details)) || String(e || "Unknown error");
    if (/JWT expired|invalid.*token/i.test(m)) m = "Your session expired. Please sign in again.";
    if (/duplicate key.*admission_no|students_school_id_admission_no_key/i.test(m)) m = "This admission number already exists.";
    if (/duplicate key/i.test(m)) m = "A record with the same unique value already exists.";
    if (/violates row-level security/i.test(m)) m = "You do not have permission to perform this action.";
    if (/permission denied/i.test(m) && !/Permission denied:/.test(m)) m = "You do not have permission to perform this action.";
    return m.replace(/^Error:\s*/, "");
  };
  T.rpc = async (fn, args = {}, opts = {}) => {
    const { data, error } = await window.sb.rpc(fn, args);
    if (error) { const err = new Error(T.errMsg(error)); err.code = error.code; throw err; }
    if (opts.mutates) T.cache.clear();
    return data;
  };
  /** Run a PostgREST query builder and throw a friendly error */
  T.q = async (builder) => {
    const { data, error, count } = await builder;
    if (error) throw new Error(T.errMsg(error));
    return count !== undefined && count !== null ? { data, count } : data;
  };
  T.mutate = async (builder) => { const r = await T.q(builder); T.cache.clear(); return r; };

  T.sessions = {
    async load() {
      const rows = await T.q(window.sb.from("academic_sessions").select("*").order("start_date", { ascending: false }));
      T.state.sessions = rows;
      const key = "trollify:" + (T.state.user?.id || "") + ":session";
      let saved = null; try { saved = localStorage.getItem(key); } catch (_) {}
      const pick = rows.find((s) => s.id === saved) || rows.find((s) => s.is_active) || rows[0];
      T.state.session = pick ? pick.id : null;
      return rows;
    },
    current: () => T.state.sessions.find((s) => s.id === T.state.session) || null,
    set(id) {
      T.state.session = id; T.cache.clear();
      try { localStorage.setItem("trollify:" + (T.state.user?.id || "") + ":session", id); } catch (_) {}
    },
  };

  T.schoolId = () => T.state.access?.school_id;
  T.logoUrl = (path) => (path && window.sb ? window.sb.storage.from("school-logos").getPublicUrl(path).data.publicUrl : null);

  /** Upload to a private bucket under <school_id>/..., returns the storage path */
  T.upload = async (bucket, file, prefix = "") => {
    if (!file) return null;
    const ext = (file.name.split(".").pop() || "bin").toLowerCase().replace(/[^a-z0-9]/g, "");
    const path = `${T.schoolId()}/${prefix}${prefix ? "/" : ""}${T.uuid()}.${ext}`;
    const { error } = await window.sb.storage.from(bucket).upload(path, file, { contentType: file.type, upsert: false });
    if (error) throw new Error(T.errMsg(error));
    return path;
  };
  T.signedUrl = async (bucket, path) => {
    const { data, error } = await window.sb.storage.from(bucket).createSignedUrl(path, 300);
    if (error) throw new Error(T.errMsg(error));
    return data.signedUrl;
  };

  T.CLASSES = ["Nursery", "LKG", "UKG", ...Array.from({ length: 12 }, (_, i) => "Class " + (i + 1))];
  T.CATEGORIES = { general: "General", rte: "RTE", scholarship: "Scholarship", full_waiver: "Full Fee Waiver", partial_waiver: "Partial Fee Waiver", staff_ward: "Staff Ward", sibling_concession: "Sibling Concession", custom: "Custom Category" };
  T.MODES = { cash: "Cash", upi: "UPI", bank_transfer: "Bank Transfer", cheque: "Cheque", card: "Card", other: "Other" };
  T.CALL_STATUS = { connected: "Connected", not_answered: "Not Answered", busy: "Busy", switched_off: "Switched Off", wrong_number: "Wrong Number", callback_requested: "Call Back Requested", promised_to_pay: "Parent Promised to Pay", refused: "Parent Refused", payment_done: "Payment Already Done", dispute: "Dispute / Fee Issue", other: "Other" };
  T.ROLES = { school_owner: "School Owner", principal: "Principal", accountant: "Accountant", fee_manager: "Fee Manager", teacher: "Teacher", viewer: "Viewer / Auditor" };
  T.classRank = (c) => T.CLASSES.indexOf(c);
})();
