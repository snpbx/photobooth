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
    private static let css = """
    :root { color-scheme: dark; --bg:#0b0b0c; --card:#161618; --line:#2a2a2e;
            --ink:#f2f2f3; --dim:#a0a0a8; --accent:#e8b33c; }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--ink); -webkit-text-size-adjust:100%;
           font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
    .wrap { max-width:760px; margin:0 auto; padding:24px 16px 64px; }
    header { padding:8px 0 20px; }
    h1 { margin:0 0 4px; font-size:22px; letter-spacing:.01em; }
    .sub { color:var(--dim); font-size:14px; margin:0; }
    .row { display:flex; gap:10px; flex-wrap:wrap; margin:18px 0 26px; }
    .btn { display:inline-flex; align-items:center; gap:8px; padding:13px 18px; border-radius:12px;
           border:1px solid var(--line); background:var(--card); color:var(--ink);
           font-size:15px; font-weight:600; text-decoration:none; cursor:pointer; }
    .btn:active { transform:translateY(1px); }
    .btn-go { background:var(--accent); border-color:var(--accent); color:#1a1200; }
    .btn[disabled] { opacity:.55; cursor:default; }
    .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(150px,1fr)); gap:14px; }
    figure { margin:0; background:var(--card); border:1px solid var(--line); border-radius:14px;
             overflow:hidden; }
    figure img { display:block; width:100%; height:auto; }
    figcaption { display:flex; justify-content:space-between; align-items:center;
                 padding:9px 12px; font-size:13px; color:var(--dim); }
    figcaption a { color:var(--ink); text-decoration:none; font-weight:600; }
    .hero { margin:0 0 22px; display:grid; gap:14px; grid-template-columns:1fr; }
    .hero img { display:block; width:100%; height:auto; border-radius:14px; border:1px solid var(--line); }
    /* Print and loop side by side once there is room; stacked on a phone, which
       is where nearly every guest opens this. */
    @media (min-width:640px) { .hero.pair { grid-template-columns:1fr 1fr; align-items:start; } }
    .note { color:var(--dim); font-size:13px; margin:26px 0 0; }
    footer { margin-top:34px; padding-top:18px; border-top:1px solid var(--line);
             color:var(--dim); font-size:13px; }
    footer a { color:var(--ink); }
    .empty { color:var(--dim); padding:40px 0; text-align:center; }
    """

    private static func head(_ title: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex, nofollow">
        <title>\(esc(title))</title>
        <style>\(css)</style>
        </head>
        <body><div class="wrap">
        """
    }

    private static func foot(brandLink: String?, brandLabel: String) -> String {
        var f = "<footer>"
        if let link = brandLink, !link.isEmpty {
            f += "<p>\(esc(brandLabel)) — <a href=\"\(esc(link))\">\(esc(link))</a></p>"
        }
        f += "<p>Photographs stay up as long as this page does. Save the ones you want.</p>"
        f += "</footer>"
        return f + "</div></body></html>"
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
        const blob = new Blob([...parts, ...central, new Uint8Array(end.buffer)],
                              { type: 'application/zip' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = zipName;
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 30000);
      } catch (e) {
        btn.textContent = 'Could not build the zip — save them one by one';
        setTimeout(() => { btn.textContent = label; btn.disabled = false; }, 4000);
        return;
      }
      btn.textContent = label;
      btn.disabled = false;
    }
    </script>
    """

    // MARK: - Pages

    static func landing(siteTitle: String) -> String {
        head(siteTitle) + """
        <header>
          <h1>\(esc(siteTitle))</h1>
          <p class="sub">Scan the code on the booth screen or on your print to open your photographs.</p>
        </header>
        <p class="note">Each session has its own address, so this page has nothing to list.
        If you have lost the link, ask whoever ran the booth — they can find it again.</p>
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

    static func sessionPage(siteTitle: String,
                            event: EventRecord,
                            session: SessionRecord,
                            photos: [PhotoRef],
                            print printRef: PhotoRef?,
                            gif gifRef: PhotoRef? = nil,
                            albumHref: String,
                            brandLink: String? = nil,
                            brandLabel: String = "") -> String {
        var all = photos
        if let p = printRef { all.append(p) }
        if let g = gifRef { all.append(g) }
        let jsList = "[" + all.map { "'\($0.src)'" }.joined(separator: ",") + "]"
        let zipName = "photos-\(session.publicToken).zip"

        var html = head("Your photos — \(event.name)")
        html += """
        <header>
          <h1>Your photos</h1>
          <p class="sub">\(esc(event.name)) · \(dateFormatter.string(from: session.startedAt)) at \(timeFormatter.string(from: session.startedAt))</p>
        </header>
        """

        if printRef != nil || gifRef != nil {
            let pair = printRef != nil && gifRef != nil
            html += "<div class=\"hero\(pair ? " pair" : "")\">"
            if let p = printRef {
                html += "<img src=\"\(esc(p.src))\" alt=\"Your print\">"
            }
            if let g = gifRef {
                // No <video>, no script: a GIF in an <img> plays by itself, which
                // is the whole reason the booth makes one.
                html += "<img class=\"loop\" src=\"\(esc(g.src))\" alt=\"Your GIF\">"
            }
            html += "</div>"
        }

        html += "<div class=\"row\">"
        if !all.isEmpty {
            html += """
            <button class="btn btn-go" onclick="downloadAll(this, \(jsList), '\(zipName)')">Download all \(all.count)</button>
            """
        }
        if let p = printRef {
            html += "<a class=\"btn\" href=\"\(esc(p.save))\" download>Save the print</a>"
        }
        if let g = gifRef {
            html += "<a class=\"btn\" href=\"\(esc(g.save))\" download>Save the GIF</a>"
        }
        html += "<a class=\"btn\" href=\"\(esc(albumHref))\">The whole album</a>"
        html += "</div>"

        if photos.isEmpty {
            html += "<p class=\"empty\">The photographs for this session are still uploading.</p>"
        } else {
            html += "<div class=\"grid\">"
            for (i, ref) in photos.enumerated() {
                html += """
                <figure>
                  <img src="\(esc(ref.src))" alt="Photo \(i + 1)" loading="lazy">
                  <figcaption><span>\(i + 1)</span><a href="\(esc(ref.save))" download>Save</a></figcaption>
                </figure>
                """
            }
            html += "</div>"
        }

        html += "<p class=\"note\">On an iPhone, hold a photograph and choose “Add to Photos”, or use Save."
        if gifRef != nil {
            html += " Hold the GIF the same way to send it on."
        }
        html += "</p>"
        html += zipScript
        return html + foot(brandLink: brandLink, brandLabel: brandLabel)
    }

    static func albumPage(siteTitle: String,
                          event: EventRecord,
                          entries: [AlbumEntry],
                          brandLink: String? = nil,
                          brandLabel: String = "") -> String {
        var html = head("\(event.name) — album")
        html += """
        <header>
          <h1>\(esc(event.name))</h1>
          <p class="sub">\(entries.count) session\(entries.count == 1 ? "" : "s") · \(dateFormatter.string(from: event.date))</p>
        </header>
        """
        if entries.isEmpty {
            html += "<p class=\"empty\">Nothing published yet.</p>"
        } else {
            html += "<div class=\"grid\">"
            for e in entries {
                html += """
                <figure>
                  <a href="\(esc(e.href))"><img src="\(esc(e.cover))" alt="Session" loading="lazy"></a>
                  <figcaption><span>\(timeFormatter.string(from: e.stamp))</span><a href="\(esc(e.href))">Open</a></figcaption>
                </figure>
                """
            }
            html += "</div>"
        }
        return html + foot(brandLink: brandLink, brandLabel: brandLabel)
    }
}
