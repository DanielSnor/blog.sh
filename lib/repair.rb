# frozen_string_literal: true

require 'cgi'
require 'json'
require 'fileutils'
require_relative 'entity_text'
require_relative 'atomic_write'
require_relative 'post_versions'
require_relative 'checker'
require_relative 'post_address'
require_relative 'path_glob'

# lib/repair.rb -- turns a finding into the one repair it allows, and
# applies it when a human says so.
#
# The rule this module exists to keep is the one the checker's own comment
# states: a checker that also acts has to be trusted twice. So the acting
# half is separate, it is never automatic, and it is deliberately narrow --
# it proposes for the four kinds where the right answer is not a matter of
# taste, and says nothing at all for the rest. A finding with no proposal
# is shown and skipped, never guessed at.
#
# Three rules hold for every proposal here:
#
#   Add rather than rewrite, wherever adding is possible. A dead link to
#   an old address is repaired on the TARGET post, by writing the old
#   address into its redirect_from -- one new line, the author's twenty
#   year old text untouched, and every link to that address fixed at once,
#   including the ones from outside the site that no check can see.
#
#   Never delete. A file nobody references goes to the trash the engine
#   already has -- trash/<year>/<slug>/media/, the same place a deleted
#   post's media lands -- and `./blog.sh restore <slug>` hands it back.
#   The pass first invented a layout of its own, which made that promise
#   false; the layout is the promise.
#
#   Nothing happens twice. A second run over a repaired archive proposes
#   nothing, because the finding it would have proposed for is gone.
module Repair
  # A repair, as data rather than a closure: it can be printed, counted,
  # tested and applied by something other than whoever proposed it.
  Proposal = Struct.new(:action, :data, keyword_init: true)

  # The first segments of a redirect_from that belong to the site itself --
  # the build refuses these with a warning, so proposing one would be
  # proposing a change that quietly does nothing. There were four copies of
  # this list; it has one home now, and every reader borrows it from there.
  RESERVED = PostAddress::REDIRECT_RESERVED

  module_function

  # A slug names a post only if it names exactly one. It is unique within a
  # year, not across the archive -- sean.cz carries two pairs that repeat
  # across years -- so the index keeps every post of a name and the lookup
  # refuses to choose between them.
  def index(posts)
    by_slug = posts.group_by { |post| post['slug'].to_s }
    # ...and the same thing folded, for addresses that shout. An old
    # permalink is often /Archiv/Motorola-A1000.html, and percent-encoding
    # arrives with anything a browser ever touched. Two slugs that fold
    # together name neither post, exactly like two that are equal.
    { 'by_slug' => by_slug, 'folded' => by_slug.keys.group_by { |slug| Checker.fold_name(slug) } }
  end

  # The post a slug names, or nil with a reason worth telling: a draft has
  # no address on the site yet (the build writes neither its page at the
  # ordinary address nor its redirect stubs), and a slug two posts share
  # names neither of them.
  def resolve(slug, idx)
    found = idx['by_slug'][slug] || folded_match(slug, idx)
    return [nil, nil] if found.nil? || found.empty?
    return [nil, :duplicate] if found.size > 1
    return [nil, :draft] if PostAddress.draft?(found.first)

    [found.first, nil]
  end

  def only(idx, slug)
    resolve(slug, idx).first
  end

  # One folded candidate, or nothing.
  def folded_match(slug, idx)
    names = idx['folded'][Checker.fold_name(slug)]
    return nil unless names && names.size == 1

    idx['by_slug'][names.first]
  end

  # The shorter side of a prefix match must be at least this long. Measured
  # rather than guessed: the six real prefix matches on sean.cz are 48 to
  # 128 characters, the false ones 1 to 14. Below this a "prefix" is a
  # coincidence -- /item/motorola-a1000 would otherwise claim
  # motorola-a1000-vstupuje-na-scenu.
  MIN_PREFIX = 30
  # ...with one exception, which is why the loose match existed at all: an
  # old permalink is often the slug with a file extension stuck on it.
  EXTENSION = /\A(.+)\.[a-z0-9]{1,5}\z/i.freeze

  # Percent escapes undone, one path segment at a time, and only when what
  # comes out is a string at all.
  def decode_path(path)
    Checker.percent_decoded(path)
  end

  def tail_of(url)
    path = url.to_s.split('#').first.to_s.split('?').first.to_s
    tail = path.sub(%r{/\z}, '').split('/').last.to_s
    # %C3%AD is what a browser makes of an accented slug, and an archive
    # full of old permalinks is full of them. But %E8 (latin-1, from a site
    # that predates UTF-8) decodes to bytes that are not a string at all --
    # and every String method after this one raises on them. Undecoded is
    # the honest answer there: no match, no crash.
    decoded = CGI.unescape(tail)
    decoded.valid_encoding? ? decoded : tail
  end

  def target_for(url, idx)
    tail = tail_of(url)
    return nil if tail.empty?

    post = only(idx, tail)
    return post if post

    stripped = tail[EXTENSION, 1]
    post = stripped && only(idx, stripped)
    return post if post

    matches = idx['by_slug'].keys.select do |slug|
      next false unless slug.start_with?(tail) || tail.start_with?(slug)

      [slug.length, tail.length].min >= MIN_PREFIX
    end
    matches.size == 1 ? only(idx, matches.first) : nil
  end

  def post_path(post)
    PostAddress.path(post)
  end

  # Why a finding got no offer, when the answer is worth a sentence: the
  # tool FOUND something and refused it on purpose. Everything else keeps
  # the general "this one is yours to decide".
  def why_not(finding, idx)
    data = finding.data || {}
    return nil unless %i[link_dead link_relative].include?(finding.kind)

    tail = tail_of(data['url'])
    reason = tail.empty? ? nil : resolve(tail, idx).last
    return reason if reason

    # ...and the query shape, which is how most relative links name their
    # target: ./?item=<slug>.
    query = data['url'].to_s.split('#').first.to_s.split('?')[1].to_s
    query.split('&').filter_map do |pair|
      value = pair.split('=', 2)[1].to_s
      next if value.empty?

      resolve(value, idx).last
    end.first
  end

  # Whether an address can be a redirect_from at all. The build refuses a
  # query string, a fragment and the site's own first segments, so a
  # proposal carrying one of those would be a promise the build breaks.
  def redirectable?(origin)
    PostAddress.redirect_refusal(origin).nil?
  end

  # The one repair a finding allows, or nil when the answer is a person's
  # to give.
  def propose(finding, idx)
    data = finding.data || {}
    case finding.kind
    when :link_dead then propose_redirect(data, idx)
    when :link_relative then propose_rewrite(data, idx)
    when :media_misnamed then propose_rename(data)
    when :post_entities
      # Nothing to work out: the fix is the text itself, decoded. The
      # decision the reader is being asked for is whether those entities
      # were meant literally -- which is why this is offered one post at a
      # time rather than swept.
      Proposal.new(action: :decode_entities,
                   data: { 'slug' => data['slug'].to_s, 'year' => data['year'].to_s })
    when :media_orphan
      Proposal.new(action: :trash, data: { 'path' => File.join('media.nosync', data['dir'].to_s) })
    when :media_stray
      # The directory the checker actually walked -- for a post whose file
      # sits in another year than its date, that is not year/slug. The old
      # shape stays as the fallback so a finding out of an older --json
      # dump still behaves.
      dir = data['dir'].to_s.empty? ? File.join(data['year'].to_s, data['slug'].to_s) : data['dir'].to_s
      Proposal.new(action: :trash,
                   data: { 'path' => File.join('media.nosync', dir, data['file'].to_s) })
    end
  end

  # The bytes are the fact; the name in the post is only a record of them.
  # So the repair rewrites the RECORD -- never the file on disk, which
  # rsync, backups and older exports know under the name it has, and which
  # on a case-sensitive volume might collide with a file already there.
  #
  # Not offered when the post already uses the correct name somewhere else:
  # two blocks would then share one url, and which picture was lost is not
  # a question for a machine.
  def propose_rename(data)
    from = data['file'].to_s
    to = data['actual'].to_s
    return nil if from.empty? || to.empty? || from == to
    # The comment above has promised this since it was written, and the
    # code never asked: the refusal lived at apply time instead, so the
    # rename was offered in full, the keypress was taken, and the answer
    # was "could not be applied" with no reason given.
    return nil if data['actual_in_use']

    Proposal.new(action: :rename_media_ref,
                 data: { 'slug' => data['slug'].to_s, 'year' => data['year'].to_s,
                         'dir' => data['dir'].to_s, 'from' => from, 'to' => to })
  end

  def propose_redirect(data, idx)
    # Decoded segment by segment: the build serves the stub at the address
    # as written, and a stub written as /archiv/motorola-%C3%A1... answers
    # at a literal percent sign, which is not where anybody knocks. Segment
    # by segment rather than whole, because CGI.unescape would also turn a
    # literal "+" into a space.
    origin = decode_path(data['url'].to_s.split('#').first.to_s)
    return nil unless redirectable?(origin)

    target = target_for(origin, idx)
    return nil if target.nil?

    Proposal.new(action: :add_redirect,
                 data: { 'slug' => target['slug'], 'year' => PostAddress.file_year(target),
                         'origin' => origin, 'to' => post_path(target) })
  end

  # A relative link often carries its target in the QUERY rather than in the
  # path -- `./?item=another-post` is the shape a dynamic site left behind,
  # and it was the commonest of the 73 found in one real archive. The path
  # of that address says nothing at all ("."), so the query is asked next.
  # Every value in the query goes through the same matcher, and the answer
  # counts only if the WHOLE query names one post. Two values pointing at
  # two posts is not a tie to be broken by order.
  def target_in_query(url, idx)
    query = url.to_s.split('#').first.to_s.split('?')[1].to_s
    hits = query.split('&').filter_map do |pair|
      value = pair.split('=', 2)[1].to_s
      next if value.empty?

      only(idx, value) || target_for(value, idx)
    end
    unique = hits.uniq { |post| [PostAddress.file_year(post), post['slug']] }
    unique.size == 1 ? unique.first : nil
  end

  def propose_rewrite(data, idx)
    target = target_for(data['url'], idx) || target_in_query(data['url'], idx)
    return nil if target.nil?

    # The YEAR of the post that carries the link, not of the target: this is
    # which file to open, and a slug alone does not say.
    #
    # An anchor rides along: ../about/#kontakt means a paragraph, and
    # rewriting it to /about/ lands the reader at the top of the page with
    # nothing to say what they came for.
    anchor = data['url'].to_s[/#.*\z/].to_s
    Proposal.new(action: :rewrite_link,
                 data: { 'slug' => data['slug'].to_s, 'year' => data['year'].to_s,
                         'from' => data['url'].to_s, 'to' => "#{post_path(target)}#{anchor}" })
  end

  # --- applying -------------------------------------------------------------

  # A repair that cannot be carried out answers false; it never raises into
  # the pass. One unreadable post in an archive of thousands must not end a
  # session that was about to fix ninety others -- and the caller counts a
  # false, so nothing is passed over in silence either.
  def apply!(proposal, root)
    apply_one(proposal, root)
  rescue StandardError => e
    warn "repair failed (#{proposal.action}): #{e.message}"
    false
  end

  def apply_one(proposal, root)
    case proposal.action
    when :add_redirect then add_redirect(proposal.data, root)
    when :rewrite_link then rewrite_link(proposal.data, root)
    when :decode_entities then decode_entities(proposal.data, root)
    when :rename_media_ref then rename_media_ref(proposal.data, root)
    when :trash then trash(proposal.data, root)
    else false
    end
  end

  # Decoding is done by the same code the Twitter importer uses, spans and
  # all: the text shrinks, so every formatting offset after an entity has to
  # move with it or a link ends up over the wrong words. Writing that twice
  # is how the two would drift.
  def decode_entities(data, root)
    path = post_file(root, data['year'], data['slug'])
    return false unless File.exist?(path)

    post = JSON.parse(File.read(path, encoding: 'utf-8'))
    changed = false
    Array(post['content']).each do |block|
      next unless block.is_a?(Hash)

      if block['type'] == 'text' && EntityText.entities?(block['text'])
        decoded, = EntityText.decode(block['text'].to_s, block['formatting'] || [])
        block['text'] = decoded
        changed = true
      end
      # A link card's own words, which the check has looked at since 1.5:
      # they are the card's headline and its blurb, and an entity there is
      # as visible as one in a paragraph.
      next unless block['type'] == 'link'

      %w[title description].each do |key|
        next unless EntityText.entities?(block[key])

        block[key] = EntityText.decode(block[key].to_s, []).first
        changed = true
      end
    end
    # The TITLE. The check learned to look at it in 1.5 and this did not
    # follow, so the two posts on one real archive whose entity is in the
    # title were offered the repair, took the keypress, and were reported
    # as done while nothing was written -- the same shape the bounty found
    # in the media rename. No formatting to carry: a title has none.
    if EntityText.entities?(post['title'])
      post['title'] = EntityText.decode(post['title'].to_s, []).first
      changed = true
    end
    # Nothing to decode is a FAILURE here, not a quiet success. The repair
    # is only ever offered against a finding that says there are entities;
    # if none are found now, the post changed under the run, and a summary
    # counting that as applied is a summary that lies.
    return false unless changed
    return false unless keep_version(path, root)

    AtomicWrite.write_json(path, post)
    true
  rescue StandardError
    false
  end

  def post_file(root, year, slug)
    File.join(root, 'content.nosync', 'posts', year.to_s, "#{slug}.json")
  end

  def add_redirect(data, root)
    path = post_file(root, data['year'], data['slug'])
    return false unless File.exist?(path)

    post = JSON.parse(File.read(path, encoding: 'utf-8'))
    list = Array(post['redirect_from'])
    return true if list.include?(data['origin']) # already there: nothing to do, and that is a success

    post['redirect_from'] = list + [data['origin']]
    return false unless keep_version(path, root)

    AtomicWrite.write_json(path, post)
    true
  end

  # Every other writer of a post in this engine leaves a copy behind first
  # (scripts/manage_post.rb does it before an edit and before a delete), and
  # `./blog.sh versions` is how an author walks back. The repair pass was
  # the one writer that did not, which made it the one change in the archive
  # that could not be undone from inside the engine.
  # One version per post per pass, not one per repair. A post with eleven
  # dead links used to spend the whole CAP of ten in a single run and push
  # the author's own history off the end of it -- the repair pass would then
  # be the only thing anybody could walk back to.
  def kept_this_run
    @kept_this_run ||= {}
  end

  def keep_version(path, root)
    return true if kept_this_run[path]

    content = File.join(root, 'content.nosync', 'posts')
    slug = File.basename(path, '.json')
    year = File.basename(File.dirname(path))
    before = File.read(path, encoding: 'utf-8')
    PostVersions.keep(path, content_dir: content)
    # What matters is whether the state BEFORE this change can be walked
    # back to -- not whether the number of files grew. PostVersions.keep
    # legitimately writes nothing when a byte-identical copy is already
    # there (its guard against a re-import filling the history with
    # duplicates), and at a full CAP the prune drops the oldest as the new
    # one lands, so the count stays put. Counting called both of those a
    # failure -- and the first one is every archive that was ever imported
    # twice, which is most of the ones this pass exists for.
    kept = PostVersions.list(slug, year, content_dir: content).any? do |file|
      # Per file: one unreadable version in the history (a write cut short
      # by a full disk, a permission left behind by a restore) must not
      # stop every repair on that post -- which is what a single raise
      # inside this loop did.
      begin
        File.read(file, encoding: 'utf-8') == before
      rescue SystemCallError, IOError
        false
      end
    end
    unless kept
      warn "version not kept for #{File.basename(path)} -- nothing was changed"
      return false
    end

    kept_this_run[path] = true
  rescue StandardError => e
    # No copy, no write. The whole promise of this pass is that a change can
    # be walked back; a repair that cannot be undone is a different offer
    # from the one that was made.
    warn "version not kept for #{File.basename(path)}: #{e.message}"
    false
  end

  # The link lives in a formatting span or in a link block, and both shapes
  # occur in one archive -- the same two places Checker.all_links reads, for
  # the same reason.
  def rewrite_link(data, root)
    # By year and slug when the finding carried a year (it does since 1.4),
    # because a slug can name a file in two different years and the glob
    # answered with whichever came first alphabetically.
    year = data['year'].to_s
    path = year.empty? ? nil : post_file(root, year, data['slug'])
    unless path && File.exist?(path)
      path = PathGlob.under(root, 'content.nosync', 'posts', '*',
                            "#{PathGlob.literal(data['slug'])}.json").first
    end
    return false unless path && File.exist?(path)

    post = JSON.parse(File.read(path, encoding: 'utf-8'))
    touched = false
    Array(post['content']).each do |block|
      next unless block.is_a?(Hash)

      if block['url'].to_s == data['from']
        block['url'] = data['to']
        touched = true
      end
      [block['formatting'], *Array(block['items']).map { |i| i.is_a?(Hash) ? i['formatting'] : nil }].each do |spans|
        Array(spans).each do |span|
          next unless span.is_a?(Hash) && span['url'].to_s == data['from']

          span['url'] = data['to']
          touched = true
        end
      end
    end
    # Nothing to change because an earlier repair in this same pass already
    # rewrote every occurrence of that address: a success, not a refusal.
    # Two findings can name one address, and the second must not be reported
    # -- nor counted -- as something that failed.
    return true if !touched && link_urls(post).include?(data['to'])
    return false unless touched
    return false unless keep_version(path, root)

    AtomicWrite.write_json(path, post)
    true
  end

  # The trash the engine already has, with the archive's own shape kept
  # inside it, so what came out of media.nosync/2014/a-post goes back there
  # by hand if anyone wants it. Never a delete: the whole point of a repair
  # that runs over somebody's twenty-year archive is that it can be undone.
  def rename_media_ref(data, root)
    path = post_file(root, data['year'], data['slug'])
    return false unless File.exist?(path)

    post = JSON.parse(File.read(path, encoding: 'utf-8'))
    # The post file lives under the FILE year (the line above); the media
    # may live under the date year -- the finding carries the directory
    # that was actually read, and only falls back to year/slug for a
    # finding out of an older --json dump.
    rel = data['dir'].to_s.empty? ? File.join(data['year'].to_s, data['slug'].to_s) : data['dir'].to_s
    dir = File.join(root, 'media.nosync', rel)
    # Asked again at the moment of writing, not trusted from the scan: the
    # directory has to hold that name NOW.
    return false unless Dir.exist?(dir) && Dir.children(dir).include?(data['to'])
    return false if media_names(post).include?(data['to'])

    touched = false
    each_media_entry(post) do |entry|
      next unless entry['url'].to_s == data['from']

      entry['url'] = data['to']
      touched = true
    end
    return false unless touched

    return false unless keep_version(path, root)

    AtomicWrite.write_json(path, post)
    true
  end


  # Every link address a post carries -- the same two places the checker
  # reads them from.
  def link_urls(post)
    urls = []
    Array(post['content']).each do |block|
      next unless block.is_a?(Hash)

      urls << block['url'].to_s if block['type'] == 'link'
      spans = Array(block['formatting']) +
              Array(block['items']).flat_map { |item| item.is_a?(Hash) ? Array(item['formatting']) : [] }
      spans.each { |span| urls << span['url'].to_s if span.is_a?(Hash) && span['type'] == 'link' }
    end
    urls
  end

  # Both places a block keeps a file name, the same two the checker reads:
  # the media list and a video's poster.
  def each_media_entry(post)
    Array(post['content']).each do |block|
      next unless block.is_a?(Hash)

      (Array(block['media']) + Array(block['poster'])).each do |entry|
        yield entry if entry.is_a?(Hash)
      end
    end
  end

  def media_names(post)
    names = []
    each_media_entry(post) { |entry| names << entry['url'].to_s }
    names
  end

  # The guard that makes the module's second promise true rather than
  # merely intended. A finding is a fact about the moment of the scan; the
  # move happens minutes later, after however many keystrokes. So the
  # archive is asked once more, right here -- and asked the way the volume
  # answers, by identity rather than by spelling, so this holds even if the
  # claim above were wrong.
  #
  # Only one post can own the file: a media url is a bare name that the
  # build resolves inside that post's own directory and nowhere else. So
  # this reads one JSON, not the archive.
  def still_unreferenced?(data, root)
    parts = data['path'].to_s.split('/')
    return true unless parts.first == 'media.nosync' && parts.length >= 3

    year = parts[1]
    slug = parts[2]
    dir = File.join(root, 'media.nosync', year, slug)
    target = File.join(root, data['path'])
    # Every post of that slug, in EVERY year -- not just the year the media
    # path is named after. A post whose date was corrected keeps its file
    # where it was while the build puts its media under the date's year, so
    # asking one directory could miss the very post that uses this file.
    owners = PathGlob.under(root, 'content.nosync', 'posts', '*', "#{PathGlob.literal(slug)}.json")
    return true if owners.empty?

    # A whole directory is refused only when a post of that name actually
    # keeps files IN IT. Refusing on the mere existence of a namesake in
    # another year left such a directory impossible to tidy away, for ever,
    # with check reporting it on every run.
    owners.none? do |owner|
      post = JSON.parse(File.read(owner, encoding: 'utf-8'))
      claimed = Checker.claim_media(dir, media_names(post)).values.compact
      if File.directory?(target)
        # For a directory: does this post keep anything at all in there?
        claimed.any? { |name, _how| File.exist?(File.join(dir, name)) }
      else
        claimed.any? do |name, _how|
          candidate = File.join(dir, name)
          File.exist?(candidate) && File.identical?(candidate, target)
        end
      end
    end
  rescue StandardError
    # Unreadable post: refuse. Nothing is lost by declining a repair.
    false
  end

  def trash(data, root)
    source = File.join(root, data['path'])
    return false unless File.exist?(source)
    return false unless still_unreferenced?(data, root)

    target = trash_target(root, data['path'])
    return false if target.nil?

    if File.directory?(source)
      # Merged into the media/ directory rather than set beside it under a
      # stamped name: the trash already keeps this post's media there, and
      # a directory called media.20260822013000 is one restore does not
      # look for and the NEXT restore of that post deletes outright.
      FileUtils.mkdir_p(target)
      Dir.children(source).each { |name| move_aside(File.join(source, name), File.join(target, name)) }
      FileUtils.rm_rf(source) if Dir.children(source).empty?
    else
      FileUtils.mkdir_p(File.dirname(target))
      move_aside(source, target)
    end
    true
  end

  # A name already taken in the trash gets a stamp -- on the FILE, which
  # restore hands back, never on the directory it looks in.
  def move_aside(source, target)
    target = "#{target}.#{Time.now.strftime('%Y%m%d%H%M%S')}" if File.exist?(target)
    FileUtils.mv(source, target)
  end

  # The shape the engine already uses for a deleted post's media
  # (scripts/manage_post.rb moves media.nosync/<year>/<slug> to
  # trash/<year>/<slug>/media), so what this pass sets aside lands where
  # both a person and `restore` already know to look. The pass invented its
  # own trash/media.nosync/... layout at first, which is the only reason
  # restore could not reach it.
  def trash_target(root, rel)
    parts = rel.to_s.split('/')
    return nil unless parts.first == 'media.nosync' && parts.length >= 3

    File.join(root, 'trash', parts[1], parts[2], 'media', *parts[3..])
  end
end
