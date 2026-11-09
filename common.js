// أدوات مشتركة بين صفحة الإدارة وصفحة الفرع
const CFG = window.APP_CONFIG || {};
const sb = window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY);

const TZ = 'Asia/Riyadh';
const AR = 'ar-SA-u-ca-gregory-nu-latn';

// ---------- التواريخ (نصوص بصيغة YYYY-MM-DD) ----------
function todayISO() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
}
function parseISO(s) { const [y, m, d] = s.split('-').map(Number); return new Date(Date.UTC(y, m - 1, d)); }
function toISO(dt) { return dt.toISOString().slice(0, 10); }
function addDays(s, n) { const d = parseISO(s); d.setUTCDate(d.getUTCDate() + n); return toISO(d); }
function addMonths(s, n) { const d = parseISO(s.slice(0, 8) + '01'); d.setUTCMonth(d.getUTCMonth() + n); return toISO(d); }
function monthStart(s) { return s.slice(0, 8) + '01'; }
function monthEnd(s) { const d = parseISO(monthStart(s)); d.setUTCMonth(d.getUTCMonth() + 1); d.setUTCDate(0); return toISO(d); }
function daysRange(a, b) { const out = []; for (let s = a; s <= b; s = addDays(s, 1)) out.push(s); return out; }
function minISO(a, b) { return a < b ? a : b; }

function fmtDate(s, opts) { return new Intl.DateTimeFormat(AR, { timeZone: 'UTC', ...opts }).format(parseISO(s)); }
const fmtLong  = s => fmtDate(s, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
const fmtShort = s => fmtDate(s, { day: 'numeric', month: 'long' });
const fmtDayName = s => fmtDate(s, { weekday: 'long' });
const fmtMonth = s => fmtDate(s, { month: 'long', year: 'numeric' });
function fmtStamp(ts) {
  return new Intl.DateTimeFormat(AR, { timeZone: TZ, day: 'numeric', month: 'long', hour: 'numeric', minute: '2-digit' }).format(new Date(ts));
}

// ---------- الأرقام ----------
const NUM = new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 });
function money(n) { return NUM.format(Number(n) || 0); }
// يقبل الأرقام العربية والفواصل: "١٢٬٥٠٠٫٥" => 12500.5
function parseAmount(str) {
  if (str == null) return NaN;
  let s = String(str).trim()
    .replace(/[٠-٩]/g, d => '٠١٢٣٤٥٦٧٨٩'.indexOf(d))
    .replace(/[۰-۹]/g, d => '۰۱۲۳۴۵۶۷۸۹'.indexOf(d))
    .replace(/٫/g, '.').replace(/[,٬\s]/g, '');
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return NaN;
  return Number(s);
}

// ---------- واجهة ----------
function esc(s) { return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function errMsg(e) { return (e && (e.message || e.error_description)) || 'تعذّر الاتصال. تحقق من الإنترنت وحاول مرة أخرى.'; }
function toast(msg, type = 'ok') {
  let wrap = document.getElementById('toasts');
  if (!wrap) { wrap = document.createElement('div'); wrap.id = 'toasts'; wrap.className = 'toast-wrap'; document.body.appendChild(wrap); }
  const t = document.createElement('div');
  t.className = 'toast toast-' + type;
  t.setAttribute('role', 'status');
  t.textContent = msg;
  wrap.appendChild(t);
  setTimeout(() => { t.classList.add('out'); setTimeout(() => t.remove(), 300); }, 3800);
}
