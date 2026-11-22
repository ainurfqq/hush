/**
 * Hush waitlist: the sign-up form on the Hush page posts here; each sign-up becomes one row in this Sheet.
 * Deployed as a web app (execute as the owner, anyone can post). No personal data is returned to the caller.
 */
const SHEET_NAME = 'Sign-ups';
const HEADERS = ['Time', 'Email', 'Computer', 'Meeting apps', 'Use for', 'Source', 'Consent'];

function doPost(e) {
  const p = (e && e.parameter) || {};
  if (p.website) return json_({ ok: true });                       // honeypot field: bots fill it, people never see it
  const email = String(p.email || '').trim().toLowerCase().slice(0, 200);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return json_({ ok: false, error: 'email' });
  if (p.consent !== 'yes') return json_({ ok: false, error: 'consent' });
  if (tooMany_()) return json_({ ok: false, error: 'busy' });          // spam flood guard: 30 sign-ups a minute in total

  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    const sh = sheet_();
    const last = sh.getLastRow();
    const known = last > 1 ? sh.getRange(2, 2, last - 1, 1).getValues().map(r => String(r[0])) : [];
    if (known.indexOf(email) === -1) {
      sh.appendRow([new Date(), email, cell_(p.os), cell_(p.apps), cell_(p.use, 500), cell_(p.source), 'yes']);
    }
  } finally {
    lock.releaseLock();
  }
  return json_({ ok: true });
}

function tooMany_() {
  const c = CacheService.getScriptCache(), key = 'n' + Math.floor(Date.now() / 60000);
  const n = Number(c.get(key) || 0) + 1;
  c.put(key, String(n), 120);
  return n > 30;
}

/** A GET shows that the endpoint is alive, nothing else. */
function doGet() { return json_({ ok: true, service: 'hush-waitlist' }); }

function sheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(SHEET_NAME);
  if (!sh) {
    sh = ss.insertSheet(SHEET_NAME);
    sh.appendRow(HEADERS);
    sh.setFrozenRows(1);
    sh.getRange(1, 1, 1, HEADERS.length).setFontWeight('bold');
  }
  return sh;
}

/** Trims, caps length, and stops text that starts with = + - @ from running as a formula. */
function cell_(v, max) {
  let s = String(v || '').replace(/[\r\n\t]+/g, ' ').trim().slice(0, max || 120);
  if (/^[=+\-@]/.test(s)) s = "'" + s;
  return s;
}

function json_(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }

/** Run once from the editor to grant access and create the header row. */
function setup() { sheet_(); }
