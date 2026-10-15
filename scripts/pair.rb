#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/pair.rb -- `./blog.sh pair`: let an app in by showing it a code.
#
#   ./blog.sh pair                    shows a code and waits for the app
#   ./blog.sh pair --list             the devices let in this way
#   ./blog.sh pair --revoke [<device>]  takes one out: its number, name or
#                                     fingerprint from --list -- or, with
#                                     nothing said, the one it asks about
#
#   --host <address> --port <n>       where the app is to connect, when the
#                                     guess is wrong or nobody is there to ask
#   --no-wait                         prints the code and leaves; the code
#                                     keeps its ten minutes
#
#   --list --json                     the same list for a program: one
#                                     object, each device with its name,
#                                     its fingerprint and whether it is
#                                     the one asking
#   --revoke --json                   takes out the device that is asking,
#                                     and no other; nothing may follow it
#
# The two --json forms are what an app reaches through scripts/remote.sh.
# Which device is asking is known by one thing only: the word its line in
# authorized_keys hands that script (BLOG_SH_DEVICE by the time it is
# here; ./blog.sh carries it past env.sh, so nothing written there
# stands in for it). A device can therefore show the others and take out
# itself; a code is shown, and another device taken out, by somebody at
# a terminal.
#
# What a code is and what happens when one is read is in lib/pairing.rb.
# This is the screen: it checks that an app would have something to
# connect to, asks the one thing it cannot know -- the address this
# machine has from where the phone is -- draws the code, and waits.
#
# The way in by hand, a line written into authorized_keys, is untouched
# by any of this and stays what docs/operations.md describes.
require 'io/console'
require 'json'
require_relative '../lib/yaml_compat'
require_relative '../lib/config_lang'

ROOT = File.expand_path('..', __dir__)
SITE_YML = File.join(ROOT, 'config', 'site.yml')

require_relative '../lib/i18n'
lang = ConfigLang.of(SITE_YML)
# A program's answer is said in the language of whoever reads it, when
# they said which (scripts/remote.rb hands an app's language over in
# BLOG_SH_SPEAK, as it does for check and doctor). The terminal speaks
# the blog's own, as before.
spoken = ARGV.include?('--json') ? ENV['BLOG_SH_SPEAK'].to_s : ''
spoken = '' unless spoken.match?(/\A[a-z]{2,3}\z/) && File.file?(File.join(ROOT, 'locales', "#{spoken}.yml"))
I18n.force_lang(spoken.empty? ? (lang.to_s.empty? ? 'en' : lang.to_s) : spoken)

require_relative '../lib/tui'
require_relative '../lib/qr_code'
require_relative '../lib/pairing'

$stdout.sync = true

def t(key, **vars)
  I18n.t("pair.#{key}", **vars)
end

# What was typed is UTF-8 whatever the shell said its language was. With
# no LANG -- cron, `docker exec`, a bare ssh command -- Ruby labels every
# argument as raw bytes, and a device called "Danielův iPhone" then could
# not even be compared with the name in the file: --revoke died on it with
# an encoding error and the device stayed (fleet, 8. 10. 2026). Labelled,
# not converted: an argument that really is not UTF-8 matches no name.
ARGV.map! { |arg| arg.dup.force_encoding(Encoding::UTF_8) }
ARGV.map! { |arg| arg.valid_encoding? ? arg : arg.scrub('?') }

def value_of(flag)
  at = ARGV.index(flag)
  at && ARGV[at + 1]
end

# The words after --revoke, up to the next switch: a device is called
# "motorola edge 70 fusion", and somebody who types that after --revoke
# has said which device they mean -- with or without quotes around it.
def revoke_words
  at = ARGV.index('--revoke')
  at ? ARGV.drop(at + 1).take_while { |word| !word.start_with?('--') } : []
end

# With --json every answer is one object and the status is 0, as wherever
# a program asks: the status says that an answer arrived, the object says
# what it was. A sentence written for the terminal loses its mark on the way.
JSON_OUT = ARGV.include?('--json')
# Set by scripts/remote.rb: the request came through the door.
REMOTE = ENV['BLOG_SH_REMOTE'] == '1'
# How long a program waits for the key file when somebody else is
# changing it, before it is told to come back.
LOCK_SECONDS = 5

