(function () {
  var esc = window.Blog.escapeHtml;
  var formatDate = window.Blog.formatDate;
  var i18n = window.BLOG_I18N || {};

  // A post carries exactly one comments network (the build writes either
  // data-toot-url or data-bluesky-uri, never both) -- see
  // comments_attrs in build/build_blog.rb.

  function parseTootUrl(url) {
    var m = url.match(/^https?:\/\/([^/]+)\/@[^/]+\/(\d+)/) ||
            url.match(/^https?:\/\/([^/]+)\/users\/[^/]+\/statuses\/(\d+)/);
    return m ? { instance: m[1], id: m[2] } : null;
  }

  var STAR_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M12 2l3.09 6.26L22 9.27l-5 4.87L18.18 21 12 17.77 5.82 21 7 14.14 2 9.27l6.91-1.01L12 2z"/></svg>';
  var BOOST_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 1l4 4-4 4"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><path d="M7 23l-4-4 4-4"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg>';
  var COMMENT_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/></svg>';

  // Counts are read from /stats.json, filled in server-side by cron -- the
  // visitor's browser never talks to the network's API for this at all.
  //
  // On a post's own page the thread is fetched anyway for the comments, so
  // the comment count immediately gets overwritten with the live value --
  // otherwise it could show something different from the list right below it.
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

  // --- Mastodon ---------------------------------------------------------

  // Everything except status.content is escaped: the name, profile URL and
  // avatar address are set by the reply's author, i.e. anyone in the
  // Fediverse. status.content itself is HTML sanitized by Mastodon and is
  // deliberately inserted as HTML -- otherwise comments would be raw markup.
  function renderComment(status) {
    var acct = status.account;
    var name = acct.display_name || acct.username;
    var favs = status.favourites_count > 0
      ? ' <span class="comment-favs">❤ ' + esc(status.favourites_count) + '</span>'
      : '';
    return (
      '<div class="comment">' +
        '<img class="comment-avatar" src="' + esc(acct.avatar) + '" alt="" loading="lazy">' +
        '<div class="comment-body">' +
          '<div class="comment-meta">' +
            '<a href="' + esc(acct.url) + '" target="_blank" rel="noopener">' + esc(name) + '</a>' +
            ' <a class="comment-date" href="' + esc(status.url) + '" target="_blank" rel="noopener">' + esc(formatDate(status.created_at)) + '</a>' +
            favs +
          '</div>' +
          '<div class="comment-content">' + status.content + '</div>' +
        '</div>' +
      '</div>'
    );
  }

  function loadMastodonThread(container, tootUrl) {
    var parsed = parseTootUrl(tootUrl);
    if (!parsed) return;

    var replyLink = '<p class="comments-reply"><a href="' + esc(tootUrl) + '" target="_blank" rel="noopener">' + esc(i18n.reply_on_mastodon) + '</a></p>';
    var apiUrl = 'https://' + parsed.instance + '/api/v1/statuses/' + parsed.id + '/context';

    fetch(apiUrl)
      .then(function (res) { return res.ok ? res.json() : Promise.reject(res.status); })
      .then(function (ctx) {
        var replies = (ctx.descendants || []).filter(function (s) { return !s.sensitive; });
        container.innerHTML = replyLink + replies.map(renderComment).join('');
        applyThreadCount(tootUrl, replies.length);
      })
      .catch(function () {
        container.innerHTML = replyLink;
      });
  }

  // --- Bluesky ----------------------------------------------------------

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

  // Bluesky reply text is plain text (not sanitized HTML like Mastodon's),
  // so it's escaped wholesale; newlines become <br>.
  function renderBlueskyComment(post) {
    var author = post.author || {};
    var name = author.displayName || author.handle;
    var favs = post.likeCount > 0
      ? ' <span class="comment-favs">❤ ' + esc(post.likeCount) + '</span>'
      : '';
    return (
      '<div class="comment">' +
        '<img class="comment-avatar" src="' + esc(author.avatar) + '" alt="" loading="lazy">' +
        '<div class="comment-body">' +
          '<div class="comment-meta">' +
            '<a href="' + esc('https://bsky.app/profile/' + author.handle) + '" target="_blank" rel="noopener">' + esc(name) + '</a>' +
            ' <a class="comment-date" href="' + esc(blueskyPostUrl(post)) + '" target="_blank" rel="noopener">' + esc(formatDate(post.record.createdAt)) + '</a>' +
            favs +
          '</div>' +
          '<div class="comment-content">' + esc(post.record.text).replace(/\n/g, '<br>') + '</div>' +
        '</div>' +
      '</div>'
    );
  }

  function loadBlueskyThread(container, uri, humanUrl) {
    var replyLink = '<p class="comments-reply"><a href="' + esc(humanUrl) + '" target="_blank" rel="noopener">' + esc(i18n.reply_on_bluesky) + '</a></p>';
    var apiUrl = 'https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?depth=10&uri=' + encodeURIComponent(uri);

    fetch(apiUrl)
      .then(function (res) { return res.ok ? res.json() : Promise.reject(res.status); })
      .then(function (data) {
        var replies = flattenBlueskyReplies(data.thread && data.thread.replies, []);
        container.innerHTML = replyLink + replies.map(renderBlueskyComment).join('');
        applyThreadCount(uri, replies.length);
      })
      .catch(function () {
        container.innerHTML = replyLink;
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
    if (tootUrl) {
      loadMastodonThread(container, tootUrl);
    } else if (bskyUri) {
      loadBlueskyThread(container, bskyUri, container.getAttribute('data-bluesky-url'));
    }
  });
})();
