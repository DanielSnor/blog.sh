#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/enroll.rb -- what scripts/enroll.sh hands over to: one line of
# JSON in, the app's key written where the pairing code's was, one object
# out. Everything that decides is in lib/pairing.rb; this reads and
# answers.
#
# The reading is bounded on both sides, as remote.rb's is: a line may be
# so long and take so long to arrive, because whoever is on the other end
# holds a key that was on a screen.
require 'json'
require 'timeout'

# No LANG under sshd: standard input would be read as bytes with no name,
# and a device called "Danielův iPhone" is UTF-8.
Encoding.default_external = Encoding::UTF_8
$stdin.set_encoding(Encoding::UTF_8)
$stdout.set_encoding(Encoding::UTF_8)

ROOT = File.expand_path('..', __dir__)
LIMIT = 4096
SECONDS = 30

require_relative '../lib/pairing'

def answer(object)
  puts JSON.generate(object)
  exit 0
end

MESSAGES = {
  unknown_code: 'This code is not one this blog is waiting for.',
  used: 'This code has already been used.',
  expired: 'This code has run out. Ask for a new one with ./blog.sh pair.',
  bad_key: 'The key has to be one ed25519 public key, as OpenSSH writes it.',
  key_in_use: 'This key already opens something else on this account, and a key opens one thing. Make a key for this blog alone.',
  bad_request: 'Send one line of JSON: {"key": "ssh-ed25519 ...", "name": "..."}.'
}.freeze

def refuse(reason)
  answer('ok' => false, 'error' => reason.to_s, 'message' => MESSAGES.fetch(reason, reason.to_s))
end

line = begin
  Timeout.timeout(SECONDS) { $stdin.gets(LIMIT + 1) }
rescue Timeout::Error
  nil
end
refuse(:bad_request) if line.nil? || line.bytesize > LIMIT || !line.valid_encoding?

request = begin
  JSON.parse(line)
rescue JSON::ParserError
  nil
end
refuse(:bad_request) unless request.is_a?(Hash) && request['key'].is_a?(String)

begin
  device = Pairing.enroll(root: ROOT, id: ARGV[0].to_s, key: request['key'], name: request['name'])
  answer('ok' => true, 'device' => device)
rescue Pairing::Refused => e
  refuse(e.reason)
rescue StandardError => e
  # A file that could not be written, a record that will not parse: said
  # as a failure of this end, in one line, never as a backtrace.
  answer('ok' => false, 'error' => 'engine_failed', 'message' => e.message.to_s.lines.first.to_s.strip[0, 300])
end