def answer(object)
  puts JSON.generate(object)
  exit 0
end

def refuse(code, message)
  answer('ok' => false, 'error' => code, 'message' => message.sub(/\A\s*❌\s*/, '')) if JSON_OUT
  abort message
end

KNOWN = %w[--list --revoke --host --port --no-wait --json].freeze
with_value = %w[--host --port]
skip = false
named = revoke_words.size
unknown = ARGV.each_with_index.reject do |arg, i|
  if skip
    skip = false
    next true
  end
  at = ARGV.index('--revoke')
  next true if at && i > at && i <= at + named

  skip = with_value.include?(arg)
  KNOWN.include?(arg)
end.map(&:first)
refuse('bad_args', t('unknown_option', option: unknown.join(' '))) unless unknown.empty?
with_value.each { |flag| refuse('bad_args', t('needs_value', option: flag)) if ARGV.include?(flag) && value_of(flag).to_s.empty? }
# A program gets two things and nothing else: the list, and its own way
# out. `--revoke Telefon --json` is refused here rather than read as
# "the caller": a name after --revoke means somebody else, and that is
# not a program's to ask. And what came through the door is a program
# whatever it says -- without --json it would be a code on a screen
# nobody is looking at.
if JSON_OUT || REMOTE
  asked = %w[--list --revoke].select { |word| ARGV.include?(word) }
  refuse('bad_args', t('json_scope')) unless JSON_OUT && asked.size == 1 && (ARGV - ['--json', asked.first]).empty?
end
# The file every road below reads or writes, asked for once here: a path
# that cannot be expanded is said in a sentence, not in a backtrace.
begin
  Pairing.keys_file
rescue Pairing::Refused => e
  refuse('keys_path', t('keys_path_bad', path: e.message))
end

def site_name
  data = begin
    YamlCompat.load_file(SITE_YML)
  rescue StandardError
    nil
  end
  data.is_a?(Hash) ? data.dig('site', 'short_name').to_s : ''
end

# A file that would not be written is said in a sentence, with its name:
# this is the file that decides who may log in, and a backtrace about it
# is the last thing anybody should have to read.
def keys_guarded
  yield
rescue SystemCallError => e
  refuse('write_failed', t('write_failed', path: Pairing.keys_file, error: e.message))
end

# ...and one that cannot be read, likewise: through the door nothing is
# swept first, so the list is the first thing to find that out.
def keys_read
  yield
rescue SystemCallError => e
  refuse('read_failed', t('read_failed', path: Pairing.keys_file, error: e.message))
end

# Whatever was asked, the doors left open by a terminal that was closed
# are shut first: their keys stopped working when their minute passed,
# and this takes their lines out.
#
# ...and the line of a device let in before a line said whose it is gets
# the word it lacks, so that the device can be told from the others the
# next time it connects. A courtesy and not a condition: beside a file
# that cannot be written, --list still lists.
#
# Both at the terminal only. Through the door a list is a read and writes
# nothing, and the one thing a device may change there is its own line.
unless REMOTE
  keys_guarded { Pairing.sweep(root: ROOT) }
  begin
    Pairing.identify(root: ROOT)
  rescue SystemCallError, ArgumentError
    nil
  end
end

# Which device is asking: the fingerprint its own line handed the door,
# and only when a line of this blog really holds that key. Anything else
# -- a line written by hand, one from before the word, a variable somebody
# set -- is nobody.
def asking(devices)
  said = ENV['BLOG_SH_DEVICE'].to_s
  said.match?(Pairing::PRINT) && devices.any? { |device| device['fingerprint'] == said } ? said : nil
end

# A fingerprint as ssh-keygen and --list print it.
def printed(fingerprint)
  fingerprint.to_s.empty? ? '' : "SHA256:#{fingerprint}"
end

def for_a_program(devices, me)
  devices.map do |device|
    { 'name' => device['name'], 'fingerprint' => printed(device['fingerprint']), 'self' => !me.nil? && device['fingerprint'] == me }
  end
end

