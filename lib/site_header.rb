# frozen_string_literal: true

require_relative 'site_config'
require_relative 'tui'
require_relative 'version'

# lib/site_header.rb -- the "which site am I connected to" banner both
# wizards (./blog.sh and ./import.sh) print at startup and after every
# screen clear. Shared rather than duplicated: someone running several
# blog.sh installs should see the same identity block whichever tool
# they're in, and it should never drift between the two.
#
# An accent bar rather than a boxed panel so it never needs a bordered
# panel's width-matching discipline (see the design discussion this came
# out of): each line stands alone, so a long site name or claim just makes
# that one line longer instead of risking mismatched corners on a narrow
# terminal. Site fields are all optional -- on a barely-started install
# they can be blank, and absent ones are skipped rather than rendered as
# an empty line.
module SiteHeader
  module_function

  # The tool name is written the way it is typed -- "./blog.sh", not
  # "blog.sh" -- and carries the version, because the wizard's first screen
  # is where someone about to report a problem is already looking.
  def render(tool: './blog.sh')
    bar = Tui.paint('▍', :cyan)
    short_name = SiteConfig.get('site', 'short_name')
    base_url = ENV['SITE_BASE_URL'] || SiteConfig.get('site', 'base_url')

    # The same precedence the site's banner overlay uses: banner.claim
    # when set (the key exists precisely because site.description must
    # stay plain text), site.description otherwise -- so the identity
    # block here reads like the identity block on the site. The claim may
    # carry <br> line breaks; on one terminal line they become a
    # separator, and any other markup is dropped.
    #
    # Built from the pieces between the breaks rather than by replacing the
    # breaks in place: a claim that is only markup ("<br>", or a stray tag)
    # left the separator behind with nothing on either side of it, and the
    # site header greeted the author with a lone middle dot.
    claim_text = SiteConfig.get('banner', 'claim') || SiteConfig.get('site', 'description')
    claim_text = claim_text.to_s
                           .split(%r{<br\s*/?>}i)
                           .map { |part| part.gsub(/<[^>]+>/, '').strip }
                           .reject(&:empty?)
                           .join(' · ')
    claim = [short_name, claim_text].compact.reject(&:empty?).join(' — ')

    # The full URL, protocol included, not a bare domain: terminals
    # linkify what they see, and a bare domain got mangled into a
    # punycode guess (https://xn--...) -- with the protocol present the
    # link is exactly the site's address.
    url = base_url.to_s.chomp('/')

    lines = ["#{Tui.paint(tool, :bold)} #{Tui.paint(BlogSh::VERSION, :dim)}"]
    lines << claim unless claim.empty?
    lines << Tui.paint(url, :dim) unless url.empty?
    lines.map { |line| "#{bar}#{line}" }.join("\n")
  rescue StandardError, SystemExit
    # ./setup.sh and ./style.sh print this banner too, and they run on
    # configs too broken for SiteConfig to load -- which is exactly when
    # somebody reaches for a wizard. The identity lines are a courtesy;
    # the tool line alone is still true.
    "#{Tui.paint('▍', :cyan)}#{Tui.paint(tool, :bold)} #{Tui.paint(BlogSh::VERSION, :dim)}"
  end
end
