# frozen_string_literal: true

require_relative 'run'
require_relative '../i18n'
require_relative 'pages_note'

# Operator tools speak English on purpose: a migrate script is reached by
# typing a path, not the authoring UI, and its output lands in cron logs.
# The pin is load-bearing twice over -- adapter postscripts render through
# I18n so the wizard can translate them, and forcing the language here
# keeps that lookup off SiteConfig, so a script still runs where no
# site.yml answers.
I18n.force_lang('en')

# Same cron-log audience: piped, stdout is block-buffered and a per-item
# `warn` from the run would overtake the progress line it refers to.
$stdout.sync = true

module Import
  # The non-interactive front end: what `scripts/migrate_*.rb` need so each
  # one is a handful of lines rather than its own copy of progress reporting
  # and summary formatting. The wizard (scripts/import.rb) does its own
  # thing, since it also has a preview pass and prompts to run.
  module Cli
    # How many failed items the summary names before it stops. Enough to
    # see a pattern, few enough that a broken export does not bury the
    # counts above them.
    SHOWN_ERRORS = 5

    module_function

    # Reads LIMIT from the environment. Validated rather than .to_i'd,
    # because a typo would otherwise become 0 and the import would "succeed"
    # having written nothing at all -- the failure most easily mistaken for
    # success.
    def limit_from_env(env = ENV)
      case env['LIMIT']
      when nil, '' then nil
      when /\A[1-9]\d*\z/ then env['LIMIT'].to_i
      else abort("LIMIT must be a positive integer (got #{env['LIMIT'].inspect})")
      end
    end

    # Reads KEEP_PERMALINKS from the environment, validated for the same
    # reason as LIMIT: a typo like KEEP_PERMALINKS=yes silently meaning
    # "no" would cost the one thing the flag exists to preserve.
    def keep_permalinks_from_env(env = ENV)
      case env['KEEP_PERMALINKS']
      when nil, '', '0' then false
      when '1' then true
      else abort("KEEP_PERMALINKS must be 1 or 0 (got #{env['KEEP_PERMALINKS'].inspect})")
      end
    end

    def run(adapter, limit: nil)
      puts adapter.preamble if adapter.respond_to?(:preamble) && adapter.preamble
      puts "Importing #{adapter.label}#{limit ? " (first #{limit} as a trial run)" : ''}…"

      announced_total = false
      on_post = lambda do |written, post, scanned|
        # The source's size is often only known once the first page comes
        # back, so it's announced at the first post rather than up front:
        # without it, "12" doesn't say whether this finishes in a second or
        # an hour.
        total = adapter.respond_to?(:total) ? adapter.total : nil
        if total && !announced_total
          announced_total = true
          puts "#{total} item(s) in the source."
        end

        puts "  #{position(written, scanned, total, limit)} #{post['slug']} (#{media_note(post)})"
      end

      result = Run.new(adapter, limit: limit, on_post: on_post).call
      report(result)
      # One line, once -- e.g. "N post(s) had no usable original address":
      # per-post warnings would repeat the same fact hundreds of times on
      # exactly the archives (plain-permalink WordPress) it describes.
      puts "  #{adapter.postscript}" if adapter.respond_to?(:postscript) && adapter.postscript
      # A cron or a script must see a partial run as a failure, or nobody
      # ever finds out the source died -- the summary above already said
      # everything a human needs.
      # An item that failed is a loss the exit code has to carry: a cron
      # or a CI step that only looks at the status saw a clean 0 while a
      # page was quietly missing from the archive.
      exit 1 if result.interrupted || Array(result.respond_to?(:errors) ? result.errors : nil).any?
      result
    end

    # Whichever fraction actually tells you how far along this run is. With
    # a limit the goal is a number of written posts, so count against that;
    # otherwise progress is a position in the source, since a source that
    # skips replies and reposts will never write as many posts as it holds
    # (and "3/453" that stops at 3 would read as a stalled import).
    def position(written, scanned, total, limit)
      return "#{written}/#{limit}" if limit
      return "#{scanned}/#{total}" if total

      written.to_s
    end

    def media_note(post)
      count = post['content'].count { |b| %w[image video].include?(b['type']) }
      "#{count} media block(s)"
    end

    def report(result)
      puts
      if result.interrupted
        puts "⚠️  The source stopped answering after #{result.scanned} item(s): #{result.interrupted}"
        puts "   #{result.written} post(s) written so far are saved. Re-running is safe -- posts are matched on their source id, never duplicated."
      else
        puts "Done. #{result.written} post(s) written, #{result.media} media file(s)."
      end
      # Or the same sentence describes a run that downloaded 420 files and
      # one that downloaded none -- which is what a re-import over an
      # archive that is already here now costs.
      puts "  #{I18n.t('import.media_reused', count: result.media_reused)}" if result.media_reused.to_i.positive?
      # The one signal that the source has drifted away from this archive:
      # bytes were fetched, they no longer match the copy under the
      # entry's name, and the copy won -- by the no-replace rule. Silent,
      # this looked exactly like a re-import that did nothing.
      if result.respond_to?(:media_superseded) && result.media_superseded.to_i.positive?
        puts "  #{I18n.t('import.media_superseded', count: result.media_superseded)}"
      end
      result.skipped.sort_by { |reason, _| reason.to_s }.each do |reason, count|
        puts "  #{count} skipped (#{reason})"
      end
      # An error is not a category of skip like "reply" or "boost": those
      # are decisions, this is something that went wrong, and the count
      # alone leaves the reader to guess which of five thousand items it
      # was. Named here, with the reason, the way media failures are.
      errors = result.respond_to?(:errors) ? Array(result.errors) : []
      errors.first(SHOWN_ERRORS).each { |line| puts "    #{line}" }
      puts "    ... #{errors.size - SHOWN_ERRORS} more" if errors.size > SHOWN_ERRORS
      # Built from what the run WROTE, not from what the source contained.
      pages_note = Import.pages_note(Array(result.respond_to?(:pages) ? result.pages : nil))
      puts "  #{pages_note}" if pages_note
      # One line for all eleven adapters that parse HTML bodies: what the
      # block schema could not hold. It used to be counted by exactly one
      # of them (feed.rb) and thrown away by the rest, while the header of
      # migrate_feed.rb promised the counting on everyone's behalf.
      dropped = result.respond_to?(:dropped_elements) ? result.dropped_elements : nil
      if dropped && !dropped.empty?
        listed = dropped.sort_by { |name, count| [-count, name] }
                        .map { |name, count| "#{name} (#{count})" }.join(', ')
        puts "  #{I18n.t('import.note.feed_dropped', listed: listed)}"
      end
      # A source that handed out the same id twice. Said out loud, because
      # the alternative is a duplicate post the operator never hears about
      # -- and because the number that used to be printed was worse than
      # silence: the second item overwrote the first and the run counted
      # two written.
      dupes = result.respond_to?(:duplicate_ids) ? Array(result.duplicate_ids) : []
      puts "  #{I18n.t('import.note.duplicate_ids', count: dupes.size)}" unless dupes.empty?

      return if result.media_failures.empty?

      # Split, because these are two different losses: a written post
      # missing one of its files, and a post never written at all (a
      # photo-only post whose file is gone skips as :empty). One line for
      # both claimed every such post was "written without them" -- media
      # lost from posts that never landed on disk.
      from_written = result.media_failures.size - result.skipped_media_failures.size
      puts "  #{from_written} media file(s) could not be downloaded; their posts were written without them." if from_written.positive?
      unless result.skipped_media_failures.empty?
        puts "  #{result.skipped_media_failures.size} media file(s) could not be downloaded from post(s) that were skipped."
      end
    end
  end
end
