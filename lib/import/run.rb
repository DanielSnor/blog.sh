# frozen_string_literal: true

require 'tmpdir'
require_relative '../post_writer'
require_relative 'media'

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
    Result = Struct.new(:written, :scanned, :skipped, :media, :media_failures, :samples, :interrupted,
                        keyword_init: true)

    def initialize(adapter, dry_run: false, limit: nil, on_post: nil, on_scan: nil)
      @adapter = adapter
      @dry_run = dry_run
      @limit = limit
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

    def call
      written = 0
      scanned = 0
      skipped = Hash.new(0)
      media_count = 0
      media_failures = []
      samples = []

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
          begin
            Dir.mktmpdir do |tmpdir|
              media = Media.new(tmpdir, dry_run: @dry_run)
              post = @adapter.map(item, media)

              if post.is_a?(Symbol)
                skipped[post] += 1
                # Harvested BEFORE the early return: a photo-only post whose
                # file is missing from the export maps to :empty, and its
                # missing file used to be forgotten with it -- so the run
                # said "1 skipped (no usable content)" and never named the
                # file the archive was actually missing.
                media_failures.concat(media.failures)
                next
              end

              tag_with_platform(post)
              media_count += media.count
              media_failures.concat(media.failures)

              PostWriter.write(post, media_files: media.files) unless @dry_run
              written += 1
              samples << post['slug'] if samples.size < 5
              @on_post&.call(written, post, scanned)
            end
          rescue StandardError => e
            skipped[:error] += 1
            warn "  item #{scanned} failed: #{e.class}: #{e.message}"
          end
        end
      rescue StandardError => e
        interrupted = "#{e.class}: #{e.message.lines.first.to_s.strip[0, 160]}"
      end

      Result.new(written: written, scanned: scanned, skipped: skipped, media: media_count,
                 media_failures: media_failures, samples: samples, interrupted: interrupted)
    end

    private

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
      platform = if @adapter.respond_to?(:platform_tag) && @adapter.platform_tag
                   @adapter.platform_tag.to_s
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
