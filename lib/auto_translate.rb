# frozen_string_literal: true

# A post's words in another language, written by a program the author
# names -- and never saved by it.
#
# What this file is for: handing a document to a translator, taking the
# answer back in a shape `add` can read, and saying what looks wrong with
# it. What it is NOT for: knowing any one provider. The translator is an
# adapter behind one call, `translate(instructions, document)`, chosen in
# env.sh; the engine does not know whose model answers.
#
#   TRANSLATOR=command          a program that reads standard input and
#   TRANSLATOR_COMMAND='...'    writes the translation to standard output
#   TRANSLATOR_TIMEOUT=300      seconds it may take (default 300)
#   TRANSLATOR_REMOTE=allow     lets a paired device ask for a translation
#
# The settings live in env.sh, not in config/site.yml: that file travels
# with the site's content, and a line there must never be able to name a
# program the engine will run.
#
# A translation is paid for by someone and sent to someone: the text of
# the post leaves the machine for whatever the translator is. So a program
# running over the paired-device road (BLOG_SH_REMOTE) is turned away
# unless the server said it may -- a lost phone must not be able to spend
# the owner's money or send the owner's drafts anywhere.
require 'open3'
require 'set'
require 'shellwords'

module AutoTranslate
  DEFAULT_SECONDS = 300

  # What went wrong, with a code a program can act on and the words for a
  # person; the words are the caller's (locales), the code is ours.
  class Error < StandardError
    attr_reader :code, :detail

    def initialize(code, detail = '')
      @code = code
      @detail = detail.to_s
      super("#{code}: #{@detail}")
    end
  end

  # Adapters answer `translate(instructions, document)` with the translated
  # document as a string, or raise Error. Registered by the name that
  # TRANSLATOR carries.
  ADAPTERS = {}

  module_function

  # The adapter the settings name, or an Error saying why there is none.
  def adapter(env = ENV)
    kind = env['TRANSLATOR'].to_s.strip.downcase
    kind = 'command' if kind.empty? && !env['TRANSLATOR_COMMAND'].to_s.strip.empty?
    raise Error.new('translator_not_set') if kind.empty?
    raise Error.new('translator_unknown', kind) unless ADAPTERS.key?(kind)

    ADAPTERS.fetch(kind).call(env)
  end

  # Whether anything is set up -- what a menu or an app asks before it
  # offers the button.
  def configured?(env = ENV)
    adapter(env)
    true
  rescue Error
    false
  end

  def remote?(env = ENV)
    env['BLOG_SH_REMOTE'].to_s == '1'
  end

  def remote_allowed?(env = ENV)
    env['TRANSLATOR_REMOTE'].to_s.strip.downcase == 'allow'
  end

  # Whether THIS run may use the translator: from a terminal always (the
  # person at it is the owner), from a paired device only when allowed.
  def permitted?(env = ENV)
    !remote?(env) || remote_allowed?(env)
  end

  def seconds(env = ENV)
    value = env['TRANSLATOR_TIMEOUT'].to_s.strip
    value.match?(/\A\d+\z/) && value.to_i.positive? ? value.to_i : DEFAULT_SECONDS
  end

  # What the translator is told. Neutral on purpose: no voice, no taste,
  # nothing corrected -- the translation says what the original says.
  def instructions(lang_name, lang_code)
    <<~TEXT
      Translate this blog post into #{lang_name} (language code: #{lang_code}).

      Output ONLY the translated document, with no code fence and no comment before or after it.
      - Keep the header between the --- lines: translate the title, leave slug: empty.
      - Keep the Markdown exactly: headings, lists, emphasis, links, images, and lines such as //--more--//.
      - Translate link texts but never change a URL or the name of an image or file.
      - Keep every number, name and quotation as the original has it.
      - Say what the original says: do not add, leave out, explain, soften or correct anything, including apparent typos.
      - Keep the author's register and tone as they are; translate idioms by meaning, not word for word.
    TEXT
  end

  # The translator's answer, made into a document `add` can take: a model
  # that wrapped it in a code fence is forgiven; one that did not start
  # with the header is not.
  def clean(answer)
    text = answer.to_s.dup.force_encoding(Encoding::UTF_8).sub(/\A﻿/, '').strip
    raise Error.new('translator_empty') if text.empty?
    raise Error.new('translator_bad_output', text[0, 200]) unless text.valid_encoding?

    if text.match?(/\A```[^\n]*\n/) && text.end_with?('```')
      text = text.sub(/\A```[^\n]*\n/, '').sub(/\n?```\z/, '').strip
    end
    header = text.match(/\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\z)/m)
    raise Error.new('translator_bad_output', text[0, 200]) unless header

    fixed = no_slug(header[1])
    "---\n#{fixed}\n---\n#{text[header[0].length..]}".sub(/\n*\z/, "\n")
  end

  # The translation's address is not the translator's to invent: the
  # `slug:` line is emptied whatever it says.
  def no_slug(header)
    lines = header.split("\n", -1)
    at = lines.index { |line| line.match?(/\Aslug[ \t]*:/) }
    at ? lines[at] = 'slug:' : lines << 'slug:'
    lines.join("\n")
  end

  # The document as `add` reads it back: the keys that make it a
  # translation go before the header's closing line.
  def as_file(translated, slug:, base:, lang:)
    translated.sub(/\A---\n(.*?)\n---\n/m) { "---\n#{Regexp.last_match(1)}\nedits: #{slug}\nbase: #{base}\nlang: #{lang}\n---\n" }
  end

  # What is different between the original and its translation in the
  # things a translator is known to damage and a reader does not notice:
  # an address, a file name, a number, the shape of the text. Each entry
  # is { code:, items: } -- the caller words it. A difference is a
  # warning, never a refusal: a number may be written out in words
  # legitimately; the person reading decides.
  def check(original, translated)
    a = body(original)
    b = body(translated)
    warnings = []
    add = lambda do |code, missing, extra|
      next if missing.empty? && extra.empty?

      warnings << { code: code, items: { missing: missing.sort, extra: extra.sort } }
    end

    urls_a = urls(a)
    urls_b = urls(b)
    add.call('urls', (urls_a - urls_b).to_a, (urls_b - urls_a).to_a)
    files_a = images(a)
    files_b = images(b)
    add.call('images', (files_a - files_b).to_a, (files_b - files_a).to_a)
    numbers_a = numbers(a)
    numbers_b = numbers(b)
    add.call('numbers', (numbers_a - numbers_b).to_a, (numbers_b - numbers_a).to_a)

    shape = { 'headings' => headings(a), 'paragraphs' => paragraphs(a), 'markers' => markers(a) }
    shape.each do |code, count|
      other = { 'headings' => headings(b), 'paragraphs' => paragraphs(b), 'markers' => markers(b) }[code]
      warnings << { code: code, items: { was: count, now: other } } unless count == other
    end
    warnings
  end

  # Everything under the header.
  def body(document)
    document.to_s.sub(/\A---[ \t]*\n.*?\n---[ \t]*(?:\n|\z)/m, '')
  end

  def urls(text)
    text.scan(%r{https?://[^\s)>\]"'<]+}).map { |url| url.sub(/[.,;:!?]+\z/, '') }.to_set
  end

  def images(text)
    text.scan(/!\[[^\]]*\]\(\s*([^)\s]+)/).flatten.to_set
  end

  # The digits of the prose: an address is taken out first (its numbers
  # are the address's), and a number is compared as the digits it has.
  def numbers(text)
    text.gsub(%r{https?://\S+}, ' ').gsub(/!?\[[^\]]*\]\([^)]*\)/) { |link| link[/\[([^\]]*)\]/, 1].to_s }
        .scan(/\d+/).to_set
  end

  def headings(text)
    text.scan(/^\#{1,6}[ \t]+\S/).length
  end

  def paragraphs(text)
    text.split(/\n[ \t]*\n/).count { |piece| !piece.strip.empty? }
  end

  def markers(text)
    text.scan(%r{^//--.*--//[ \t]*$}).length
  end

  # The whole of one translation: the answer of the adapter, cleaned, and
  # what looks wrong with it. { text:, warnings: }.
  def translate(original_document, lang_name:, lang_code:, env: ENV)
    translator = adapter(env)
    answer = translator.translate(instructions(lang_name, lang_code), original_document)
    text = clean(answer)
    { text: text, warnings: check(original_document, text) }
  end
end

module AutoTranslate
  # A program that reads the instructions and the post on standard input
  # and writes the translation to standard output -- `claude -p`, a Gemini
  # or Codex command line, `ollama run <model>`, a script of one's own.
  #
  # Run WITHOUT a shell: TRANSLATOR_COMMAND is split into words the way a
  # shell would split it and the program is started with them, so nothing
  # in a post or a setting can add a second command. In a process group of
  # its own, so that a translator that outlives its time is stopped with
  # everything it started.
  class CommandAdapter
    def initialize(command, seconds)
      @argv = Shellwords.split(command.to_s)
      @seconds = seconds
      raise Error.new('translator_not_set') if @argv.empty?
    rescue ArgumentError => e
      raise Error.new('translator_failed', e.message)
    end

    def translate(instructions, document)
      run("#{instructions}\n---- THE POST ----\n#{document}")
    end

    private

    def run(input)
      out = err = nil
      status = nil
      Open3.popen3(*@argv, pgroup: true) do |stdin, stdout, stderr, waiter|
        feeder = Thread.new do
          stdin.write(input)
        rescue SystemCallError, IOError
          nil
        ensure
          stdin.close unless stdin.closed?
        end
        readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
        if waiter.join(@seconds).nil?
          stop(waiter)
          raise Error.new('translator_timeout', @seconds)
        end
        feeder.join(1)
        out, err = readers.map(&:value)
        status = waiter.value
      end
      unless status.success?
        raise Error.new('translator_failed', "#{@argv.first} ended with #{status.exitstatus.inspect}: #{tail(err)}")
      end

      out
    rescue Errno::ENOENT
      raise Error.new('translator_failed', "#{@argv.first}: command not found")
    rescue Errno::EACCES
      raise Error.new('translator_failed', "#{@argv.first}: not allowed to run it")
    end

    def stop(waiter)
      Process.kill('TERM', -waiter.pid)
      waiter.join(5) || Process.kill('KILL', -waiter.pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def tail(text)
      text.to_s.force_encoding(Encoding::UTF_8).scrub.strip[-300..] || text.to_s.strip
    end
  end

  ADAPTERS['command'] = ->(env) { CommandAdapter.new(env['TRANSLATOR_COMMAND'], AutoTranslate.seconds(env)) }
end

require_relative 'auto_translate_http'
