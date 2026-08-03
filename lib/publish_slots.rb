# frozen_string_literal: true

require 'time'
require_relative 'site_config'

# lib/publish_slots.rb -- the site's usual publishing times, and the queue
# that falls out of them.
#
#   publishing:
#     slots: ["mon 09:30", "wed 09:30", "fri 09:30"]   # or ["daily 09:00"]
#
# Without the key the engine behaves exactly as before: this only ever
# suggests a time, it never moves a post that already has one. Two posts
# written the same evening go out on consecutive slots rather than
# together, which is the whole point -- the second one asks for the next
# FREE slot, not the next slot.
module PublishSlots
  DAYS = %w[sun mon tue wed thu fri sat].freeze
  # A year of lookahead: enough that even a single weekly slot with a long
  # queue resolves, and short enough that a config naming a day that never
  # comes (impossible today, but a typo away) fails as nil rather than
  # looping forever.
  HORIZON_DAYS = 370

  module_function

  def configured?
    !slots.empty?
  end

  # [[weekday_index or nil for daily, hour, minute], ...]
  def slots
    @slots ||= Array(SiteConfig.get('publishing', 'slots')).filter_map { |spec| parse(spec) }
  end

  def parse(spec)
    match = /\A\s*(\w+)\s+(\d{1,2}):(\d{2})\s*\z/.match(spec.to_s)
    return nil unless match

    day = match[1].downcase
    hour = match[2].to_i
    minute = match[3].to_i
    return nil unless hour.between?(0, 23) && minute.between?(0, 59)
    return [nil, hour, minute] if day == 'daily'

    index = DAYS.index(day[0, 3])
    index ? [index, hour, minute] : nil
  end

  # The first slot strictly after `from` that no scheduled post already
  # occupies. `taken` holds the times of posts waiting to publish -- an
  # exact match is what counts as occupied, so a post hand-scheduled for
  # 14:17 blocks nothing, and a second post deliberately aimed at an
  # occupied slot is still possible by typing the date.
  def next_free(taken: [], from: Time.now)
    return nil unless configured?

    occupied = taken.compact.map { |time| time.to_i / 60 }.to_set
    day = Time.new(from.year, from.month, from.day, 0, 0, 0, from.utc_offset)

    HORIZON_DAYS.times do
      times_on(day).sort.each do |candidate|
        next if candidate <= from
        next if occupied.include?(candidate.to_i / 60)

        return candidate
      end
      day += 24 * 60 * 60
      # Re-anchor to midnight: adding a day of seconds drifts by an hour
      # across a DST boundary, which would silently move every slot after
      # the change.
      day = Time.new(day.year, day.month, day.day, 0, 0, 0, day.utc_offset)
    end
    nil
  end

  def times_on(day)
    slots.filter_map do |weekday, hour, minute|
      next if weekday && weekday != day.wday

      Time.new(day.year, day.month, day.day, hour, minute, 0, day.utc_offset)
    end
  end
end
