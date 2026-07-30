# frozen_string_literal: true

require 'socket'

# lib/preview_server.rb -- a minimal static file server for
# `./blog.sh preview`, so trying the built site locally needs nothing
# beyond Ruby itself. Pure stdlib (TCPServer), same principle as
# lib/qr_code.rb: the obvious one-liner (`ruby -run -e httpd`) actually
# depends on webrick, a default gem some distros don't install by
# default (e.g. Debian/Ubuntu's bare `ruby` package, as opposed to
# `ruby-full`) -- which would otherwise make the one command in every
# "try it locally" instruction not just work everywhere.
#
# Deliberately minimal for a local dev preview, not a production server:
# GET/HEAD only, no keep-alive (one request per connection), no range
# requests, no directory listing, thread-per-connection concurrency.
module PreviewServer
  MIME_TYPES = {
    '.html' => 'text/html; charset=utf-8', '.css' => 'text/css; charset=utf-8',
    '.js' => 'text/javascript; charset=utf-8', '.json' => 'application/json; charset=utf-8',
    '.xml' => 'application/xml; charset=utf-8', '.txt' => 'text/plain; charset=utf-8',
    '.svg' => 'image/svg+xml', '.png' => 'image/png', '.jpg' => 'image/jpeg',
    '.jpeg' => 'image/jpeg', '.gif' => 'image/gif', '.webp' => 'image/webp',
    '.ico' => 'image/x-icon', '.woff' => 'font/woff', '.woff2' => 'font/woff2',
    '.mp4' => 'video/mp4', '.mov' => 'video/quicktime', '.webmanifest' => 'application/manifest+json'
  }.freeze
  DEFAULT_TYPE = 'application/octet-stream'

  module_function

  # Blocks until interrupted (Ctrl-C). Doesn't print its own startup
  # banner -- callers already know root/port and typically want that
  # message localized (see manage_post.rb's `preview` command), so this
  # only logs things it alone knows about: per-request errors, and a
  # blank line on shutdown.
  def serve(root, port, logger: method(:puts))
    root = File.expand_path(root)
    server = TCPServer.new(port)

    loop do
      client = server.accept
      Thread.new(client) { |c| handle(c, root, logger) }
    end
  rescue Interrupt
    logger.call('')
  ensure
    server&.close
  end

  def handle(client, root, logger)
    request_line = client.gets
    return unless request_line

    verb, raw_path, = request_line.split(' ')
    drain_headers(client)

    unless %w[GET HEAD].include?(verb)
      return respond(client, 405, 'Method Not Allowed', 'text/plain', 'Only GET/HEAD are supported')
    end

    path = resolve_path(root, raw_path)
    if path.nil?
      respond(client, 403, 'Forbidden', 'text/plain', 'Forbidden')
    elsif !File.file?(path)
      respond(client, 404, 'Not Found', 'text/plain', '404 Not Found')
    else
      mime = MIME_TYPES[File.extname(path).downcase] || DEFAULT_TYPE
      body = verb == 'GET' ? File.binread(path) : nil
      respond(client, 200, 'OK', mime, body, size: File.size(path))
    end
  rescue Errno::EPIPE, IOError
    nil # the browser closed the connection early -- nothing to do
  rescue StandardError => e
    logger.call("  error: #{e.class}: #{e.message}")
  ensure
    client.close
  end

  # Headers aren't needed for a static GET, but they must be read off the
  # socket (up to the blank line that ends them) so a client sending a
  # request body or pipelining a second request doesn't hang waiting on us.
  def drain_headers(client)
    until (line = client.gets).nil? || line == "\r\n" || line == "\n"
      # discard
    end
  end

  # URL path -> filesystem path, defaulting to index.html for a directory
  # (including the site root itself). Returns nil for anything that would
  # resolve outside `root` -- the one security property a static file
  # server actually needs.
  def resolve_path(root, raw_path)
    return nil if raw_path.nil?

    clean = percent_decode(raw_path.split('?').first.to_s)
    full = File.expand_path(File.join(root, clean))
    return nil unless full == root || full.start_with?("#{root}/")

    File.directory?(full) ? File.join(full, 'index.html') : full
  end

  def percent_decode(str)
    str.gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }.force_encoding('UTF-8')
  end

  # no-store, because this server exists to look at a build that changes
  # under the browser's feet: its whole audience is someone editing. A
  # cached search-index.json or stylesheet quietly showing the previous
  # build is indistinguishable from "my change didn't work" -- the most
  # confusing failure a preview can produce.
  def respond(client, code, reason, content_type, body, size: nil)
    size ||= body&.bytesize || 0
    client.write "HTTP/1.1 #{code} #{reason}\r\n" \
                 "Content-Type: #{content_type}\r\n" \
                 "Content-Length: #{size}\r\n" \
                 "Cache-Control: no-store\r\n" \
                 "Connection: close\r\n\r\n"
    client.write(body) if body
  end
end
