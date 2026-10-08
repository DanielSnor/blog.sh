#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/pair.rb -- `./blog.sh pair`: let an app in by showing it a code.
#
#   ./blog.sh pair                    shows a code and waits for the app
#   ./blog.sh pair --list             the devices let in this way
#   ./blog.sh pair --revoke <name>    takes one out (a name or a fingerprint)
#
#   --host <address> --port <n>       where the app is to connect, when the
#                                     guess is wrong or nobody is there to ask
#   --no-wait                         prints the code and leaves; the code
#                                     keeps its ten minutes
#
# What a code is and what happens when one is read is in lib/pairing.rb.
# This is the screen: it checks that an app would have something to
# connect to, asks the one thing it cannot know -- the address this
# machine has from where the phone is -- draws the code, and waits.
#
# The way in by hand, a line written into authorized_keys, is untouched
# by any of this and stays what docs/operations.md describes.
require 'io/console'
require_relative '../lib/yaml_compat'
require_relative '../lib/config_lang'

ROOT = File.expand_path('..', __dir__)
SITE_YML = File.join(ROOT, 'config', 'site.yml')

require_relative '../lib/i18n'
lang = ConfigLang.of(SITE_YML)
I18n.force_lang(lang.to_s.empty? ? 'en' : lang.to_s)

require_relative '../lib/tui'
require_relative '../lib/qr_code'
require_relative '../lib/pairing'

$stdout.sync = true

def t(key, **vars)
  I18n.t("pair.#{key}", **vars)
end

def value_of(flag)
  at = ARGV.index(flag)
  at && ARGV[at + 1]
end

KNOWN = %w[--list --revoke --host --port --no-wait].freeze
with_value = %w[--revoke --host --port]
skip = false
unknown = ARGV.reject do |arg|
  if skip
    skip = false
    next true
  end
  skip = with_value.include?(arg)
  KNOWN.include?(arg)
end
abort t('unknown_option', option: unknown.join(' ')) unless unknown.empty?
with_value.each { |flag| abort t('needs_value', option: flag) if ARGV.include?(flag) && value_of(flag).to_s.empty? }

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
  abort t('write_failed', path: Pairing.keys_file, error: e.message)
end

# Whatever was asked, the doors left open by a terminal that was closed
# are shut first: their keys stopped working when their minute passed,
# and this takes their lines out.
keys_guarded { Pairing.sweep(root: ROOT) }

if ARGV.include?('--list')
  devices = Pairing.devices(root: ROOT)
  if devices.empty?
    puts t('list_none')
  else
    puts t('list_head')
    devices.each { |device| puts t('list_row', name: device['name'], fingerprint: device['fingerprint']) }
  end
  exit 0
end

if ARGV.include?('--revoke')
  which = value_of('--revoke')
  gone = keys_guarded { Pairing.revoke(root: ROOT, which: which) }
  abort t('revoke_none', which: which) if gone.empty?

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
if qr && Tui.interactive?
  rows = qr.lines.size
  cols = qr.lines.first.to_s.chomp.length
  height, width = IO.console ? IO.console.winsize : [rows, cols]
  if width < cols || height < rows + 4
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
  begin
    Pairing.cancel(root: ROOT, id: id)
  rescue SystemCallError => e
    warn t('write_failed', path: Pairing.keys_file, error: e.message)
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
