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
    Result = Struct.new(:written, :skipped, :media, :media_failures, :samples, keyword_init: true)

    def initialize(adapter, dry_run: false, limit: nil, on_post: nil, on_scan: nil)
      @adapter = adapter
      @dry_run = dry_run
      @limit = limit
      # Called with (index, post) after each written post, so a wizard can
      # show progress on a run that takes an hour without this class
      # knowing anything about terminals.
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

      @adapter.each_item do |item|
        break if @limit && written >= @limit

        scanned += 1
        @on_scan&.call(scanned, written)

        Dir.mktmpdir do |tmpdir|
          media = Media.new(tmpdir, dry_run: @dry_run)
          post = @adapter.map(item, media)

          if post.is_a?(Symbol)
            skipped[post] += 1
            next
          end

          media_count += media.count
          media_failures.concat(media.failures)

          PostWriter.write(post, media_files: media.files) unless @dry_run
          written += 1
          samples << post['slug'] if samples.size < 5
          @on_post&.call(written, post)
        end
      end

      Result.new(written: written, skipped: skipped, media: media_count,
                 media_failures: media_failures, samples: samples)
    end
  end
end
