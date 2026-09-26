# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require_relative 'version'

# lib/surfer.rb -- uploads files to Surfer (Cloudron's Files API).
#
#   POST /api/files/<remote>
#   Content-Type: multipart/form-data, field "file". Success = HTTP 2xx.
#
# Configured via ENV (env.sh): SURFER_URL, SURFER_REMOTE_DIR, and how to
# sign in -- one of two ways:
#
#   SURFER_USERNAME + SURFER_PASSWORD  Surfer 7 and later: the Cloudron
#       user and an app password, sent as HTTP Basic. Surfer 7 (September
#       2026) took access tokens away; its files API is otherwise the same.
#   SURFER_TOKEN  Surfer 6 and earlier: an access token, sent as
#       ?access_token=. Surfer 7 answers it with 401.
#
# The password wins when both are set: an install moving to Surfer 7 adds
# the two lines and leaves the token where it was. And it may add them
# early. Surfer 6 does not know Basic auth -- it answers it with HTTP 500,
# "Cannot read properties of undefined (reading 'accessToken')", tried on
# blogsh.app 26. 9. 2026 -- so a password refused (401/403/500) before it
# has once been let in falls back to the token for the rest of the run,
# and every run tries the password first again: the day Cloudron brings
# Surfer 7, the password takes over by itself.
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

# A directory listing that came back as anything but the API's JSON.
class ListFailed < StandardError; end

