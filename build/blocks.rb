# frozen_string_literal: true

# build/blocks.rb -- one content block into HTML.
#
# The first domain lifted out of build_blog.rb, and the one with the
# least holding it there: seventeen functions that take a block and give
# back markup, reaching for nothing the build knows except the escaper
# and the locale. Everything about WHICH blocks get rendered, in what
# order and onto which page, stays where it was.
#
# The three constants moved with them because nothing else has ever
# asked for them, and they are the vocabulary of exactly this job: what
# an autolink looks like, what punctuation falls off the end of one, and
# the three ways a table cell may be aligned.
#
# Constants the BUILD owns -- SITE_BASE_URL, MEDIA_PREFIX and the rest --
# still resolve from in here: a module body`s lexical scope ends at
# Object, which is where a script`s top-level constants live. Same for
# the top-level helpers these call, h() and t(): they are private methods
# of Object, and a module is an Object. So this is a move, not a rewrite,
# which is the only kind of change worth making to code that has no
# test of its own beyond the site it produces.
module Blocks
  module_function

  def wrap_tag(chunk, format)
    case format['type']
    when 'bold' then "<b>#{chunk}</b>"
    when 'italic' then "<i>#{chunk}</i>"
    when 'strikethrough' then "<s>#{chunk}</s>"
    when 'code' then "<code>#{chunk}</code>"
    when 'small' then "<small>#{chunk}</small>"
    when 'link'
      title = format['title'] ? %( title="#{CGI.escapeHTML(format['title'].to_s)}") : ''
      %(<a href="#{CGI.escapeHTML(safe_href(format['url']))}"#{title}>#{chunk}</a>)
    when 'mention' then %(<a href="#{CGI.escapeHTML(safe_href(format.dig('blog', 'url')))}">#{chunk}</a>)
    when 'color' then %(<span style="color:#{CGI.escapeHTML(format['hex'].to_s)}">#{chunk}</span>)
    else chunk
    end
  end

  AUTOLINK_RE = %r{https?://[^\s<>"']+}
  # Trailing punctuation at the end of a sentence doesn't belong in the address.
  TRAILING_PUNCT_RE = /[.,;:!?»"'“”]+\z/

  # A URL written directly in the text (without a markdown link) turns itself
  # into a link. Useful for content imported from platforms/eras where authors
  # just typed addresses straight into a sentence instead of linking them.
  def autolink(raw)
    result = +''
    pos = 0
    raw.to_enum(:scan, AUTOLINK_RE).each do
      match = Regexp.last_match
      result << CGI.escapeHTML(raw[pos...match.begin(0)])
      url, trailing = split_trailing_punctuation(match[0])
      result << %(<a href="#{CGI.escapeHTML(url)}">#{CGI.escapeHTML(url)}</a>)
      result << CGI.escapeHTML(trailing)
      pos = match.end(0)
    end
    result << CGI.escapeHTML(raw[pos..].to_s)
    result
  end

  def split_trailing_punctuation(url)
    trailing = +''
    if (m = url.match(TRAILING_PUNCT_RE))
      trailing = m[0].dup
      url = url[0...-m[0].length]
    end
    # An unpaired closing parenthesis at the end belongs to the sentence, not
    # the address -- but a paired one (e.g. in a Wikipedia URL) stays in the link.
    while url.end_with?(')') && url.count('(') < url.count(')')
      trailing = ")#{trailing}"
      url = url[0..-2]
    end
    [url, trailing]
  end

  # NPF formatting offsets are Unicode-codepoint based, same as Ruby's default
  # String indexing, so no conversion is needed before slicing `text`.
  #
  # `escape: false` is for the site's own chrome (see config_html below), where
  # the text comes from site.yml -- owner-edited config, never visitor input --
  # and raw HTML in it has always been passed through. Autolinking goes off with
  # it, and must: a bare address inside an href= attribute would otherwise be
  # turned into a second link in the middle of the first one.
  def apply_formatting(text, formatting, escape: true)
    plain = ->(s) { escape ? autolink(s.to_s) : s.to_s }
    return plain.call(text) if formatting.nil? || formatting.empty?

    # A stored span can point past the end of its text: importers used to
    # compute offsets against the raw HTML text and store the collapsed one
    # (fixed in lib/import/html_blocks.rb, but posts written before that keep
    # their numbers). Clamping costs nothing and stops one such post from
    # aborting the whole build with a TypeError that names no post at all.
    formatting = formatting.filter_map do |f|
      s = f['start'].to_i.clamp(0, text.length)
      e = f['end'].to_i.clamp(0, text.length)
      next if s >= e

      f.merge('start' => s, 'end' => e)
    end
    return plain.call(text) if formatting.empty?

    boundaries = ([0, text.length] + formatting.flat_map { |f| [f['start'], f['end']] }).uniq.sort

    boundaries.each_cons(2).map do |s, e|
      next '' if s == e

      active = formatting.select { |f| f['start'] <= s && f['end'] >= e }
      # No autolinking inside an existing link, or it would produce a link
      # inside a link.
      linked = active.any? { |f| %w[link mention].include?(f['type']) }
      chunk = if !escape then text[s...e]
              elsif linked then CGI.escapeHTML(text[s...e])
              else autolink(text[s...e])
              end
      active.sort_by { |f| f['end'] - f['start'] }.each { |f| chunk = wrap_tag(chunk, f) }
      chunk
    end.join
  end

  # A newline stored in block text is a hard break. Applied after escaping and
  # span-wrapping, so the <br> can't collide with either; a chunk never
  # contains markup newlines of its own.
  def with_breaks(html)
    html.gsub("\n", '<br>')
  end

  # Local files get the native player; an imported embed (Spotify and the
  # like) is passed through like an imported video embed. No dimensions
  # anywhere -- degenerate_image? is about images reserving layout space, an
  # <audio> element has a fixed height of its own.
  def render_audio(block, media_prefix)
    local_media = (block['media'] || []).first
    if local_media
      %(<audio controls preload="metadata" src="#{media_src(media_prefix, local_media['url'])}"></audio>)
    elsif (src = Embed.src(block))
      embed_iframe(src, block)
    elsif block['embed_html'] && !block['embed_html'].strip.empty?
      Embed.without_scripts(block['embed_html'])
    elsif block['url']
      # A player that could not be looked up (offline at save time, or a
      # service with none for that address) still leaves the address, and a
      # link to it beats a dead end -- the same courtesy the video branch has
      # always shown.
      # safe_href, like the video fallback five lines of comment below --
      # the address comes from an import or a hand-edited post, which is
      # exactly the input a javascript: URL arrives in. The two branches are
      # the same shape and only one of them was filtering.
      %(<p class="audio-unavailable">#{h(t('post.audio_unavailable'))} <a href="#{h(safe_href(block['url']))}">#{h(block['url'])}</a></p>)
    else
      "<p><em>#{CGI.escapeHTML(t('post.audio_unavailable'))}</em></p>"
    end
  end

  # The players the engine builds itself, out of a provider and an id it
  # validated (lib/embed.rb) -- never out of the platform's own embed code.
  # Audio widgets are a fixed-height strip, video is 16:9 in the same
  # responsive box YouTube uses.
  def embed_iframe(src, block)
    provider = block['provider'].to_s
    title = h(provider.tr('_', '.'))
    common = %(loading="lazy" frameborder="0" allow="autoplay; clipboard-write; encrypted-media; picture-in-picture" allowfullscreen)
    if (height = Embed::AUDIO_HEIGHTS[provider])
      %(<iframe class="embed-audio" src="#{h(src)}" title="#{title}" width="100%" height="#{height}" #{common}></iframe>)
    else
      %(<div class="embed-responsive"><iframe src="#{h(src)}" title="#{title}" #{common}></iframe></div>)
    end
  end

  def render_video(block, media_prefix)
    local_media = (block['media'] || []).first
    if local_media
      %(<video controls preload="metadata"#{size_attrs(local_media)} src="#{media_src(media_prefix, local_media['url'])}"></video>)
    elsif block['embed_html'] && !block['embed_html'].strip.empty?
      # Only YouTube's embed is a plain iframe at a fixed size (356x200, 16:9) --
      # other providers (e.g. Instagram) ship their own responsive blockquote/script.
      if block['provider'] == 'youtube'
        %(<div class="embed-responsive">#{Embed.without_scripts(block['embed_html'])}</div>)
      else
        Embed.without_scripts(block['embed_html'])
      end
    elsif (id = block['youtube_id'])
      # Hand-written videos carry url + youtube_id, and the iframe is built
      # here so no foreign HTML ends up in the data. youtube-nocookie serves
      # the same player, just without tracking cookies until the visitor
      # actually starts playback.
      #
      # The condition is deliberately youtube_id, not parsing url: some
      # imports can leave blocks with provider=youtube and a url but empty
      # embed_html, because those videos have since disappeared from YouTube.
      # Those don't have a youtube_id and fall through to the polite notice
      # below instead of a broken player.
      %(<div class="embed-responsive"><iframe src="https://www.youtube-nocookie.com/embed/#{CGI.escapeHTML(id)}" ) +
        %(title="YouTube" frameborder="0" loading="lazy" ) +
        %(allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" ) +
        %(allowfullscreen></iframe></div>)
    elsif (src = Embed.src(block))
      embed_iframe(src, block)
    else
      # Escaped, both times. The address here comes from an import or a
      # hand-edited post, which is exactly the input that cannot be trusted:
      # unescaped it closed the href and wrote markup of its own into every
      # page the post appears on -- and into the RSS feed, which carries the
      # same rendered HTML.
      %(<p class="video-unavailable">#{h(t('post.video_unavailable'))} <a href="#{h(safe_href(block['url']))}">#{h(block['url'])}</a></p>)
    end
  end

  # Headings get an id derived from their text, so a section can be linked to
  # both from a table of contents at the top of the post and from outside it.
  # `seen` guards against two identically-named headings in one post getting
  # the same id.
  def heading_id(text, seen)
    base = tag_slug(text)
    base = 'section' if base.empty?
    seen[base] = seen.fetch(base, 0) + 1
    seen[base] > 1 ? "#{base}-#{seen[base]}" : base
  end

  # A list item's `children` is a nested list -- whatever shape the producer that
  # wrote it happened to use. Three have shipped and all three are in archives
  # now: markdown_parser writes a whole list block, html_blocks writes
  # {style, items} with no type at all, and wix wrote the bare items ARRAY.
  #
  # Only the first rendered. The second fell through `case block['type']` to the
  # unknown-type fallback, so a nested bullet imported from HTML -- Tumblr,
  # Ghost, WordPress, a feed, a rescued page -- printed as raw JSON in a <pre>
  # on the published page. The third reached `case` as an Array and took the
  # WHOLE BUILD down with a TypeError: not one page on the site regenerated,
  # `check` calling the archive sound, and `edit` refusing the post too, so the
  # archive was stuck.
  #
  # A nested list is a list. This is the one place that has to know it, and it
  # has to keep knowing it, because the two older shapes are already written.
  def nested_list(children)
    return nil if children.nil?
    return { 'type' => 'list', 'items' => children } if children.is_a?(Array)
    return nil unless children.is_a?(Hash)

    children['type'] ? children : children.merge('type' => 'list')
  end

  def render_block(block, media_prefix, seen = {}, title_lifted: false)
    case block['type']
    when 'text'
      heading = block['subtype'].to_s[/\Aheading([1-6])\z/, 1]
      tag = if heading then "h#{heading}"
            elsif block['subtype'] == 'quote' then 'blockquote'
            else 'p'
            end
      id = heading ? %( id="#{h(heading_id(block['text'].to_s, seen))}") : ''
      inner = with_breaks(apply_formatting(block['text'], block['formatting']))
      # A quote's attribution renders inside the blockquote as a <cite> line,
      # so the pairing survives copy-paste and reader modes.
      inner += %(<cite>— #{h(block['cite'])}</cite>) if tag == 'blockquote' && block['cite']
      "<#{tag}#{id}>#{inner}</#{tag}>"
    when 'list'
      tag = block['style'] == 'ol' ? 'ol' : 'ul'
      items = (block['items'] || []).map do |it|
        child = nested_list(it['children'])
        nested = child ? render_block(child, media_prefix, seen) : ''
        # A task item gets a real (disabled) checkbox and drops the bullet via
        # the class -- the checkbox is the bullet.
        if it.key?('checked')
          box = %(<input type="checkbox" disabled#{it['checked'] ? ' checked' : ''}>)
          %(<li class="task-item">#{box} #{apply_formatting(it['text'], it['formatting'])}#{nested}</li>)
        else
          "<li>#{apply_formatting(it['text'], it['formatting'])}#{nested}</li>"
        end
      end.join
      "<#{tag}>#{items}</#{tag}>"
    when 'table'
      render_table(block)
    when 'hr'
      '<hr>'
    when 'teaser_end'
      # Where the teaser stops. The post's own page shows everything, so the
      # marker itself renders as nothing; it exists for the toot, the link
      # card and the listing, which is where a post has to introduce itself.
      ''
    when 'code'
      lang_class = block['lang'].to_s.empty? ? '' : %( class="language-#{CGI.escapeHTML(block['lang'])}")
      # Same class as the chrome's own code blocks render with, for the same
      # reason -- see render_chrome_block. But NOT when this copy was cut to
      # fit a listing card: the button copies what the block holds, and what
      # a cut block holds is the truncation. A reader lifting a shell script
      # off the front page would get the first lines of it, run them, and
      # never be told the rest existed. With no class there is no button,
      # and the card's "read more" is what leads to the whole thing.
      cls = block['cut'] ? '' : ' class="code-block"'
      %(<pre#{cls}><code#{lang_class}>#{CGI.escapeHTML(block['text'].to_s)}</code></pre>)
    when 'file'
      file = (block['media'] || []).first || {}
      # Nothing attached: the card used to link the post's own directory
      # with a `download` attribute on it, which downloads an HTML page
      # named after the post. There is no file, so there is no card.
      return '' if file['url'].to_s.empty?

      label = block['label'].to_s.empty? ? file['url'].to_s : block['label']
      ext = File.extname(file['url'].to_s).delete('.').upcase
      ext = 'FILE' if ext.empty?
      size = human_size(file['size'])
      sub = [ext, size].compact.reject(&:empty?).join(' · ')
      %(<a class="file-card" href="#{media_src(media_prefix, file['url'])}" download>) +
        %(<span class="file-icon">#{h(ext[0, 4])}</span>) +
        %(<span class="file-meta"><span class="file-label">#{h(label)}</span>) +
        %(<span class="file-sub">#{h(sub)}</span></span>) +
        '<svg class="file-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' \
        'stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v13"/><path d="M6 12l6 6 6-6"/>' \
        '<path d="M5 21h14"/></svg></a>'
    when 'image'
      media = (block['media'] || []).first || {}
      # An image block with no media at all renders <img src="/posts/2026/x/">
      # -- the post's own directory -- which the browser fetches and draws as
      # a broken picture, and check called the archive clean. There is
      # nothing to show, so nothing is shown.
      return '' if media['url'].to_s.empty?
      caption = block['caption'] ? "<figcaption>#{CGI.escapeHTML(block['caption'])}</figcaption>" : ''
      # Listing pages ship the full post and let CSS clip it at 500px, so most
      # images on them are never actually seen -- lazy loading is what keeps
      # them from being downloaded anyway.
      # Omitted rather than empty when the size is unknown: width="" is not a
      # valid HTML integer attribute, and an image that can't reserve space is
      # better off saying nothing than saying nothing-shaped-like-a-number.
      %(<figure><img src="#{media_src(media_prefix, media['url'])}"#{size_attrs(media)} alt="#{CGI.escapeHTML(block['alt_text'].to_s)}" loading="lazy" decoding="async">#{caption}</figure>)
    when 'video'
      # <figure> is only added when a caption exists, so imported videos
      # without one don't get an unwanted layout change.
      caption = block['caption'].to_s.strip
      inner = render_video(block, media_prefix)
      return inner if caption.empty?

      %(<figure>#{inner}<figcaption>#{CGI.escapeHTML(caption)}</figcaption></figure>)
    when 'audio'
      caption = block['caption'].to_s.strip
      inner = render_audio(block, media_prefix)
      return inner if caption.empty?

      %(<figure>#{inner}<figcaption>#{CGI.escapeHTML(caption)}</figcaption></figure>)
    when 'chat'
      # A dialogue as a definition list: speaker as <dt>, line as <dd> --
      # semantic enough for reader modes, styled compactly by site.css.
      rows = (block['lines'] || []).map do |line|
        dt = line['name'] ? "<dt>#{CGI.escapeHTML(line['name'])}</dt>" : ''
        "#{dt}<dd>#{with_breaks(CGI.escapeHTML(line['text'].to_s))}</dd>"
      end.join
      %(<dl class="chat">#{rows}</dl>)
    when 'link'
      title = CGI.escapeHTML((block['title'] || block['url']).to_s)
      description = CGI.escapeHTML(block['description'].to_s)
      if title_lifted
        # The title is the post's heading now, and the heading is the link.
        # What is left here is the description -- and a link block that had
        # none has nothing left to draw at all.
        description.empty? ? '' : %(<p class="link-block">#{description}</p>)
      else
        %(<p class="link-block"><a href="#{CGI.escapeHTML(safe_href(block['url']))}"><strong>#{title}</strong></a><br>#{description}</p>)
      end
    else
      # Escaped. architecture.md promises an unknown type renders "as its
      # raw JSON in a <pre> -- loud, not silent", and raw is what it was: a
      # "<" anywhere in the block left the <pre> and became markup on the
      # page. Loud is the point; live is not.
      "<pre>#{h(block.to_json)}</pre>"
    end
  end

  TABLE_ALIGNMENTS = %w[left center right].freeze

  # A wrapper with its own scrollbar: a wide table has to scroll within itself,
  # not stretch the page -- same treatment as code blocks get on mobile.
  def render_table(block)
    align = block['align'] || []
    cell = lambda do |c, i, tag|
      # The three the markdown parser emits, and nothing else. This value
      # goes into a style attribute unescaped, and a table arrives from an
      # import or a post file somebody edited as readily as from the
      # parser. Dropped rather than escaped, because there is no fourth
      # thing a column could be aligned to: an unknown value is a mistake,
      # and the default is what a mistake should look like.
      where = TABLE_ALIGNMENTS.include?(align[i]) ? align[i] : nil
      style = where && where != 'left' ? %( style="text-align:#{where}") : ''
      "<#{tag}#{style}>#{apply_formatting(c['text'], c['formatting'])}</#{tag}>"
    end
    # No header key, no <thead>: a table that never had one (a Wix table with
    # rowHeader off, an HTML table with no <thead>) used to hand its first row
    # of data to a <th>, which is a heading to a screen reader and to anyone
    # reading the page.
    thead = if block['header']
              "<thead><tr>#{block['header'].each_with_index.map { |c, i| cell.call(c, i, 'th') }.join}</tr></thead>"
            else
              ''
            end
    body = (block['rows'] || []).map do |row|
      "<tr>#{row.each_with_index.map { |c, i| cell.call(c, i, 'td') }.join}</tr>"
    end.join
    %(<div class="table-wrap"><table>#{thead}<tbody>#{body}</tbody></table></div>)
  end

  def render_photo_grid(images, media_prefix, seen = {})
    items = images.map { |b| render_block(b, media_prefix, seen) }
    items[-1] = items[-1].sub('<figure>', '<figure class="span-2">') if items.length.odd?
    %(<div class="photo-grid">#{items.join}</div>)
  end

  # A 1x1 image is a tracking pixel an import dragged in, not a photo, and it
  # gets dropped from the page. "Dimensions unknown" is a different thing
  # entirely and used to land in the same branch, because nil.to_i is 0: any
  # format MediaDimensions can't read (GIF and WebP until now, HEIC still)
  # made the image AND its caption disappear from every rendered page without
  # a word. Unknown dimensions now render -- the page can jump a little on
  # load, which is a far smaller problem than a photo silently missing.
  # Both attributes or neither, and only when the stored size is a number at
  # all. `Integer(…, exception: false)` rather than `is_a?(Integer)` on
  # purpose: imports from before dimensions were normalised stored them as
  # strings ("640"), and 126 media blocks on the reference archive still do --
  # an Integer-only test silently stripped width/height off every one of them.
  # And rather than plain `.to_i`, because that raises on the `false` a broken
  # header reader could once produce.
  # Bytes as something a reader can weigh a click against. Shared with the
  # deploy script and the size limit it enforces, so a size reads the same
  # on an attachment card and in the message that refuses one.
  def human_size(bytes)
    FileSize.human(bytes)
  end

  def size_attrs(media)
    w = Integer(media['width'], exception: false)
    h = Integer(media['height'], exception: false)
    return '' unless w&.positive? && h&.positive?

    %( width="#{w}" height="#{h}")
  end

  def degenerate_image?(block)
    return false unless block['type'] == 'image'

    media = (block['media'] || []).first || {}
    w = Integer(media['width'], exception: false)
    h = Integer(media['height'], exception: false)
    # Unknown size (including a value that is not a number) renders; only a
    # real 1x1 is the tracking pixel this is here to drop.
    return false if w.nil? || h.nil?

    w <= 1 || h <= 1
  end

  # `lifted` is the one block whose title has been promoted to the post's
  # heading (see link_title_block); it is compared by identity, so a second
  # link block with the same title still renders in full.
  def render_content(blocks, media_prefix, lifted: nil)
    blocks = blocks.reject { |b| degenerate_image?(b) }
    seen = {}
    html = []
    i = 0
    while i < blocks.length
      if blocks[i]['type'] == 'image'
        group = []
        while i < blocks.length && blocks[i]['type'] == 'image'
          group << blocks[i]
          i += 1
        end
        html << (group.length > 1 ? render_photo_grid(group, media_prefix, seen) : render_block(group.first, media_prefix, seen))
      else
        html << render_block(blocks[i], media_prefix, seen, title_lifted: blocks[i].equal?(lifted))
        i += 1
      end
    end
    html.reject(&:empty?).join("\n")
  end
end
