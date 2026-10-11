import Foundation

/// The static site GitHub Pages serves.
///
/// Written as plain strings rather than files in the bundle so a published site
/// can never disagree with the build that made it. Every page is self-contained:
/// no stylesheet, script or font is fetched from anywhere, because a guest on
/// venue wifi with two bars should still get their photographs.
enum PagesTemplate {

    /// One photograph on a page: where it is shown from, and where "Save" points.
    /// They differ on Cloudinary, whose fl_attachment address is what actually
    /// makes a phone save the file instead of opening it.
    struct PhotoRef {
        let src: String
        let save: String
        init(src: String, save: String? = nil) { self.src = src; self.save = save ?? src }
    }

    struct AlbumEntry {
        let href: String
        let cover: String
        let stamp: Date
        let count: Int
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    // MARK: - Shared chrome

    /// One stylesheet for every page. Mobile first — this is read on a phone
    /// held at a wedding reception, not on a desk.
    ///
    /// Glyphy — "buttercream specimen sheet beneath sunset bands". A warm cream
    /// canvas, ink for everything structural, and colour only as full-bleed
    /// bands stacked yellow → orange → red → burgundy → plum, always in that
    /// order. Two radii and no others: 14px for cards, 28px for pills. Flat —
    /// hairlines and bands do the separating, never a shadow.
    ///
    /// The reference's faces (Neue Machina, System85, Pixel M Plus) are not
    /// free to embed, and every page is deliberately self-contained so that a
    /// guest on two bars of venue wifi still gets their photographs — so the
    /// heaviest system faces stand in, and the Japanese eyebrows use whatever
    /// the phone has.
    ///
    /// Sizes are fluid between a 320px phone and a desktop, and the gutters
    /// respect the notch and home indicator (`viewport-fit=cover` plus the
    /// safe-area insets), so nothing hides under the rounded corners of a
    /// modern iPhone held sideways.
    private static let css = """
    :root { color-scheme: light;
            --cream:#fef9e6; --ink:#000000; --carbon:#060606; --drift:#c7c3b4; --stone:#8d8b80;
            --amber:#fdc331; --ember:#fe5722; --red:#f0353c; --merlot:#b4213d; --plum:#671c3b;
            --g:clamp(16px,4.2vw,40px);
            --gl:max(var(--g),env(safe-area-inset-left)); --gr:max(var(--g),env(safe-area-inset-right));
            --sans:-apple-system,BlinkMacSystemFont,"Inter","Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
            --display:"Arial Black",-apple-system,BlinkMacSystemFont,system-ui,"Segoe UI",Roboto,Arial,sans-serif;
            --mono:ui-monospace,"SF Mono",Menlo,Consolas,"Roboto Mono",monospace;
            --jp:"Hiragino Kaku Gothic ProN","Hiragino Sans","Noto Sans JP","Yu Gothic",ui-monospace,monospace; }
    * { box-sizing:border-box; }
    html { -webkit-text-size-adjust:100%; text-size-adjust:100%; }
    body { margin:0; min-height:100vh; background:var(--cream); color:var(--ink);
           font:400 16px/1.2 var(--sans); -webkit-tap-highlight-color:transparent;
           overflow-x:hidden; }
    img { max-width:100%; }
    a { color:inherit; }
    :focus-visible { outline:2px solid var(--ink); outline-offset:3px; }
    .pad { padding-left:var(--gl); padding-right:var(--gr); }

    /* Nav strip */
    .bar { display:flex; align-items:center; justify-content:space-between; gap:12px;
           min-height:52px; background:var(--carbon); color:var(--cream);
           padding-top:env(safe-area-inset-top); }
    .mark { min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
            font:700 15px/1 var(--sans); letter-spacing:.02em; text-transform:uppercase; }
    .bar .jp { flex:none; font:400 12px/1 var(--jp); letter-spacing:.12em; opacity:.8; }

    /* Hero wordmark */
    .hero { display:grid; gap:18px; padding-top:clamp(28px,7vw,80px); padding-bottom:clamp(28px,6vw,64px); }
    .eyebrow { margin:0 0 8px; font:400 13px/1 var(--jp); letter-spacing:.14em; color:var(--stone); }
    h1 { margin:0; font:900 clamp(54px,17.5vw,150px)/.78 var(--display); letter-spacing:-.035em;
         text-transform:uppercase; overflow-wrap:anywhere; hyphens:auto; }
    h1.long { font-size:clamp(40px,11vw,112px); line-height:.85; }
    .tag { margin:0; font:400 16px/1.25 var(--sans); max-width:34ch; }
    .tag b { display:block; font-weight:700; font-size:18px; margin-bottom:4px; }
    @media (min-width:760px) {
      .hero { grid-template-columns:1fr auto; align-items:end; }
      .tag { text-align:right; font-size:18px; }
    }
    @media (orientation:landscape) and (max-height:500px) {
      h1 { font-size:clamp(44px,19vh,96px); }
      h1.long { font-size:clamp(34px,13vh,80px); }
      .hero { padding-top:24px; padding-bottom:24px; }
    }

    /* Dark specimen card — the print, and the GIF beside it */
    .media { display:grid; gap:16px; padding-bottom:clamp(24px,5vw,40px); }
    @media (min-width:760px) { .media.pair { grid-template-columns:1fr 1fr; align-items:start; } }
    .media:not(.pair) .card { max-width:680px; }
    .card { margin:0; background:var(--carbon); color:var(--cream); border-radius:14px;
            padding:clamp(12px,3.4vw,27px); }
    .card .top { display:flex; justify-content:space-between; align-items:center; gap:10px;
                 margin-bottom:clamp(12px,3vw,20px); }
    .label { font:400 13px/1 var(--mono); letter-spacing:.02em; }
    .card img, .card video { display:block; width:100%; height:auto; max-height:78vh; object-fit:contain;
                             background:#1a1a1a; border-radius:0; }

    /* Pills — ghost, outlined in whatever colour the text is */
    .pill { flex:none; display:inline-flex; align-items:center; justify-content:center; gap:6px;
            min-height:44px; padding:0 clamp(16px,4vw,27px); border:1px solid currentColor;
            border-radius:28px; background:transparent; color:inherit; text-decoration:none;
            font:400 14px/1 var(--sans); letter-spacing:.04em; text-transform:uppercase; white-space:nowrap; }
    .pill.sm { min-height:36px; padding:0 14px; font-size:12px; }

    /* Sunset bands — full bleed, name left, pill right, colour in fixed order */
    .bands { display:flex; flex-direction:column; }
    .band { display:flex; align-items:center; justify-content:space-between; gap:14px; width:100%;
            min-height:84px; margin:0; border:0; border-radius:0; cursor:pointer; text-align:left;
            text-decoration:none; color:var(--ink); background:var(--amber);
            padding-top:clamp(18px,4.5vw,40px); padding-bottom:clamp(18px,4.5vw,40px);
            font:700 clamp(20px,5.6vw,32px)/1.05 var(--sans); letter-spacing:-.01em; }
    .band .name { min-width:0; }
    .band:nth-child(5n+2) { background:var(--ember); }
    .band:nth-child(5n+3) { background:var(--red);    color:var(--cream); }
    .band:nth-child(5n+4) { background:var(--merlot); color:var(--cream); }
    .band:nth-child(5n+5) { background:var(--plum);   color:var(--cream); }
    .band[disabled] { cursor:progress; }
    .band[disabled] .pill { opacity:.55; }
    @media (hover:hover) {
      .band:hover .pill { background:var(--ink); border-color:var(--ink); color:var(--cream); }
      .band:nth-child(5n+3):hover .pill, .band:nth-child(5n+4):hover .pill, .band:nth-child(5n+5):hover .pill
        { background:var(--cream); border-color:var(--cream); color:var(--ink); }
    }
    .band:active { filter:brightness(.94); }

    /* Section header */
    .sec { padding-top:clamp(32px,7vw,80px); }
    .sec h2 { margin:0 0 clamp(16px,3vw,24px); font:700 clamp(26px,7vw,40px)/1 var(--sans);
              letter-spacing:-.02em; text-transform:uppercase; }

    /* Specimen grid — one continuous sheet of hairlines, no gaps */
    .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(140px,1fr)); gap:1px;
            background:var(--drift); border:1px solid var(--drift); border-radius:14px; overflow:hidden; }
    @media (min-width:900px) { .grid { grid-template-columns:repeat(auto-fill,minmax(220px,1fr)); } }
    .grid figure { margin:0; background:var(--cream); display:flex; flex-direction:column; min-width:0; }
    .grid figure > a { display:block; }
    /* Fixed shapes keep the sheet an even grid while images arrive, and a
       broken or missing one leaves a quiet tile instead of alt text. */
    .grid img, .grid .ph { display:block; width:100%; height:auto; aspect-ratio:3/2; object-fit:cover;
                           background:#efe9d3; color:transparent; font-size:0; }
    .grid.covers img, .grid.covers .ph { aspect-ratio:2/3; }
    .grid figcaption { display:flex; flex-wrap:wrap; justify-content:space-between; align-items:center;
                       gap:6px 8px; padding:10px; margin-top:auto; }
    .grid .label { color:var(--stone); white-space:nowrap; }
    @media (max-width:374px) { .grid .pill.sm { padding:0 11px; } .grid .label { font-size:12px; } }

    .note { margin:clamp(24px,5vw,40px) 0 0; padding:18px 20px; border:1px solid var(--ink);
            border-radius:14px; font-size:15px; line-height:1.3; max-width:680px; }
    .empty { padding:48px 0; font:400 14px/1.3 var(--mono); color:var(--stone); }

    footer { margin-top:clamp(40px,8vw,80px); background:var(--carbon); color:var(--cream);
             padding-top:28px; padding-bottom:calc(28px + env(safe-area-inset-bottom)); font-size:14px; line-height:1.35; }
    footer p { margin:4px 0; }
    footer a { font-weight:700; overflow-wrap:anywhere; }
    footer .jp { display:block; margin-bottom:12px; font:400 12px/1 var(--jp); letter-spacing:.14em; color:var(--stone); }
    """

