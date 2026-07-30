# frozen_string_literal: true

require_relative 'run'

module Import
  # The non-interactive front end: what `scripts/migrate_*.rb` need so each
  # one is a handful of lines rather than its own copy of progress reporting
  # and summary formatting. The wizard (scripts/import.rb) does its own
  # thing, since it also has a preview pass and prompts to run.
  #
  # Deliberately plain English and no I18n, matching the scripts it serves:
  # these are operator tools reached by typing a path, not the authoring UI.
  module Cli
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
      puts "Done. #{result.written} post(s) written, #{result.media} media file(s)."
      result.skipped.sort_by { |reason, _| reason.to_s }.each do |reason, count|
        puts "  #{count} skipped (#{reason})"
      end
      return if result.media_failures.empty?

      puts "  #{result.media_failures.size} media file(s) could not be downloaded; their posts were written without them."
    end
  end
end
