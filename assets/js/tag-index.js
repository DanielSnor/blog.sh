(function () {
  var list = document.getElementById('tag-index');
  if (!list) return;

  var i18n = window.BLOG_I18N || {};
  var KEY = 'tags-order';

  // The order the build wrote: folded alphabetical. Kept as the baseline
  // rather than re-sorted here, because sorting Czech in a browser is not
  // the same operation the build did -- localeCompare would put `škola`
  // somewhere the year's worth of pages already disagrees with, and the two
  // orders differing between "before JS ran" and "after" is worse than
  // either order on its own.
  // The alphabetical order is everything the build wrote, letters
  // included; the count order is the tags alone. A letter above a run of
  // names says nothing once the names are ordered by how many posts carry
  // them, so the switch takes them out rather than leaving twenty-seven
  // headings over a list they no longer describe.
  var all = Array.prototype.slice.call(list.children);
  var items = all.filter(function (el) { return el.className.indexOf('tag-index-item') !== -1; });
  var byCount = items.slice().sort(function (a, b) {
    var d = Number(b.getAttribute('data-count')) - Number(a.getAttribute('data-count'));
    // Ties keep the alphabetical order underneath, so the list does not
    // shuffle its own equals every time it is redrawn.
    return d !== 0 ? d : items.indexOf(a) - items.indexOf(b);
  });

  // Reordered in the DOM, not with CSS `order`: with the flex property the
  // eye would see one order while a screen reader and the Tab key kept the
  // other, and a list of seven hundred links is exactly where that matters.
  function apply(order) {
    var wanted = order === 'count' ? byCount : all;
    while (list.firstChild) list.removeChild(list.firstChild);
    var frag = document.createDocumentFragment();
    for (var i = 0; i < wanted.length; i++) frag.appendChild(wanted[i]);
    list.appendChild(frag);
    for (var j = 0; j < buttons.length; j++) {
      var on = buttons[j].getAttribute('data-order') === order;
      buttons[j].setAttribute('aria-pressed', on ? 'true' : 'false');
    }
    try { localStorage.setItem(KEY, order); } catch (e) { /* private mode: the choice just does not persist */ }
  }

  function button(order, label) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'tag-index-sort-button';
    b.setAttribute('data-order', order);
    b.textContent = label;
    b.addEventListener('click', function () { apply(order); });
    return b;
  }

  // Built here rather than shipped in the HTML: without this script the
  // switch would be a control that does nothing, and the page is complete
  // without it -- the list is already in a useful order.
  var bar = document.createElement('div');
  bar.className = 'tag-index-sort';
  var buttons = [
    button('alpha', i18n.tags_sort_alpha || 'A–Z'),
    button('count', i18n.tags_sort_count || '#')
  ];
  for (var k = 0; k < buttons.length; k++) bar.appendChild(buttons[k]);
  list.parentNode.insertBefore(bar, list);

  var saved = null;
  try { saved = localStorage.getItem(KEY); } catch (e) { saved = null; }
  apply(saved === 'count' ? 'count' : 'alpha');
})();