# Surfer said no to the credentials (401/403). Raised from the first file
# rather than counted: every other file would get the same answer, and a
# deploy of 6,000 files printed 6,000 lines of HTTP 401 before it said
# anything a person could act on.
class Unauthorized < StandardError; end

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
    !ENV['SURFER_URL'].to_s.empty? && !sign_in.nil?
  end

  # :password, :token, or nil when neither is filled in.
  def sign_in
    if password? && !@on_token
      :password
    elsif token?
      :token
    end
  end

  def password?
    !ENV['SURFER_USERNAME'].to_s.empty? && !ENV['SURFER_PASSWORD'].to_s.empty?
  end

  def token?
    !ENV['SURFER_TOKEN'].to_s.empty?
  end

  # What an older Surfer answers a password with. 500 belongs here only
  # until the password has worked once: after that a 500 is the server's
  # own trouble, not the sign-in's.
  PASSWORD_NOT_TAKEN = [401, 403, 500].freeze

  # Called with every response. true when the request is to be sent again
  # -- the password was not taken and a token stands behind it.
  def switch_to_token?(code)
    return false unless sign_in == :password && !@password_worked

    if code.to_i.between?(200, 299) || code.to_i == 404
      @password_worked = true
      return false
    end
    return false unless PASSWORD_NOT_TAKEN.include?(code.to_i) && token?

    @on_token = true
    @fell_back = true
    true
  end

  # Whether this run went on with the token, once -- said by whoever
  # reports the run, in its own words.
  def fell_back?
    @fell_back == true
  end

  def reset_sign_in
    @on_token = @password_worked = @fell_back = false
  end

  # A password with no token to fall back on, refused -- 500 included, which
  # is how Surfer 6 refuses it.
  def password_refused?(code)
    sign_in == :password && !@password_worked && PASSWORD_NOT_TAKEN.include?(code.to_i)
  end

  def authorize(request)
    request.basic_auth(ENV['SURFER_USERNAME'].to_s, ENV['SURFER_PASSWORD'].to_s) if sign_in == :password
    request
  end

  def refused?(code)
    [401, 403].include?(code.to_i)
  end

  # Opens one connection and yields a Session (see below) to the block. The
  # connection is always closed once the block finishes.
  #
  # read_timeout: a deploy waits a minute for a big upload to be taken;
  # doctor's listing asks for one directory and passes its own, shorter.
  def session(read_timeout: 60)
    reset_sign_in
    base = URI(ENV['SURFER_URL'].to_s.chomp('/'))
    http = Net::HTTP.new(base.host, base.port)
    http.use_ssl = (base.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = read_timeout
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
      logger&.call("  ℹ️  SURFER_URL or its sign-in (SURFER_USERNAME + SURFER_PASSWORD) not set -> upload skipped (#{path})")
      return :skipped
    end

    session { |s| s.upload(path, logger: logger, remote_name: remote_name) }
  end

  # What to say when Surfer refuses: the fix depends on which way in was
  # tried, and a token refused is almost always a Surfer that became 7.
  def refusal_sentence(code)
    require_relative 'i18n'
    key = if sign_in == :password && code.to_i == 500 then 'cli.surfer_password_unsupported'
          elsif sign_in == :password then 'cli.surfer_refused_password'
          else 'cli.surfer_refused_token'
          end
    I18n.t(key, url: ENV['SURFER_URL'].to_s.chomp('/'), code: code)
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
        say.call("  ℹ️  SURFER_URL or its sign-in (SURFER_USERNAME + SURFER_PASSWORD) not set -> upload skipped (#{path})")
        return :skipped
      end

      remote = Surfer.remote_path(path, remote_name)
      resp = signed_request(say) { build_upload(remote, path) }
      raise Unauthorized, "HTTP #{resp.code}" if Surfer.refused?(resp.code) || Surfer.password_refused?(resp.code)

      ok = resp.code.to_i.between?(200, 299)
      say.call("  #{ok ? '✅' : '❌'} upload -> #{ENV['SURFER_URL'].to_s.chomp('/')}/#{remote} (HTTP #{resp.code})")
      ok ? :ok : :failed
    rescue Unauthorized
      raise
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
      resp = signed_request(say) { build_delete(remote) }
      code = resp.code.to_i
      return :missing if code == 404
      raise Unauthorized, "HTTP #{code}" if Surfer.refused?(code) || Surfer.password_refused?(code)

      ok = code.between?(200, 299)
      say.call("  #{ok ? '🗑️ ' : '❌'} deleted -> #{remote} (HTTP #{resp.code})")
      ok ? :ok : :failed
    rescue Unauthorized
      raise
    rescue StandardError => e
      say.call("  ❌ delete failed: #{e.class}: #{e.message}")
      :failed
    end

    # [name, directory?] for what stands in a remote directory. The API
    # lists a directory asked for WITH its trailing slash and answers
    # HTTP 222; the root is `/api/files//` -- `/api/files/` alone is not
    # the API at all but the site's own front page, served with a 404.
    def list(dir)
      remote = dir.to_s.gsub(%r{\A/+|/+\z}, '')
      # Asked once. send_request reconnects and asks again, and Net::HTTP
      # retries an idempotent GET on its own: against a Surfer that takes
      # the connection and never answers, that was four waits of a minute
      # each. A listing that does not come back in time is the answer.
      @http.max_retries = 0 if @http.respond_to?(:max_retries=)
      resp = begin
        r = @http.request(build_list(remote))
        Surfer.switch_to_token?(r.code) ? @http.request(build_list(remote)) : r
      rescue Net::ReadTimeout
        raise ListFailed, I18n.t('doctor.deploy_target_timeout', seconds: @http.read_timeout.to_i)
      end
      code = resp.code.to_i
      raise Unauthorized, Surfer.refusal_sentence(code) if Surfer.refused?(code) || Surfer.password_refused?(code)
      raise ListFailed, "HTTP #{code}" unless code.between?(200, 299)

      entries = JSON.parse(resp.body.to_s)['entries']
      raise ListFailed, "HTTP #{code}, no entries" unless entries.is_a?(Array)

      entries.map { |e| [e['fileName'].to_s, e['isDirectory'] == true] }
    rescue JSON::ParserError
      raise ListFailed, "HTTP #{code}, not a listing"
    end

    private

    def build_list(remote)
      uri = api_uri(remote)
      # "/api/files/posts" -> ".../posts/", and the root "/api/files/" -> "//".
      uri.path = "#{uri.path}/"
      req = Net::HTTP::Get.new(uri)
      req['User-Agent'] = Surfer::USER_AGENT
      Surfer.authorize(req)
    end

    # Sent with the password first, if there is one; refused and backed by
    # a token, sent once more with the token -- and said, once, in the log.
    def signed_request(say, &build)
      resp = send_request(&build)
      return resp unless Surfer.switch_to_token?(resp.code)

      require_relative 'i18n'
      say.call("  ℹ️  #{I18n.t('cli.surfer_fell_back', code: resp.code)}")
      send_request(&build)
    end

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
      params = Surfer.sign_in == :token ? { 'access_token' => ENV['SURFER_TOKEN'].to_s } : {}
      params = params.merge(extra_params)
      query = params.empty? ? '' : "?#{URI.encode_www_form(params)}"
      URI("#{ENV['SURFER_URL'].to_s.chomp('/')}/api/files/#{remote_enc}#{query}")
    end

    def build_delete(remote)
      req = Net::HTTP::Delete.new(api_uri(remote))
      req['User-Agent'] = Surfer::USER_AGENT
      Surfer.authorize(req)
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
      Surfer.authorize(req)
    end
  end
end
