# frozen_string_literal: true

require 'base64'
require 'digest'
require 'etc'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'socket'
require 'time'
require 'tmpdir'
require 'uri'
require_relative 'atomic_write'

# lib/pairing.rb -- letting an app in by showing it a code.
#
# An app reaches this installation over SSH with a key of its own, held to
# one command (scripts/remote.sh). Getting that key onto the server has
# meant copying it out of the app and writing a line into
# ~/.ssh/authorized_keys by hand -- options, a quoted path, sometimes a
# PATH -- which is a fair ask of somebody who administers the machine and
# a wall for everybody else. That way in stays exactly as it is. This is a
# second one beside it: `./blog.sh pair` shows a code, the app reads it
# with its camera, and that is all either side is asked to do.
#
# What happens under the code:
#
#   1. A key is made here that is good for ten minutes and for one thing.
#      Its line in authorized_keys carries a forced command,
#      scripts/enroll.sh, that does nothing but take a public key in --
#      and refuses once the ten minutes are up -- and sshd's own
#      `expiry-time` behind that. The private half goes into the code,
#      with where to connect and the fingerprints of this server's own keys.
#   2. The app connects with that key -- knowing from the fingerprints
#      that it reached this machine and not something in between -- and
#      hands over the public half of a key it made itself.
#   3. The ten-minute line is replaced by an ordinary one for the app's
#      key, held to scripts/remote.sh like any written by hand.
#
# So the secret that was on a screen stops opening anything the moment it
# is used, or ten minutes later whichever comes first, and the key the app
# lives on never leaves the device it was made on.
#
# ⚠️ This is the one place the engine writes outside its own folder into a
# file that decides who may log in. The rules it holds to:
#
#   - It writes only lines that begin `restrict,` and force a command of
#     THIS installation. It cannot be made to write a line that grants a
#     shell: the only thing that arrives from outside is a public key, and
#     it is taken only if it is exactly an ed25519 key and nothing else.
#   - It touches only lines it wrote, known by their closing comment and
#     by this installation's path in their command. Every other line is
#     written back byte for byte, in its place.
#   - It keeps the file as it was before each change beside it, and
#     replaces the file whole or not at all.
module Pairing
  module_function

  class Refused < StandardError
    attr_reader :reason

    def initialize(reason, message = nil)
      @reason = reason
      super(message || reason.to_s)
    end
  end

  # How long a code is good for.
  SECONDS = 600
  # The closing comment of a line written here: `blog.sh-pair:<id>` while a
  # code is waiting, `blog.sh:<device>` once an app has come in.
  WAITING = 'blog.sh-pair:'
  DEVICE = 'blog.sh:'
  # An ed25519 public key as OpenSSH writes one: the type, a space, 68
  # characters of base64. Nothing before, nothing after -- a line break,
  # an option or a second key cannot ride in on it.
  PUBLIC_KEY = %r{\Assh-ed25519 [A-Za-z0-9+/]{68}\z}.freeze
  KEYGEN = 'ssh-keygen'

  # --- where things are ---------------------------------------------------

  # BLOG_SH_AUTHORIZED_KEYS is for an account whose sshd reads another
  # file -- and for the tests, which must never write into a person's own.
  def keys_file
    return @keys_file if @keys_file

    chosen = ENV['BLOG_SH_AUTHORIZED_KEYS'].to_s
    chosen.empty? ? File.join(Dir.home, '.ssh', 'authorized_keys') : chosen
  end

  # The file a code was opened in is the file it is closed in. The app
  # arrives through sshd, whose forced command has none of the terminal's
  # environment -- so a code opened in a file named by the variable above
  # would be looked for, and locked, and found missing, in the account's
  # default one. The record of the code says which file it was.
  def in_keys_file(path)
    before = @keys_file
    @keys_file = path.to_s.empty? ? nil : path.to_s
    yield
  ensure
    @keys_file = before
  end

  def host_keys_dir
    chosen = ENV['BLOG_SH_HOST_KEYS_DIR'].to_s
    chosen.empty? ? '/etc/ssh' : chosen
  end

  def records_dir(root)
    File.join(root, 'tmp', 'pairing')
  end

  def record_path(root, id)
    File.join(records_dir(root), "#{id}.json")
  end

  # --- the lines ----------------------------------------------------------

  def shell_quote(text)
    "'#{text.to_s.gsub("'") { %q('\\'') }}'"
  end

  # The command sshd runs for a key, as it stands inside command="...".
  # PATH is the one this very process was started with: a forced command
  # runs in the account's bare non-interactive shell, where the Ruby that
  # a login shell finds (rbenv, Homebrew) is often not on the path at all
  # -- and a pairing that ends in "ruby: command not found" on the app's
  # first request is not a pairing.
  def forced_command(root, script, *words)
    ["PATH=#{in_option(shell_quote(ENV['PATH'].to_s))}", script_token(root, script), *words].join(' ')
  end

  # A piece of text as it stands inside the double quotes of an option.
  def in_option(text)
    text.gsub('\\') { '\\\\' }.gsub('"') { '\\"' }
  end

  # One of this installation's scripts exactly as a line names it: quoted
  # for the shell, then for the option. Written and recognised by the same
  # function, so a folder with a space or a quote in its name is found
  # again by the spelling it was written with.
  def script_token(root, script)
    in_option(shell_quote(File.join(File.expand_path(root), 'scripts', script)))
  end

  # sshd's own clock on the line: YYYYMMDDHHMM in the server's time. A key
  # past it is refused by sshd before anything here is asked.
  #
  # ⚠️ A second lock, and a coarse one -- the ten minutes are kept by the
  # record (see `enroll`), which is asked every time because the key can
  # do nothing but ask. sshd reads the stamp to the minute, and measured
  # on OpenSSH 10.3 it reads it as STANDARD time: in summer the line
  # outlives its code by an hour. The form that says UTC outright (a
  # trailing Z) would be exact, and an sshd older than 9.1 rejects it --
  # and with it the whole line, so the code would open nothing at all.
  # An hour of a dead line is the cheaper of the two: what this clock is
  # for is the line nobody ever came for and nobody tidied away.
  def waiting_line(root, id, public_key, expires)
    %(restrict,expiry-time="#{expires.localtime.strftime('%Y%m%d%H%M')}",) +
      %(command="#{forced_command(root, 'enroll.sh', id)}" #{public_key} #{WAITING}#{id})
  end

  def device_line(root, public_key, name)
    %(restrict,command="#{forced_command(root, 'remote.sh')}" #{public_key} #{DEVICE}#{name})
  end

  # Whether a line of the file is one this installation wrote: by its
  # closing comment AND by this installation's own scripts in its command,
  # so two blogs in one account each see only their own.
  def ours?(line, root, marker)
    script = marker == WAITING ? 'enroll.sh' : 'remote.sh'
    line.start_with?('restrict,') && line.include?(" #{marker}") && line.include?(script_token(root, script))
  end

  def comment_of(line, marker)
    line[/ #{Regexp.escape(marker)}(.*)\z/, 1].to_s
  end

  # A name for a device, as it will stand at the end of a line of
  # authorized_keys and on this screen: letters, digits, spaces and a few
  # marks, forty characters. Whatever else an app sends is dropped -- and
  # a name with nothing left in it is "device".
  def device_name(text)
    # Every kind of space becomes a space first -- a line break or a tab in
    # a name is two words, not one run-together -- and only then is
    # everything that is not a letter, a digit or one of four marks dropped.
    name = text.to_s.dup.force_encoding('UTF-8').scrub('')
               .gsub(/[[:space:]]+/, ' ').gsub(/[^\p{L}\p{N} ._-]/, '').squeeze(' ').strip[0, 40].to_s.strip
    name.empty? ? 'device' : name
  end

  # --- reading and writing the file ---------------------------------------

  def read_lines
    File.file?(keys_file) ? File.read(keys_file, encoding: 'utf-8').lines.map(&:chomp) : []
  end

  # One change at a time: the terminal that is waiting and the app that
  # has just arrived both rewrite this file, and each has to see what the
  # other did.
  def locked
    FileUtils.mkdir_p(File.dirname(keys_file), mode: 0o700)
    File.open("#{keys_file}.blog-sh.lock", File::CREAT | File::RDWR, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end

  # The file as it was goes beside it first, then the new one replaces it
  # whole. 0600 both: sshd refuses an authorized_keys others can write, and
  # a copy of it deserves no less.
  def write_lines(lines)
    if File.file?(keys_file)
      AtomicWrite.write("#{keys_file}.blog-sh.bak", File.read(keys_file, encoding: 'utf-8'), permissions: 0o600)
    end
    AtomicWrite.write(keys_file, lines.empty? ? '' : "#{lines.join("\n")}\n", permissions: 0o600)
  end

  # --- this machine, as an app has to find it -----------------------------

  # Over SSH the session says which address and port it came in on, and
  # that is an address this machine demonstrably answers at. At the
  # machine's own keyboard there is no such witness, and what is offered
  # is the machine's NUMBER on the network it is on: a phone on the same
  # network always finds a number, and usually does not find a name -- a
  # bare host name is known to this machine and to nobody else, which is
  # what the first person to try this was offered and could not use
  # (Pavel, 8. 10. 2026). The name is the fallback for a machine with no
  # network to have a number on.
  def guess_address
    server = ENV['SSH_CONNECTION'].to_s.split
    return [server[2], server[3].to_i] if server.size == 4

    [lan_address || Socket.gethostname, 22]
  end

  # The address of the interface this machine reaches the rest of the
  # world through. Asked of the system by pointing a datagram socket at an
  # address nothing lives at (192.0.2.1 is reserved for documentation):
  # nothing is sent, the system only decides which interface it WOULD use
  # -- which on a machine with a VPN, a container bridge and a cable is
  # the question worth asking, and a list of addresses does not answer it.
  def lan_address
    address = UDPSocket.open do |socket|
      socket.connect('192.0.2.1', 9)
      socket.addr.last
    end
    address.to_s.start_with?('127.') || address.to_s.empty? ? first_address : address
  rescue SystemCallError, SocketError
    first_address
  end

  def first_address
    Socket.ip_address_list.find { |a| a.ipv4? && !a.ipv4_loopback? }&.ip_address
  rescue SystemCallError, SocketError
    nil
  end

  # The account this runs in, asked of the system: it is the account whose
  # authorized_keys is written, so it is the one an app has to log in as.
  # Not $USER, which is whatever the shell was told -- empty under a
  # runner, somebody else's after `sudo -u` -- and a code naming the wrong
  # account is a code that connects nowhere.
  def user
    Etc.getpwuid(Process.euid).name
  end

  # The fingerprints of this server's own keys, as `ssh-keygen -l` prints
  # them without the prefix: the app compares what the server shows on
  # connecting with these, so the first connection is to a machine it was
  # told about rather than to whoever answered.
  def host_fingerprints
    %w[ed25519 ecdsa].map { |type| File.join(host_keys_dir, "ssh_host_#{type}_key.pub") }
                     .select { |file| File.file?(file) && File.readable?(file) }
                     .map { |file| fingerprint(File.read(file).split[1].to_s) }.compact
  end

  def fingerprint(blob_base64)
    blob = Base64.strict_decode64(blob_base64)
    Base64.strict_encode64(Digest::SHA256.digest(blob)).delete('=')
  rescue ArgumentError
    nil
  end

  # Whether an SSH server answers on this machine's own port: by what it
  # SAYS, not by a connection going through. An sshd introduces itself
  # the moment it is reached ("SSH-2.0-..."), and anything else that
  # happens to accept a connection there -- another program, a network
  # filter that takes every connection before deciding, a port that for a
  # moment connects to itself -- says nothing of the kind.
  def ssh_answers?(port)
    Socket.tcp('127.0.0.1', port, connect_timeout: 2) do |socket|
      return false unless IO.select([socket], nil, nil, 3)

      socket.read_nonblock(8, exception: false).to_s.start_with?('SSH-')
    end
  rescue SystemCallError, SocketError, IOError
    false
  end

  def keygen?
    _, status = Open3.capture2e(KEYGEN, '-?')
    !status.nil?
  rescue SystemCallError
    false
  end

  # --- a key for ten minutes ----------------------------------------------

  # Made by ssh-keygen, which is on any machine that runs sshd, in a
  # scratch folder that is gone before this returns: the private half
  # exists afterwards only in what is handed back, for the code.
  def one_time_key(id)
    Dir.mktmpdir('blogsh-pair') do |scratch|
      file = File.join(scratch, 'key')
      out, status = Open3.capture2e(KEYGEN, '-q', '-t', 'ed25519', '-N', '', '-C', "#{WAITING}#{id}", '-f', file)
      raise Refused.new(:keygen, out.strip) unless status.success?

      public_key = File.read("#{file}.pub").split.first(2).join(' ')
      [public_key, seed_of(File.read(file))]
    end
  end

  # The 32 bytes an ed25519 private key IS, out of the file OpenSSH wraps
  # them in (openssh-key-v1): a code has room for the bytes, not for the
  # wrapping, and every SSH library builds its key from them.
  def seed_of(private_file)
    body = Base64.decode64(private_file.lines.reject { |line| line.start_with?('-----') }.join)
    magic = "openssh-key-v1\0"
    raise Refused.new(:keygen, 'not an OpenSSH private key') unless body.start_with?(magic)

    at = magic.bytesize
    take = lambda do
      length = body[at, 4].unpack1('N')
      value = body[at + 4, length]
      at += 4 + length
      value
    end
    raise Refused.new(:keygen, 'the key is encrypted') unless take.call == 'none'

    take.call # kdf name
    take.call # kdf options
    at += 4   # number of keys
    take.call # the public key
    secret = take.call
    inner = 8 # two check numbers
    read = lambda do
      length = secret[inner, 4].unpack1('N')
      value = secret[inner + 4, length]
      inner += 4 + length
      value
    end
    read.call # key type
    read.call # public half
    pair = read.call
    raise Refused.new(:keygen, 'not an ed25519 key') unless pair.bytesize == 64

    pair[0, 32]
  end

  # --- the code -----------------------------------------------------------

  # What the app reads: a link of its own scheme, so a camera that is not
  # the app's offers to open the app, and so the same text can be pasted
  # where there is no camera to point.
  def code(host:, port:, user:, seed:, fingerprints:, site:)
    query = { 'v' => '1', 'h' => host, 'p' => port.to_s, 'u' => user,
              'k' => Base64.urlsafe_encode64(seed, padding: false) }
    # In the alphabet a link carries as it stands (- and _ for + and /),
    # with a dot between two: a code is drawn module by module, and three
    # characters for every one that needed escaping is a larger code.
    query['f'] = fingerprints.map { |print| print.tr('+/', '-_') }.join('.') unless fingerprints.empty?
    query['n'] = site.to_s[0, 24] unless site.to_s.strip.empty?
    "blogsh://pair?#{URI.encode_www_form(query)}"
  end

  # --- starting, finishing, giving up -------------------------------------

  # Opens the door: a key, its line, a record of when it closes. Answers
  # with what the terminal needs to show and to wait on.
  def start(root:, host:, port:, site: nil, now: Time.now)
    raise Refused.new(:keygen, 'ssh-keygen is not on the PATH') unless keygen?

    id = SecureRandom.hex(8)
    # sshd reads the line's clock to the minute, so the minute is rounded
    # up: ten minutes are promised and a little more is given, never less.
    expires = Time.at(((now.to_i + SECONDS) / 60.0).ceil * 60)
    public_key, seed = one_time_key(id)
    locked do
      kept = read_lines.reject { |line| expired_waiting?(line, root, now) }
      write_lines(kept + [waiting_line(root, id, public_key, expires)])
    end
    FileUtils.mkdir_p(records_dir(root))
    AtomicWrite.write_json(record_path(root, id), { 'id' => id, 'state' => 'waiting', 'expires' => expires.utc.iso8601,
                                                    'keys_file' => File.expand_path(keys_file) }, permissions: 0o600)
    { id: id, expires: expires,
      code: code(host: host, port: port, user: user, seed: seed, fingerprints: host_fingerprints, site: site) }
  end

  def record(root, id)
    data = JSON.parse(File.read(record_path(root, id), encoding: 'utf-8'))
    data.is_a?(Hash) ? data : nil
  rescue SystemCallError, JSON::ParserError
    nil
  end

  # A waiting line whose code has run out: by the record where there is
  # one, and otherwise by the line's own clock.
  def expired_waiting?(line, root, now = Time.now)
    return false unless ours?(line, root, WAITING)

    known = record(root, comment_of(line, WAITING))
    return Time.parse(known['expires']) <= now if known && known['expires']

    stamp = line[/expiry-time="(\d{12})"/, 1]
    stamp.nil? || Time.strptime(stamp, '%Y%m%d%H%M') <= now
  rescue ArgumentError
    true
  end

  # What scripts/enroll.sh comes to: the app's own key in, the ten-minute
  # line out. Every refusal leaves the file as it was.
  def enroll(root:, id:, key:, name:, now: Time.now)
    raise Refused, :unknown_code unless id.to_s.match?(/\A[0-9a-f]{16}\z/)

    # One line: the type and the key, and after them at most the comment a
    # public key file carries. A line break or any other control character
    # anywhere in what was sent is not a key with something extra, it is
    # not a key -- nothing past the second word would be written either
    # way, but what is refused here is never looked at twice.
    sent = key.to_s
    raise Refused, :bad_key if sent.match?(/[[:cntrl:]]/) || !sent.valid_encoding?

    public_key = sent.split(' ').first(2).join(' ')
    raise Refused, :bad_key unless sent.lstrip.start_with?(public_key) && public_key.match?(PUBLIC_KEY) && ed25519?(public_key)

    device = device_name(name)
    opened = record(root, id)
    raise Refused, :unknown_code unless opened

    in_keys_file(opened['keys_file']) { enroll_locked(root, id, public_key, device, now) }
    device
  end

  def enroll_locked(root, id, public_key, device, now)
    locked do
      known = record(root, id)
      raise Refused, :unknown_code unless known
      raise Refused, :used unless known['state'] == 'waiting'
      raise Refused, :expired if Time.parse(known['expires'].to_s) <= now

      lines = read_lines
      at = lines.index { |line| ours?(line, root, WAITING) && comment_of(line, WAITING) == id }
      raise Refused, :unknown_code unless at
      # The same device coming in again -- a reinstalled app, a second try
      # -- is the same device: its old line goes, so a list of devices is a
      # list of devices and not of attempts.
      taken = lines.each_index.select { |i| i != at && ours?(lines[i], root, DEVICE) && lines[i].include?(" #{public_key} ") }
      lines[at] = device_line(root, public_key, device)
      taken.reverse_each { |i| lines.delete_at(i) }
      write_lines(lines)
      AtomicWrite.write_json(record_path(root, id), known.merge('state' => 'paired', 'device' => device,
                                                                'fingerprint' => fingerprint(public_key.split.last)), permissions: 0o600)
    end
  end

  # The bytes really are an ed25519 key: the type's name with its length,
  # then thirty-two bytes with theirs. The pattern says the text has the
  # right shape; this says the shape holds what it claims to.
  def ed25519?(public_key)
    blob = Base64.strict_decode64(public_key.split.last)
    blob.bytesize == 51 && blob[0, 4].unpack1('N') == 11 && blob[4, 11] == 'ssh-ed25519' && blob[15, 4].unpack1('N') == 32
  rescue ArgumentError
    false
  end

  # Closes a door nobody came through.
  def cancel(root:, id:)
    opened = record(root, id)
    in_keys_file(opened && opened['keys_file']) { cancel_locked(root, id) }
    FileUtils.rm_f(record_path(root, id))
  end

  def cancel_locked(root, id)
    locked do
      lines = read_lines
      kept = lines.reject { |line| ours?(line, root, WAITING) && comment_of(line, WAITING) == id }
      write_lines(kept) unless kept == lines
    end
  end

  # Doors left open by a terminal that was closed: their lines and their
  # records. sshd has refused those keys since their minute passed; this
  # is the tidying.
  def sweep(root:, now: Time.now)
    removed = 0
    locked do
      lines = read_lines
      kept = lines.reject { |line| expired_waiting?(line, root, now) }
      removed = lines.size - kept.size
      write_lines(kept) unless removed.zero?
    end
    # A record outlives its code only as long as the terminal that asked
    # might still be reading it: gone once the code has run out.
    Dir.glob(File.join(records_dir(root), '*.json')).each do |file|
      known = record(root, File.basename(file, '.json'))
      over = begin
        known.nil? || Time.parse(known['expires'].to_s) <= now
      rescue ArgumentError
        true
      end
      FileUtils.rm_f(file) if over
    end
    removed
  end

  # Waiting lines of this installation that are past their time.
  def leftovers(root:, now: Time.now)
    read_lines.count { |line| expired_waiting?(line, root, now) }
  end

  # --- the devices --------------------------------------------------------

  # Every app this installation let in by a code, as [name, fingerprint].
  # A line written by hand is not here: it has no closing comment of ours,
  # and what somebody wrote into that file themselves is theirs.
  def devices(root:)
    read_lines.select { |line| ours?(line, root, DEVICE) }.map do |line|
      key = line[/ (ssh-ed25519 [A-Za-z0-9+\/]{68}) #{Regexp.escape(DEVICE)}/, 1].to_s
      { 'name' => comment_of(line, DEVICE), 'fingerprint' => fingerprint(key.split.last.to_s).to_s }
    end
  end

  # Takes a device out, by its name or by its key's fingerprint. Answers
  # the devices removed -- more than one when two were given one name.
  def revoke(root:, which:)
    gone = []
    locked do
      lines = read_lines
      kept = lines.reject do |line|
        next false unless ours?(line, root, DEVICE)

        key = line[/ (ssh-ed25519 [A-Za-z0-9+\/]{68}) #{Regexp.escape(DEVICE)}/, 1].to_s
        match = comment_of(line, DEVICE) == which || fingerprint(key.split.last.to_s) == which.to_s.sub(/\ASHA256:/, '')
        gone << comment_of(line, DEVICE) if match
        match
      end
      write_lines(kept) unless gone.empty?
    end
    gone
  end
end
