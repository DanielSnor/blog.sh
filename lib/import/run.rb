# frozen_string_literal: true

require 'set'
require 'tmpdir'
require_relative '../post_writer'
require_relative 'media'
require_relative 'media_index'
require_relative 'html_blocks'
require_relative '../post_address'
require_relative 'pages_note'

module Import
  # The half of an import that has nothing to do with the platform: walk
  # the source, hand each item to the adapter, write what comes back,
  # count what didn't, and report. Adapters are left with only the part
  # that genuinely differs -- how to page through a source and how to
  # shape one item.
  #
  # An adapter must respond to:
  #   label      -> String for the summary ("Bluesky (@handle)")
  #   each_item  -> yields raw items, handling the source's own paging
  #   map(item, media) -> a post hash, or a Symbol naming why it was
  #                       skipped (:reply, :repost, :empty, ...)
  #
  # Skips are Symbols rather than nil so the summary can say *why* an
  # import wrote fewer posts than the source has -- the question anyone
  # looks at a summary to answer.
  class Run
    # `interrupted` is nil on a complete run, and the error's message when
    # the SOURCE died mid-paging -- a 5xx from an API on page 12, a feed
    # that stopped answering. `scanned` says how far it got. Everything
    # written up to that point is real and on disk, which is exactly what
    # the report has to say: the old behaviour was a raw backtrace and no
    # summary at all, so a three-hour run that died at item 900 of 2000
    # told the operator nothing about what it had done.
    #
    # `skipped_media_failures` is the subset of `media_failures` harvested
    # from posts that were skipped. Kept apart because a reporter that says
    # a failure cost a WRITTEN post its file has to be able to leave these
    # out -- lumped together, the summary claimed media were lost from
    # posts that were never written at all.
    #
    # `media_reused` is the subset of `media` that was already in the
    # archive and cost no download. Reported rather than merely enjoyed:
    # the old summary said "420 media file(s)" for a run that fetched all
    # 420 and for one that fetched none, which is the same sentence for two
    # very different afternoons.
    #
    # `media_superseded` counts the fetches this run threw away because
    # the archive already held DIFFERENT bytes under the entry's name --
    # a source that re-encodes its pictures and keeps the addresses. The
    # archive's copy wins by rule; the number is here so the summary can
    # say the source has drifted, which is the operator's only signal.
    Result = Struct.new(:written, :scanned, :skipped, :media, :media_reused,
                        :media_failures, :skipped_media_failures, :samples, :interrupted,
                        :dropped_elements, :media_superseded, :pages, :errors,
                        :duplicate_ids,
                        keyword_init: true)

    # `media_index` is what lets a re-import skip what it already has (see
    # MediaIndex). Built once, lazily, and shared by every item.
    #
    # `refetch` (REFETCH_MEDIA=1) makes the run download even what the
    # index already has. The index stays in place regardless: it is what
    # the run falls back on when the source no longer answers.
    def initialize(adapter, dry_run: false, limit: nil, on_post: nil, on_scan: nil,
                   media_index: MediaIndex.shared, refetch: MediaIndex.refetch?)
      @adapter = adapter
      @dry_run = dry_run
      @limit = limit
      @media_index = media_index
      @refetch = refetch
      # Called with (written, post, scanned) after each written post, so a
      # wizard can show progress on a run that takes an hour without this
      # class knowing anything about terminals. Both counters are passed
      # because neither alone is the useful fraction: against a limit the
      # goal is `written`, against a whole source it's `scanned` -- a source
      # that skips items never writes as many posts as it has.
      @on_post = on_post
      # Called with (scanned, written) for every item seen, written or not.
      # The reading pass is the part with nothing to show otherwise: paging
      # through thousands of items over an API takes minutes during which a
      # silent terminal is indistinguishable from a hung one.
      @on_scan = on_scan
    end

    # The wizard runs an adapter TWICE -- a preview, then the real thing --
    # and an adapter counts as it goes: snapshots read, items it could not
    # parse, pictures the Archive never saved. Without putting the counters
    # back between the two, the note printed after the real run reports
    # both runs added together, so "N image(s) are lost" says twice what
    # was lost. Only whole numbers are taken: those are the counters, and
    # everything else an adapter holds -- its paths, its parsed export, its
    # answers to the wizard's questions -- has to survive untouched.
    def self.counter_snapshot(adapter)
      adapter.instance_variables
             .select { |name| adapter.instance_variable_get(name).is_a?(Integer) }
             .to_h { |name| [name, adapter.instance_variable_get(name)] }
    end

    def self.restore_counters(adapter, snapshot)
      snapshot.each { |name, value| adapter.instance_variable_set(name, value) }
      adapter
    end

    def call
      # A fresh ledger per run, or a second import in one process would
      # report the first one's losses again.
      HtmlBlocks.reset_dropped!
      # PostWriter counts per process; the run owns only its own delta --
      # same reason as the ledger above, without a reset that would zero
      # another run's tally mid-flight.
      superseded_before = PostWriter.superseded_downloads
      written = 0
      scanned = 0
      skipped = Hash.new(0)
      media_count = 0
      media_reused = 0
      media_failures = []
      skipped_media_failures = []
      samples = []
      # Identities this run has already written, so a source that hands
      # out the same id twice cannot make the second item overwrite the
      # first -- see the note by the check below.
      @seen_ids = Set.new
      duplicate_ids = []
      pages = []
      errors = []

      interrupted = nil

      # The rescue around the whole iteration is for the PAGING, not the
      # items: each item's own failures are caught inside the block below,
      # so what reaches here is the source itself dying between pages.
      # Recording it instead of crashing means the summary still runs and
      # the counts are honest -- and thanks to the source-id matching in
      # PostWriter, re-running after the source recovers picks up where
      # this run got to without duplicating anything it wrote.
      # An abort() (a rejected API key) is SystemExit, not StandardError,
      # and still stops everything, as it should.
      begin
        @adapter.each_item do |item|
          break if @limit && written >= @limit

          scanned += 1
          @on_scan&.call(scanned, written)

          # One malformed item -- a date that won't parse, markup nothing
          # anticipated -- must cost that item, not the run: dying on item
          # 2000 of 6000 leaves a third of an archive imported and no report
          # of what happened. Counted under :error and named on stderr, so
          # the summary shows the loss instead of pretending completeness.
          failed_slug = nil
          begin
            Dir.mktmpdir do |tmpdir|
              # The export's root, so a path it names cannot walk out of it.
              # Adapters that copy local files answer import_root; the rest do
              # not touch the filesystem and have nothing to confine.
              root = @adapter.respond_to?(:import_root) ? @adapter.import_root : nil
              media = Media.new(tmpdir, dry_run: @dry_run, index: @media_index,
                                refetch: @refetch, root: root)
              post = @adapter.map(item, media)
              failed_slug = post['slug'] if post.is_a?(Hash)

              if post.is_a?(Symbol)
                skipped[post] += 1
                # Harvested BEFORE the early return: a photo-only post whose
                # file is missing from the export maps to :empty, and its
                # missing file used to be forgotten with it -- so the run
                # said "1 skipped (no usable content)" and never named the
                # file the archive was actually missing. Recorded in the
                # skipped ledger too, so the summary can attribute these
                # losses to posts that were never written -- otherwise it
                # claims a skipped post was "written without" its file.
                media_failures.concat(media.failures)
                skipped_media_failures.concat(media.failures)
                next
              end

              tag_with_platform(post)
              record_media_sources(post, media)
              media_count += media.count
              media_reused += media.reused
              media_failures.concat(media.failures)

              # Two items in ONE run that claim the same identity are not
              # a re-import, they are a source with a duplicate id -- two
              # feed entries sharing a <guid>, which plenty of generators
              # emit. Matched on it, the second overwrote the first IN
              # PLACE and the summary still counted two written: one post
              # destroyed, and a number that says nothing went wrong.
              #
              # The second one loses its identity instead. A duplicate is
              # recoverable -- somebody deletes it -- where a wrong match
              # destroys a post that cannot be got back, which is the rule
              # PostWriter.source_key already states for the same reason.
              key = PostWriter.source_key(post['source'])
              if key && !@seen_ids.add?(key)
                duplicate_ids << key
                post = post.merge('source' => post['source'].reject { |k, _| k == 'original_id' })
              end

              written_slug = post['slug']
              unless @dry_run
                path = PostWriter.write(post, media_files: media.files)
                remember_media(post, path)
                # unique_slug may have handed the post another name on the
                # way in, and the sentence about pages has to say the
                # address the reader will actually find -- not the one the
                # source asked for.
                written_slug = File.basename(path, '.json')
              end
              written += 1
              # The addresses of pages that actually landed. The sentence
              # about them used to be built where the source was PARSED, so
              # a page the write refused was still announced as "came across
              # and is at /about/" -- pointing at somebody else's page.
              # A page whose slug is one the engine owns (/tag/, /search/,
              # /posts/) is NOT announced as "came across and is at" -- the
              # site answers that address itself, and feed.rb names such
              # pages separately as needing a rename. Saying both would be
              # sending the reader somewhere the page is not.
              if PostAddress.page?(post) && post['state'] != 'draft' &&
                 !Import::RESERVED_PAGE_SLUGS.include?(written_slug.to_s.downcase)
                pages << PostAddress.path(post.merge('slug' => written_slug))
              end
              # The address the post LANDED at, not the one the source
              # asked for. unique_slug may have handed it another name on
              # the way in -- the pages sentence above learned that when it
              # was written -- and a run that reports the source's slug
              # sends the reader looking for a page that is not there.
              samples << written_slug if samples.size < 5
              @on_post&.call(written, post.merge('slug' => written_slug), scanned)
            end
          rescue StandardError => e
            skipped[:error] += 1
            # Kept, not just counted. "1 skipped (error)" in a run that
            # scrolled past a hundred lines of progress tells nobody which
            # item was lost or why, and the reason is usually the one thing
            # that can be acted on.
            errors << "#{failed_slug || "item #{scanned}"}: #{e.message.lines.first.to_s.strip[0, 160]}"
            warn "  item #{scanned} failed: #{e.class}: #{e.message}"
          end
        end
      rescue StandardError => e
        interrupted = "#{e.class}: #{e.message.lines.first.to_s.strip[0, 160]}"
      end

      Result.new(written: written, scanned: scanned, skipped: skipped, media: media_count,
                 pages: pages, errors: errors,
                 media_reused: media_reused, media_failures: media_failures,
                 skipped_media_failures: skipped_media_failures,
                 samples: samples, interrupted: interrupted,
                 dropped_elements: HtmlBlocks.dropped.dup,
                 duplicate_ids: duplicate_ids,
                 media_superseded: PostWriter.superseded_downloads - superseded_before)
    end

    private

    # Writes each media entry's original address into the post as `src`,
    # beside the local filename.
    #
    # Here rather than in the adapters: twenty-two of them build media
    # entries, in about thirty places, and a key that must be present for
    # the archive to recognise its own files cannot depend on all of them
    # remembering. Media already knows the mapping -- it allocated the name
    # from the address -- so this is the one place both halves are in hand.
    #
    # Never overwrites: an entry that already carries a src has one that
    # travelled further than this run (a block coming home from an export
    # brings the address the file was fetched from years ago), and that is
    # the address worth keeping.
    def record_media_sources(post, media)
      MediaIndex.each_media_entry(post) do |entry|
        next unless entry['src'].to_s.empty?

        src = media.source_of(entry['url'].to_s)
        entry['src'] = src if src
      end
    end

    # Adds what this post just wrote to the index, so the SAME address used
    # by a later post in the same run is not fetched a second time. Old
    # blogs reuse one picture across dozens of posts, and without this the
    # index was a snapshot taken before the run began -- it could only ever
    # answer for what a PREVIOUS run had put there.
    #
    # Read back off the post rather than out of Media, so what goes in is
    # exactly what the next run's own pass would find there.
    def remember_media(post, path)
      return unless @media_index

      dir = PostWriter.media_dir_for(path)
      MediaIndex.each_media_entry(post) do |entry|
        src = entry['src'].to_s
        name = entry['url'].to_s
        next if src.empty? || !MediaIndex.plain_name?(name)

        @media_index.remember(src, File.join(dir, name), entry['width'], entry['height'])
      end
    end

    # Every imported post carries a tag naming where it came from, so an
    # archive assembled from several platforms stays sortable by origin --
    # `/tag/tumblr/` is the whole of one old blog. Applied here rather than
    # in each adapter, which makes it a property of importing rather than
    # four copies of the same line and a fifth one forgotten.
    #
    # Case-insensitive dedup, because a source's own tags may already
    # include the platform's name and "Tumblr" plus "tumblr" would render
    # as two pills pointing at one page.
    def tag_with_platform(post)
      # An adapter may name the tag itself when its platform makes a poor
      # one: "feed" says nothing about where a post came from, where
      # "medium.com" says all of it. source.platform stays what it is --
      # the kind of source, and half the re-import dedup key.
      platform = if @adapter.respond_to?(:platform_tag)
                   tag = @adapter.platform_tag
                   # An adapter that HAS the method and still answers nil
                   # is saying this post wants no platform tag at all --
                   # not "fall back to source.platform". A tree written by
                   # `./blog.sh export` carries its own source, so
                   # importing it back would otherwise pin every post with
                   # a pill for the platform it left years ago.
                   return if tag.nil?

                   tag.to_s
                 else
                   post.dig('source', 'platform').to_s
                 end
      return if platform.empty?

      tags = post['tags'] ||= []
      return if tags.any? { |tag| tag.to_s.casecmp?(platform) }

      tags << platform
    end
  end
end
