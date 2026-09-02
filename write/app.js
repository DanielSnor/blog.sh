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
  var state = { title: "", body: "", tags: "", shots: [] };

  function load() {
    try {
      var saved = JSON.parse(localStorage.getItem(KEY) || "null");
      if (saved) state = Object.assign(state, saved);
    } catch (e) { /* private mode, cleared storage: start empty */ }
  }
  var saveTimer = null;
  function save() {
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
          '<div class="row">' +
            '<button type="button" class="link" data-drop="' + i + '"></button>' +
            '<button type="button" class="link" data-insert="' + i + '">![ ]</button>' +
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
      row.querySelector("[data-drop]").textContent = t("app.discard");
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
    if (drop) { state.shots.splice(Number(drop.dataset.drop), 1); drawShots(); save(); return; }
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

  var askTimer = null;
  $("discard").addEventListener("click", function () {
    var btn = this;
    if (btn.dataset.ask !== "yes") {
      btn.dataset.ask = "yes";
      btn.textContent = t("app.discard_confirm");
      say(t("app.discard_note"));
      clearTimeout(askTimer);
      askTimer = setTimeout(function () {
        btn.dataset.ask = ""; btn.textContent = t("app.discard"); say("");
      }, 5000);
      return;
    }
    clearTimeout(askTimer);
    btn.dataset.ask = ""; btn.textContent = t("app.discard");
    state = { title: "", body: "", tags: "", shots: [] };
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
    say(t("app.sending"));
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

  // --------------------------------------------------------------- start
  function render() {
    $("title").value = state.title;
    $("body").value = state.body;
    $("tags").value = state.tags;
    drawShots();
    $("kept").hidden = !(state.title || state.body || state.shots.length);
    $("kept").textContent = t("app.saved_locally");
  }

  load();
  render();
})();
