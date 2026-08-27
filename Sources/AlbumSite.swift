import Foundation

/// Builds one password-protected album page per event.
///
/// The page is a single self-contained file: no stylesheet, script or font is
/// fetched from anywhere, so it can be opened from a USB stick, a laptop with no
/// internet, or any host that serves static files. The only things it reaches for
/// are the photographs themselves, on the CDN.
///
/// Its whole payload — every address, every session, the event's own name — is
/// encrypted with the album password before it is written. See `AlbumCrypto`.
enum AlbumSite {

    struct Shot {
        let src: String
        let save: String
        let index: Int
    }

    struct Session {
        let id: String
        let time: String
        let shots: [Shot]
        let print: Shot?
    }

    struct Album {
        let eventName: String
        let date: String
        let venue: String
        let boothName: String
        let brandLink: String?
        let brandLabel: String
        let sessions: [Session]

        var photoCount: Int { sessions.reduce(0) { $0 + $1.shots.count } }
    }

    // MARK: - Manifest

    /// Everything the page needs, as JSON — and the only thing the password
    /// unlocks. Deliberately includes the event name: an album found by accident
    /// should not even reveal whose wedding it was.
    static func manifest(for album: Album) throws -> Data {
        var sessions: [[String: Any]] = []
        for s in album.sessions {
            var dict: [String: Any] = [
                "id": s.id,
                "time": s.time,
                "shots": s.shots.map { ["src": $0.src, "save": $0.save, "n": $0.index] }
            ]
            if let p = s.print { dict["print"] = ["src": p.src, "save": p.save] }
            sessions.append(dict)
        }
        let root: [String: Any] = [
            "event": album.eventName,
            "date": album.date,
            "venue": album.venue,
            "brandLink": album.brandLink ?? "",
            "brandLabel": album.brandLabel,
            "sessions": sessions
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [])
    }

    // MARK: - Page