if ARGV.include?('--list')
  devices = keys_read { Pairing.devices(root: ROOT) }
  if JSON_OUT
    me = asking(devices)
    answer('ok' => true, 'devices' => for_a_program(devices, me), 'self' => me && printed(me))
  end
  if devices.empty?
    puts t('list_none')
  else
    puts t('list_head')
    devices.each_with_index do |device, i|
      puts t('list_row', number: i + 1, name: device['name'], fingerprint: device['fingerprint'])
    end
  end
  exit 0
end

# Which device --revoke means. Said outright it is a name (every device
# of that name goes), a number from --list, or a fingerprint. Said by
# nobody, somebody at a terminal is asked: about the only device where
# there is one, by number where there are several -- and nothing is taken
# out without a yes, because the next thing that device does is fail.
def device_to_revoke(devices)
  said = revoke_words.join(' ').strip
  unless said.empty?
    return said if devices.any? { |device| device['name'] == said }

    numbered = said.match?(/\A\d+\z/) ? devices[said.to_i - 1] : nil
    return said_by(numbered) if numbered && said.to_i.positive?

    return said
  end
  abort t('revoke_needs_device') unless Tui.interactive?
  abort t('list_none') if devices.empty?

  chosen = devices.first
  if devices.size > 1
    puts t('list_head')
    devices.each_with_index { |device, i| puts t('list_row', number: i + 1, name: device['name'], fingerprint: device['fingerprint']) }
    print t('q_revoke_which', count: devices.size)
    number = $stdin.gets.to_s.strip
    chosen = number.match?(/\A\d+\z/) && number.to_i.positive? ? devices[number.to_i - 1] : nil
    abort t('revoke_none', which: number) unless chosen
  end
  print t('q_revoke', device: chosen['name'])
  exit 0 unless Tui.yes?($stdin.gets)

  said_by(chosen)
end

# What a device picked off the list is taken out by: its key's
# fingerprint -- one device, whatever else shares its name -- and, where
# the key cannot be read and there is no fingerprint, its line as it
# stands. (With a fingerprint of nothing for such a line, its number
# named no device at all.)
def said_by(device)
  device['fingerprint'].empty? ? device['line'] : device['fingerprint']
end

# A device's own way out. By its key and by nothing else -- two devices
# may share a name, and every name is on the list for anybody to read.
if ARGV.include?('--revoke') && JSON_OUT
  me = asking(keys_read { Pairing.devices(root: ROOT) })
  refuse('device_unknown', t('device_unknown')) unless me
  gone = begin
    keys_guarded { Pairing.revoke_key(root: ROOT, print: me, wait: LOCK_SECONDS) }
  rescue Pairing::Refused => e
    raise unless e.reason == :busy

    refuse('busy', t('busy'))
  end
  # Taken out by somebody at the terminal between the look and the lock.
  refuse('device_unknown', t('device_unknown')) unless gone
  answer('ok' => true, 'revoked' => { 'name' => gone['name'], 'fingerprint' => printed(gone['fingerprint']) },
         'devices' => for_a_program(Pairing.devices(root: ROOT), nil), 'self' => nil)
end

if ARGV.include?('--revoke')
  which = device_to_revoke(Pairing.devices(root: ROOT))
  gone = keys_guarded { Pairing.revoke(root: ROOT, which: which) }
  abort t('revoke_none', which: revoke_words.join(' ')) if gone.empty?

  gone.each { |device| puts t('revoked', device: device) }
  exit 0
end

abort t('no_keygen') unless Pairing.keygen?

guess_host, guess_port = Pairing.guess_address
port = (value_of('--port') || guess_port).to_i
abort t('needs_value', option: '--port') unless port.between?(1, 65_535)

# Nothing to connect to is the one failure worth stopping for before a key
# is made: the app would read the code, try, and report a refusal about a
# server that was never listening.
unless Pairing.ssh_answers?(port)
  warn t('no_sshd', port: port)
  warn(if File.exist?('/.dockerenv') then t('container')
       elsif RUBY_PLATFORM.include?('darwin') then t('no_sshd_mac')
       else t('no_sshd_other')
       end)
  exit 1
end

