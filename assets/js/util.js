// Shared utilities. Must load first -- the other scripts rely on window.Blog.
window.Blog = window.Blog || {};

// Escaping of ALL foreign data inserted into innerHTML. Data from the
// Fediverse (account names, avatar URLs) is set by anyone in the world, so
// without this it's enough to reply to a toot with <img onerror=...> in the
// displayed name and the script runs for visitors right on this site.
window.Blog.escapeHtml = function (s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
};

window.Blog.formatDate = function (iso) {
  var locale = (window.BLOG_I18N && window.BLOG_I18N.date_locale) || 'en-US';
  return new Date(iso).toLocaleDateString(locale, { day: 'numeric', month: 'short', year: 'numeric' });
};
