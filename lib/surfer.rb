# frozen_string_literal: true

require 'net/http'
require 'uri'
require_relative 'version'

# lib/surfer.rb -- uploads files to Surfer (Cloudron's Files API).
#
#   POST /api/files/<remote>?access_token=TOKEN&newFilePath=<remote>
#   Content-Type: multipart/form-data, field "file". Success = HTTP 2xx.
#
# Configured via ENV (env.sh): SURFER_URL, SURFER_TOKEN, SURFER_REMOTE_DIR.
#
# For a batch of files, use Surfer.session -- it holds one HTTP/TLS
# connection for the whole batch. A new connection per file (the original
# behavior) meant thousands of TLS handshakes on a large deploy, i.e. tens
# of minutes of pure waiting.
module Surfer
  USER_AGENT = BlogSh.user_agent('upload')

# Raised when the connection to the Surfer app cannot be opened at all:
# nothing was uploaded, nothing was deleted, and retrying would dial the
# same dead address again. deploy_web turns this into a sentence naming
# SURFER_URL -- it used to escape as a raw Errno backtrace, the only
# stack trace an otherwise fully spoken setup could still show a
# beginner (a stopped app and a mistyped URL both land here).
class Unreachable < StandardError; end

# Everything TCPSocket/TLS can throw before the first request goes out.
# Distinct from Session::RETRIABLE on purpose: those happen mid-batch on
# a connection that already worked, and reconnecting once is the right
# answer there. Here nothing ever worked.
CONNECT_ERRORS = [
  Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
  Errno::ETIMEDOUT, Net::OpenTimeout, SocketError, OpenSSL::SSL::SSLError
].freeze

module_function

  def configured?
    !ENV['SURFER_URL'].to_s.empty? && !ENV['SURFER_TOKEN'].to_s.empty?
  end

  # Opens one connection and yields a Session (see below) to the block. The
  # connection is always closed once the block finishes.
  def session
    base = URI(ENV['SURFER_URL'].to_s.chomp('/'))
    http = Net::HTTP.new(base.host, base.port)
    http.use_ssl = (base.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 60
    begin
      http.start
    rescue *CONNECT_ERRORS => e
      raise Unreachable, "#{e.class}: #{e.message.lines.first.to_s.strip}"
    end
    yield Session.new(http)
  ensure
    http.finish if http&.started?
  end

  # One-off upload of a single file (opens and closes its own connection).
  def upload(path, logger: nil, remote_name: nil)
    unless configured?
      logger&.call("  ℹ️  SURFER_URL/SURFER_TOKEN not set -> upload skipped (#{path})")
      return :skipped
    end

    session { |s| s.upload(path, logger: logger, remote_name: remote_name) }
  end

  # Remote path = SURFER_REMOTE_DIR + relative name (preserves subdirectories).
  # Falls back to the basename without remote_name.
  def remote_path(path, remote_name)
    dir = ENV['SURFER_REMOTE_DIR'].to_s.gsub(%r{\A/+|/+\z}, '')
    rel = (remote_name && !remote_name.empty?) ? remote_name.gsub(%r{\A/+}, '') : File.basename(path)
    dir.empty? ? rel : "#{dir}/#{rel}"
  end

  # Holds one connection across the whole batch. If the server closes it
  # mid-batch (a keep-alive timeout is common with thousands of files), it
  # reconnects once and retries the upload -- otherwise the rest of the
  # batch would fail.
  class Session
    RETRIABLE = [
      EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError,
      Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
    ].freeze

    def initialize(http)
      @http = http
    end

    def upload(path, logger: nil, remote_name: nil)
      say = ->(m) { logger&.call(m) }
      unless Surfer.configured?
        say.call("  ℹ️  SURFER_URL/SURFER_TOKEN not set -> upload skipped (#{path})")
        return :skipped
      end

      remote = Surfer.remote_path(path, remote_name)
      resp = send_request { build_upload(remote, path) }
      ok = resp.code.to_i.between?(200, 299)
      say.call("  #{ok ? '✅' : '❌'} upload -> #{ENV['SURFER_URL'].to_s.chomp('/')}/#{remote} (HTTP #{resp.code})")
      ok ? :ok : :failed
    rescue StandardError => e
      say.call("  ❌ upload failed: #{e.class}: #{e.message}")
      :failed
    end

    # Deletes the remote file. HTTP 404 counts as success (:missing) -- the
    # goal is for the file to not exist on Surfer, and if it's already gone,
    # that goal is met.
    def delete(remote_name, logger: nil)
      say = ->(m) { logger&.call(m) }
      remote = Surfer.remote_path(remote_name, remote_name)
      resp = send_request { build_delete(remote) }
      code = resp.code.to_i
      return :missing if code == 404

      ok = code.between?(200, 299)
      say.call("  #{ok ? '🗑️ ' : '❌'} deleted -> #{remote} (HTTP #{resp.code})")
      ok ? :ok : :failed
    rescue StandardError => e
      say.call("  ❌ delete failed: #{e.class}: #{e.message}")
      :failed
    end

    private

    # The request is only built here, inside the block, so it can be built
    # again after a reconnect.
    def send_request(retried: false, &build)
      @http.request(build.call)
    rescue *RETRIABLE
      raise if retried

      reconnect
      send_request(retried: true, &build)
    end

    def reconnect
      @http.finish if @http.started?
    rescue StandardError
      nil
    ensure
      @http.start
    end

    def api_uri(remote, extra_params = {})
      # Path segments, not form fields. encode_www_form_component writes a
      # space as "+", which is form syntax: in a path a "+" is a literal
      # plus, so a banner called "muj banner.png" was uploaded as
      # "muj+banner.png" while every page linked to "muj%20banner.png" --
      # and the delete that should have taken it down named the third
      # spelling. One helper builds both requests, so both were wrong in
      # the same direction and nothing ever noticed.
      remote_enc = remote.split('/')
                         .map { |s| URI.encode_www_form_component(s).gsub('+', '%20') }
                         .join('/')
      params = { 'access_token' => ENV['SURFER_TOKEN'].to_s }.merge(extra_params)
      URI("#{ENV['SURFER_URL'].to_s.chomp('/')}/api/files/#{remote_enc}?#{URI.encode_www_form(params)}")
    end

    def build_delete(remote)
      req = Net::HTTP::Delete.new(api_uri(remote))
      req['User-Agent'] = Surfer::USER_AGENT
      req
    end

    def build_upload(remote, path)
      uri = api_uri(remote, 'newFilePath' => remote)

      boundary = "----Blog#{rand(10**16)}"
      # The header is switched to binary before the file content is
      # appended -- otherwise, for a filename with diacritics, concatenating
      # a UTF-8 string with ASCII-8BIT would raise Encoding::CompatibilityError.
      body = +"--#{boundary}\r\n" \
              "Content-Disposition: form-data; name=\"file\"; filename=\"#{File.basename(path)}\"\r\n" \
              "Content-Type: application/octet-stream\r\n\r\n"
      body.force_encoding(Encoding::BINARY)
      body << File.binread(path)
      body << "\r\n--#{boundary}--\r\n"

      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      req['User-Agent'] = Surfer::USER_AGENT
      req.body = body
      req
    end
  end
end
