/* =====================================================================
 * TROLLIFY - central Supabase configuration (the ONLY place to edit).
 * Paste your project values from Supabase Dashboard > Project Settings > API.
 * Use the "anon / publishable" key. NEVER put the service_role / secret key here.
 * ===================================================================== */
const SUPABASE_URL = "https://qrfsowovwnsazrimorgg.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFyZnNvd292d25zYXpyaW1vcmdnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ5MjQwNTEsImV4cCI6MjExMDUwMDA1MX0._9AVnfVN2YtKM0e0T6dYbl4CUwRr1OqRguISRV8G47I";

window.TCONFIG = {
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  configured: !SUPABASE_URL.startsWith("PASTE_") && !SUPABASE_ANON_KEY.startsWith("PASTE_"),
  APP_NAME: "Trollify School Fee & Recovery",
  PAGE_SIZE: 25,
};

if (window.TCONFIG.configured && window.supabase) {
  window.sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false, storageKey: "trollify-auth" },
  });
} else {
  window.sb = null;
}
