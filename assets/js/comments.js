(function () {
  var esc = window.Blog.escapeHtml;
  var formatDate = window.Blog.formatDate;
  var i18n = window.BLOG_I18N || {};

  function parseTootUrl(url) {
    var m = url.match(/^https?:\/\/([^/]+)\/@[^/]+\/(\d+)/) ||
            url.match(/^https?:\/\/([^/]+)\/users\/[^/]+\/statuses\/(\d+)/);
    return m ? { instance: m[1], id: m[2] } : null;
  }

  var STAR_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M12 2l3.09 6.26L22 9.27l-5 4.87L18.18 21 12 17.77 5.82 21 7 14.14 2 9.27l6.91-1.01L12 2z"/></svg>';
  var BOOST_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 1l4 4-4 4"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><path d="M7 23l-4-4 4-4"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg>';
  var COMMENT_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/></svg>';

  // Counts are read from /stats.json, filled in server-side by cron -- the
  // visitor's browser never talks to the Mastodon instance for this at all.
  // Previously a request went out to the third-party API for every post in
  // a listing; harmless with three tooted posts, but it would grow with
  // every new article.
  //
  // On a post's own page the thread is fetched anyway for the comments, so
  // the comment count immediately gets overwritten with the live value --
  // otherwise it could show something different from the list right below it.
  var threadCounts = {};

  function statsContainerFor(tootUrl) {
    var all = document.querySelectorAll('.post-stats[data-toot-url]');
    for (var i = 0; i < all.length; i++) {
      if (all[i].getAttribute('data-toot-url') === tootUrl) return all[i];
    }
    return null;
  }

  function renderPostStats(stats, tootUrl) {
    var known = threadCounts[tootUrl];
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
  function applyThreadCount(tootUrl, count) {
    threadCounts[tootUrl] = count;
    var stats = statsContainerFor(tootUrl);
    var value = stats && stats.querySelector('.reply-count');
    if (value) value.textContent = count;
  }

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

  document.addEventListener('DOMContentLoaded', function () {
    var statsContainers = document.querySelectorAll('.post-stats[data-toot-url]');
    if (statsContainers.length) {
      fetch('/stats.json')
        .then(function (res) { return res.ok ? res.json() : Promise.reject(res.status); })
        .then(function (all) {
          Array.prototype.forEach.call(statsContainers, function (el) {
            var url = el.getAttribute('data-toot-url');
            // A post tooted after the last cron run isn't in the data yet;
            // the counters fill in on their own at the next refresh.
            if (all[url]) el.innerHTML = renderPostStats(all[url], url);
          });
        })
        .catch(function () { /* counters stay empty */ });
    }

    var container = document.getElementById('comments');
    if (!container) return;

    var tootUrl = container.getAttribute('data-toot-url');
    var parsed = tootUrl && parseTootUrl(tootUrl);
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
  });
})();
