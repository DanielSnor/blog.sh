# frozen_string_literal: true

require_relative '../i18n'

module Import
  # Two sentences a run owes the person afterwards, in one place because
  # there are two doors into this tool and they must not answer
  # differently: scripts/*.rb through Import::Cli, and ./import.sh through
  # the wizard, which is the one this tool's own header calls the way in.
  #
  # The wizard used to print neither. Someone importing a blog full of
  # embedded video was told "Wrote N post(s)" and nothing else, while the
  # paragraph that said "look at this video:" is now followed by nothing --
  # the tally existed, was translated into all three languages, and had
  # exactly one caller. Same shape as pages_note, and for the same reason.

  # What the block schema could not hold: iframe (3), form (1). Counted by
  # HtmlBlocks on behalf of every adapter that parses HTML, and by Tumblr
  # for an NPF block type nothing here has a shape for.
  def self.dropped_note(dropped)
    return nil if dropped.nil? || dropped.empty?

    listed = dropped.sort_by { |name, count| [-count, name] }
                    .map { |name, count| "#{name} (#{count})" }.join(', ')
    I18n.t('import.note.feed_dropped', listed: listed)
  end

  # A source that handed out the same id twice -- two feed entries sharing
  # a <guid>, which plenty of generators emit. The second item keeps its
  # post and loses the identity, so it cannot overwrite the first.
  def self.duplicate_ids_note(ids)
    return nil if ids.nil? || ids.empty?

    I18n.t('import.note.duplicate_ids', count: ids.size)
  end
end
