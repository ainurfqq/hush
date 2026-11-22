/**
 * Hush waitlist: the sign-up form on the Hush page posts here; each sign-up becomes one row in this Sheet.
 * Deployed as a web app (execute as the owner, anyone can post). No personal data is returned to the caller.
 * Apple Silicon Mac sign-ups get one email with the download link, so a phone sign-up can install on the Mac later.
 */
const SHEET_NAME = 'Sign-ups';
const HEADERS = ['Time', 'Email', 'Computer', 'Meeting apps', 'Use for', 'Source', 'Consent', 'Email sent'];
const SENT_COL = 8;
const DMG_URL = 'https://github.com/ainurfqq/hush/releases/latest/download/Hush.dmg';

function doPost(e) {
  const p = (e && e.parameter) || {};
  if (p.website) return json_({ ok: true });                       // honeypot field: bots fill it, people never see it
  const email = String(p.email || '').trim().toLowerCase().slice(0, 200);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return json_({ ok: false, error: 'email' });
  if (p.consent !== 'yes') return json_({ ok: false, error: 'consent' });
  if (tooMany_()) return json_({ ok: false, error: 'busy' });          // spam flood guard: 30 sign-ups a minute in total

  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  let row = 0;
  const mac = p.os === 'mac-apple-silicon';
  try {
    const sh = sheet_();
    const last = sh.getLastRow();
    const known = last > 1 ? sh.getRange(2, 2, last - 1, 1).getValues().map(r => String(r[0])) : [];
    if (known.indexOf(email) === -1) {          // one email per address, ever: a repeat sign-up sends nothing
      sh.appendRow([new Date(), email, cell_(p.os), cell_(p.apps), cell_(p.use, 500), cell_(p.source), 'yes', mac ? 'pending' : '']);
      row = sh.getLastRow();
    }
  } finally {
    lock.releaseLock();
  }
  if (row && mac) trySend_(sheet_(), row, email);
  return json_({ ok: true });
}

/** Sends the download email if today's Gmail quota allows; otherwise the row stays "pending" for sendPending. */
function trySend_(sh, row, email) {
  if (MailApp.getRemainingDailyQuota() < 1) return false;
  try {
    MailApp.sendEmail({ to: email, subject: 'Link download Hush untuk Mac', name: 'Hush', body: mailText_(), htmlBody: mailHtml_() });
    sh.getRange(row, SENT_COL).setValue(new Date());
    return true;
  } catch (err) {
    sh.getRange(row, SENT_COL).setValue('pending');
    return false;
  }
}

/** Daily trigger (made by setup): sends the emails that hit the 100-a-day limit. */
function sendPending() {
  const sh = sheet_(), last = sh.getLastRow();
  if (last < 2) return;
  const rows = sh.getRange(2, 1, last - 1, SENT_COL).getValues();
  for (let i = 0; i < rows.length; i++) {
    if (rows[i][SENT_COL - 1] === 'pending' && !trySend_(sh, i + 2, String(rows[i][1]))) break;
  }
}

function mailText_() {
  return [
    'Terima kasih sudah daftar Hush.',
    '',
    'Buka email ini di Mac kamu, lalu unduh Hush di sini:',
    DMG_URL,
    '',
    'Cara memasang (cukup sekali):',
    '1. Buka file Hush.dmg, lalu seret Hush ke folder Applications.',
    '2. Buka Hush dari Applications. Mac akan bilang Apple tidak bisa memeriksa Hush. Klik Done.',
    '3. Buka System Settings, pilih Privacy & Security, gulir ke bawah, lalu klik Open Anyway. Masukkan password Mac.',
    '',
    'Peringatan itu muncul karena Hush belum terdaftar berbayar di Apple. Kodenya terbuka di https://github.com/ainurfqq/hush',
    'Saat pertama dibuka, Hush mengunduh model suara sekitar 800 MB. Versi baru nanti terpasang dari dalam aplikasi.',
    '',
    'Butuh Mac M1 atau lebih baru, dengan macOS 14.4 ke atas.',
    'Ada kendala? Balas saja email ini.',
  ].join('\n');
}

function mailHtml_() {
  return '<div style="font:16px/1.6 -apple-system,Helvetica,Arial,sans-serif;color:#1E1E22;max-width:520px">' +
    '<p>Terima kasih sudah daftar Hush.</p>' +
    '<p>Buka email ini di Mac kamu, lalu unduh Hush:</p>' +
    '<p><a href="' + DMG_URL + '" style="display:inline-block;background:#4B4BC8;color:#fff;text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:600">Unduh Hush untuk Mac</a></p>' +
    '<p style="margin-bottom:4px"><b>Cara memasang (cukup sekali):</b></p><ol style="margin-top:0;padding-left:20px">' +
    '<li>Buka file <b>Hush.dmg</b>, lalu seret Hush ke folder Applications.</li>' +
    '<li>Buka Hush dari Applications. Mac akan bilang Apple tidak bisa memeriksa Hush. Klik <b>Done</b>.</li>' +
    '<li>Buka <b>System Settings</b>, pilih <b>Privacy &amp; Security</b>, gulir ke bawah, lalu klik <b>Open Anyway</b>. Masukkan password Mac.</li></ol>' +
    '<p style="color:#4C483F;font-size:14px">Peringatan itu muncul karena Hush belum terdaftar berbayar di Apple. Kodenya terbuka di <a href="https://github.com/ainurfqq/hush">GitHub</a>. ' +
    'Saat pertama dibuka, Hush mengunduh model suara sekitar 800 MB. Versi baru nanti terpasang dari dalam aplikasi.</p>' +
    '<p style="color:#4C483F;font-size:14px">Butuh Mac M1 atau lebih baru, dengan macOS 14.4 ke atas. Ada kendala? Balas saja email ini.</p></div>';
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

/** Run once from the editor: grants access, adds the header row/column, and makes the daily sendPending trigger. */
function setup() {
  const sh = sheet_();
  if (sh.getRange(1, SENT_COL).getValue() !== 'Email sent') sh.getRange(1, SENT_COL).setValue('Email sent').setFontWeight('bold');
  if (!ScriptApp.getProjectTriggers().some(t => t.getHandlerFunction() === 'sendPending')) {
    ScriptApp.newTrigger('sendPending').timeBased().everyDays(1).atHour(9).create();
  }
}
