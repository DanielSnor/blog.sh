# frozen_string_literal: true

require 'uri'

module Import
  # The one question every importer answers the same way: what site-root
  # path did this post live at on its old platform? Fed by the source's
  # own URL for the post, consumed as a redirect_from entry -- but only
  # when the answer is a real path. A bare host ("https://example.com/"),
  # an unparseable URL, or WordPress's plain permalinks ("/?p=123", where
  # the identity is in the query string a static stub can never see) all
  # answer nil, and the importer counts them rather than writing a
  # redirect that could only ever point at the homepage.
  module Permalinks
    module_function

    # The same parser the rest of the import uses on a URL that was never
    # escaped -- see Media.parse_url and Feed#host_of, which both retry
    # this way and say so.
    ESCAPER = defined?(URI::RFC2396_PARSER) ? URI::RFC2396_PARSER : URI::DEFAULT_PARSER

    def local_path(url)
      return nil if url.to_s.strip.empty?

      uri = begin
        URI.parse(url)
      rescue URI::InvalidURIError
        # Raw non-ASCII raises: a UTF-8 permalink written unescaped, or an
        # internationalised host such as dodlaně.cz. Swallowed, it lost
        # the redirect for a post whose address was perfectly readable --
        # and the run then filed it under the "/?p=123" message, which
        # names a defect that is not there. Escape and retry, the way the
        # two siblings fifteen lines away already do.
        begin
          URI.parse(ESCAPER.escape(url.to_s))
        rescue StandardError
          return nil
        end
      end

      path = uri.path.to_s
      return nil if path.empty? || path == '/'
      return nil unless path.start_with?('/')

      path
    end
  end
end
