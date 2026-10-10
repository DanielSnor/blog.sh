#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/remote.rb -- `run`, the half of scripts/remote.sh that runs one
# engine command for a program on the far end of SSH.
#
# Standard input is one JSON object on ONE LINE, {"args": [...]}: the argv
# ./blog.sh would get, word by word, so nothing here is ever parsed as
# shell -- a
# series called "Procházky a výlety" travels as one word and arrives as
# one argument. The words are checked against a whitelist before the
# engine sees them: the commands a program may run, and for each the
# flags it may give. A flag that takes a value takes exactly the next word,
# whatever it holds short of a control character. Everything positional --
# a slug, `trash`, `versions` -- is held to a slug's own alphabet. --json
# is added when it is missing, so an answer is always an object.
#
# What is NOT here, on purpose: add (a post arrives as a delivery through
# `receive`; `edit` and `translate` are allowed because with --json they
# only hand the text out), export, preview, doctor's --strip-location and
# --online, check's --repair and --online, browse and the wizard. Each either opens an
# editor, asks a question, writes outside the archive or reaches the
# network on somebody else's account; a program with a key is not the
# author at their desk.
#
# Like receive.sh: an answer is an object and the status is 0, whatever
# the answer. The engine speaking prose instead (no env.sh, a config that
# will not parse, a backtrace) is wrapped as engine_failed with its words.
#
# `--deliver` is the other half: a delivery in receive.sh's own shape, read
# up to a line saying `end` (or to the end of the stream, for a sender that
# can close it) and handed to receive.sh whole on a pipe -- which is where
# the EOF receive.sh waits for comes from. Nothing about the delivery is
# judged here; every check stays in receive.sh.
require 'json'
require 'open3'

# ⚠️ The forced command runs with no LANG (sshd, docker exec, cron), and
# Ruby then reads standard input as ASCII-8BIT -- on which a UTF-8 regexp
# raises, so a series called Procházky took the whole request down with
# it, answered by nothing at all. The bytes are UTF-8 either way; only
# the label on them was wrong.
Encoding.default_external = Encoding::UTF_8
$stdin.set_encoding(Encoding::UTF_8)
$stdout.set_encoding(Encoding::UTF_8)

ROOT = File.expand_path('..', __dir__)
LIMIT = 65_536
FIRST_SECONDS = 30
# How long the REST of the request's one line may take once its first
# byte is here. FIRST_SECONDS watched only for that first byte, so a
# sender that wrote half a line and went quiet held a process for as long
# as it cared to hold the connection.
LINE_SECONDS = ENV.fetch('BLOGSH_LINE_SECONDS', '30').to_i
# Long enough for a full rebuild of a large archive and its upload -- and
# a ceiling that is kept: an engine still running after this is stopped,
# with everything it started, and the caller is told. (For as long as
# this file has existed the number was written here and read nowhere.)
RUN_SECONDS = ENV.fetch('BLOGSH_RUN_SECONDS', '1800').to_i
# A delivery's ceiling, the receiver's own plus room for the names and the
# line breaks; the receiver measures the exact one. How long the lines may
# take to keep coming is the receiver's BLOGSH_BODY_SECONDS too.
MAX_MB = ENV.fetch('BLOGSH_MAX_MB', '24').to_i
DELIVER_LIMIT = (MAX_MB.positive? ? MAX_MB : 24) * 1_048_576 * 2
BODY_SECONDS = ENV.fetch('BLOGSH_BODY_SECONDS', '600').to_i

def answer(object)
  puts JSON.generate(object)
  exit 0
end

def refuse(code, message)
  answer('ok' => false, 'error' => code, 'message' => message)
end

# The commands a program may run, each with the flags it may say. A flag
# listed with a trailing `=` takes a value, as `--flag=value` or as the
# next word; one without is a bare switch.
ALLOWED = {
  'version' => %w[],
  'list' => %w[--drafts --type= --tag= --search=],
  'drafts' => %w[],
  'edit' => %w[],
  'translate' => %w[--lang=],
  'props' => %w[--set= --drop-address= --rename= --versions --restore-version= --yes --rebuild],
  'queue' => %w[--up= --down= --move= --to=],
  'schedule' => %w[--at= --cancel --compact --allow-partial],
  'publish' => %w[--yes --no-announce --allow-partial --compact],
  'unpublish' => %w[--yes],
  'delete' => %w[--yes --rebuild],
  'restore' => %w[--rebuild],
  'rebuild' => %w[--full --force],
  'empty' => %w[--yes],
  'toot' => %w[--force],
  'bluesky' => %w[--force],
  'stats' => %w[],
  'on-this-day' => %w[--date=],
  'check' => %w[--languages],
  # The installation's diagnosis, as it stands on disk. Not --online
  # (it reaches the network on the author's accounts) and not
  # --strip-location (it rewrites photographs).
  'doctor' => %w[]
}.freeze

