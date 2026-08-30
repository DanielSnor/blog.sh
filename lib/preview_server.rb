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
# GET/HEAD only, no keep-alive (one request per connection), no directory
# listing, thread-per-connection concurrency. Byte ranges are the one
# "real server" feature it does implement, because without them a preview
# cannot show what the site does: Safari refuses to play a media element
# served by something that answers a Range request with a plain 200, and
# seeking in a video or an audio post needs them everywhere else.
module PreviewServer
  # Every extension the engine can put into a post has to be here, or the
  # preview serves it as application/octet-stream -- which a browser
  # downloads instead of playing or displaying, so the local preview
  # disagrees with the deployed site about what the page even does. The
  # lists mirror MarkdownParser's VIDEO/AUDIO/FILE_EXTENSIONS; when one
  # of those grows, this grows with it.
  MIME_TYPES = {
    # Formats the importers bring home: an .avif from a modern export and
    # an .heic straight off a phone (kept under its own name when
    # media.convert_heic is off). Without a type the browser downloaded
    # the picture instead of showing it, in the one place whose whole job
    # is showing the site.
    '.avif' => 'image/avif',
    '.heic' => 'image/heic',
    '.html' => 'text/html; charset=utf-8', '.css' => 'text/css; charset=utf-8',
    '.js' => 'text/javascript; charset=utf-8', '.json' => 'application/json; charset=utf-8',
    '.xml' => 'application/xml; charset=utf-8', '.txt' => 'text/plain; charset=utf-8',
    '.svg' => 'image/svg+xml', '.png' => 'image/png', '.jpg' => 'image/jpeg',
    '.jpeg' => 'image/jpeg', '.jpe' => 'image/jpeg', '.jfif' => 'image/jpeg',
    '.gif' => 'image/gif', '.webp' => 'image/webp', '.bmp' => 'image/bmp',
    '.tif' => 'image/tiff', '.tiff' => 'image/tiff', '.svgz' => 'image/svg+xml',
    '.ico' => 'image/x-icon', '.woff' => 'font/woff', '.woff2' => 'font/woff2',
    '.mp4' => 'video/mp4', '.mov' => 'video/quicktime', '.m4v' => 'video/x-m4v',
    '.mp3' => 'audio/mpeg', '.m4a' => 'audio/mp4', '.ogg' => 'audio/ogg',
    '.opus' => 'audio/ogg', '.aac' => 'audio/aac', '.flac' => 'audio/flac',
    '.wav' => 'audio/wav',
    '.pdf' => 'application/pdf', '.zip' => 'application/zip',
    '.tgz' => 'application/gzip', '.epub' => 'application/epub+zip',
    '.md' => 'text/markdown; charset=utf-8', '.ics' => 'text/calendar; charset=utf-8',
    '.gpx' => 'application/gpx+xml', '.csv' => 'text/csv; charset=utf-8',
    '.webmanifest' => 'application/manifest+json'
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
    # Loopback only. TCPServer.new(port) binds every interface, so the
    # whole build -- which after an import is a personal archive that has
    # never been public -- was served to the LAN while the CLI printed
    # "http://localhost:<port>/". A default that cannot be walked back
    # once someone has shipped on it.
    server = TCPServer.new('127.0.0.1', port)

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
    headers = read_headers(client)
    head = verb == 'HEAD'

    unless %w[GET HEAD].include?(verb)
      return respond(client, 405, 'Method Not Allowed', 'text/plain', 'Only GET/HEAD are supported', head: head)
    end

    path = resolve_path(root, raw_path)
    if path.nil?
      respond(client, 403, 'Forbidden', 'text/plain', 'Forbidden', head: head)
    elsif !File.file?(path)
      # The build makes a 404 page; the preview is where its own site is
      # looked at, so it should be the one the reader would get.
      own = File.join(root, '404.html')
      if File.file?(own)
        respond(client, 404, 'Not Found', 'text/html; charset=utf-8', File.read(own, encoding: 'utf-8'), head: head)
      else
        respond(client, 404, 'Not Found', 'text/plain', '404 Not Found', head: head)
      end
    else
      send_file(client, path, verb, headers['range'])
    end
  rescue Errno::EPIPE, IOError
    nil # the browser closed the connection early -- nothing to do
  rescue StandardError => e
    logger.call("  error: #{e.class}: #{e.message}")
  ensure
    client.close
  end

  # The headers have to be read off the socket (up to the blank line that
  # ends them) so a client sending a request body or pipelining a second
  # request doesn't hang waiting on us. Only Range is acted on; the rest is
  # collected because a hash is no more work than a loop that discards.
  def read_headers(client)
    headers = {}
    until (line = client.gets).nil? || line == "\r\n" || line == "\n"
      name, value = line.split(':', 2)
      headers[name.to_s.strip.downcase] = value.to_s.strip if value
    end
    headers
  end

  # A single byte range, as far as this server goes: `bytes=100-200`,
  # `bytes=100-` (to the end) and `bytes=-500` (the last 500 bytes) cover
  # every player that matters. A multi-range request is answered with the
  # whole file, which is what the spec allows and what a preview should do
  # rather than grow a multipart encoder.
  #
  # Returns [first, last] inclusive, nil for "send the whole thing", or
  # :unsatisfiable when the range starts past the end of the file -- that
  # one is a 416, not a silent full body, or a player seeking past the end
  # would get a file it thinks is the part it asked for.
  def parse_range(header, size)
    return nil unless header.to_s =~ /\Abytes=(\d*)-(\d*)\z/

    first = Regexp.last_match(1)
    last = Regexp.last_match(2)
    return nil if first.empty? && last.empty?

    if first.empty?
      length = last.to_i
      return :unsatisfiable if length.zero? || size.zero?

      [[size - length, 0].max, size - 1]
    else
      from = first.to_i
      return :unsatisfiable if from >= size
      # "bytes=5-2" is not a range, it is a typo -- and answering it as one
      # produced a 206 with a negative Content-Length and the whole file
      # behind it. Treated as no range at all: send the file.
      return nil if !last.empty? && last.to_i < from

      [from, last.empty? ? size - 1 : [last.to_i, size - 1].min]
    end
  end

  # Streams rather than reading the file into memory: a preview of a post
  # with a video used to allocate the whole file per request, and a range
  # request only ever wants a slice of it anyway.
  def send_file(client, path, verb, range_header)
    mime = MIME_TYPES[File.extname(path).downcase] || DEFAULT_TYPE
    size = File.size(path)
    range = parse_range(range_header, size)

    if range == :unsatisfiable
      return respond(client, 416, 'Range Not Satisfiable', 'text/plain', 'Range Not Satisfiable',
                     extra: { 'Content-Range' => "bytes */#{size}" }, head: verb == 'HEAD')
    end

    if range
      first, last = range
      length = last - first + 1
      write_head(client, 206, 'Partial Content', mime, length,
                 'Content-Range' => "bytes #{first}-#{last}/#{size}", 'Accept-Ranges' => 'bytes')
      return if verb == 'HEAD'

      File.open(path, 'rb') do |f|
        f.seek(first)
        IO.copy_stream(f, client, length)
      end
    else
      write_head(client, 200, 'OK', mime, size, 'Accept-Ranges' => 'bytes')
      return if verb == 'HEAD'

      IO.copy_stream(path, client)
    end
  end

  # URL path -> filesystem path, defaulting to index.html for a directory
  # (including the site root itself). Returns nil for anything that would
  # resolve outside `root` -- the one security property a static file
  # server actually needs.
  def resolve_path(root, raw_path)
    return nil if raw_path.nil?

    clean = percent_decode(raw_path.split('?').first.to_s)
    # A NUL byte (%00) makes every File call raise "string contains null
    # byte", which escaped handle() before any response was written -- the
    # connection just dropped. It is never part of a real path; refuse it.
    return nil if clean.include?("\0")
    full = File.expand_path(File.join(root, clean))
    return nil unless full == root || full.start_with?("#{root}/")

    # ...and where it REALLY is, not just what its name says. A symlink
    # inside public.nosync pointing out of the tree passed the name test
    # and was then served -- the preview would hand out anything on the
    # machine the link happened to name.
    #
    # The TARGET is resolved when it exists -- resolving only its parent
    # left a symlinked FILE served from wherever it pointed, the exact
    # hole the block describes, one shape over. And a path that simply is
    # not there is judged by its nearest existing ancestor rather than
    # refused: nothing about a missing page is forbidden -- the 404 branch
    # is the answer to it, and this used to turn every miss two levels
    # deep into a bare 403.
    # The index.html is appended BEFORE the check, not after it. Appended
    # after, the file actually served was the one file never examined:
    # public.nosync/foo/index.html -> /etc/passwd was refused when asked
    # for by name (/foo/index.html -> 403, this branch caught it) and
    # served in full when asked for as a directory (/foo/ -> 200, the
    # file's contents). The same leak, one shape over -- which is the
    # shape the paragraph above was written about.
    target = File.directory?(full) ? File.join(full, 'index.html') : full

    begin
      probe = target
      probe = File.dirname(probe) while !File.exist?(probe) && probe != File.dirname(probe)
      real = File.realpath(probe)
      root_real = File.realpath(root)
      return nil unless real == root_real || real.start_with?("#{root_real}/")
    rescue SystemCallError
      return nil
    end

    target
  end

  def percent_decode(str)
    str.gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }.force_encoding('UTF-8')
  end

  # no-store, because this server exists to look at a build that changes
  # under the browser's feet: its whole audience is someone editing. A
  # cached search-index.json or stylesheet quietly showing the previous
  # build is indistinguishable from "my change didn't work" -- the most
  # confusing failure a preview can produce.
  def respond(client, code, reason, content_type, body, size: nil, extra: {}, head: false)
    write_head(client, code, reason, content_type, size || body&.bytesize || 0, **extra)
    # HEAD carries the headers of the GET it stands in for -- Content-Length
    # and all -- but never the body. The error responses (404, 403, 405,
    # 416) went out with their body regardless, which is a protocol bug a
    # strict client trips over.
    client.write(body) if body && !head
  end

  def write_head(client, code, reason, content_type, size, **extra)
    head = +"HTTP/1.1 #{code} #{reason}\r\n" \
            "Content-Type: #{content_type}\r\n" \
            "Content-Length: #{size}\r\n" \
            "Cache-Control: no-store\r\n" \
            "Connection: close\r\n"
    extra.each { |name, value| head << "#{name}: #{value}\r\n" }
    client.write("#{head}\r\n")
  end
end
