(function () {
  "use strict";

  // ---------------------------------------------------------------- i18n
  // The reader's language, then its base ("de-AT" -> "de"), then English.
  // Missing keys fall through rather than showing the key itself: a raw
  // "app.send" in the middle of a button is worse than an English word.
  var LANG = (function () {
    var have = window.I18N || {};
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

  function load() {
    try {
      var saved = JSON.parse(localStorage.getItem(KEY) || "null");
      if (saved) state = Object.assign(state, saved);
    } catch (e) { /* private mode, cleared storage: start empty */ }
  }
  var saveTimer = null;
  function save() {
    drawBatch();
    // Debounced: this runs on every keystroke and the body can hold photos
    // as data URLs, so writing on each one makes typing stutter.
    clearTimeout(saveTimer);
    saveTimer = setTimeout(function () {
      try {
        localStorage.setItem(KEY, JSON.stringify(state));
        $("kept").textContent = t("app.saved_locally");
        $("kept").hidden = false;
      } catch (e) {
        // Quota, most often, and it matters: the author must not believe
        // their text is safe when it is not.
        // It used to say error.no_reply -- "the server said nothing" --
        // about a server that nothing had asked.
        say(t("app.not_saved"), "bad");
      }
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
    base = base.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
    return (base || ("photo-" + index)) + "." + (ext || "jpg");
  }

  // What to call a picture that is passed through untouched. The name it
  // arrived with first, because that is what the author will recognise;
  // the MIME subtype when the name carries no extension at all.
  function extensionOf(file) {
    var m = /\.([a-z0-9]{1,8})$/i.exec(String(file.name || ""));
    if (m) return m[1].toLowerCase();
    var t = /^image\/([a-z0-9]+)/i.exec(String(file.type || ""));
    return t ? t[1].toLowerCase() : "img";
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

  function addFiles(files) {
    var list = Array.prototype.filter.call(files, function (f) { return /^image\//.test(f.type); });
    if (!list.length) return;
    say(t("app.sending") === "" ? "" : "…");
    var asIs = [];
    function keep(file, ext, dataUrl, w, h) {
      state.shots.push({
        name: freeName(safeName(file.name, state.shots.length + 1, ext),
                       state.shots.map(function (s) { return s.name; })),
        data: dataUrl, w: w, h: h, alt: "", raw: !w, size: file.size
      });
      drawShots();
    }
    list.reduce(function (chain, file) {
      return chain.then(function () {
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
      say(asIs.length ? t("app.picture_as_is") + ": " + asIs.join(", ") : "",
          asIs.length ? "good" : "");
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
    var re = /!\[[^\]]*\]\(([^)]+)\)/g;
    var m;
    while ((m = re.exec(state.body)) !== null) {
      var target = m[1].trim();
      if (target.indexOf("/") !== -1 || target.charAt(0) === "~") out.push(target);
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
      // it could not be shrunk: the browser will not decode it.
      if (shot.raw) row.querySelector("img").remove();
      else row.querySelector("img").src = shot.data;
      var used = usedInText(shot.name);
      var name = row.querySelector(".name");
      name.textContent = shot.name + "  " +
        (shot.raw ? Math.round((shot.size || 0) / 1024) + " kB"
                  : shot.w + "×" + shot.h) + " ";
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
      .replace(/^["']|["']$/g, "")
      .replace(/^\[|\]$/g, "")
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
    if (!lines.length) return "";
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
    var bytes = 0;
    state.shots.forEach(function (shot) {
      var data = String(shot.data || "");
      bytes += Math.floor((data.length - (data.indexOf(",") + 1)) * 3 / 4);
    });
    bytes += new TextEncoder().encode(markdown()).length;
    return { pictures: state.shots.length, bytes: bytes };
  }

  function formatBytes(n) {
    if (n < 1024 * 1024) return Math.max(1, Math.round(n / 1024)) + " kB";
    return String(Math.round(n / 1024 / 1024 * 10) / 10).replace(".", t("app.decimal")) + " MB";
  }

  // "3 pictures, 4.2 MB" -- with the plural the reader's language wants:
  // one, a few (two to four, which Czech counts differently), many.
  function describeBatch(size) {
    var n = size.pictures;
    var what = n === 0 ? t("app.text_only")
             : n + " " + t(n === 1 ? "app.pictures_1" : n < 5 ? "app.pictures_few" : "app.pictures_many");
    return what + ", " + formatBytes(size.bytes);
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
      // Every picture has been through the canvas, so it is a JPEG
      // whatever it arrived as, and safeName has already given it a .jpg.
      return new File([dataUrlToBytes(shot.data)], shot.name, { type: "image/jpeg" });
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
  function buildBundle() {
    var enc = new TextEncoder();
    var entries = [{ name: slugForFile(), bytes: enc.encode(markdown()) }];
    state.shots.forEach(function (shot) {
      entries.push({ name: shot.name, bytes: dataUrlToBytes(shot.data) });
    });
    return zip(entries);
  }

  // -------------------------------------------------------------- events
  ["title", "body", "tags"].forEach(function (id) {
    $(id).addEventListener("input", function (e) {
      state[id] = e.target.value;
      if (id === "body") drawShots();   // the "used in text" chips follow along
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
    if (retitle(shot.name, before, shot.alt)) drawShots();
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
    var line = new RegExp("^[ \\t]*!\\[[^\\]]*\\]\\(" + name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\)[ \\t]*$");
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
  function retitle(name, before, after) {
    var body = $("body");
    var find = "![" + before + "](" + name + ")";
    if (body.value.indexOf(find) === -1) return false;
    body.value = body.value.split(find).join("![" + after + "](" + name + ")");
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
      body.value = before + spacedMark(before, after,
                                       "![" + (shot.alt || "") + "](" + shot.name + ")") + after;
      state.body = body.value;
      drawShots(); save();
    }
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
    state = { title: "", body: "", tags: "", shots: [], publish: false };
    try { localStorage.removeItem(KEY); } catch (e) { /* nothing to clear */ }
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
    // Said once, and only about pictures the text actually shows: a
    // description missing from a published picture cannot be added later
    // by the person who needed it. Not a refusal -- the author may have
    // reasons -- but it must not leave silently either.
    var mute = state.shots.filter(function (shot) {
      return usedInText(shot.name) && !shot.alt.trim();
    });
    if (mute.length && !this.dataset.anyway) {
      this.dataset.anyway = "yes";
      say(t("app.alt_missing") + ": " + mute.map(function (s) { return s.name; }).join(", "), "bad");
      return;
    }
    this.dataset.anyway = "";
    say(t("app.handing").replace("{what}", describeBatch(batchSize())));
    var files = buildFiles();
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
        .then(function () { say(t("app.bundle_note"), "good"); })
        .catch(function (err) {
          // ⚠️ AbortError is the NORMAL end of this path, not a failure.
          // A share-sheet shortcut that hands the run over to the
          // Shortcuts app -- which this one must, to be allowed to open
          // an SSH connection -- leaves the extension without completing
          // the share, and WebKit reports that as an abort. The very same
          // error also means the person closed the sheet, and the page
          // cannot tell the two apart. So the message claims neither:
          // it says the files left, and where the answer is.
          if (err && err.name === "AbortError") { say(t("app.share_cancelled"), "good"); return; }
          download(buildBundle());
        });
    } else {
      download(buildBundle());
    }
  });

  function download(blob) {
    var url = URL.createObjectURL(blob);
    var a = document.createElement("a");
    a.href = url;
    a.download = "post.zip";
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 10000);
    say(t("app.saved_instead"), "good");
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
  // opened. Everything after #r= belongs to it: the shortcut encodes the
  // whole reply, so no & or # in there can be anything but its own.
  function answerIn(href) {
    var s = String(href || "");
    var at = s.indexOf("#r=");
    var raw;
    if (at !== -1) raw = s.slice(at + 3);
    else {
      var m = /[?&]r=([^&#]*)/.exec(s);
      if (!m) return null;
      raw = m[1];
    }
    try { return decodeURIComponent(raw); } catch (e) { return raw; }
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
      if (post.url) {
        var a = document.createElement("a");
        a.href = post.url;
        a.textContent = open ? post.url : t("app.result_preview");
        add("p").appendChild(a);
      }
      if (post.deploy === "pending") add("p", t("app.result_pending"));
      if (!open) {
        // No button for it here, on purpose: publishing is a decision the
        // desk makes with the preview open, and the command is one line.
        var code = document.createElement("code");
        code.textContent = "./blog.sh publish " + post.slug;
        add("p", t("app.result_publish_hint") + " ", "meta").appendChild(code);
      }
      if (post.warnings && post.warnings.length) {
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
        // server's own words where it does not.
        var known = t("error." + r.error);
        add("p", known !== "error." + r.error ? known : (r.message || r.error), "bad");
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
    if (post) {
      state = { title: "", body: "", tags: "", shots: [], publish: false };
      try { localStorage.removeItem(KEY); } catch (e) { /* nothing to clear */ }
      render();
    }
    window.scrollTo(0, 0);
  }

  function answerFromAddress() {
    var raw = answerIn(location.href);
    if (raw === null) return;
    showAnswer(describeAnswer(parseAnswer(raw)), raw);
    // Off the address once read: a reload or a bookmark must not clear
    // a new draft against an old answer.
    try { history.replaceState(null, "", location.pathname + location.search); } catch (e) { /* file:, maybe */ }
  }

  // --------------------------------------------------------------- start
  function drawBatch() {
    var el = $("batch");
    if (!el) return;
    var size = batchSize();
    // Nothing to say about an empty page.
    var empty = !state.shots.length && !state.body.trim();
    el.hidden = empty;
    el.textContent = empty ? "" : t("app.batch").replace("{what}", describeBatch(size));
  }

  function render() {
    $("title").value = state.title;
    $("body").value = state.body;
    $("tags").value = state.tags;
    drawShots();
    drawMode();
    drawBatch();
    $("kept").hidden = !(state.title || state.body || state.shots.length);
    $("kept").textContent = t("app.saved_locally");
  }

  load();
  render();
  answerFromAddress();
  // The same page may already be open when the shortcut arrives; then
  // only the fragment changes, and nothing is loaded again.
  window.addEventListener("hashchange", answerFromAddress);
})();