WORD = /\A[a-z0-9-]{1,200}\z/

# A word that is not a flag names a post. The engine makes slugs out of
# lowercase letters, digits and hyphens, and that was the rule here -- but
# it does not make every slug an archive holds: an import keeps the names
# the old system gave (b2evolution wrote underscores; fourteen posts of
# the first real archive behind this door have one), and those posts were
# listed to the app by `list` and then refused when it asked for them by
# the name it was given (fleet, 8. 10. 2026). So: what can be a file name
# and reads as a name -- letters and digits of any alphabet, `_`, `.`, `-`
# -- starting with a letter, a digit or `_`, which keeps out a hidden file,
# a way up (`..`) and anything the engine would read as a switch. Still
# no space, no separator and nothing a shell has a use for: none of them
# is in a name any writer of slugs produces, and the door stays narrower
# than the engine behind it on purpose. A mark counts as part of the
# letter it stands on once the name has begun: some alphabets write their
# vowels that way, and a volume may keep an accent apart from its letter.
SLUG = /\A[\p{L}\p{N}_][\p{L}\p{M}\p{N}._-]*\z/
SLUG_BYTES = 255

def slug?(word)
  word.bytesize <= SLUG_BYTES && word.match?(SLUG)
end

# The request's line, read against a clock: whatever has arrived by the
# first newline, by the end of the stream or by the limit -- and a refusal
# when none of the three has come in time.
def line_within(seconds)
  raw = +''
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  until raw.include?("\n") || raw.bytesize > LIMIT
    left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refuse('timeout', "The request stalled for #{seconds} seconds before its line ended, and was dropped.") if left <= 0 || IO.select([$stdin], nil, nil, left).nil?

    chunk = $stdin.read_nonblock(LIMIT + 1, exception: false)
    break if chunk.nil?

    raw << chunk.force_encoding(Encoding::UTF_8) unless chunk == :wait_readable
  end
  raw.include?("\n") ? raw[0..raw.index("\n")] : raw
end

# What went wrong, in the room an answer has for it. An engine that died
# of an exception says so on the FIRST line of what it prints -- where,
# what, and which error -- and forty lines of "from ..." after it; the
# last 600 characters of that are the bottom of the stack and nothing
# else. So a crash is answered with the line that names it, and prose --
# which ends with what matters -- with its end, as before.
def failure_words(text)
  crashed = text.lines.map(&:rstrip).find { |line| line.match?(/\.rb:\d+:in .+\([A-Z][\w:]*\)\z/) }
  crashed ? crashed[0, 600] : (text[-600..] || text)
end

# The engine, run against a clock. In a process group of its own, so that
# stopping it stops the build and the upload it started as well.
def run_engine(env, command, args)
  Open3.popen3(env, command, *args, chdir: ROOT, pgroup: true) do |stdin, stdout, stderr, runner|
    stdin.close
    said = [Thread.new { stdout.read }, Thread.new { stderr.read }]
    if runner.join(RUN_SECONDS).nil?
      %w[TERM KILL].each do |signal|
        Process.kill(signal, -runner.pid)
        break if runner.join(5)
      rescue SystemCallError
        break
      end
      refuse('timeout', "The engine was still running after #{RUN_SECONDS} seconds and was stopped.")
    end
    [said[0].value.to_s, said[1].value.to_s, runner.value]
  end
end

def read_request
  ready = IO.select([$stdin], nil, nil, FIRST_SECONDS)
  refuse('empty_input', "Nothing arrived on standard input for #{FIRST_SECONDS} seconds.") if ready.nil?

  # One line, ended by its newline rather than by the end of the stream:
  # an SSH library without a half-close (the app's) could never signal
  # EOF, and JSON.generate never breaks a line, so the newline is enough.
  raw = line_within(LINE_SECONDS)
  refuse('empty_input', 'Nothing arrived on standard input.') if raw.strip.empty?
  refuse('too_large', "The request is over #{LIMIT} bytes.") if raw.bytesize > LIMIT

  request = begin
    JSON.parse(raw)
  rescue JSON::ParserError
    refuse('bad_json', 'The request is not a JSON object.')
  end
  refuse('bad_json', 'The request is not a JSON object with "args".') unless request.is_a?(Hash) && request['args'].is_a?(Array)
  args = request['args']
  refuse('bad_args', 'Every argument has to be a string.') unless args.all? { |a| a.is_a?(String) }
  refuse('bad_args', 'The first argument is the command.') if args.empty?
  [args, spoken(request['lang'])]
end