    static func page(for album: Album, password: String) throws -> String {
        let sealed = try AlbumCrypto.seal(manifest(for: album), password: password)
        let booth = esc(album.boothName)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex, nofollow">
        <title>\(booth) — private album</title>
        <style>\(css)</style>
        </head>
        <body>
        <header class="masthead">
          <span class="wordmark">\(booth)</span>
        </header>

        <main id="gate" class="gate">
          <div class="card">
            <p class="eyebrow">Private album</p>
            <h1 class="display">Your photographs<br>are waiting.</h1>
            <p class="lede">Enter the password from the booth to open them. Nothing is listed on this page until you do.</p>
            <form id="form" autocomplete="off">
              <input id="pw" type="password" placeholder="Password" autocomplete="off"
                     spellcheck="false" aria-label="Album password">
              <button id="go" class="pill dark" type="submit">Open the album</button>
            </form>
            <p id="err" class="err" hidden>That password does not open this album.</p>
            <p id="busy" class="muted" hidden>Unlocking…</p>
          </div>
        </main>

        <main id="album" hidden>
          <section class="intro">
            <p class="eyebrow" id="a-date"></p>
            <h1 class="display" id="a-event"></h1>
            <p class="lede" id="a-meta"></p>
          </section>
          <div id="sessions"></div>
          <footer class="foot">
            <p id="a-brand"></p>
            <p class="muted">Save what you would like to keep — this page needs the password again next time.</p>
          </footer>
        </main>

        <div id="viewer" class="viewer" hidden>
          <button class="close pill" id="v-close" aria-label="Close">Close</button>
          <img id="v-img" alt="">
          <a id="v-save" class="pill light" download>Save this photo</a>
        </div>

        <script>
        const SEALED = {
          salt: "\(sealed.salt)",
          nonce: "\(sealed.nonce)",
          payload: "\(sealed.payload)",
          rounds: \(sealed.rounds)
        };
        \(script)
        </script>
        </body>
        </html>
        """
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Look
    //
    // A variation on the reference rather than a copy of it: the same calm,
    // shadowless, cream-and-ink temperament and pill controls, but built around
    // photographs — a narrower measure, a warmer ink, one ember accent used
    // sparingly, and a grid that lets the pictures carry the page. No mascots,
    // no primary-bright fills; the guests' faces are the illustration.
    private static let css = """
    :root {
      --canvas:#faf8f5; --surface:#ffffff; --sand:#f1ede7; --line:#e6e0d8;
      --ink:#141312; --heading:#2b2926; --body:#4a4641; --muted:#8a847c;
      --ember:#e2552b;
      --r-card:12px; --r-photo:10px; --pill:999px;
      --measure:1080px;
    }
    @media (prefers-color-scheme: dark) {
      :root { --canvas:#121110; --surface:#1a1917; --sand:#201e1b; --line:#2c2925;
              --ink:#f7f4ef; --heading:#f2eee8; --body:#c9c3ba; --muted:#8f887f; }
    }
    * { box-sizing:border-box; }
    /* The viewer sets display:flex, which outranks the browser's own rule for
       the hidden attribute — without this it is on screen from the first paint. */
    [hidden] { display:none !important; }
    html,body { margin:0; background:var(--canvas); color:var(--body); }
    body {
      font:400 17px/1.53 ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif;
      letter-spacing:-0.001em; -webkit-text-size-adjust:100%;
      -webkit-font-smoothing:antialiased;
    }
    .masthead { padding:28px 24px; max-width:var(--measure); margin:0 auto; }
    .wordmark {
      font-size:13px; font-weight:600; letter-spacing:0.14em; text-transform:uppercase;
      color:var(--muted);
    }
    .display {
      font-size:clamp(34px,7vw,56px); line-height:1.06; letter-spacing:-0.03em;
      font-weight:500; color:var(--heading); margin:0 0 14px;
    }
    .eyebrow {
      font-size:13px; font-weight:600; letter-spacing:0.12em; text-transform:uppercase;
      color:var(--ember); margin:0 0 14px;
    }
    .lede { font-size:17px; color:var(--body); margin:0; max-width:44ch; }
    .muted { color:var(--muted); font-size:15px; }

    /* Gate */
    .gate { max-width:var(--measure); margin:0 auto; padding:6vh 24px 80px; }
    .card {
      background:var(--surface); border:1px solid var(--line); border-radius:var(--r-card);
      padding:clamp(24px,5vw,52px); max-width:620px;
    }
    form { display:flex; gap:10px; flex-wrap:wrap; margin:28px 0 0; }
    input[type=password] {
      flex:1 1 220px; min-width:0; padding:14px 18px; font-size:17px; color:var(--ink);
      background:var(--canvas); border:1px solid var(--line); border-radius:var(--pill);
      outline:none;
    }
    input[type=password]:focus { border-color:var(--ink); }
    .pill {
      display:inline-flex; align-items:center; justify-content:center; gap:8px;
      padding:14px 26px; border-radius:var(--pill); border:1px solid transparent;
      font-size:15px; font-weight:600; letter-spacing:-0.005em; cursor:pointer;
      text-decoration:none; white-space:nowrap;
    }
    .pill.dark { background:var(--ink); color:var(--canvas); }
    .pill.light { background:var(--sand); color:var(--ink); border-color:var(--line); }
    .pill.quiet { background:transparent; color:var(--ink); border-color:var(--line); }
    .pill:active { transform:translateY(1px); }
    .pill[disabled] { opacity:.5; cursor:default; }
    .err { color:var(--ember); font-size:15px; margin:16px 0 0; }

    /* Album */
    .intro { max-width:var(--measure); margin:0 auto; padding:4vh 24px 40px; }
    .session { max-width:var(--measure); margin:0 auto; padding:0 24px 64px; }
    .session-head {
      display:flex; align-items:baseline; justify-content:space-between; gap:16px;
      padding:22px 0 18px; border-top:1px solid var(--line); flex-wrap:wrap;
    }
    .session-title { font-size:23px; font-weight:500; color:var(--heading); margin:0; letter-spacing:-0.02em; }
    .session-body { display:grid; gap:20px; }
    .session-body.with-print { grid-template-columns:minmax(160px,220px) 1fr; align-items:start; }
    @media (max-width:640px) { .session-body.with-print { grid-template-columns:1fr; } }
    .print-col { display:flex; flex-direction:column; gap:8px; }
    .print-label { margin:0; font-size:13px; color:var(--muted); letter-spacing:0.04em; }
    .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(190px,1fr)); gap:14px; }
    .shot { position:relative; margin:0; border-radius:var(--r-photo); overflow:hidden;
            background:var(--sand); aspect-ratio:3/2; }
    .shot.print { aspect-ratio:2/3; }
    .shot img { width:100%; height:100%; object-fit:cover; display:block; cursor:zoom-in;
                transition:transform .5s cubic-bezier(.2,.7,.3,1); }
    .shot:hover img { transform:scale(1.03); }
    .shot .save {
      position:absolute; right:10px; bottom:10px; padding:9px 16px; font-size:13px;
      background:rgba(250,248,245,.94); color:var(--ink); border-radius:var(--pill);
      text-decoration:none; font-weight:600; opacity:0; transition:opacity .2s;
    }
    .shot:hover .save, .shot:focus-within .save { opacity:1; }
    @media (hover:none) { .shot .save { opacity:1; } }
    .foot { max-width:var(--measure); margin:0 auto; padding:40px 24px 90px;
            border-top:1px solid var(--line); }
    .foot a { color:var(--ink); }

