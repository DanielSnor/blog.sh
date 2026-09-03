(function () {
  "use strict";

  // ---------------------------------------------------------------- i18n
  // The blog's language first -- site.js says what it is -- because this
  // is the blog's own desk, not an app of its own: its author writes a
  // Czech blog from an English phone and expects the desk in Czech. Only
  // without site.js does the browser's language decide: the reader's
  // language, then its base ("de-AT" -> "de"), then English. Missing
  // keys fall through rather than showing the key itself: a raw
  // "app.send" in the middle of a button is worse than an English word.
  var LANG = (function () {
    var have = window.I18N || {};
    var site = window.BLOG_SITE && String(window.BLOG_SITE.lang || "").toLowerCase();
    if (site && have[site]) return site;
    var want = (navigator.languages || [navigator.language || "en"]);
    for (var i = 0; i < want.length; i++) {
      var code = String(want[i] || "").toLowerCase();
      if (have[code]) return code;
      var base = code.split("-")[0];
      if (have[base]) return base;
    }
    return window.I18N_FALLBACK || "en";
  })();

  function t(path) {
    var order = [LANG, window.I18N_FALLBACK || "en"];
    for (var i = 0; i < order.length; i++) {
      var node = (window.I18N || {})[order[i]];
      var parts = path.split(".");
      for (var j = 0; node && j < parts.length; j++) node = node[parts[j]];
      if (typeof node === "string") return node;
    }
    return path;
  }

  document.documentElement.lang = LANG;
  Array.prototype.forEach.call(document.querySelectorAll("[data-t]"), function (el) {
    el.textContent = t(el.dataset.t);
  });

  var $ = function (id) { return document.getElementById(id); };

  // --------------------------------------------------------------- state
  var KEY = "blogsh-mobile-draft";
  var MAX_EDGE = 2560;   // long edge; a phone photo is far larger than any blog needs
  var state = { title: "", body: "", tags: "", shots: [], publish: false };

  // ------------------------------------------------------------ storage
  // The text, and what the page knows about each picture, go to
  // localStorage: small and synchronous. The bytes of the pictures and
  // videos go to IndexedDB, which holds hundreds of megabytes where
  // localStorage holds five. Until this split a draft with a phone video
  // -- or with five photographs -- could not be kept at all, and the page
  // said so on every keystroke.
  var DB = "blogsh-write", STORE = "shots";
  function idb() {
    return new Promise(function (done, fail) {
      if (!window.indexedDB) return fail(new Error("no indexedDB"));
      var req = indexedDB.open(DB, 1);
      req.onupgradeneeded = function () { req.result.createObjectStore(STORE, { keyPath: "name" }); };
      req.onsuccess = function () { done(req.result); };
      req.onerror = function () { fail(req.error); };
    });
  }
  function bytesRun(mode, act) {
    return idb().then(function (db) {
      return new Promise(function (done, fail) {
        var tx = db.transaction(STORE, mode);
        var req = act(tx.objectStore(STORE));
        tx.oncomplete = function () { db.close(); done(req && req.result); };
        tx.onerror = function () { db.close(); fail(tx.error); };
        tx.onabort = function () { db.close(); fail(tx.error); };
      });
    });
  }
  function bytesGetAll() { return bytesRun("readonly", function (st) { return st.getAll(); }); }
  function bytesPut(name, data) { return bytesRun("readwrite", function (st) { return st.put({ name: name, data: data }); }); }
  function bytesDelete(name) { return bytesRun("readwrite", function (st) { return st.delete(name); }); }
  function bytesClear() { return bytesRun("readwrite", function (st) { return st.clear(); }); }
  function forget(promise) { promise.then(null, function () { /* nothing to clear, or nowhere */ }); }

  // What localStorage gets: everything but the bytes, and nothing that is
  // only this page's bookkeeping.
  function forStorage(st) {
    return Object.assign({}, st, {
      shots: st.shots.map(function (shot) {
        var copy = Object.assign({}, shot);
        delete copy.data;
        delete copy._stored;
        return copy;
      })
    });
  }

  // What the page wrote is what it expects back; anything else -- a hand
  // edit, another version's shape, half a write -- is taken for what it
  // is worth and no further. A draft that could not be read used to
  // throw inside load(), before render() and before the page began to
  // listen for the server's reply: the form stood empty, the buttons
  // wore their labels, and the reply that arrived went nowhere.
  function sane(saved) {
    var out = { title: "", body: "", tags: "", shots: [], publish: false, sentAt: 0, receipt: "" };
    if (!saved || typeof saved !== "object") return out;
    ["title", "body", "tags"].forEach(function (k) { if (typeof saved[k] === "string") out[k] = saved[k]; });
    out.publish = saved.publish === true;
    out.sentAt = typeof saved.sentAt === "number" ? saved.sentAt : 0;
    // Sixteen hex characters or nothing: it is written into the markdown
    // and becomes a filename on the blog, so a stored draft is not
    // allowed to talk this page into asking for some other address.
    out.receipt = /^[0-9a-f]{16}$/.test(saved.receipt) ? saved.receipt : "";
    if (Array.isArray(saved.shots)) {
      out.shots = saved.shots.filter(function (shot) {
        return shot && typeof shot === "object" && typeof shot.name === "string" && shot.name;
      }).map(function (shot) {
        if (typeof shot.alt !== "string") shot.alt = "";
        if (shot.data != null && typeof shot.data !== "string") delete shot.data;
        return shot;
      });
    }
    return out;
  }

  function load() {
    try {
      state = sane(JSON.parse(localStorage.getItem(KEY) || "null"));
    } catch (e) { /* private mode, cleared storage, not JSON: start empty */ }
    // The bytes, from IndexedDB. A draft written before the split still
    // carries them inline, and keeps them until its next save moves them.
    var need = state.shots.filter(function (shot) { return !shot.data; });
    if (!need.length) return Promise.resolve();
    function without(rows) {
      var by = {};
      (rows || []).forEach(function (row) { by[row.name] = row.data; });
      var lost = [];
      state.shots = state.shots.filter(function (shot) {
        if (shot.data) return true;
        if (by[shot.name]) { shot.data = by[shot.name]; shot._stored = true; return true; }
        lost.push(shot.name);
        return false;
      });
      // Said, and taken out of the text as well: a reference left standing
      // sent a post the far end refused for a picture nobody could see on
      // this page any more.
      if (lost.length) {
        lost.forEach(function (name) { state.body = unreference(state.body, name); });
        say(t("app.pictures_lost") + ": " + lost.join(", "), "bad");
      }
    }
    return bytesGetAll().then(without, function () { without([]); });
  }

  var saveTimer = null;
  function save() {
    drawBatch();
    schedulePreview();
    // Debounced: this runs on every keystroke, so writing on each one
    // makes typing stutter.
    clearTimeout(saveTimer);
    saveTimer = setTimeout(function () {
      try {
        localStorage.setItem(KEY, JSON.stringify(forStorage(state)));
        $("kept").textContent = t("app.saved_locally");
        $("kept").hidden = false;
      } catch (e) {
        // Quota, most often, and it matters: the author must not believe
        // their text is safe when it is not.
        // It used to say error.no_reply -- "the server said nothing" --
        // about a server that nothing had asked.
        say(t("app.not_saved"), "bad");
        $("kept").hidden = true;
      }
      // The bytes, once each: a picture already stored is not written again.
      state.shots.forEach(function (shot) {
        if (shot._stored || !shot.data) return;
        shot._stored = "pending";
        bytesPut(shot.name, shot.data).then(function () { shot._stored = true; }, function () {
          shot._stored = false;
          say(t("app.pictures_not_saved"), "bad");
        });
      });
    }, 400);
  }

  function say(text, kind) {
    var el = $("say");
    el.textContent = text || "";
    if (kind) el.dataset.kind = kind; else el.removeAttribute("data-kind");
  }

  // ------------------------------------------------------------- pictures
  function shrink(file) {
    return new Promise(function (done, fail) {
      var url = URL.createObjectURL(file);
      var img = new Image();
      img.onload = function () {
        URL.revokeObjectURL(url);
        var w = img.naturalWidth, h = img.naturalHeight;
        var scale = Math.min(1, MAX_EDGE / Math.max(w, h));
        var cw = Math.max(1, Math.round(w * scale)), ch = Math.max(1, Math.round(h * scale));
        var canvas = document.createElement("canvas");
        canvas.width = cw; canvas.height = ch;
        canvas.getContext("2d").drawImage(img, 0, 0, cw, ch);
        canvas.toBlob(function (blob) {
          if (!blob) return fail(new Error("encode"));
          done({ blob: blob, w: cw, h: ch });
        }, "image/jpeg", 0.88);
      };
      img.onerror = function () { URL.revokeObjectURL(url); fail(new Error("decode")); };
      img.src = url;
    });
  }

  // Names must survive being read back out of markdown, so anything that
  // would need escaping there is replaced rather than kept.
  function safeName(name, index, ext) {
    var base = String(name || "").replace(/\.[^.]*$/, "");
    base = base.normalize ? base.normalize("NFKD").replace(/[̀-ͯ]/g, "") : base;
    base = base.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 100);
    return (base || ("photo-" + index)) + "." + (ext || "jpg");
  }

  // What to call a picture that is passed through untouched. The name it
  // arrived with first, because that is what the author will recognise;
  // the MIME subtype when the name carries no extension at all.
  function extensionOf(file) {
    var m = /\.([a-z0-9]{1,8})$/i.exec(String(file.name || ""));
    if (m) return m[1].toLowerCase();
    var t = /^(image|video)\/([a-z0-9-]+)/i.exec(String(file.type || ""));
    if (!t) return "img";
    var sub = t[2].toLowerCase();
    return { quicktime: "mov", "x-m4v": "m4v", jpeg: "jpg" }[sub] || sub;
  }

  // ⚠️ Two photographs can slug to the same name -- "Vlak v Chocni.jpg" and
  // "vlak v chocni.JPEG", or two a camera numbered alike, once the diacritics
  // and the extension are gone. Both were pushed under that one name and both
  // were really sent; at the far end the second landed on top of the first,
  // because replacing a plain file is what an ordinary re-send does. What
  // arrived was a post referring to two pictures with one of them on disk,
  // and nothing anywhere said so.
  function freeName(name, taken) {
    if (taken.indexOf(name) === -1) return name;
    var dot = name.lastIndexOf(".");
    var stem = dot > 0 ? name.slice(0, dot) : name;
    var ext = dot > 0 ? name.slice(dot) : "";
    var n = 2;
    while (taken.indexOf(stem + "-" + n + ext) !== -1) n++;
    return stem + "-" + n + ext;
  }

  var MEDIA_EXT = /\.(jpe?g|png|gif|webp|heic|heif|avif|tiff?|bmp|mp4|mov|m4v)$/i;
  function isMedia(f) {
    // iOS hands some files over with no type at all; the extension then
    // says what the type did not.
    return /^(image|video)\//.test(f.type) || (!f.type && MEDIA_EXT.test(String(f.name || "")));
  }
  function isVideo(f) {
    return /^video\//.test(f.type) || (!f.type && /\.(mp4|mov|m4v)$/i.test(String(f.name || "")));
  }
  function addFiles(files) {
    var list = Array.prototype.filter.call(files, isMedia);
    var skipped = files.length - list.length;
    if (!list.length) { if (skipped) say(t("app.files_skipped"), "bad"); return; }
    say(t("app.sending") === "" ? "" : "…");
    var asIs = [];
    function keep(file, ext, dataUrl, w, h, kind) {
      state.shots.push({
        name: freeName(safeName(file.name, state.shots.length + 1, ext),
                       state.shots.map(function (s) { return s.name; })),
        data: dataUrl, w: w, h: h, alt: "", raw: !w, size: file.size,
        type: String(file.type || ""), kind: kind || "image"
      });
      drawShots();
    }
    list.reduce(function (chain, file) {
      return chain.then(function () {
        // A video goes as it is: nothing on this page can shrink one, and
        // the blog takes the file whole. The same card, the same button,
        // one more exclamation mark in the text.
        if (isVideo(file)) {
          return blobToDataUrl(file).then(function (dataUrl) {
            keep(file, extensionOf(file), dataUrl, 0, 0, "video");
          });
        }
        return shrink(file).then(function (out) {
          return blobToDataUrl(out.blob).then(function (dataUrl) {
            keep(file, "jpg", dataUrl, out.w, out.h);
          });
        }, function () {
          // ⚠️ A picture this browser cannot open goes as it IS, rather
          // than being refused. Safari does not decode HEIC in an <img>,
          // and HEIC is what an iPhone writes by default -- so the
          // shrinking step fails on exactly the format this app exists to
          // carry. The blog converts HEIC when it arrives, so the honest
          // answer is to hand it over whole. What is lost is the preview
          // and the shrinking: it travels at full size, and the message
          // below says so rather than letting the wait be a mystery.
          return blobToDataUrl(file).then(function (dataUrl) {
            keep(file, extensionOf(file), dataUrl, 0, 0);
            asIs.push(state.shots[state.shots.length - 1].name);
          });
        });
      });
    }, Promise.resolve()).then(function () {
      save();
      var note = asIs.length ? t("app.picture_as_is") + ": " + asIs.join(", ") : "";
      if (skipped) note = (note ? note + " " : "") + t("app.files_skipped");
      say(note, skipped ? "bad" : (asIs.length ? "good" : ""));
    }).catch(function () {
      // Not "the bundle is not a readable archive", which is what this
      // said for one release after the archive itself was removed: the
      // message named a thing that no longer existed anywhere.
      say(t("app.picture_failed"), "bad");
    });
  }

  function blobToDataUrl(blob) {
    return new Promise(function (done, fail) {
      var r = new FileReader();
      r.onload = function () { done(r.result); };
      r.onerror = function () { fail(r.error); };
      r.readAsDataURL(blob);
    });
  }

  // Every picture reference must be a bare name. The engine resolves a
  // bare name into incoming/ and takes anything with a slash as a path --
  // which is fine at a desk, where whoever writes the path already has the
  // file. Sent over the network it is a way to read what the server can
  // read, so the far end refuses it. Checked here as well, because being
  // told by one's own phone before sending beats a rejection afterwards.
  function badReferences() {
    var out = [];
    var re = /!\[[^\n]*?\]\(([^)]+)\)/g;
    var m;
    while ((m = re.exec(state.body)) !== null) {
      var target = m[1].trim();
      if (target.indexOf("/") !== -1 || target.charAt(0) === "~") out.push(target);
    }
    return out;
  }

  // Every name the text refers to that is not among the pictures here.
  function missingReferences() {
    var have = state.shots.map(function (shot) { return shot.name; });
    var out = [], re = /!{1,2}\[[^\n]*?\]\(([^)\s]+)\)/g, m;
    while ((m = re.exec(state.body)) !== null) {
      var name = m[1].trim();
      if (name.indexOf("/") === -1 && name.charAt(0) !== "~" && have.indexOf(name) === -1 && out.indexOf(name) === -1) out.push(name);
    }
    return out;
  }

  function usedInText(name) {
    // Only a bare name counts, because that is what the engine resolves
    // into incoming/. A path would point somewhere else entirely.
    return state.body.indexOf("](" + name + ")") !== -1;
  }

  function drawShots() {
    var box = $("shots");
    box.textContent = "";
    state.shots.forEach(function (shot, i) {
      var row = document.createElement("div");
      row.className = "shot";
      row.innerHTML =
        '<img alt="">' +
        '<div class="side">' +
          '<span class="name"></span>' +
          '<textarea data-i="' + i + '" rows="2"></textarea>' +
          // ⚠️ Insert first and big, remove last and dim. These two used to
          // be a pair of tiny underlined links, the destructive one on the
          // LEFT, and it removed the picture on a single tap -- so a thumb
          // aiming for ![ ] took the photograph away instead, often. The
          // insert is a real button now; the remove sits at the far right,
          // looks inactive, and only becomes a button once it is tapped.
          '<div class="row">' +
            '<button type="button" class="btn small" data-insert="' + i + '"></button>' +
            '<button type="button" class="remove" data-drop="' + i + '"></button>' +
          '</div>' +
        '</div>';
      // A passed-through picture has no preview here for the same reason
      // it could not be shrunk: the browser will not decode it. A video
      // gets a square that says so.
      if (shot.kind === "video") {
        var clip = document.createElement("div");
        clip.className = "clip";
        clip.textContent = t("app.video_badge");
        row.querySelector("img").replaceWith(clip);
      } else if (shot.raw) row.querySelector("img").remove();
      else row.querySelector("img").src = shot.data;
      var used = usedInText(shot.name);
      var name = row.querySelector(".name");
      name.textContent = shot.name + "  " +
        (shot.raw ? formatBytes(shot.size || 0) : shot.w + "×" + shot.h) + " ";
      var chip = document.createElement("span");
      chip.className = "chip " + (used ? "ok" : "warn");
      chip.textContent = used ? t("app.used_in_text") : t("app.unused_image");
      name.appendChild(chip);
      if (!shot.alt) {
        var alt = document.createElement("span");
        alt.className = "chip warn";
        alt.textContent = t("app.alt_missing");
        name.appendChild(alt);
      }
      var ta = row.querySelector("textarea");
      ta.value = shot.alt;
      ta.placeholder = t("app.alt_hint");
      row.querySelector("[data-insert]").textContent = t("app.insert");
      row.querySelector("[data-drop]").textContent = t("app.remove");
      box.appendChild(row);
    });
  }

  // ------------------------------------------------------------ markdown
  // The engine's front matter parser is not YAML and takes values
  // literally: quotes around a title become part of it, and tags in
  // brackets make one tag called "[a, b]". The author never sees that
  // file, so the app has to be the one that knows.
  function frontMatter() {
    var lines = [];
    // Brackets as well as quotes, and for the same reason: the parser takes
    // the value literally, so "[foto] Sobota" would keep its brackets in
    // the title exactly as [foto] would keep them in a tag name.
    var title = state.title.trim()
      .replace(/^(["'])(.*)\1$/, "$2")
      .replace(/^\[(.*)\]$/, "$1")
      .trim();
    if (title) lines.push("title: " + title);
    // Brackets stripped before AND after the split, because both spellings
    // turn up: someone types "[foto, cesty]" out of YAML habit, someone
    // else "[foto], [cesty]". Either way the parser would keep the
    // brackets in the tag name and the blog would grow a tag called
    // "[foto]" -- which reads as a bug in the blog, not in what was typed.
    var raw = state.tags.trim().replace(/^\[|\]$/g, "");
    var tags = raw.split(",").map(function (s) {
      return s.trim()
        .replace(/^#/, "")
        .replace(/^\[|\]$/g, "")
        .replace(/^["']|["']$/g, "")
        .trim();
    }).filter(Boolean);
    if (tags.length) lines.push("tags: " + tags.join(", "));
    // Draft is the default and needs no saying. Only the decision to go
    // straight out is written down -- and the blog reads it the way it
    // reads `publish <slug> --yes` at a desk: published, and announced.
    if (state.publish) lines.push("publish: yes");
    // The name this page will ask the answer by. Written into the post
    // rather than waited for, because the road a reply takes back -- a
    // shortcut opening a URL -- does not reach a page kept on the home
    // screen, which has storage of its own. See askReceipt below.
    if (state.receipt) lines.push("receipt: " + state.receipt);
    // A body that itself opens with --- would be read as front matter by
    // the engine; an empty header in front of it keeps it a body.
    if (!lines.length) return /^---(\n|$)/.test(state.body) ? "---\n---\n\n" : "";
    return "---\n" + lines.join("\n") + "\n---\n\n";
  }

  function markdown() { return frontMatter() + state.body.trim() + "\n"; }

  function slugForFile() {
    var base = (state.title || state.body).trim().split(/\s+/).slice(0, 6).join(" ");
    base = base.normalize ? base.normalize("NFKD").replace(/[̀-ͯ]/g, "") : base;
    base = base.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
    return (base || "post").slice(0, 40) + ".md";
  }

  // ---------------------------------------------------------------- size
  // What is about to travel, counted from what is on the device, so the
  // wait afterwards is not a mystery. The wire carries a third more --
  // the batch is base64 -- and one connection carries all of it.
  function batchSize() {
    var bytes = 0, pictures = 0, videos = 0, files = [];
    state.shots.forEach(function (shot) {
      var data = String(shot.data || "");
      var n = Math.floor((data.length - (data.indexOf(",") + 1)) * 3 / 4);
      bytes += n; files.push(n);
      if (shot.kind === "video") videos++; else pictures++;
    });
    var text = new TextEncoder().encode(markdown()).length;
    bytes += text; files.push(text);
    return { pictures: pictures, videos: videos, bytes: bytes, files: files };
  }

  // What the wire carries: the batch is base64, a third more than the
  // bytes, plus a name and a dot for each file. The receiver measures
  // THAT against its ceiling, so this is the number to compare.
  //
  // Per file: base64 is four characters for every three bytes, and the
  // shortcut's Base64 Encode breaks the line every 76 characters with a
  // CRLF -- two more bytes each -- which the receiver counts, because it
  // measures the stream. Modelled without the wrapping, the page said
  // "fine" over a band of half a megabyte below the ceiling, and the
  // phone spent the upload finding out.
  function wireBytesOf(bytes) {
    var chars = 4 * Math.ceil(bytes / 3);
    return chars + 2 * Math.ceil(chars / 76);
  }
  function wireBytes(size) {
    var files = (size.files || []);
    var total = 0;
    if (files.length) files.forEach(function (n) { total += wireBytesOf(n); });
    else total = wireBytesOf(size.bytes);
    return total + (size.pictures + size.videos + 1) * 80;
  }
  function overLimit(size, maxMb) {
    return !!maxMb && wireBytes(size) > maxMb * 1048576;
  }

  function formatBytes(n) {
    var kb = Math.round(n / 1024);
    if (n > 0 && kb === 0) kb = 1;   // a few bytes are not nothing
    if (kb < 1024) return kb + " kB";
    return String(Math.round(n / 1024 / 1024 * 10) / 10).replace(".", t("app.decimal")) + " MB";
  }

  // "3 pictures, 1 video, 4.2 MB" -- with the plural the reader's
  // language wants: one, a few (two to four, which Czech counts
  // differently), many.
  function plural(n, what) {
    return n + " " + t("app." + what + "_" + (n === 1 ? "1" : n < 5 ? "few" : "many"));
  }
  function describeBatch(size) {
    var parts = [];
    if (size.pictures) parts.push(plural(size.pictures, "pictures"));
    if (size.videos) parts.push(plural(size.videos, "videos"));
    if (!parts.length) parts.push(t("app.text_only"));
    return parts.join(", ") + ", " + formatBytes(size.bytes);
  }

  // ----------------------------------------------------------------- zip
  // Written here rather than pulled in: a library would be the only
  // dependency in the whole app, and "stored" is all this needs -- the
  // photos are already JPEG, so deflating them buys nothing.
  var CRC_TABLE = (function () {
    var table = new Uint32Array(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      table[n] = c >>> 0;
    }
    return table;
  })();

  function crc32(bytes) {
    var c = 0xFFFFFFFF;
    for (var i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
  }

  function zip(entries) {
    var chunks = [], central = [], offset = 0;
    var enc = new TextEncoder();
    // One fixed timestamp instead of the clock: the same post packed twice
    // then gives the same bytes, which makes a failed send safe to repeat.
    var dosTime = 0, dosDate = 33; // 1980-01-01 00:00

    entries.forEach(function (entry) {
      var nameBytes = enc.encode(entry.name);
      var sum = crc32(entry.bytes);
      var local = new DataView(new ArrayBuffer(30));
      local.setUint32(0, 0x04034b50, true);
      local.setUint16(4, 20, true);
      local.setUint16(6, 0x0800, true);   // names are UTF-8
      local.setUint16(8, 0, true);        // stored, no compression
      local.setUint16(10, dosTime, true);
      local.setUint16(12, dosDate, true);
      local.setUint32(14, sum, true);
      local.setUint32(18, entry.bytes.length, true);
      local.setUint32(22, entry.bytes.length, true);
      local.setUint16(26, nameBytes.length, true);
      local.setUint16(28, 0, true);
      chunks.push(new Uint8Array(local.buffer), nameBytes, entry.bytes);

      var dir = new DataView(new ArrayBuffer(46));
      dir.setUint32(0, 0x02014b50, true);
      dir.setUint16(4, 20, true);
      dir.setUint16(6, 20, true);
      dir.setUint16(8, 0x0800, true);
      dir.setUint16(10, 0, true);
      dir.setUint16(12, dosTime, true);
      dir.setUint16(14, dosDate, true);
      dir.setUint32(16, sum, true);
      dir.setUint32(20, entry.bytes.length, true);
      dir.setUint32(24, entry.bytes.length, true);
      dir.setUint16(28, nameBytes.length, true);
      dir.setUint32(42, offset, true);
      central.push(new Uint8Array(dir.buffer), nameBytes);

      offset += 30 + nameBytes.length + entry.bytes.length;
    });

    var centralSize = central.reduce(function (n, c) { return n + c.length; }, 0);
    var end = new DataView(new ArrayBuffer(22));
    end.setUint32(0, 0x06054b50, true);
    end.setUint16(8, entries.length, true);
    end.setUint16(10, entries.length, true);
    end.setUint32(12, centralSize, true);
    end.setUint32(16, offset, true);
    return new Blob(chunks.concat(central, [new Uint8Array(end.buffer)]),
                    { type: "application/zip" });
  }

  function dataUrlToBytes(url) {
    var base64 = url.slice(url.indexOf(",") + 1);
    var binary = atob(base64);
    var out = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  }

  // What is sent: one file per picture and one for the text, each on its
  // own. The receiver takes one file per connection, and the markdown
  // arriving is what makes the post -- so everything the text names has
  // to be on the server before the text goes.
  //
  // The markdown is LAST in the list on purpose. The shortcut sends the
  // pictures first and the text after them, in two passes, because the
  // order a share sheet hands files over in is nobody's promise; when it
  // does survive, a single loop happens to be right too.
  function buildFiles() {
    var enc = new TextEncoder();
    var files = state.shots.map(function (shot) {
      // A picture that went through the canvas is a JPEG whatever it
      // arrived as, and safeName has given it a .jpg; one passed through
      // untouched -- a HEIC, a video -- keeps the type it came with.
      var type = shot.raw ? (shot.type || "application/octet-stream") : "image/jpeg";
      return new File([dataUrlToBytes(shot.data)], shot.name, { type: type });
    });
    // text/plain rather than text/markdown. iOS decides what a shared file
    // IS from its filename extension and never reads this field, so the .md
    // survives either way; elsewhere text/plain is a type share targets
    // actually accept, and the far end reads only the name.
    files.push(new File([enc.encode(markdown())], slugForFile(), { type: "text/plain" }));
    return files;
  }

  // ⚠️ Only for the way out when sharing is not on offer -- and on a Mac
  // that is the ordinary case, not the rare one: Safari there does not
  // hand files from a page to a share target at all, so this is the path
  // a desktop takes every time. Saved as ONE archive because a browser
  // will not give four downloads in a row, and the person unpacks it and
  // hands the files inside to the shortcut. The archive never reaches the
  // server: the receiver has no unpacking in it, and a post.zip sent
  // whole would simply be stored in incoming/ and make nothing.
  // ⚠️ Same order as buildFiles: pictures first, the markdown LAST. The
  // markdown arriving is what makes the post, so whoever unpacks this
  // archive and hands the files over has to keep that order -- the text
  // going first means the blog answers missing_images about a delivery
  // where nothing was missing.
  function buildBundle() {
    var enc = new TextEncoder();
    var entries = state.shots.map(function (shot) {
      return { name: shot.name, bytes: dataUrlToBytes(shot.data) };
    });
    entries.push({ name: slugForFile(), bytes: enc.encode(markdown()) });
    return zip(entries);
  }

  // -------------------------------------------------------------- events
  ["title", "body", "tags"].forEach(function (id) {
    $(id).addEventListener("input", function (e) {
      state[id] = e.target.value;
      if (id === "body") drawShots();   // the "used in text" chips follow along
      if (id === "tags") drawTags();
      save();
    });
  });

  $("shots").addEventListener("input", function (e) {
    if (e.target.tagName !== "TEXTAREA") return;
    var shot = state.shots[Number(e.target.dataset.i)];
    var before = shot.alt;
    shot.alt = e.target.value;
    // The description has to follow the reference that is already in the
    // text. Without this it was copied once, when the picture was
    // inserted, and a description written afterwards stayed on this screen
    // only -- the post went out as ![](photo.jpg) and nothing said so.
    if (retitle(shot.name, before, shot.alt)) {
      // The chips follow the text, so the cards are redrawn -- and the
      // redraw used to take the focus, and with it the keyboard, out of
      // the very field being typed into, after every letter.
      var i = e.target.dataset.i, at = e.target.selectionStart, to = e.target.selectionEnd;
      drawShots();
      var again = $("shots").querySelector('textarea[data-i="' + i + '"]');
      if (again) { again.focus(); try { again.setSelectionRange(at, to); } catch (err) { /* fine */ } }
    }
    save();
  });

  // ⚠️ A blank line on each side, counted. The blog renders a picture only
  // as a paragraph of its own and refuses one sitting on the line straight
  // after a sentence -- and this button used to put in a single newline,
  // so the one route that needs no typing at all reliably produced the one
  // post that cannot be written. Counted, so pressing it twice does not
  // open a chasm, and so an existing blank line is left alone.
  function spacedMark(before, after, mark) {
    var gapBefore = before === "" ? "" : ["\n\n", "\n", ""][Math.min(2, /\n*$/.exec(before)[0].length)];
    var gapAfter = after === "" ? "\n" : ["\n\n", "\n", ""][Math.min(2, /^\n*/.exec(after)[0].length)];
    return gapBefore + mark + gapAfter;
  }

  // Takes every ![…](name) line out of the text, together with the blank
  // line that was keeping it a paragraph of its own -- so removing a
  // picture never leaves a chasm where it stood, and never leaves a
  // reference the far end would refuse. A reference that shares a line
  // with prose is left alone: cutting words out of a sentence is not this
  // button's business.
  function unreference(text, name) {
    // One mark or two: a picture is ![…](name), a video !![…](name).
    var line = new RegExp("^[ \\t]*!{1,2}\\[[^\\n]*\\]\\(" + name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\)[ \\t]*$");
    var out = [], lines = text.split("\n");
    for (var i = 0; i < lines.length; i++) {
      if (!line.test(lines[i])) { out.push(lines[i]); continue; }
      // The blank line that followed it goes too: the reference and its
      // paragraph gap were put in together, and they leave together.
      if (i + 1 < lines.length && lines[i + 1].trim() === "") i++;
    }
    return out.join("\n");
  }

  // Rewrites ![old](name) to ![new](name). Only an exact match of what was
  // there is replaced: anything else is the author's own wording and is
  // not ours to overwrite.
  // A description is one line in the markdown, whatever the box held: a
  // newline in ![…](name) is a picture the engine refuses, with a reason
  // that names the wrong thing.
  function oneLine(text) { return String(text || "").replace(/\s+/g, " ").trim(); }

  function retitle(name, before, after) {
    var body = $("body");
    var find = "![" + oneLine(before) + "](" + name + ")";
    if (body.value.indexOf(find) === -1) return false;
    body.value = body.value.split(find).join("![" + oneLine(after) + "](" + name + ")");
    state.body = body.value;
    return true;
  }

  $("shots").addEventListener("click", function (e) {
    var drop = e.target.closest("[data-drop]");
    if (drop) {
      // Two taps, with the second one having to come soon. The first only
      // ARMS the control -- it turns into a button that says what it is
      // about to do -- and a tap that never comes lets it fall back to
      // inactive. The same rule the big Discard below has followed since
      // its first version; the picture's own remove never had it.
      if (drop.dataset.arm !== "yes") {
        arm(drop, t("app.remove_confirm"), t("app.remove"));
        return;
      }
      // ⚠️ The reference goes with the picture. Removing a photograph
      // used to leave its ![…](name) standing in the text, and the post
      // then failed at the far end with missing_images -- for a picture
      // the author had deliberately taken out.
      var gone = state.shots[Number(drop.dataset.drop)];
      state.shots.splice(Number(drop.dataset.drop), 1);
      forget(bytesDelete(gone.name));
      var body = $("body");
      body.value = unreference(body.value, gone.name);
      state.body = body.value;
      drawShots(); save(); return;
    }
    var insert = e.target.closest("[data-insert]");
    if (insert) {
      var shot = state.shots[Number(insert.dataset.insert)];
      var body = $("body");
      var at = body.selectionStart != null ? body.selectionStart : body.value.length;
      var before = body.value.slice(0, at), after = body.value.slice(at);
      // ⚠️ A BLANK LINE on each side, not one newline. The blog renders a
      // picture only as a paragraph of its own and refuses one sitting on
      // the line straight after a sentence -- and this button used to
      // insert exactly that shape. The one route that needs no typing at
      // all reliably produced the one post that cannot be written, and
      // the refusal came back from the far end as nothing at all.
      // Counted, so pressing it twice does not open a chasm.
      // Two marks for a video, one for a picture: that is how the blog
      // tells them apart, and the reader never has to know.
      var bang = shot.kind === "video" ? "!!" : "!";
      body.value = before + spacedMark(before, after,
                                       bang + "[" + oneLine(shot.alt) + "](" + shot.name + ")") + after;
      state.body = body.value;
      drawShots(); save();
    }
  });

  $("tagrow").addEventListener("click", function (e) {
    var b = e.target.closest("[data-tag]");
    if (!b) return;
    // The chosen tag replaces whatever was being typed, and the comma
    // after it leaves the field ready for the next one.
    var parts = tagParts(state.tags);
    state.tags = parts.done.concat([b.dataset.tag]).join(", ") + ", ";
    $("tags").value = state.tags;
    drawTags(); save();
  });

  $("mode").addEventListener("click", function (e) {
    var seg = e.target.closest("[data-mode]");
    if (!seg) return;
    state.publish = seg.dataset.mode === "publish";
    drawMode(); save();
  });
  function drawMode() {
    var segs = $("mode").querySelectorAll("[data-mode]");
    for (var i = 0; i < segs.length; i++) {
      segs[i].classList.toggle("on", (segs[i].dataset.mode === "publish") === !!state.publish);
    }
    $("send").textContent = t(state.publish ? "app.send_publish" : "app.send");
  }

  $("pick").addEventListener("click", function () { $("file").click(); });
  $("file").addEventListener("change", function (e) {
    addFiles(e.target.files);
    e.target.value = "";
  });

  document.addEventListener("paste", function (e) {
    var items = (e.clipboardData || {}).items || [];
    var files = [];
    for (var i = 0; i < items.length; i++) {
      if (items[i].kind === "file" && /^image\//.test(items[i].type)) {
        var f = items[i].getAsFile();
        if (f) files.push(f);
      }
    }
    if (files.length) { e.preventDefault(); addFiles(files); }
  });

  // Arms a destructive control for five seconds: it changes from something
  // that looks inactive into a button that names what it will do, and a
  // second tap inside that window is what does it. Left alone, it falls
  // back. One rule for both the big Discard and each picture's remove.
  function arm(btn, armedLabel, restLabel) {
    btn.dataset.arm = "yes";
    btn.textContent = armedLabel;
    clearTimeout(btn._armTimer);
    btn._armTimer = setTimeout(function () {
      btn.dataset.arm = ""; btn.textContent = restLabel;
    }, 5000);
  }

  $("discard").addEventListener("click", function () {
    var btn = this;
    if (btn.dataset.arm !== "yes") {
      arm(btn, t("app.discard_confirm"), t("app.discard"));
      say(t("app.discard_note"));
      return;
    }
    clearTimeout(btn._armTimer);
    btn.dataset.arm = ""; btn.textContent = t("app.discard");
    clearTimeout(saveTimer);
    state = { title: "", body: "", tags: "", shots: [], publish: false, sentAt: 0, receipt: "" };
    try { localStorage.removeItem(KEY); } catch (e) { /* nothing to clear */ }
    forget(bytesClear());
    render();
    say(t("app.discarded"), "good");
  });

  $("send").addEventListener("click", function () {
    if (!state.body.trim()) { say(t("app.no_body"), "bad"); $("body").focus(); return; }
    // A refusal, not a warning: the far end rejects these outright, so
    // sending would only trade a message here for a failure there.
    var bad = badReferences();
    if (bad.length) {
      say(t("error.bad_reference") + " " + bad.join(", "), "bad");
      return;
    }
    // A picture the text names and this page no longer has -- its bytes
    // were lost, or the line was typed by hand -- would be refused at the
    // far end under a name the author cannot see anywhere here.
    var gone = missingReferences();
    if (gone.length) {
      say(t("app.reference_missing").replace("{names}", gone.join(", ")), "bad");
      return;
    }
    // Said once, and only about pictures the text actually shows: a
    // description missing from a published picture cannot be added later
    // by the person who needed it. Not a refusal -- the author may have
    // reasons -- but it must not leave silently either.
    // One latch per reason: the second tap that answers "no description"
    // must not also answer "over the limit".
    var mute = state.shots.filter(function (shot) {
      return usedInText(shot.name) && !(shot.alt || "").trim();
    });
    if (mute.length && this.dataset.anyway !== "alt") {
      this.dataset.anyway = "alt";
      say(t("app.alt_missing") + ": " + mute.map(function (s) { return s.name; }).join(", "), "bad");
      return;
    }
    // Over the server's ceiling as this page knows it. A second tap
    // sends anyway, because the page's number is the build's and the
    // server's may have been raised since; but the first tap says it.
    if (overLimit(batchSize(), maxMb()) && this.dataset.anyway !== "size") {
      this.dataset.anyway = "size";
      say(t("app.batch_over_send").replace("{max}", String(maxMb()))
                                  .replace("{wire}", formatBytes(wireBytes(batchSize()))), "bad");
      return;
    }
    this.dataset.anyway = "";
    say(t("app.handing").replace("{what}", describeBatch(batchSize())));
    // Minted before the files are built, because it is written INTO the
    // markdown they carry. A fresh one per send: an answer belongs to the
    // post that asked for it.
    state.receipt = newReceipt();
    var files;
    try { files = buildFiles(); } catch (e) {
      // A picture whose stored bytes will not decode. Said, rather than
      // a button that does nothing from now on.
      say(t("app.picture_failed"), "bad");
      return;
    }
    // The hand-off is what a later reply is allowed to answer for: a
    // reply that arrives at a page which sent nothing clears nothing.
    state.sentAt = Date.now();
    save();
    // Sharing hands the files to the shortcut. Whether a browser will do
    // ⚠️ canShare is a far smaller question than it looks: it answers
    // whether this page may share at all and whether the list is not empty,
    // and NOTHING about the types, the sizes or how many there are. It
    // cannot be used to validate a share. So saving is not a fallback
    // bolted on afterwards but the other half of the same button.
    if (navigator.canShare && navigator.canShare({ files: files })) {
      // files ALONE. Adding title or text makes sharing fail on iOS often
      // enough that the MDN example itself carries the workaround
      // (mdn/content#32019): the files go, everything else is dropped.
      navigator.share({ files: files })
        .then(function () { say(t("app.bundle_note"), "good"); askReceipt(state.receipt, false); })
        .catch(function (err) {
          // ⚠️ AbortError is the NORMAL end of this path, not a failure.
          // A share-sheet shortcut that hands the run over to the
          // Shortcuts app -- which this one must, to be allowed to open
          // an SSH connection -- leaves the extension without completing
          // the share, and WebKit reports that as an abort. The very same
          // error also means the person closed the sheet, and the page
          // cannot tell the two apart. So the message claims neither:
          // it says the files left, and where the answer is.
          if (err && err.name === "AbortError") {
            say(t("app.share_cancelled"), "good");
            askReceipt(state.receipt, false);
            return;
          }
          try { saveBundle(); } catch (e2) { say(t("app.picture_failed"), "bad"); }
        });
    } else {
      try { saveBundle(); } catch (e) { say(t("app.picture_failed"), "bad"); }
    }
  });

  // The road for a browser that will not hand files over -- Safari at a
  // desk is the ordinary case, not the rare one. It asks for the receipt
  // exactly as the share road does:
  // the answer does not depend on HOW the files travelled, and a page that
  // saved a bundle and then never mentioned the post again was the one
  // road with no way back at all.
  function saveBundle() {
    // download() says what it did; this adds the half that matters here --
    // the page will go on asking what became of the post.
    download(buildBundle());
    askReceipt(state.receipt, false);
  }

  // The name matters as much as the bytes: the receiver decides what a
  // delivery IS by the name of the file in it, so a saved publish request
  // called post.zip is not a publish request at all.
  function download(blob, name) {
    var url = URL.createObjectURL(blob);
    var a = document.createElement("a");
    a.href = url;
    a.download = name || "post.zip";
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 10000);
    say(t("app.saved_instead"), "good");
  }

  // ---------------------------------------------------------------- site
  // What the build knows about the blog this page belongs to, written
  // into site.js beside it: the name and claim, the palette, the favicon,
  // and the tags the blog has used, each with a count. Absent -- an older
  // build, a page opened from disk -- and the page is what it always was:
  // blog.sh's own colours, no second line, no suggestions.
  var SITE = window.BLOG_SITE || null;

  function luminance(hex) {
    var m = /^#?([0-9a-f]{6})$/i.exec(String(hex || "").trim());
    if (!m) return null;
    var parts = [0, 2, 4].map(function (i) {
      var c = parseInt(m[1].slice(i, i + 2), 16) / 255;
      return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2];
  }

  // The blog's palette in this page's terms. The blog names seven colours;
  // the page uses a few more, and takes them from the nearest: the tinted
  // nav background is what a sunken field looks like, the pill colour is
  // the soft accent, and a card is white by day and the nav colour by
  // night. The text on an accent button is whichever of white and near
  // black the accent's lightness asks for.
  function paletteCss(colors) {
    function block(c, dark) {
      var out = [];
      if (c.bg) out.push("--bg:" + c.bg);
      if (c.text) out.push("--text:" + c.text);
      if (c.meta_text) out.push("--meta:" + c.meta_text);
      if (c.border) out.push("--border:" + c.border);
      if (c.accent) {
        out.push("--accent:" + c.accent);
        var l = luminance(c.accent);
        if (l !== null) out.push("--on-accent:" + (l < 0.4 ? "#ffffff" : "#1a1c1e"));
      }
      if (c.pill_bg) out.push("--accent-soft:" + c.pill_bg);
      if (c.nav_bg) { out.push("--sunk:" + c.nav_bg); if (dark) out.push("--surface:" + c.nav_bg); }
      if (!dark && c.bg) out.push("--surface:#ffffff");
      return out.join(";");
    }
    var light = block((colors && colors.light) || {}, false);
    var dark = block((colors && colors.dark) || {}, true);
    var css = "";
    if (light) css += ":root{" + light + "}\n";
    if (dark) {
      css += "@media (prefers-color-scheme:dark){:root:not([data-theme=\"light\"]){" + dark + "}}\n";
      css += ":root[data-theme=\"dark\"]{" + dark + "}\n";
    }
    return css;
  }

  function applySite() {
    if (!SITE) return;
    var head = document.head;
    if (SITE.colors) {
      var style = document.createElement("style");
      style.textContent = paletteCss(SITE.colors);
      head.appendChild(style);
      var accent = SITE.colors.light && SITE.colors.light.accent;
      var theme = document.querySelector('meta[name="theme-color"]');
      if (accent && theme) theme.content = accent;
    }
    if (SITE.favicon) {
      var mark = $("mark");
      mark.src = SITE.favicon;
      mark.hidden = false;
      ["icon", "apple-touch-icon"].forEach(function (rel) {
        var link = document.createElement("link");
        link.rel = rel; link.href = SITE.favicon;
        head.appendChild(link);
      });
    }
    if (SITE.name) {
      $("site-name").textContent = SITE.name;
      $("site-claim").textContent = SITE.claim || "";
      $("site").hidden = false;
      document.title = SITE.name + " · " + t("app.subtitle");
      // What the phone calls the page once it is on the home screen.
      var title = document.createElement("meta");
      title.name = "apple-mobile-web-app-title"; title.content = SITE.name;
      head.appendChild(title);
    }
  }

  // ---------------------------------------------------------------- tags
  // The tags the blog has used, offered as the author types: those that
  // begin with what is typed first, then those that merely contain it,
  // each group by how often the blog has used them. With nothing typed
  // yet, the ones used in the last twelve months, most used first -- not
  // the most used of all time, which on an imported archive are the
  // places it came from, and nobody tags a new post with those. Never one
  // the post already carries. Offered so a tag is tapped rather than
  // typed -- and typed as it was before, instead of the blog growing a
  // second spelling of it.
  function suggestTags(all, typed, taken, limit) {
    var q = String(typed || "").trim().toLowerCase();
    var have = (taken || []).map(function (s) { return String(s).toLowerCase(); });
    var starts = [], holds = [];
    (all || []).forEach(function (row) {
      var name = String(row[0]), low = name.toLowerCase();
      if (have.indexOf(low) !== -1) return;
      if (!q) { if (row[2] > 0) starts.push(row); }
      else if (low.indexOf(q) === 0) starts.push(row);
      else if (low.indexOf(q) !== -1) holds.push(row);
    });
    var byName = function (a, b) { return a[0].toLowerCase() < b[0].toLowerCase() ? -1 : 1; };
    var byUse = function (a, b) { return (b[1] - a[1]) || byName(a, b); };
    var byRecent = function (a, b) { return ((b[2] || 0) - (a[2] || 0)) || byUse(a, b); };
    if (!q) return starts.sort(byRecent).slice(0, limit || 8);
    return starts.sort(byUse).concat(holds.sort(byUse)).slice(0, limit || 8);
  }

  // The tags field as the author has it: the ones finished, and the one
  // being typed after the last comma.
  function tagParts(value) {
    var parts = String(value || "").split(",");
    var typing = parts.pop();
    return { done: parts.map(function (s) { return s.trim(); }).filter(Boolean), typing: typing.trim() };
  }

  function drawTags() {
    var row = $("tagrow");
    if (!row) return;
    if (!SITE || !SITE.tags || !SITE.tags.length) { row.hidden = true; return; }
    var parts = tagParts(state.tags);
    var pairs = suggestTags(SITE.tags, parts.typing, parts.done, 8);
    row.textContent = "";
    row.hidden = !pairs.length;
    pairs.forEach(function (pair) {
      var b = document.createElement("button");
      b.type = "button";
      b.dataset.tag = pair[0];
      b.textContent = pair[0];
      var n = document.createElement("b");
      n.textContent = String(pair[1]);
      b.appendChild(n);
      row.appendChild(b);
    });
  }

  // --------------------------------------------------------------- marks
  // The marks the text takes, from the row of buttons above it. Each is a
  // function of the text and the selection alone, so it can be checked
  // without a screen. A paired mark wraps what is selected and, applied
  // again to the same selection, takes itself off; with nothing selected
  // it puts the pair in and leaves the caret between. A line mark goes to
  // the start of every line the selection touches, and comes off the
  // same way. Words for the link's two placeholders come from the reader's
  // language.
  var PAIRED = { bold: "**", italic: "*", strike: "~~", code: "`" };
  var LINED = { h2: "## ", quote: "> ", ul: "- " };

  function applyMark(value, start, end, kind, words) {
    var v = String(value || "");
    start = Math.max(0, Math.min(start, v.length));
    end = Math.max(start, Math.min(end, v.length));
    var sel = v.slice(start, end);
    var mark = PAIRED[kind];
    if (mark) {
      var n = mark.length;
      // Selected together with its marks, or between them: either way
      // the second tap takes them off.
      // A mark of one character next to another of the same character is
      // part of a longer mark -- the * of **bold** -- and not this one:
      // tapping italic on a bold word used to un-bold it.
      var edge = function (a, b) { return n === 1 && (v.charAt(a - 1) === mark || v.charAt(b) === mark); };
      if (sel.length >= 2 * n && sel.slice(0, n) === mark && sel.slice(-n) === mark && !edge(start, end)) {
        return { value: v.slice(0, start) + sel.slice(n, -n) + v.slice(end), start: start, end: end - 2 * n };
      }
      if (start >= n && v.slice(start - n, start) === mark && v.slice(end, end + n) === mark && !edge(start - n, end + n)) {
        return { value: v.slice(0, start - n) + sel + v.slice(end + n), start: start - n, end: end - n };
      }
      return { value: v.slice(0, start) + mark + sel + mark + v.slice(end), start: start + n, end: end + n };
    }
    if (kind === "link") {
      var w = words || {};
      // The whole word, when the selection stops inside one: a phone
      // selects a word up to its dot, so "sean.cz" arrived as "sean." --
      // and half an address is no address. A bare caret takes the word
      // it stands in or just after. Brackets and the punctuation a
      // sentence puts around a word stay outside the link.
      while (start > 0 && /\S/.test(v.charAt(start - 1))) start--;
      while (end < v.length && /\S/.test(v.charAt(end))) end++;
      // Inside a link that already is one, there is nothing to make.
      var around = v.slice(Math.max(0, start - 1), end + 1);
      if (/^\[[^\]]*\]\([^)]*\)$/.test(v.slice(start, end)) || /\]\(/.test(v.slice(start, end))) {
        return { value: v, start: start, end: end };
      }
      while (start < end && /[([{"']/.test(v.charAt(start))) start++;
      while (end > start && /[)\]}.,;:!?"']/.test(v.charAt(end - 1))) end--;
      sel = v.slice(start, end);
      var isUrl = /^(https?:\/\/|mailto:)\S+$/i.test(sel);
      // A bare domain is an address too, and its own best label.
      var isDomain = !isUrl && /^(www\.)?[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(\/\S*)?$/i.test(sel);
      var label = isUrl ? String(w.text || "text") : (sel || String(w.text || "text"));
      var url = isUrl ? sel : isDomain ? "https://" + sel : String(w.url || "https://");
      var out = "[" + label + "](" + url + ")";
      // What is left selected is what the author may still want to type:
      // the words for an address, the address for words.
      var onLabel = isUrl || isDomain;
      var from = onLabel ? start + 1 : start + 1 + label.length + 2;
      var len = onLabel ? label.length : url.length;
      return { value: v.slice(0, start) + out + v.slice(end), start: from, end: from + len };
    }
    if (kind === "fence") {
      var open = (start > 0 && v.charAt(start - 1) !== "\n" ? "\n" : "") + "```\n";
      var close = "\n```" + (end < v.length && v.charAt(end) !== "\n" ? "\n" : "");
      return { value: v.slice(0, start) + open + sel + close + v.slice(end), start: start + open.length, end: start + open.length + sel.length };
    }
    // Line marks: the lines the selection touches, whole.
    var ls = v.lastIndexOf("\n", start - 1) + 1;
    var probe = end > start ? end - 1 : end;
    var le = v.indexOf("\n", probe);
    if (le === -1) le = v.length;
    var lines = v.slice(ls, le).split("\n");
    var has;
    // Added, a mark goes on every line once -- a line that already had it
    // is not given a second one -- and every line loses it when they all
    // had it.
    if (kind === "ol") {
      has = lines.every(function (l) { return /^\d+\. /.test(l); });
      lines = lines.map(function (l, i) { var bare = l.replace(/^\d+\. /, ""); return has ? bare : (i + 1) + ". " + bare; });
    } else {
      var prefix = LINED[kind];
      if (!prefix) return { value: v, start: start, end: end };
      has = lines.every(function (l) { return l.indexOf(prefix) === 0; });
      lines = lines.map(function (l) { var bare = l.indexOf(prefix) === 0 ? l.slice(prefix.length) : l; return has ? bare : prefix + bare; });
    }
    var block = lines.join("\n");
    var nv = v.slice(0, ls) + block + v.slice(le);
    if (end > start) return { value: nv, start: ls, end: ls + block.length };
    // A bare caret stays on its line, moved by what the line gained or lost
    // before it.
    var firstDelta = lines[0].length - v.slice(ls, le).split("\n")[0].length;
    var caret = Math.max(ls, start + firstDelta);
    return { value: nv, start: caret, end: caret };
  }

  // The toolbar. pointerdown is swallowed so the text keeps its focus and
  // its selection: a button that took the focus would close the keyboard
  // on a phone and lose the very selection it was about to mark.
  (function () {
    var bar = $("marks");
    if (!bar) return;
    bar.addEventListener("pointerdown", function (e) {
      if (e.target.closest("[data-mark]")) e.preventDefault();
    });
    Array.prototype.forEach.call(bar.querySelectorAll("[data-mark]"), function (b) {
      var name = t("app.mark_" + b.dataset.mark);
      b.title = name;
      b.setAttribute("aria-label", name);
    });
    bar.addEventListener("click", function (e) {
      var b = e.target.closest("[data-mark]");
      if (!b) return;
      var ta = $("body");
      var out = applyMark(ta.value, ta.selectionStart, ta.selectionEnd, b.dataset.mark,
                          { text: t("app.mark_link_text"), url: t("app.mark_link_url") });
      ta.value = out.value;
      ta.focus();
      ta.setSelectionRange(out.start, out.end);
      state.body = ta.value;
      drawShots(); save();
    });
  })();

  // ------------------------------------------------------------- preview
  // The post as the blog would show it, near enough: the markdown this
  // page knows -- paragraphs, headings, bold, italic, strikethrough,
  // code, links, quotes, lists, fenced code, and a picture on a line of
  // its own -- rendered here and dressed in the blog's own stylesheets,
  // which site.js names. Near enough, not exact: the engine renders the
  // real thing, and the draft's preview after sending is that. What this
  // is for is seeing the shape of a post before it leaves the phone.
  function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  // Code spans first and kept apart, so a * inside one is not emphasis.
  function inlineHtml(text) {
    return String(text).split(/(`[^`]+`)/).map(function (piece) {
      if (/^`[^`]+`$/.test(piece)) return "<code>" + escapeHtml(piece.slice(1, -1)) + "</code>";
      var out = escapeHtml(piece);
      out = out.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
      out = out.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1<em>$2</em>");
      out = out.replace(/~~(.+?)~~/g, "<del>$1</del>");
      // A link only to somewhere a link may go; anything else stays words.
      // One level of parentheses inside an address, as the engine allows:
      // a Wikipedia link ends in one more often than not.
      out = out.replace(/\[([^\]]+)\]\(((?:\([^()\s]*\)|[^)\s])+)\)/g, function (_, label, url) {
        return /^(https?:\/\/|mailto:|\/)/i.test(url) ? '<a href="' + url + '">' + label + "</a>" : label;
      });
      return out;
    }).join("");
  }

  function renderMarkdown(md, shots) {
    var byName = {};
    (shots || []).forEach(function (shot) { byName[shot.name] = shot; });
    var lines = String(md || "").replace(/\r\n?/g, "\n").split("\n");
    var html = [], para = [], i = 0, m;
    var LIST = /^\s*([-*+]|\d+\.)\s+/;
    function flush() {
      if (para.length) html.push("<p>" + inlineHtml(para.join("\n")) + "</p>");
      para = [];
    }
    while (i < lines.length) {
      var line = lines[i];
      if (/^```/.test(line)) {
        flush();
        var code = [];
        i++;
        while (i < lines.length && !/^```/.test(lines[i])) code.push(lines[i++]);
        i++;
        html.push('<pre class="code-block"><code>' + escapeHtml(code.join("\n")) + "</code></pre>");
        continue;
      }
      if ((m = /^(#{1,3})\s+(.+)$/.exec(line))) {
        flush();
        var level = m[1].length + 1;   // a post's own title is the h1
        html.push("<h" + level + ">" + inlineHtml(m[2]) + "</h" + level + ">");
        i++; continue;
      }
      var glued = function () {
        // The engine takes a picture only as a paragraph of its own: a
        // blank line before it and after it. The preview used to show a
        // figure where the engine would refuse the post.
        return (i > 0 && lines[i - 1].trim() !== "") || (i + 1 < lines.length && lines[i + 1].trim() !== "");
      };
      if ((m = /^!!\[([^\n]*)\]\(([^)\s]+)\)\s*$/.exec(line))) {
        flush();
        var clip = byName[m[2]];
        if (glued()) {
          html.push('<figure><div class="no-preview">' + escapeHtml(t("app.preview_picture_glued").replace("{name}", m[2])) + "</div></figure>");
        } else if (clip && clip.data) {
          html.push('<figure><video controls playsinline src="' + escapeHtml(clip.data) + '"></video>' +
                    (m[1] ? "<figcaption>" + escapeHtml(m[1]) + "</figcaption>" : "") + "</figure>");
        } else {
          html.push('<figure><div class="no-preview">' +
                    escapeHtml(t("app.preview_missing_picture").replace("{name}", m[2])) + "</div></figure>");
        }
        i++; continue;
      }
      if ((m = /^!\[([^\n]*)\]\(([^)\s]+)\)\s*$/.exec(line))) {
        flush();
        var shot = byName[m[2]];
        if (glued()) {
          html.push('<figure><div class="no-preview">' + escapeHtml(t("app.preview_picture_glued").replace("{name}", m[2])) + "</div></figure>");
        } else if (shot && !shot.raw) {
          html.push('<figure><img src="' + escapeHtml(shot.data) + '" alt="' + escapeHtml(m[1]) + '"></figure>');
        } else {
          // A picture the browser could not decode has no bytes to show
          // here; the blog converts it on arrival. Said in the box where
          // it will stand, rather than left out as if the line were not
          // there.
          html.push('<figure><div class="no-preview">' +
                    escapeHtml(t("app.preview_missing_picture").replace("{name}", m[2])) + "</div></figure>");
        }
        i++; continue;
      }
      if (/^>\s?/.test(line)) {
        flush();
        var quote = [];
        while (i < lines.length && /^>\s?/.test(lines[i])) quote.push(lines[i++].replace(/^>\s?/, ""));
        html.push("<blockquote><p>" + inlineHtml(quote.join("\n")) + "</p></blockquote>");
        continue;
      }
      if (LIST.test(line)) {
        flush();
        var ordered = /^\s*\d+\./.test(line);
        var items = [];
        while (i < lines.length && LIST.test(lines[i])) items.push("<li>" + inlineHtml(lines[i++].replace(LIST, "")) + "</li>");
        html.push((ordered ? "<ol>" : "<ul>") + items.join("") + (ordered ? "</ol>" : "</ul>"));
        continue;
      }
      if (line.trim() === "") { flush(); i++; continue; }
      para.push(line);
      i++;
    }
    flush();
    return html.join("\n");
  }

  // A whole page for the iframe, wearing the stylesheets a post page
  // wears -- the same paths, resolved against this site, so the preview
  // changes when the skin does.
  function previewDocument(bodyHtml) {
    var sheets = (SITE && SITE.css) || [];
    var links = sheets.map(function (href) {
      return '<link rel="stylesheet" href="' + escapeHtml(href) + '">';
    }).join("");
    var title = state.title.trim() ? "<h1>" + escapeHtml(state.title.trim()) + "</h1>" : "";
    return '<!doctype html><html lang="' + escapeHtml((SITE && SITE.lang) || LANG) + '"><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1"><base href="/">' + links +
      "<style>body{margin:0;padding:1rem}figure{margin:1rem 0}figure img,figure video{max-width:100%;height:auto}" +
      ".no-preview{padding:1rem;border:1px dashed currentColor;opacity:.6;font-size:.9em}</style></head>" +
      '<body><main><article><div class="post-header">' + title + '</div><div class="post-body">' +
      bodyHtml + "</div></article></main></body></html>";
  }

  var previewOpen = false, previewTimer = null;
  function drawPreview() {
    var box = $("preview-box"), btn = $("preview");
    if (!box || !btn) return;
    btn.textContent = t(previewOpen ? "app.preview_hide" : "app.preview");
    box.hidden = !previewOpen;
    if (!previewOpen) return;
    var frame = $("preview-frame");
    frame.title = t("app.preview");
    // Measured when the document has loaded, and again once its web fonts
    // have: the blog's own face arrives after the markup, and the text
    // reflows taller than the first measurement saw -- which left a
    // scrollbar inside the frame where it should not be.
    function fit() {
      try { frame.style.height = Math.max(96, frame.contentDocument.documentElement.scrollHeight + 8) + "px"; }
      catch (e) { /* the frame's height stays as it is */ }
    }
    frame.onload = function () {
      fit();
      try { frame.contentDocument.fonts.ready.then(fit); } catch (e) { setTimeout(fit, 600); }
    };
    frame.srcdoc = previewDocument(renderMarkdown(state.body, state.shots));
  }
  // Redrawn a moment after the typing stops, not on each keystroke: the
  // pictures ride inside the document as data URLs, and re-parsing them
  // per letter makes the keyboard lag.
  function schedulePreview() {
    if (!previewOpen) return;
    clearTimeout(previewTimer);
    previewTimer = setTimeout(drawPreview, 350);
  }
  if ($("preview")) {
    $("preview").addEventListener("click", function () { previewOpen = !previewOpen; drawPreview(); });
  }

  // -------------------------------------------------------------- answer
  // The server's reply comes back through the address bar. The sending
  // shortcut has no page of its own to show, so it percent-encodes what
  // came over SSH and opens this page with it after #r=. A fragment, not
  // a query: it never leaves the browser, so nothing on the way logs it.
  //
  // What comes is one JSON object per picture, then whatever the engine
  // printed for the text -- an object across several lines, or a refusal
  // on one. Found by brace depth rather than by line, because pretty
  // printing is not a promise the engine makes.
  function parseAnswer(text) {
    var out = [], depth = 0, start = -1, inString = false, escaped = false;
    var s = String(text || "");
    for (var i = 0; i < s.length; i++) {
      var c = s.charAt(i);
      if (inString) {
        if (escaped) escaped = false;
        else if (c === "\\") escaped = true;
        else if (c === '"') inString = false;
        continue;
      }
      if (c === '"') { if (depth > 0) inString = true; continue; }
      if (c === "{") { if (depth === 0) start = i; depth++; continue; }
      if (c === "}" && depth > 0) {
        depth--;
        if (depth === 0) {
          try { out.push(JSON.parse(s.slice(start, i + 1))); } catch (e) { /* not JSON: skipped */ }
        }
      }
    }
    return out;
  }

  // The reply out of the address, decoded; null when the page was simply
  // opened. Everything after the key belongs to it: the shortcut encodes
  // the whole reply, so no & or # in there can be anything but its own.
  //
  // Two keys, because Shortcuts reads a reply that is JSON as a
  // Dictionary and then refuses to hand a Dictionary to URL Encode --
  // "couldn't convert from Dictionary to Text", on exactly the replies
  // that matter, the refusals. Base64 Encode takes anything, so #b=
  // carries the reply as base64 (line breaks and all, which Shortcuts
  // puts in every 76 characters unless told not to); #r= stays for a
  // percent-encoded reply.
  function answerIn(href) {
    var s = String(href || "");
    var at = s.indexOf("#b=");
    var raw = null;
    if (at !== -1) raw = fromBase64(s.slice(at + 3));
    else {
      at = s.indexOf("#r=");
      if (at === -1) return null;
      raw = s.slice(at + 3);
      try { raw = decodeURIComponent(raw); } catch (e) { /* not percent-encoded, then */ }
    }
    // A key with nothing after it is no reply, not a reply that said nothing.
    return raw.trim() === "" ? null : raw;
  }

  // Base64 as an address carries it: percent-encoded by whoever put it
  // in the fragment, or not; wrapped every 76 characters, or not; with
  // - and _ where + and / are awkward, or not. UTF-8 underneath, because
  // a refusal names a file, and a file is named in whatever language.
  function fromBase64(raw) {
    var text = raw;
    try { text = decodeURIComponent(raw); } catch (e) { /* not percent-encoded, then */ }
    text = text.replace(/[^A-Za-z0-9+/_=-]/g, "").replace(/-/g, "+").replace(/_/g, "/");
    try {
      var binary = atob(text);
      var bytes = new Uint8Array(binary.length);
      for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      var decoded = new TextDecoder("utf-8").decode(bytes);
      // Text that was never base64 decodes to rubbish rather than failing:
      // the words that came are better than that, so they are shown when
      // they are what holds the braces.
      return decoded.indexOf("{") === -1 && raw.indexOf("{") !== -1 ? raw : decoded;
    } catch (e) { return raw; }
  }

  // The reply sorted into what the page will say about it: the pictures
  // the server kept, what it refused, and the post if the text was taken.
  function describeAnswer(objects) {
    var d = { stored: [], refused: [], post: null };
    (objects || []).forEach(function (o) {
      if (!o || typeof o !== "object") return;
      if (typeof o.stored === "string") d.stored.push(o.stored);
      else if (o.ok === false) d.refused.push({ error: String(o.error || ""), message: String(o.message || "") });
      else if (typeof o.slug === "string") d.post = o;
    });
    return d;
  }

  function showAnswer(d, raw) {
    var box = $("result");
    box.textContent = "";
    function add(tag, text, cls) {
      var el = document.createElement(tag);
      if (text != null) el.textContent = text;
      if (cls) el.className = cls;
      box.appendChild(el);
      return el;
    }
    var post = d.post;
    if (post) {
      var open = post.state === "published";
      add("h2", t(open ? "app.result_published" : "app.result_saved"));
      // A link only to this site. The reply comes in through the address
      // bar, where anyone who can send the author a link can put one, and
      // a "Preview" that ran javascript: on the blog's own origin is not
      // a preview.
      if (siteUrl(post.url)) {
        var a = document.createElement("a");
        a.href = post.url;
        a.textContent = open ? post.url : t("app.result_preview");
        add("p").appendChild(a);
      }
      if (post.deploy === "pending") add("p", t("app.result_pending"));
      if (!open) {
        // A button for it, now that there is a road: one file holding the
        // slug, down the same connection the post took. It appears only
        // where the answer came back with a receipt to ask by -- which
        // means the post was sent from THIS page and the blog is the one
        // that answered.
        // Either the answer was fetched by receipt (and names the slug it
        // was about), or it came through the address bar on a page that
        // had just sent something -- in which case the answer IS about
        // what this page sent, and the receipt is the one it sent with.
        var by = lastAnswer && (lastAnswer.slug === null || lastAnswer.slug === post.slug)
          ? lastAnswer.receipt : "";
        if (by) {
          var go = document.createElement("button");
          go.type = "button";
          // The same class the Send button wears: this is the one action
          // the answer offers, and a bare button in a card reads as a
          // link that failed to become one.
          go.className = "btn small";
          go.textContent = t("app.publish_now");
          go.addEventListener("click", function () {
            go.disabled = true;
            publishFromPhone(post.slug, by);
          });
          add("p").appendChild(go);
        }
        // And the line for a desk, which is still where most of this is
        // done and where the preview is easier to read.
        var code = document.createElement("code");
        code.textContent = "./blog.sh publish " + post.slug;
        add("p", t("app.result_publish_hint") + " ", "meta").appendChild(code);
      }
      if (Array.isArray(post.warnings) && post.warnings.length) {
        add("p", t("app.result_warnings"), "meta");
        var ul = add("ul");
        post.warnings.forEach(function (w) {
          var li = document.createElement("li");
          li.textContent = String(w);
          ul.appendChild(li);
        });
      }
    }
    if (d.refused.length) {
      if (!post) add("h2", t("app.result_refused"));
      d.refused.forEach(function (r) {
        // The code in the reader's language where the app knows it, the
        // server's own words where it does not -- and beside the
        // translation where it does, because the server's words carry
        // what the code cannot: which line, which picture.
        var known = t("error." + r.error);
        var text = known !== "error." + r.error ? known : (r.message || r.error);
        if (known !== "error." + r.error && r.message && r.message !== known) text += " (" + r.message + ")";
        add("p", text, "bad");
      });
    }
    if (d.stored.length) add("p", t("app.result_stored") + ": " + d.stored.join(", "), "meta");
    if (!post && !d.refused.length) {
      if (d.stored.length) add("h2", t("error.missing_markdown"));
      else if (!String(raw || "").trim()) add("h2", t("error.no_reply"));
      else {
        add("h2", t("app.result_unreadable"));
        add("pre", String(raw).slice(0, 2000));
      }
    }
    var close = add("button", t("app.result_close"), "btn ghost close");
    close.type = "button";
    close.addEventListener("click", function () { box.hidden = true; });
    box.hidden = false;
    // A post the server took is no longer a draft on this device: the
    // text is on the blog now, and a copy kept here is a post sent twice.
    // A refusal keeps everything, so it can be mended and sent again.
    // And only a page that SENT something is cleared: the reply arrives
    // through the address bar, and a link with a slug in it is something
    // anyone can send the author -- it used to empty two hours of writing
    // on arrival.
    if (post && state.sentAt) {
      clearTimeout(saveTimer);
      state = { title: "", body: "", tags: "", shots: [], publish: false, sentAt: 0, receipt: "" };
      try { localStorage.removeItem(KEY); } catch (e) { /* nothing to clear */ }
      forget(bytesClear());
      render();
    }
    window.scrollTo(0, 0);
  }

  // Only an address on this site. Everything after "://" up to the first
  // slash has to be this page's own host.
  function siteUrl(url) {
    if (typeof url !== "string" || !/^https?:\/\//i.test(url)) return false;
    try { return new URL(url).origin === location.origin; } catch (e) { return false; }
  }

  // ---------------------------------------------------------------- asking
  //
  // The answer can also be FETCHED, and on a phone it usually has to be.
  // A page added to the home screen runs as an app with storage of its
  // own; the reply arrives as a URL, which opens in the browser, where
  // the draft it is about does not exist. So the page picks a name for
  // its answer before it sends anything, writes that name into the post,
  // and afterwards asks the blog for a small file at an address made of
  // it. The reply through the address bar still works and still wins --
  // this is the road that does not depend on anything coming back.
  var pending = null;

  function newReceipt() {
    var bytes = new Uint8Array(8);
    if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(bytes);
    else for (var i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
    return Array.prototype.map.call(bytes, function (b) { return ("0" + b.toString(16)).slice(-2); }).join("");
  }

  // Asks every three seconds for five minutes. The build writes the file,
  // so the wait is a build and a deploy of the blog -- seconds on a small
  // one, a minute on a large one -- and a post sent over a slow
  // connection can take longer than either. It stops asking when the file
  // says what it was waiting to hear, and says so if it never does: a
  // page that gave up in silence would be indistinguishable from a post
  // that never arrived.
  function askReceipt(receipt, wantPublished) {
    if (!/^[0-9a-f]{16}$/.test(receipt)) return;
    if (pending && pending.timer) clearTimeout(pending.timer);
    // This asking's OWN record, and what everything below compares itself
    // against. The receipt cannot do that job: Publish on the answer card
    // asks again with the SAME receipt, so a receipt tells the second
    // asking from the first not at all.
    var mine = { receipt: receipt, until: Date.now() + 5 * 60 * 1000, timer: 0, published: !!wantPublished };
    pending = mine;
    tick();

    function again() {
      if (pending === mine) pending.timer = setTimeout(tick, 3000);
    }

    function tick() {
      if (pending !== mine) return;
      if (Date.now() > pending.until) {
        pending = null;
        say(t("app.answer_late"), "bad");
        return;
      }
      // Same origin, and a name this page made: the address cannot come
      // from anywhere else, so there is nothing here for a crafted link
      // to reach.
      fetch("r/" + receipt + ".json", { cache: "no-store" })
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (o) {
          // ⚠️ An answer belongs to the asking that fetched it, and this
          // one may have been superseded while it was in the air -- the
          // fetch was already gone when `pending` was replaced, and
          // nothing recalls it. Landing anyway was two failures at once:
          // it cleared `pending`, which killed the wait Publish had just
          // started -- the page then sat silent forever, never saying
          // even that the answer was late -- and it redrew the card as
          // the draft the post had that moment stopped being. The same
          // line covers the answer to an EARLIER post arriving after a
          // second one has been handed over, which showed the wrong post
          // and cleared the new one's draft with it.
          if (pending !== mine) return;
          if (!o || typeof o.slug !== "string") { again(); return; }
          if (wantPublished && o.state !== "published") { again(); return; }

          pending = null;
          lastAnswer = { slug: o.slug, receipt: receipt, state: o.state };
          showAnswer(describeAnswer([o]), JSON.stringify(o));
        })
        .catch(function () { again(); });
    }
  }

  // What the last answer was about, kept out of the draft state on
  // purpose: showing an answer CLEARS the draft, and the Publish button
  // that answer carries needs the slug after that has happened.
  var lastAnswer = null;

  // Publishing from the phone: one file called publish.txt holding the
  // slug, down the same road the post itself took. The receiver knows
  // that shape and runs `publish <slug> --yes --json` for it -- which is
  // the one thing a phone could not do at all, because publishing lived
  // in a dialog and a phone has no terminal to answer one.
  function publishFromPhone(slug, receipt) {
    var file;
    try {
      file = new File([slug], "publish.txt", { type: "text/plain" });
    } catch (e) {
      say(t("app.publish_failed"), "bad");
      return;
    }
    function sent() {
      say(t("app.publish_sent"), "good");
      // The same receipt, asked again until it says published: the build
      // rewrites that file when the post goes out.
      askReceipt(receipt, true);
    }
    if (navigator.canShare && navigator.canShare({ files: [file] })) {
      navigator.share({ files: [file] })
        .then(sent)
        // AbortError is the ordinary end of a share that handed over to
        // the Shortcuts app, exactly as it is for the post itself.
        .catch(function (err) {
          if (err && err.name === "AbortError") { sent(); return; }
          say(t("app.publish_failed"), "bad");
        });
    } else {
      // No share sheet -- a desk, mostly. The file still has to reach the
      // shortcut, and its NAME is the whole signal, so it is saved under
      // that name and the page says what is left to do rather than
      // claiming the request has gone.
      try {
        download(new Blob([slug], { type: "text/plain" }), "publish.txt");
        // Said after download's own line, and it is the one that matters:
        // this file is a request, and it is not a request until the
        // shortcut has it.
        say(t("app.publish_saved"), "good");
      } catch (e2) { say(t("app.publish_failed"), "bad"); }
    }
  }

  // A page reopened while an answer is still on its way picks the asking
  // back up: the receipt is in the draft, and the draft survives a
  // reload. Only for a draft that was actually SENT -- a receipt with no
  // send behind it is a name for an answer nobody is coming to give.
  function resumeAsking() {
    if (!state.receipt || !state.sentAt) return;
    // Five minutes from the send, not from the reload, so a page opened
    // an hour later does not sit there asking about a post whose answer
    // was read long ago.
    if (Date.now() - state.sentAt > 5 * 60 * 1000) return;

    askReceipt(state.receipt, false);
  }

  function answerFromAddress() {
    var raw;
    try { raw = answerIn(location.href); } catch (e) { raw = null; }
    if (raw === null) return;

    // The receipt this page sent with the post, remembered before
    // showAnswer clears the draft it lives in. Without this the Publish
    // button appeared only when the answer had been FETCHED -- and the
    // fetch exists because the reply through the address bar is the road
    // that does not always arrive, not because it is the rare one.
    if (state.receipt && state.sentAt) lastAnswer = { receipt: state.receipt, slug: null };
    // Off the address FIRST: whatever showing it does, a reload or a
    // bookmark must not clear a new draft against an old answer.
    try { history.replaceState(null, "", location.pathname); } catch (e) { /* file:, maybe */ }
    try { showAnswer(describeAnswer(parseAnswer(raw)), raw); }
    catch (e) { say(t("app.result_unreadable"), "bad"); }
  }

  // --------------------------------------------------------------- start
  // ⚠️ The bar at the bottom covers whatever the page's bottom padding
  // does not clear -- and the padding was a figure guessed when the bar
  // was one row. It has a mode row and a message line now, and the line
  // wraps; on a phone the end of the form, the very button that adds a
  // picture, sat under it and could not be scrolled to. Measured, and
  // measured again whenever the bar changes height.
  (function () {
    var bar = document.querySelector(".bar");
    if (!bar) return;
    function clear() { document.body.style.paddingBottom = (bar.offsetHeight + 24) + "px"; }
    clear();
    if (window.ResizeObserver) new ResizeObserver(clear).observe(bar);
    window.addEventListener("resize", clear);
  })();

  function maxMb() { return (SITE && Number(SITE.max_mb)) || 24; }

  function drawBatch() {
    var el = $("batch");
    if (!el) return;
    var size = batchSize();
    // Nothing to say about an empty page.
    var empty = !state.shots.length && !state.body.trim();
    el.hidden = empty;
    var text = empty ? "" : t("app.batch").replace("{what}", describeBatch(size));
    // Said here, in red, the moment the batch outgrows the server's
    // ceiling -- not after the phone has spent the upload finding out.
    var over = !empty && overLimit(size, maxMb());
    if (over) {
      text += " -- " + t("app.batch_over").replace("{max}", String(maxMb()))
                                          .replace("{wire}", formatBytes(wireBytes(size)));
    }
    el.textContent = text;
    if (over) el.dataset.kind = "bad"; else el.removeAttribute("data-kind");
  }

  // The legend under the pictures: what happens to a picture, what to a
  // video, and how much the server takes -- so that nobody can say they
  // were not told.
  function drawLegend() {
    var el = $("images-hint");
    if (!el) return;
    el.textContent = t("app.images_hint").replace("{edge}", String(MAX_EDGE))
      .replace("{max}", String(maxMb())).replace("{files}", String(Math.floor(maxMb() * 0.73)));
  }

  function render() {
    $("title").value = state.title;
    $("body").value = state.body;
    $("tags").value = state.tags;
    drawShots();
    drawMode();
    drawLegend();
    drawBatch();
    drawTags();
    $("kept").hidden = !(state.title || state.body || state.shots.length);
    $("kept").textContent = t("app.saved_locally");
  }

  applySite();
  // The same page may already be open when the shortcut arrives; then
  // only the fragment changes, and nothing is loaded again. Registered
  // before anything below can fail, so a draft that will not load does
  // not also make the page deaf.
  window.addEventListener("hashchange", answerFromAddress);
  // Two pages of this site -- a Safari tab and the home-screen app, or two
  // tabs -- share this storage. When one of them sent the post and
  // cleared the draft, the other must not keep a copy that a keystroke
  // would write back and a tap would send again.
  window.addEventListener("storage", function (e) {
    if (e.key !== KEY && e.key !== null) return;
    if (e.newValue !== null) return;
    clearTimeout(saveTimer);
    state = { title: "", body: "", tags: "", shots: [], publish: false, sentAt: 0, receipt: "" };
    render();
    say(t("app.sent_elsewhere"), "good");
  });
  load().then(null, function () { /* the bytes could not be read; the text stands */ }).then(function () {
    try { render(); } catch (e) { /* a draft the page cannot draw must not stop the reply below */ }
    // The address first: a reply that is already here beats one that has
    // to be asked for, and it clears the draft this would go on asking
    // about.
    answerFromAddress();
    resumeAsking();
  });
})();