# The language the caller reads: `"lang": "cs"` beside the args. The blog
# speaks its own language, and an app in Czech showing an English blog's
# diagnosis shows English -- reported twice by the first person to try it
# (Pavel, 8. 10. 2026). Where the answer is sentences for a person and
# nothing is built -- `check` and `doctor` -- the engine says them in the
# language asked for, if it has one by that name.
#
# Only a language the engine ships a locale for, and by its exact name:
# anything else -- missing, not a string, a path, a language nobody
# translated -- is the blog's own language, as before. Never a refusal:
# an app that sends its locale must not be turned away for being Finnish.
def spoken(lang)
  return nil unless lang.is_a?(String) && lang.match?(/\A[a-z]{2,3}\z/)

  File.file?(File.join(ROOT, 'locales', "#{lang}.yml")) ? lang : nil
end

def clean?(value)
  value.valid_encoding? && value.bytesize <= 4000 && !value.match?(/[\u0000-\u001f\u007f]/)
end

def check(args)
  command = args.first
  flags = ALLOWED[command]
  refuse('unknown_command', "#{command.inspect} is not a command a program may run.") unless flags && command.match?(WORD)

  rest = args.drop(1)
  until rest.empty?
    word = rest.shift
    refuse('bad_args', 'An argument holds a control character or is too long.') unless clean?(word)
    if word.start_with?('--')
      next if word == '--json'

      name, inline = word.split('=', 2)
      if flags.include?("#{name}=")
        next unless inline.nil?

        value = rest.shift
        refuse('bad_args', "#{name} needs a value after it.") if value.nil? || value.start_with?('--')
        refuse('bad_args', 'An argument holds a control character or is too long.') unless clean?(value)
      elsif flags.include?(name) && inline.nil?
        next
      else
        refuse('bad_args', "#{command} may not take #{name} here.")
      end
    else
      refuse('bad_args', "#{word.inspect} is not a slug.") unless slug?(word)
    end
  end
  args.include?('--json') ? args : args + ['--json']
end

# The delivery, line by line, up to `end`. A line is a name, a line of
# base64 or the closing dot of receive.sh's frame; `end` is none of those
# -- three characters are not a base64 line, and a file called `end` is
# the one name this road cannot carry. The bytes go to receive.sh exactly
# as they came, newline for newline.
def deliver
  collected = +''
  deadline = FIRST_SECONDS
  loop do
    ready = IO.select([$stdin], nil, nil, deadline)
    refuse('timeout', "The delivery stalled for #{deadline} seconds and was dropped.") if ready.nil?

    line = $stdin.gets
    break if line.nil? || line.chomp == 'end'

    collected << line
    refuse('too_large', "The delivery is over #{DELIVER_LIMIT / 1_048_576} MB on the wire.") if collected.bytesize > DELIVER_LIMIT
    deadline = BODY_SECONDS
  end
  refuse('empty_input', 'Nothing arrived before the end.') if collected.strip.empty?

  # ⚠️ [path, name], never the bare path: a single string with a space in
  # it is handed to a shell, which splits it -- and an iCloud folder on a
  # Mac has one (the iCloud documents folder). The first delivery from the app
  # died with the shell complaining that half the path did not exist.
  receiver = File.join(ROOT, 'scripts', 'receive.sh')
  out, err, = begin
    Open3.capture3([receiver, 'receive.sh'], chdir: ROOT, stdin_data: collected)
  rescue SystemCallError => e
    refuse('engine_failed', "Could not run the receiver: #{e.message}")
  end
  if out.lstrip.start_with?('{')
    print out
    exit 0
  end
  reason = "#{out}\n#{err}".scrub('').gsub(/[\u0000-\u0008\u000b-\u001f\u007f]/, '').strip.tr("\n", ' ')
  refuse('engine_failed', failure_words(reason))
end

deliver if ARGV.first == '--deliver'

args, speak = read_request
args = check(args)

engine = File.join(ROOT, 'blog.sh')
# BLOG_SH_SPEAK is named or UNSET, never inherited: what the forced
# command's own environment says is not what this caller asked for.
out, err, status = begin
  run_engine({ 'BLOG_SH_REMOTE' => '1', 'BLOG_SH_SPEAK' => speak }, [engine, 'blog.sh'], args)
rescue SystemCallError => e
  refuse('engine_failed', "Could not run the engine: #{e.message}")
end
out = out.force_encoding(Encoding::UTF_8)
err = err.force_encoding(Encoding::UTF_8)

if out.lstrip.start_with?('{')
  print out
  exit 0
end
reason = failure_words("#{out}\n#{err}".scrub('').gsub(/[\u0000-\u0008\u000b-\u001f\u007f]/, '').strip)
refuse('engine_failed', "#{reason.tr("\n", ' ')} (status #{status.exitstatus})")