    private static func head(_ title: String, siteTitle: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="robots" content="noindex, nofollow">
        <meta name="theme-color" content="#060606">
        <meta name="format-detection" content="telephone=no">
        <title>\(esc(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <nav class="bar pad"><span class="mark">\(esc(siteTitle))</span><span class="jp" lang="ja">フォトブース</span></nav>
        """
    }

    private static func foot(brandLink: String?, brandLabel: String) -> String {
        var f = "<footer class=\"pad\"><span class=\"jp\" lang=\"ja\">ありがとう</span>"
        if let link = brandLink, !link.isEmpty {
            let label = brandLabel.isEmpty ? "" : "\(esc(brandLabel)) — "
            f += "<p>\(label)<a href=\"\(esc(link))\">\(esc(link))</a></p>"
        }
        f += "<p>Photographs stay up as long as this page does. Save the ones you want.</p>"
        f += "</footer>"
        return f + "</body></html>"
    }

    /// A headline that would not fit at wordmark size gets the smaller cut —
    /// an event called "Anna & Benedict's Rehearsal Dinner" should wrap into
    /// four tidy lines on a phone, not twelve broken ones.
    private static func h1(_ text: String) -> String {
        let longest = text.split(separator: " ").map(\.count).max() ?? 0
        let cls = (text.count > 14 || longest > 8) ? " class=\"long\"" : ""
        return "<h1\(cls)>\(esc(text))</h1>"
    }

    // MARK: - Client-side zip
    //
    // GitHub Pages cannot build a zip — there is no server. The browser does it
    // instead, STORE method only: nothing is compressed, so the code stays short
    // and JPEGs would not have shrunk anyway.
    private static let zipScript = """
    <script>
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
      const out = btn.querySelector('.name') || btn;
      const label = out.textContent;
      btn.disabled = true;
      const enc = new TextEncoder(), parts = [], central = [];
      const [time, date] = dosStamp(new Date());
      let offset = 0, done = 0;
      try {
        for (const path of files) {
          out.textContent = 'Packing ' + (++done) + ' of ' + files.length + '…';
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
        const blob = new Blob([...parts, ...central, new Uint8Array(end.buffer)],
                              { type: 'application/zip' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = zipName;
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 30000);
      } catch (e) {
        out.textContent = 'Could not build the zip — save them one by one';
        setTimeout(() => { out.textContent = label; btn.disabled = false; }, 4000);
        return;
      }
      out.textContent = label;
      btn.disabled = false;
    }
    </script>
    """

    // MARK: - Pages

    static func landing(siteTitle: String) -> String {
        head(siteTitle, siteTitle: siteTitle) + """
        <header class="hero pad">
          <div><p class="eyebrow" lang="ja">ようこそ</p>\(h1(siteTitle))</div>
          <p class="tag">Scan the code on the booth screen or on your print to open your photographs.</p>
        </header>
        <div class="pad"><p class="note">Each session has its own address, so this page has nothing to list.
        If you have lost the link, ask whoever ran the booth — they can find it again.</p></div>
        """ + foot(brandLink: nil, brandLabel: "")
    }

    static func readme(siteTitle: String) -> String {
        """
        # \(siteTitle)

        A photobooth gallery served by GitHub Pages. Every file here is written by
        the Photobooth app on the booth Mac — edit the app's settings, not this
        repository.

        * `/s/<token>/` — one session: its photographs and its print
        * `/e/<token>/` — the album for one event
        * `.nojekyll` — stops GitHub from reprocessing the pages
        * `robots.txt` — keeps albums out of search results

        **Everything in this repository is public.** GitHub Pages on a free account
        cannot serve from a private repository. Addresses are unguessable, which is
        not the same as private.
        """
    }

    /// One sunset band. Colour comes from its position in `.bands`, so the
    /// stack always runs yellow → plum however many actions a session has.
    private static func band(href: String, name: String, pill: String, download: Bool = false) -> String {
        "<a class=\"band pad\" href=\"\(esc(href))\"\(download ? " download" : "")>"
            + "<span class=\"name\">\(esc(name))</span><span class=\"pill\">\(pill)</span></a>"
    }

    /// The page that exists before the photographs do.
    ///
    /// GitHub Pages takes twenty-odd seconds to build whatever is pushed to it,
    /// which is twenty-odd seconds during which a code printed on a strip leads
    /// to a 404 and a guest concludes the booth lost their pictures. So the page
    /// is pushed when the session *starts*: by the time the strip is in their
    /// hand it is built and live, and it replaces itself with the real one as
    /// soon as the photographs land.
    ///
    /// It refreshes itself rather than asking to be reloaded. Somebody standing
    /// in a marquee holding a strip will not pull-to-refresh on a promise; they
    /// will put the phone away.
    static func holdingPage(siteTitle: String,
                            eventName: String,
                            startedAt: Date,
                            brandLink: String? = nil,
                            brandLabel: String = "") -> String {
        var html = head("Your photos — \(eventName)", siteTitle: siteTitle)
        html = html.replacingOccurrences(
            of: "<meta name=\"theme-color\"",
            with: "<meta http-equiv=\"refresh\" content=\"10\">\n<meta name=\"theme-color\"")
        html += """
        <header class="hero pad">
          <div><p class="eyebrow" lang="ja">もうすぐ</p><h1 class="long">Nearly<br>there</h1></div>
          <p class="tag"><b>\(esc(eventName))</b>\(dateFormatter.string(from: startedAt)) · \(timeFormatter.string(from: startedAt))</p>
        </header>
        <nav class="bands">
          <span class="band pad"><span class="name">Your photographs are uploading</span>
          <span class="pill">Wait ↻</span></span>
        </nav>
        <div class="pad"><p class="note">This page refreshes itself every few seconds. Keep it open — your
        photographs appear here as soon as the booth has sent them, usually within a minute of your last shot.</p></div>
        """
        return html + foot(brandLink: brandLink, brandLabel: brandLabel)
    }

    static func sessionPage(siteTitle: String,
                            event: EventRecord,
                            session: SessionRecord,
                            photos: [PhotoRef],
                            print printRef: PhotoRef?,
                            gif gifRef: PhotoRef? = nil,
                            video videoRef: PhotoRef? = nil,
                            albumHref: String,
                            brandLink: String? = nil,
                            brandLabel: String = "") -> String {
        var all = photos
        if let p = printRef { all.append(p) }
        if let g = gifRef { all.append(g) }
        // The film is left out of "download all": it is the heaviest thing here
        // by an order of magnitude, and a zip built in a phone browser over
        // venue wifi is not where anybody wants it.

        let jsList = "[" + all.map { "'\($0.src)'" }.joined(separator: ",") + "]"
        let zipName = "photos-\(session.publicToken).zip"

        var html = head("Your photos — \(event.name)", siteTitle: siteTitle)
        html += """
        <header class="hero pad">
          <div><p class="eyebrow" lang="ja">あなたの写真</p><h1>Your<br>photos</h1></div>
          <p class="tag"><b>\(esc(event.name))</b>\(dateFormatter.string(from: session.startedAt)) · \(timeFormatter.string(from: session.startedAt))</p>
        </header>
        """

        // The film first: it is the thing a guest came back to the page for,
        // and `playsinline` is what stops an iPhone taking it full-screen the
        // moment it is touched.
        if let v = videoRef {
            html += """
            <section class="media pad"><figure class="card">\
            <div class="top"><span class="label">Your video</span>\
            <a class="pill sm" href="\(esc(v.save))" download>Save ↓</a></div>\
            <video controls playsinline preload="metadata" src="\(esc(v.src))"></video></figure></section>
            """
        }

        if printRef != nil || gifRef != nil {
            let pair = printRef != nil && gifRef != nil
            html += "<section class=\"media pad\(pair ? " pair" : "")\">"
            if let p = printRef {
                html += """
                <figure class="card"><div class="top"><span class="label">Your print</span>\
                <a class="pill sm" href="\(esc(p.src))">View →</a></div>\
                <img src="\(esc(p.src))" alt="Your print"></figure>
                """
            }
            if let g = gifRef {
                // No <video>, no script: a GIF in an <img> plays by itself, which
                // is the whole reason the booth makes one.
                html += """
                <figure class="card"><div class="top"><span class="label">Your GIF</span>\
                <a class="pill sm" href="\(esc(g.src))">View →</a></div>\
                <img class="loop" src="\(esc(g.src))" alt="Your GIF"></figure>
                """
            }
            html += "</section>"
        }

        html += "<nav class=\"bands\">"
        if all.count > 1 {
            html += """
            <button class="band pad" onclick="downloadAll(this, \(jsList), '\(zipName)')">\
            <span class="name">Download all \(all.count)</span><span class="pill">Zip ↓</span></button>
            """
        }
        if let p = printRef {
            html += band(href: p.save, name: "Save the print", pill: "Save ↓", download: true)
        }
        if let g = gifRef {
            html += band(href: g.save, name: "Save the GIF", pill: "Save ↓", download: true)
        }
        if let v = videoRef {
            html += band(href: v.save, name: "Save the video", pill: "Save ↓", download: true)
        }
        html += band(href: albumHref, name: "The whole album", pill: "Open →")
        html += "</nav>"

        if !photos.isEmpty {
            html += """
            <section class="sec pad"><p class="eyebrow" lang="ja">しゃしん</p><h2>The photos</h2><div class="grid">
            """
            for (i, ref) in photos.enumerated() {
                let n = String(format: "%02d", i + 1)
                html += """
                <figure><a href="\(esc(ref.src))"><img src="\(esc(ref.src))" alt="Photo \(i + 1)" loading="lazy"></a>\
                <figcaption><span class="label">No. \(n)</span>\
                <a class="pill sm" href="\(esc(ref.save))" download>Save ↓</a></figcaption></figure>
                """
            }
            html += "</div></section>"
        } else if printRef == nil && gifRef == nil {
            html += "<p class=\"empty pad\">The photographs for this session are still uploading.</p>"
        }

        let subject = photos.isEmpty ? "the print" : "a photograph"
        html += "<div class=\"pad\"><p class=\"note\">On an iPhone, hold \(subject) and choose “Save to Photos”, or use Save."
        if gifRef != nil {
            html += " Hold the GIF the same way to send it on."
        }
        html += "</p></div>"
        html += zipScript
        return html + foot(brandLink: brandLink, brandLabel: brandLabel)
    }

    static func albumPage(siteTitle: String,
                          event: EventRecord,
                          entries: [AlbumEntry],
                          brandLink: String? = nil,
                          brandLabel: String = "") -> String {
        var html = head("\(event.name) — album", siteTitle: siteTitle)
        html += """
        <header class="hero pad">
          <div><p class="eyebrow" lang="ja">アルバム</p>\(h1(event.name))</div>
          <p class="tag"><b>\(entries.count) session\(entries.count == 1 ? "" : "s")</b>\(dateFormatter.string(from: event.date))</p>
        </header>
        """
        if entries.isEmpty {
            html += "<p class=\"empty pad\">Nothing published yet.</p>"
        } else {
            html += "<section class=\"pad\"><div class=\"grid covers\">"
            for e in entries {
                let cover = e.cover.isEmpty
                    ? "<span class=\"ph\"></span>"
                    : "<img src=\"\(esc(e.cover))\" alt=\"Session at \(timeFormatter.string(from: e.stamp))\" loading=\"lazy\">"
                html += """
                <figure><a href="\(esc(e.href))">\(cover)</a>\
                <figcaption><span class="label">\(timeFormatter.string(from: e.stamp))</span>\
                <a class="pill sm" href="\(esc(e.href))">Open →</a></figcaption></figure>
                """
            }
            html += "</div></section>"
        }
        return html + foot(brandLink: brandLink, brandLabel: brandLabel)
    }
}
