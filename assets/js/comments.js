(function () {
  var esc = window.Blog.escapeHtml;
  var formatDate = window.Blog.formatDate;
  var i18n = window.BLOG_I18N || {};

  // A post carries exactly one comments network (the build writes either
  // data-toot-url or data-bluesky-uri, never both) -- see
  // comments_attrs in build/build_blog.rb.
  //
  // There are two ways the comments under a post can arrive, and the
  // build says which by putting data-moderated on the container:
  //
  //   without it  the live thread, read straight from the network's
  //               public API -- what every site did before moderation
  //               existed, and still the default.
  //   with it     /comments.json, written by cron from the replies the
  //               author favourited. The browser makes no third-party
  //               request at all then: "did the author favourite this"
  //               is an authenticated question, so it cannot be asked
  //               from here, and the answer arrives already applied.
  //
  // Both paths render the same markup, so everything below the fetch is
  // shared.

  // The same three patterns as lib/post_stats.rb, in the same order, and
  // they have to stay identical character for character -- they are one
  // rule written in two languages and they would drift in silence.
  //
  // Order is the fix: GoToSocial writes /@user/statuses/<ULID>, so the
  // loose Mastodon pattern must come LAST or it captures the word
  // "statuses" as the id.
  function parseTootUrl(url) {
    var m = url.match(/^https?:\/\/([^/]+)\/@[^/]+\/statuses\/([A-Za-z0-9]+)/) ||
            url.match(/^https?:\/\/([^/]+)\/users\/[^/]+\/statuses\/([A-Za-z0-9]+)/) ||
            url.match(/^https?:\/\/([^/]+)\/@[^/]+\/([A-Za-z0-9]+)/);
    return m ? { instance: m[1], id: m[2] } : null;
  }

  var STAR_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M12 2l3.09 6.26L22 9.27l-5 4.87L18.18 21 12 17.77 5.82 21 7 14.14 2 9.27l6.91-1.01L12 2z"/></svg>';
  var BOOST_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 1l4 4-4 4"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><path d="M7 23l-4-4 4-4"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg>';
  var COMMENT_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/></svg>';

  // Counts are read from /stats.json, filled in server-side by cron -- the
  // visitor's browser never talks to the network's API for this at all.
  //
  // On a post's own page the live thread is fetched anyway for the
  // comments, so the comment count immediately gets overwritten with the
  // live value -- otherwise it could show something different from the
  // list right below it. Under moderation there is nothing to reconcile:
  // both numbers come from the same cron run.
  var threadCounts = {};

  function statsKey(el) {
    return el.getAttribute('data-toot-url') || el.getAttribute('data-bluesky-uri');
  }

  function statsContainerFor(key) {
    var all = document.querySelectorAll('.post-stats[data-toot-url], .post-stats[data-bluesky-uri]');
    for (var i = 0; i < all.length; i++) {
      if (statsKey(all[i]) === key) return all[i];
    }
    return null;
  }

  function renderPostStats(stats, key) {
    var known = threadCounts[key];
    var comments = known === undefined ? stats.comments : known;
    return (
      '<span class="post-stat" title="' + esc(i18n.stats_favourited) + '">' + STAR_ICON + ' ' + esc(stats.favourites) + '</span>' +
      '<span class="post-stat" title="' + esc(i18n.stats_boosted) + '">' + BOOST_ICON + ' ' + esc(stats.reblogs) + '</span>' +
      '<span class="post-stat" title="' + esc(i18n.stats_comments) + '">' + COMMENT_ICON + ' <span class="reply-count">' + esc(comments) + '</span></span>'
    );
  }

  // The order the two fetches resolve in isn't guaranteed: if the thread
  // arrives first, the count is stashed here and renderPostStats uses it;
  // if it arrives later, it overwrites directly.
  function applyThreadCount(key, count) {
    threadCounts[key] = count;
    var stats = statsContainerFor(key);
    var value = stats && stats.querySelector('.reply-count');
    if (value) value.textContent = count;
  }

  // --- rendering --------------------------------------------------------

  // Everything except the body is escaped: the name, profile URL and
  // avatar address are set by the reply's author, i.e. anyone on the
  // network.
  //
  // The body arrives in one of two fields, and the field name is what
  // says how it may be treated. `html` is Mastodon's own sanitized status
  // HTML and is deliberately inserted as HTML -- otherwise comments would
  // be raw markup. `text` is Bluesky's plain text and is escaped here.
  // Neither is ever guessed at: a payload carrying the wrong one renders
  // nothing rather than the other one's assumptions.
  // Pictures a reply carries. Same-origin pages already hotlink the
  // commenter's avatar from their instance, so the thumbnails follow the
  // same road; each links out to the full picture. Images only -- a video
  // rendered as a still LOOKS like an image and then refuses to play,
  // which reads as broken, and the link to the reply is right above.
  function mediaHtml(media) {
    if (!media || !media.length) return '';
    return (
      '<div class="comment-media">' +
      media.map(function (m) {
        // Most Fediverse replies carry no description, so alt is "" and
        // the anchor had no text, no title and no label -- a link a
        // screen reader announces as its URL, or as nothing. The
        // description is the accessible name when there is one, and a
        // plain "picture" when there is not: a name somebody can hear
        // beats a name that is technically absent.
        var name = (m.alt || '').trim();
        var label = name || (i18n.comment_picture || 'Picture');
        return '<a href="' + esc(m.href) + '" target="_blank" rel="noopener"' +
          ' aria-label="' + esc(label) + '">' +
          '<img src="' + esc(m.src) + '" alt="' + esc(name) + '" loading="lazy">' +
        '</a>';
      }).join('') +
      '</div>'
    );
  }

  function renderComment(comment) {
    var favs = comment.favourites > 0
      ? ' <span class="comment-favs">❤ ' + esc(comment.favourites) + '</span>'
      : '';
    var body = typeof comment.html === 'string'
      ? comment.html
      : esc(comment.text || '').replace(/\n/g, '<br>');
    return (
      '<div class="comment">' +
        // 40x40 is what .comment-avatar is in the stylesheet, said here too
        // so the row is its right height before the picture arrives -- a
        // thread of twenty replies used to shuffle downwards as they landed.
        // A commenter with no picture used to get src="", which the browser
        // resolves to the page itself: it re-fetches the whole HTML document
        // and draws a broken-image icon in the avatar slot. An empty div
        // holds the same 40x40 without asking for anything.
        (comment.avatar
          ? '<img class="comment-avatar" src="' + esc(comment.avatar) + '" alt="" width="40" height="40" loading="lazy">'
          : '<div class="comment-avatar" aria-hidden="true"></div>') +
        '<div class="comment-body">' +
          '<div class="comment-meta">' +
            '<a href="' + esc(comment.author_url) + '" target="_blank" rel="noopener">' + esc(comment.author) + '</a>' +
            ' <a class="comment-date" href="' + esc(comment.url) + '" target="_blank" rel="noopener">' + esc(formatDate(comment.date)) + '</a>' +
            favs +
          '</div>' +
          '<div class="comment-content">' + body + '</div>' +
          mediaHtml(comment.media) +
        '</div>' +
      '</div>'
    );
  }

  function replyLinkHtml(url, label) {
    return '<p class="comments-reply"><a href="' + esc(url) + '" target="_blank" rel="noopener">' + esc(label) + '</a></p>';
  }

  // The note is not decoration. Someone who replies and then finds
  // nothing under the article concludes the site is broken and replies
  // again -- so the page has to say that what it shows is a selection and
  // where the whole thread is. It is its own function because the note is
  // owed to that reader whenever the page is moderated, including on the
  // paths where no comment ever gets rendered.
  function moderationNote() {
    return '<p class="comments-note">' + esc(i18n.comments_moderated) + '</p>';
  }

  function render(container, key, replyLink, moderated, comments) {
    var note = moderated ? moderationNote() : '';
    container.innerHTML = note + replyLink + comments.map(renderComment).join('');
    applyThreadCount(key, comments.length);
  }

  // --- Mastodon (live thread) -------------------------------------------

  function mastodonComment(status) {
    var acct = status.account || {};
    // Attachments live outside the sanitised content, so without this
    // mapping an approved picture reply rendered as just its words. A
    // reply marked sensitive keeps its pictures to itself -- the fold
    // holds the text, and a thumbnail would sit outside it.
    var media = status.sensitive ? [] : (status.media_attachments || [])
      .filter(function (a) { return a.type === 'image' && a.preview_url; })
      .map(function (a) {
        return { src: a.preview_url, href: a.url || a.remote_url || status.url, alt: a.description || '' };
      });
    return {
      author: acct.display_name || acct.username,
      author_url: acct.url,
      avatar: acct.avatar,
      url: status.url,
      date: status.created_at,
      favourites: status.favourites_count,
      html: status.content,
      media: media
    };
  }

  function loadMastodonThread(container, tootUrl) {
    var parsed = parseTootUrl(tootUrl);
    var replyLink = replyLinkHtml(tootUrl, i18n.reply_on_mastodon);
    // An address in a shape this cannot read -- a typo in the config, a
    // server whose permalinks look different again -- used to leave the
    // container completely empty: no comments, no explanation, and not
    // even the way to answer the post. The same thing a failed fetch
    // leaves behind is left here too.
    if (!parsed) {
      container.innerHTML = replyLink;
      return;
    }

    var apiUrl = 'https://' + parsed.instance + '/api/v1/statuses/' + parsed.id + '/context';

    fetch(apiUrl)
      .then(function (res) { return res.ok ? res.json() : Promise.reject(res.status); })
      .then(function (ctx) {
        var replies = (ctx.descendants || []).filter(function (s) { return !s.sensitive; });
        render(container, tootUrl, replyLink, false, replies.map(mastodonComment));
      })
      .catch(function () {
        container.innerHTML = replyLink;
      });
  }

  // --- Bluesky (live thread) --------------------------------------------

  // Replies arrive as a tree; flatten depth-first so a sub-conversation
  // stays grouped under the reply that started it. Placeholders for
  // blocked/deleted posts have no .post, and labeled (moderated) posts are
  // skipped -- the same courtesy the Mastodon path pays to `sensitive`.
  function flattenBlueskyReplies(replies, out) {
    (replies || []).forEach(function (item) {
      if (!item || !item.post || !item.post.record) return;
      if ((item.post.labels || []).length > 0) return;
      out.push(item.post);
      flattenBlueskyReplies(item.replies, out);
    });
    return out;
  }

  function blueskyPostUrl(post) {
    var rkey = post.uri.split('/').pop();
    return 'https://bsky.app/profile/' + post.author.handle + '/post/' + rkey;
  }

  function blueskyComment(post) {
    var author = post.author || {};
    // The view embed carries the images (thumb + fullsize, alt included);
    // a labelled post keeps them folded away, same instinct as Mastodon's
    // sensitive flag.
    var embed = post.embed || {};
    var images = embed.images || (embed.media && embed.media.images) || [];
    var media = (post.labels || []).length ? [] : images
      .filter(function (img) { return img.thumb; })
      .map(function (img) {
        return { src: img.thumb, href: img.fullsize || blueskyPostUrl(post), alt: img.alt || '' };
      });
    return {
      author: author.displayName || author.handle,
      author_url: 'https://bsky.app/profile/' + author.handle,
      avatar: author.avatar,
      url: blueskyPostUrl(post),
      date: post.record.createdAt,
      favourites: post.likeCount,
      text: post.record.text,
      media: media
    };
  }

  function loadBlueskyThread(container, uri, humanUrl) {
    var replyLink = replyLinkHtml(humanUrl, i18n.reply_on_bluesky);
    var apiUrl = 'https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?depth=10&uri=' + encodeURIComponent(uri);

    fetch(apiUrl)
      .then(function (res) { return res.ok ? res.json() : Promise.reject(res.status); })
      .then(function (data) {
        var replies = flattenBlueskyReplies(data.thread && data.thread.replies, []);
        render(container, uri, replyLink, false, replies.map(blueskyComment));
      })
      .catch(function () {
        container.innerHTML = replyLink;
      });
  }

  // --- moderated (same-origin) ------------------------------------------

  // Fails closed, and on purpose. A missing or unreadable comments.json
  // means this page cannot tell approved replies from the rest, and the
  // whole point of moderation is that the ones it cannot vouch for do not
  // appear. The reply link stays either way, so the discussion is always
  // one click away even when nothing renders.
  function loadApproved(container, key, replyLink) {
    fetch('/comments.json')
      .then(function (res) { return res.ok ? res.json() : Promise.reject(res.status); })
      .then(function (all) {
        render(container, key, replyLink, true, all[key] || []);
      })
      .catch(function () {
        // Showing no comments here is right; dropping the note with them was
        // not. Without it the article ended in a bare reply link, which reads
        // as a discussion nobody joined -- exactly the misreading the note was
        // written to prevent, and exactly the reader it was written for. It is
        // also the ordinary state of a moderated site between a publish and
        // the next cron tick, not a rare breakage.
        //
        // The comment counter is deliberately left as cron filled it in: this
        // branch could not read the approved list, so it knows nothing about
        // how many replies are in it and must not overwrite a known number
        // with a guessed zero. The note is what explains the difference
        // between the count above and the list below.
        container.innerHTML = moderationNote() + replyLink;
      });
  }

  // --- wiring -----------------------------------------------------------

  document.addEventListener('DOMContentLoaded', function () {
    var statsContainers = document.querySelectorAll('.post-stats[data-toot-url], .post-stats[data-bluesky-uri]');
    if (statsContainers.length) {
      fetch('/stats.json')
        .then(function (res) { return res.ok ? res.json() : Promise.reject(res.status); })
        .then(function (all) {
          Array.prototype.forEach.call(statsContainers, function (el) {
            var key = statsKey(el);
            // A post announced after the last cron run isn't in the data
            // yet; the counters fill in on their own at the next refresh.
            if (all[key]) el.innerHTML = renderPostStats(all[key], key);
          });
        })
        .catch(function () { /* counters stay empty */ });
    }

    var container = document.getElementById('comments');
    if (!container) return;

    var tootUrl = container.getAttribute('data-toot-url');
    var bskyUri = container.getAttribute('data-bluesky-uri');
    var moderated = container.hasAttribute('data-moderated');

    if (tootUrl && moderated) {
      loadApproved(container, tootUrl, replyLinkHtml(tootUrl, i18n.reply_on_mastodon));
    } else if (bskyUri && moderated) {
      loadApproved(container, bskyUri, replyLinkHtml(container.getAttribute('data-bluesky-url'), i18n.reply_on_bluesky));
    } else if (tootUrl) {
      loadMastodonThread(container, tootUrl);
    } else if (bskyUri) {
      loadBlueskyThread(container, bskyUri, container.getAttribute('data-bluesky-url'));
    }
  });
})();
