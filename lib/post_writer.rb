require 'json'
require 'fileutils'
require 'securerandom'
require 'time'
require_relative 'atomic_write'
require_relative 'post_versions'
require_relative 'exif_location'
require_relative 'site_config'

module PostWriter
  ROOT = File.expand_path('..', __dir__)
  CONTENT_DIR = File.join(ROOT, 'content.nosync', 'posts')
  MEDIA_DIR = File.join(ROOT, 'media.nosync')

  # post: hash matching the post schema (slug, title, date, state, tags, content, source)
  # media_files: { source_path => desired_filename } to copy into media/<year>/<slug>/
  def self.write(post, media_files: {})
    date = Time.parse(post.fetch('date'))
    year = date.year.to_s

    # A post already imported from this exact source item is UPDATED, not
    # duplicated -- "matched on their source id" is a promise README and the
    # docs both make, and until now it only held while the slug-producing
    # text at the source never changed. A fixed typo in an RSS title, an
    # edited toot, and the re-import minted a second post under the new
    # slug while the old one sat next to it.
    #
    # The existing slug is kept on purpose: the URL is published, links and
    # announcement toots point at it, and a re-import must never move it
    # just because a title was edited at the source.
    existing_path = find_by_source(post['source'])
    if existing_path
      post = post.merge('slug' => File.basename(existing_path, '.json'))
      return update_matched(existing_path, post, year, media_files)
    end

    dir = File.join(CONTENT_DIR, year)
    FileUtils.mkdir_p(dir)
    slug = unique_slug(post.fetch('slug'), dir, post['source'])
    post = post.merge('slug' => slug)
    post = ensure_draft_token(post)

    copy_media(media_files, year, slug)
    path = File.join(dir, "#{slug}.json")
    AtomicWrite.write_json(path, post)
    index[source_key(post['source'])] = path if source_key(post['source'])
    path
  end

  # media.strip_location, on unless a site says otherwise. On by default
  # because the cost of the wrong default is asymmetric: a photographer who
  # wants coordinates in their archive notices they are missing and turns
  # this off, while somebody who never knew phones write them finds out from
  # a stranger who read them off the web.
  def self.strip_location?
    SiteConfig.get('media', 'strip_location', default: true) != false
  end

  def self.copy_media(media_files, year, slug)
    return if media_files.empty?

    media_dir = File.join(MEDIA_DIR, year, slug)
    FileUtils.mkdir_p(media_dir)
    media_files.each do |src_path, filename|
      dest = File.join(media_dir, filename)
      next if File.exist?(dest)

      # Copied beside the destination and renamed into place, rather than
      # written straight to it. "Skip what already exists" is what makes a
      # re-import safe, and a copy interrupted halfway -- Ctrl-C, a full
      # disk, a container that went away -- leaves a truncated file that
      # every later run then skips, so the half-image publishes and no
      # amount of re-importing replaces it. A rename either happened or it
      # did not, so the only file under the real name is a complete one.
      tmp = File.join(media_dir, ".#{filename}.part")
      begin
        FileUtils.cp(src_path, tmp)
        # On the copy, never on the author's own file: what sits in
        # incoming/ or in a photo library is theirs, and the archive's
        # copy is the one about to be published. Between the cp and the
        # rename is the one moment the file is the engine's alone.
        ExifLocation.strip_file(tmp) if strip_location?
        File.rename(tmp, dest)
      rescue StandardError
        begin
          File.delete(tmp)
        rescue StandardError
          nil
        end
        raise
      end
    end
  end

  # Overwrites the matched post in place -- or moves it when the source
  # changed the item's date across a year boundary, since the build derives
  # both the URL and the media lookup from the date, and a file left in the
  # old year's directory with a new year's date loses its images (the same
  # inconsistency prompt_and_schedule used to create).
  def self.update_matched(existing_path, post, year, media_files)
    slug = post['slug']
    old_year = File.basename(File.dirname(existing_path))

    # Engine-side state the source can never know about. A re-import that
    # dropped mastodon_url severed the announcement thread -- the post's
    # stats and comments both hang off it -- which is the exact bug cmd_edit
    # had and fixed. state and draft_token are deliberately NOT carried
    # over: what the source says about published/draft wins on re-import,
    # same as it always has.
    old = JSON.parse(File.read(existing_path, encoding: 'utf-8')) rescue nil
    # former_slugs is in the list for the same reason as the announcement
    # URLs: a rename is engine-side history the source can never know
    # about, and dropping it would break every redirect the post carries.
    # pinned and created_at joined it in 1.1 -- the pin is engine-side
    # state (the source has no notion of a front page) and created_at is
    # the draft-era timestamp the publish "was the date edited?" check
    # reads; both were silently dropped on re-import until named here. The
    # guard below only carries a key the importer did not set itself, so an
    # importer that legitimately provides one still wins. `type` stays out:
    # absent, the build re-derives it from the (re-imported) blocks, so it
    # comes back on its own.
    # redirect_from rides along too: the importer that understands the
    # source platform writes it once, and a later re-import from an export
    # that carries no URL history (or a different importer entirely) must
    # not silently drop the addresses the post still answers for.
    # page, series and series_part joined the list in 1.3. Same rule as the
    # rest: carried over only when the importer said nothing itself, so an
    # adapter that DOES recognise a page still wins, and a series -- which
    # no source has a notion of -- survives every re-import.
    %w[mastodon_url bluesky_url bluesky_uri former_slugs unpublished_from pinned created_at
       redirect_from page series series_part].each do |key|
      post[key] = old[key] if old && old[key] && !post[key]
    end
    # hero, toc and unlisted need presence rather than truth, and that
    # distinction is the whole point of them: `hero: false` is a post saying
    # "not me", and a guard that tests `old[key]` reads that as "nothing to
    # carry" and throws it away -- which is exactly how the field went
    # missing from the editor before it was a frontmatter key. Only what the
    # importer itself did not set, as above.
    #
    # unlisted was left out of both lists when it arrived in this cycle, and
    # of the three it is the one that costs something to lose: no source has
    # a notion of it, so no adapter ever sets it, and a re-import therefore
    # put a post the author had taken out of the listings back into every
    # one of them -- the homepage, the feeds, the sitemap and the search
    # index. Silently, and against a promise the import summary makes out
    # loud, that re-running is safe because posts are matched on their
    # source id. A post is unlisted for people, not for search engines, so
    # the failure is quiet on the one side that matters.
    %w[hero toc unlisted].each do |key|
      post[key] = old[key] if old&.key?(key) && !post.key?(key)
    end
    # A re-imported draft keeps its preview URL: the token is engine-side
    # state like the announcement URLs above, and minting a fresh one per
    # re-import would break every shared preview link.
    post['draft_token'] = old['draft_token'] if old && old['draft_token'] && post['state'] == 'draft' && !post['draft_token']
    post = ensure_draft_token(post)

    # unpublished_from is a promise the engine owes the web: "this post
    # used to live at that address, and when it is published again the
    # address must redirect". Publishing.publish keeps that promise and
    # spends the marker. A re-import publishes a post WITHOUT going
    # through it -- the source simply says the post is public -- so the
    # marker survived forever, and after unpublish -> rename -> re-import
    # the old address 404'd while a marker for it sat in the JSON. Spent
    # here for the same reason and in the same way.
    if post['state'] != 'draft' && post['unpublished_from']
      vacated = post.delete('unpublished_from')
      former = (Array(post['former_slugs']).map(&:to_s) + [vacated].compact).uniq - ["#{year}/#{slug}"]
      former.empty? ? post.delete('former_slugs') : post['former_slugs'] = former
    end

    new_dir = File.join(CONTENT_DIR, year)
    new_path = File.join(new_dir, "#{slug}.json")

    if File.expand_path(new_path) != File.expand_path(existing_path)
      # The same guard Publishing.publish and edit_post have, for the same
      # reason: a DIFFERENT post can already own <new_year>/<slug> -- the
      # real archive has the same slug in two years today -- and writing
      # there would replace it wholesale while this post's old file gets
      # deleted, so the build's duplicate check never fires. Raised as a
      # StandardError on purpose: inside an import the per-item rescue
      # counts it and names it, and the rest of the run continues; nothing
      # here has been moved or deleted yet.
      if File.exist?(new_path)
        raise "cannot move '#{slug}' into #{year}: a different post already owns " \
              "#{new_path} -- resolve the slug clash by hand"
      end

      # A published post that moves years vacates its public address, and
      # the redirect for it has to be recorded here exactly as edit_post
      # records it -- a re-import from a source that started reporting its
      # dates in another timezone is enough to move a post across a New
      # Year, and every link to it died with no stub behind it.
      #
      # Read from the OLD file: `post` is what the import built, and the
      # state that decides whether there is a public address to keep is the
      # state the post is in now.
      if old && old['state'] != 'draft'
        vacated = "#{old_year}/#{slug}"
        former = (Array(post['former_slugs']).map(&:to_s) + [vacated]).uniq - ["#{year}/#{slug}"]
        post['former_slugs'] = former unless former.empty?
      end

      FileUtils.mkdir_p(new_dir)
      move_media_dir(File.join(MEDIA_DIR, old_year, slug), File.join(MEDIA_DIR, year, slug))
    end

    copy_media(media_files, year, slug)
    # The other way a post's text gets replaced, and the more dangerous
    # one: a re-import overwrites in place across the whole archive at
    # once, and nobody reads a few thousand posts afterwards to see what
    # the source decided to change. Keyed on the OLD location, since that
    # is the copy about to stop existing.
    PostVersions.keep(existing_path, content_dir: CONTENT_DIR)
    # Write first, delete second -- same ordering as Publishing.publish, so
    # a failure in between leaves the post twice (recoverable) rather than
    # not at all.
    AtomicWrite.write_json(new_path, post)
    File.delete(existing_path) if File.expand_path(new_path) != File.expand_path(existing_path)
    index[source_key(post['source'])] = new_path if source_key(post['source'])
    new_path
  end

  # Every draft carries a token, no matter which path wrote it. The
  # authoring CLI always set one, but the importers never did -- so a
  # WordPress draft/pending/private post landed on the live site at
  # /draft//<slug>/, an address anyone could derive from the slug. The
  # whole point of the token is that a preview URL can't be guessed.
  def self.ensure_draft_token(post)
    return post unless post['state'] == 'draft'
    return post unless post['draft_token'].to_s.empty?

    post.merge('draft_token' => SecureRandom.hex(8))
  end

  # mv with two cautions FileUtils.mv alone doesn't have: the target year
  # directory may not exist yet (mkdir_p, or the mv raises ENOENT), and the
  # target slug directory may already exist as an orphan -- mv would then
  # NEST the source inside it (media/<year>/<slug>/<slug>/) and the page
  # would lose its files. Merging file by file keeps both sides' contents.
  def self.move_media_dir(from, to)
    return unless Dir.exist?(from)

    if Dir.exist?(to)
      # A file already sitting under the name we are moving in is NOT a
      # reason to leave ours behind. Skipping it -- which is what this did
      # -- left the post pointing at somebody else's bytes under its own
      # filename (01.jpg is 01.jpg in every post), while its real file
      # stayed in the old year where nothing would ever look for it. The
      # target directory here is an orphan a delete left behind, or the
      # post's own; either way the arriving file is the one the post
      # references. The one in the way is moved aside rather than
      # overwritten, because nothing about a stray file says it is safe
      # to destroy, and named loudly enough to notice.
      Dir.children(from).each do |f|
        dest = File.join(to, f)
        if File.exist?(dest)
          aside = "#{dest}.displaced"
          n = 1
          n += 1 while File.exist?("#{aside}#{n}")
          FileUtils.mv(dest, "#{aside}#{n}")
          warn "media: #{File.basename(to)}/#{f} was already taken -- the file that was there is now #{File.basename("#{aside}#{n}")}"
        end
        FileUtils.mv(File.join(from, f), dest)
      end
      FileUtils.rmdir(from) if Dir.empty?(from)
    else
      FileUtils.mkdir_p(File.dirname(to))
      FileUtils.mv(from, to)
    end
  end

  # source id -> path of the post that owns it, across every year. Built
  # once per process (an import re-reading the archive for each of its
  # thousands of items would be quadratic), kept current by write. Only
  # sources with an original_id participate: manual posts all share
  # {platform: manual} and nothing else, and matching them to each other
  # would overwrite one author-written post with another.
  def self.index
    @index ||= Dir.glob(File.join(CONTENT_DIR, '*', '*.json')).each_with_object({}) do |file, acc|
      existing = JSON.parse(File.read(file, encoding: 'utf-8')) rescue nil
      key = existing && source_key(existing['source'])
      acc[key] = file if key
    end
  end

  # An identity is only an identity when ALL THREE parts exist. Without the
  # account requirement, two different feeds that happen to share bare item
  # ids -- and whose channel carries no readable link, so account came out
  # nil -- collapsed onto the same key and silently overwrote each other,
  # across different slugs. An item without a full identity simply doesn't
  # participate in matching: a re-import may then duplicate it, which is
  # recoverable, where a wrong match destroys a post, which is not.
  def self.source_key(source)
    return nil unless source.is_a?(Hash)

    id = source['original_id']
    account = source['account']
    return nil if id.nil? || id.to_s.empty?
    return nil if account.nil? || account.to_s.empty?

    [source['platform'], account.to_s, id.to_s]
  end

  def self.find_by_source(source)
    key = source_key(source)
    return nil unless key

    path = index[key]
    path if path && File.exist?(path)
  end

  def self.unique_slug(base_slug, dir, source)
    n = 1
    loop do
      candidate = n == 1 ? base_slug : "#{base_slug}-#{n}"
      existing_path = File.join(dir, "#{candidate}.json")
      return candidate unless File.exist?(existing_path)
      return candidate if same_source?(existing_path, source)

      n += 1
    end
  end

  # The by-slug fallback behind the index. Requires an original_id for the
  # same reason the index does: two manual posts agree on platform, account
  # and (absent) id, so without the requirement a manual post whose slug
  # collided would silently overwrite the other one.
  def self.same_source?(existing_path, source)
    return false unless source_key(source)

    existing = JSON.parse(File.read(existing_path, encoding: 'utf-8')) rescue nil
    source_key(existing && existing['source']) == source_key(source)
  end
end