# sshd answering is not the whole of it on a Mac: a blog in Documents, on
# the Desktop or in iCloud Drive is out of its reach unless full disk
# access for remote users is on, which nothing here can see. Said, not
# refused -- the switch may well be on.
if RUBY_PLATFORM.include?('darwin') && !File.exist?('/.dockerenv') && (folder = Pairing.protected_folder(ROOT))
  warn Tui.paint(t('protected_folder_mac', folder: folder), :yellow)
end

host = value_of('--host').to_s
if host.empty?
  host = guess_host
  if Tui.interactive? && !ARGV.include?('--no-wait')
    print t('q_address', address: guess_host)
    typed = $stdin.gets.to_s.strip
    host = typed unless typed.empty?
  end
end
# An address goes into a link and onto a screen: a name or a number, no
# spaces and nothing that would end either.
abort t('bad_address', address: host) unless host.match?(/\A[A-Za-z0-9.:_-]{1,253}\z/)

started = keys_guarded { Pairing.start(root: ROOT, host: host, port: port, site: site_name) }
id = started[:id]

puts
puts t('intro', site: site_name.empty? ? './blog.sh' : site_name, time: started[:expires].localtime.strftime('%H:%M'))
puts
qr = QrCode.render(started[:code])
if qr.nil? && Tui.interactive?
  puts Tui.paint(t('code_too_long'), :yellow)
  puts
end
if qr && Tui.interactive?
  rows = qr.lines.size
  cols = qr.lines.first.to_s.chomp.length
  fits = lambda do
    height, width = IO.console ? IO.console.winsize : [rows, cols]
    width >= cols && height >= rows + 4
  end
  # A window too small for the code is asked to grow before it is given
  # up on. The code needs some sixty columns by thirty-five rows and a
  # terminal opens at eighty by twenty-four -- so the first thing somebody
  # who has never used a terminal saw was a sentence about window sizes.
  # A terminal that takes the request (xterm's, which Terminal on a Mac
  # honours) is tall enough a moment later; one that does not is told
  # what it was told before.
  unless fits.call
    print "\e[8;#{rows + 6};#{[cols + 2, 80].max}t"
    $stdout.flush
    sleep 0.4
  end
  if !fits.call
    puts Tui.paint(t('small_window', cols: cols, rows: rows + 4), :yellow)
  else
    puts t('how')
    puts
    # Black on white said outright: left to the terminal's own colours a
    # dark window draws the code inverted, and not every reader takes that.
    qr.each_line { |line| puts(Tui.color? ? "\e[30;107m#{line.chomp}\e[0m" : line.chomp) }
  end
  puts
end
puts t('as_text')
puts started[:code]
puts

exit 0 if ARGV.include?('--no-wait')

# The door is closed by whoever opened it, however this ends: Ctrl-C, a
# closed window, the code running out.
closed = false
close = lambda do |message|
  next if closed

  closed = true
  came = begin
    Pairing.cancel(root: ROOT, id: id)
  rescue SystemCallError => e
    warn t('write_failed', path: Pairing.keys_file, error: e.message)
    nil
  end
  # Somebody came through in the very moment this was being closed: the
  # door is theirs now, and saying "cancelled" over it would be saying
  # that a device which is in is not.
  if came
    puts Tui.paint(t('paired', device: came), :green)
    puts Tui.paint(t('paired_note'), :dim)
    puts
    exit 0
  end
  puts message
end
# A signal only raises a flag: a handler may not take a lock or write a
# file, and closing the door does both. The loop below looks at the flag
# four times a second.
interrupted = false
%w[INT TERM HUP].each { |signal| Signal.trap(signal) { interrupted = true } }

puts Tui.paint(t('waiting'), :dim)
loop do
  if interrupted
    close.call(t('cancelled'))
    puts
    exit 130
  end
  known = Pairing.record(ROOT, id)
  if known && known['state'] == 'paired'
    closed = true
    puts Tui.paint(t('paired', device: known['device']), :green)
    puts Tui.paint(t('paired_note'), :dim)
    puts
    exit 0
  end
  if Time.now >= started[:expires]
    close.call(t('expired'))
    puts
    exit 1
  end
  sleep 0.25
end