    /* Viewer */
    .viewer {
      position:fixed; inset:0; background:rgba(10,9,8,.94); display:flex;
      align-items:center; justify-content:center; flex-direction:column; gap:18px; padding:24px; z-index:50;
    }
    .viewer img { max-width:100%; max-height:78vh; border-radius:var(--r-photo); }
    .viewer .close { position:absolute; top:18px; right:18px; background:rgba(250,248,245,.92); color:#141312; }
    """

    // MARK: - Behaviour
    private static let script = """
    const $ = s => document.querySelector(s);
    const b64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));

    async function unlock(password) {
      const enc = new TextEncoder();
      const base = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveKey']);
      const key = await crypto.subtle.deriveKey(
        { name:'PBKDF2', salt:b64(SEALED.salt), iterations:SEALED.rounds, hash:'SHA-256' },
        base, { name:'AES-GCM', length:256 }, false, ['decrypt']);
      const clear = await crypto.subtle.decrypt(
        { name:'AES-GCM', iv:b64(SEALED.nonce) }, key, b64(SEALED.payload));
      return JSON.parse(new TextDecoder().decode(clear));
    }

    function el(tag, cls, text) {
      const n = document.createElement(tag);
      if (cls) n.className = cls;
      if (text !== undefined) n.textContent = text;
      return n;
    }

    function render(data) {
      $('#a-event').textContent = data.event;
      $('#a-date').textContent = data.date;
      const bits = [];
      if (data.venue) bits.push(data.venue);
      const shots = data.sessions.reduce((n, s) => n + s.shots.length, 0);
      bits.push(shots + (shots === 1 ? ' photograph' : ' photographs'));
      bits.push(data.sessions.length + (data.sessions.length === 1 ? ' session' : ' sessions'));
      $('#a-meta').textContent = bits.join(' · ');
      if (data.brandLink) {
        const a = el('a', null, data.brandLink.replace(/^https?:\\/\\//, ''));
        a.href = data.brandLink;
        $('#a-brand').append((data.brandLabel || 'Find us') + ' — ', a);
      }

      const host = $('#sessions');
      data.sessions.forEach((s, i) => {
        const sec = el('section', 'session');
        const head = el('div', 'session-head');
        head.append(el('h2', 'session-title', 'Session ' + (i + 1) + ' · ' + s.time));
        const all = [...s.shots.map(x => x.src)];
        if (s.print) all.push(s.print.src);
        const dl = el('button', 'pill quiet', 'Download all ' + all.length);
        dl.onclick = () => downloadAll(dl, all, 'photos-' + (i + 1) + '.zip');
        head.append(dl);
        sec.append(head);

        const shotEl = (shot, isPrint) => {
          const fig = el('figure', 'shot' + (isPrint ? ' print' : ''));
          const img = el('img');
          img.src = shot.src; img.loading = 'lazy'; img.alt = isPrint ? 'Print' : 'Photo';
          img.onclick = () => openViewer(shot);
          const a = el('a', 'save', 'Save');
          a.href = shot.save; a.setAttribute('download', '');
          fig.append(img, a);
          return fig;
        };
        // The 4x6 is a different shape from the frames it is made of, so it gets
        // its own column rather than punching a tall hole in the grid.
        const body = el('div', 'session-body' + (s.print ? ' with-print' : ''));
        if (s.print) {
          const side = el('div', 'print-col');
          side.append(shotEl(s.print, true), el('p', 'print-label', 'The print'));
          body.append(side);
        }
        const grid = el('div', 'grid');
        s.shots.forEach(x => grid.append(shotEl(x, false)));
        body.append(grid);
        sec.append(body);
        host.append(sec);
      });

      $('#gate').hidden = true;
      $('#album').hidden = false;
    }

    function openViewer(shot) {
      $('#v-img').src = shot.src;
      $('#v-save').href = shot.save;
      $('#viewer').hidden = false;
      document.body.style.overflow = 'hidden';
    }
    function closeViewer() { $('#viewer').hidden = true; document.body.style.overflow = ''; }
    $('#v-close').onclick = closeViewer;
    $('#viewer').onclick = e => { if (e.target.id === 'viewer') closeViewer(); };
    document.addEventListener('keydown', e => { if (e.key === 'Escape') closeViewer(); });

    // Browsers withhold crypto.subtle from pages opened straight off the disk,
    // so say why rather than failing as if the password were wrong.
    if (!(window.crypto && crypto.subtle)) {
      $('#err').textContent =
        'This page has to be opened from a web address. A page opened directly from a file cannot unlock, because browsers only hand out the decryption tools over http or https.';
      $('#err').hidden = false;
      $('#go').disabled = true;
      $('#pw').disabled = true;
    }

    $('#form').onsubmit = async e => {
      e.preventDefault();
      const pw = $('#pw').value.trim();
      if (!pw) return;
      $('#err').hidden = true; $('#busy').hidden = false; $('#go').disabled = true;
      try {
        render(await unlock(pw));
      } catch (err) {
        // A wrong password fails the cipher's authentication tag — there is no
        // separate check to bypass, and nothing here knows the right answer.
        $('#err').hidden = false; $('#pw').value = ''; $('#pw').focus();
      } finally {
        $('#busy').hidden = true; $('#go').disabled = false;
      }
    };
    $('#pw').focus();

    /* Zip, built in the browser: STORE only, so a phone can do it without a library. */
    const CRC = (() => { const t = new Uint32Array(256);
      for (let i = 0; i < 256; i++) { let c = i;
        for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
        t[i] = c >>> 0; } return t; })();
    function crc32(b) { let c = 0xFFFFFFFF;
      for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 0xFF] ^ (c >>> 8);
      return (c ^ 0xFFFFFFFF) >>> 0; }
    function dosStamp(d) {
      return [((d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() / 2)) & 0xFFFF,
              (((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()) & 0xFFFF];
    }
    async function downloadAll(btn, files, zipName) {
      const label = btn.textContent;
      btn.disabled = true;
      const enc = new TextEncoder(), parts = [], central = [];
      const [time, date] = dosStamp(new Date());
      let offset = 0, done = 0;
      try {
        for (const path of files) {
          btn.textContent = 'Packing ' + (++done) + ' of ' + files.length + '…';
          const data = new Uint8Array(await (await fetch(path)).arrayBuffer());
          const name = enc.encode(path.split('/').pop());
          const crc = crc32(data);
          const lh = new DataView(new ArrayBuffer(30));
          lh.setUint32(0, 0x04034b50, true); lh.setUint16(4, 20, true); lh.setUint16(6, 0, true);
          lh.setUint16(8, 0, true); lh.setUint16(10, time, true); lh.setUint16(12, date, true);
          lh.setUint32(14, crc, true); lh.setUint32(18, data.length, true);
          lh.setUint32(22, data.length, true); lh.setUint16(26, name.length, true);
          lh.setUint16(28, 0, true);
          parts.push(new Uint8Array(lh.buffer), name, data);
          const ch = new DataView(new ArrayBuffer(46));
          ch.setUint32(0, 0x02014b50, true); ch.setUint16(4, 20, true); ch.setUint16(6, 20, true);
          ch.setUint16(8, 0, true); ch.setUint16(10, 0, true); ch.setUint16(12, time, true);
          ch.setUint16(14, date, true); ch.setUint32(16, crc, true);
          ch.setUint32(20, data.length, true); ch.setUint32(24, data.length, true);
          ch.setUint16(28, name.length, true); ch.setUint16(30, 0, true); ch.setUint16(32, 0, true);
          ch.setUint16(34, 0, true); ch.setUint16(36, 0, true); ch.setUint32(38, 0, true);
          ch.setUint32(42, offset, true);
          central.push(new Uint8Array(ch.buffer), name);
          offset += 30 + name.length + data.length;
        }
        let centralSize = 0;
        for (const c of central) centralSize += c.length;
        const end = new DataView(new ArrayBuffer(22));
        end.setUint32(0, 0x06054b50, true); end.setUint16(4, 0, true); end.setUint16(6, 0, true);
        end.setUint16(8, files.length, true); end.setUint16(10, files.length, true);
        end.setUint32(12, centralSize, true); end.setUint32(16, offset, true);
        end.setUint16(20, 0, true);
        const blob = new Blob([...parts, ...central, new Uint8Array(end.buffer)], { type:'application/zip' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob); a.download = zipName;
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 30000);
      } catch (e) {
        btn.textContent = 'Could not build the zip — save them one at a time';
        setTimeout(() => { btn.textContent = label; btn.disabled = false; }, 4000);
        return;
      }
      btn.textContent = label; btn.disabled = false;
    }
    """
}
