/* Authentication, session guard, logout / account switching. */
(function () {
  const T = window.T;
  T.auth = {
    requireConfig() {
      if (!window.TCONFIG.configured || !window.sb) {
        document.body.innerHTML = `<div class="auth-wrap"><div class="card auth-card"><div class="card-body p-4"><h5 class="text-danger"><i class="bi bi-gear me-2"></i>Supabase is not configured</h5>
        <p>Open <code>js/supabase-config.js</code> and paste your <b>Project URL</b> and <b>anon / publishable key</b>. See SETUP-GUIDE.md.</p></div></div></div>`;
        throw new Error("Supabase not configured");
      }
    },
    async signIn(email, password) {
      const { data, error } = await window.sb.auth.signInWithPassword({ email: email.trim(), password });
      if (error) throw new Error(/invalid login/i.test(error.message) ? "Incorrect email or password." : T.errMsg(error));
      T.cache.clear();
      T.state.user = data.user;
      const access = await T.rpc("my_access");
      if (!access.is_super_admin && !access.school_id) {
        await window.sb.auth.signOut();
        const p = access.pending_registration;
        if (p?.status === "pending") throw new Error(`Your registration for "${p.school_name}" is still pending Super Admin approval. You will be able to sign in once it is approved.`);
        if (p?.status === "rejected") throw new Error(`Your school registration was rejected${p.reason ? ": " + p.reason : ""}. Please contact the platform administrator.`);
        throw new Error("This account has no active school access. The school may be suspended, expired or your account was deactivated.");
      }
      try { await window.sb.rpc("log_audit", { p_action: "login", p_record_type: "session", p_details: null }); } catch (_) {}
      return access;
    },
    /** Called by protected pages. Redirects to login when there is no valid session. */
    async guard({ superAdminPage = false } = {}) {
      T.auth.requireConfig();
      const { data } = await window.sb.auth.getSession();
      if (!data.session) { location.replace(superAdminPage ? "../login.html" : "login.html"); throw new Error("redirect"); }
      // account switching safety: wipe any cached data belonging to another user
      const prev = sessionStorage.getItem("trollify:uid");
      if (prev && prev !== data.session.user.id) { T.cache.clear(); }
      sessionStorage.setItem("trollify:uid", data.session.user.id);
      T.state.user = data.session.user;
      let access;
      try { access = await T.rpc("my_access"); } catch (e) { await window.sb.auth.signOut(); location.replace(superAdminPage ? "../login.html" : "login.html"); throw e; }
      T.state.access = access;
      if (superAdminPage && !access.is_super_admin) { location.replace("../app.html"); throw new Error("redirect"); }
      if (!superAdminPage && !access.school_id) {
        if (access.is_super_admin) { location.replace("super-admin/index.html"); throw new Error("redirect"); }
        await window.sb.auth.signOut(); location.replace("login.html"); throw new Error("redirect");
      }
      window.sb.auth.onAuthStateChange((ev, s) => {
        if (ev === "SIGNED_OUT" || (s && s.user.id !== T.state.user.id)) { T.cache.clear(); location.replace(superAdminPage ? "../login.html" : "login.html"); }
      });
      return access;
    },
    async logout() {
      try { await window.sb.rpc("log_audit", { p_action: "logout", p_record_type: "session", p_details: null }); } catch (_) {}
      T.cache.clear();
      try { sessionStorage.clear(); } catch (_) {}
      await window.sb.auth.signOut();
      location.replace(location.pathname.includes("/super-admin/") ? "../login.html" : "login.html");
    },
  };
})();
