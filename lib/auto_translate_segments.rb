# frozen_string_literal: true

# Translators that are not language models: DeepL and LibreTranslate. They
# take no instructions -- they translate text -- so a post cannot be handed
# to them whole: they would translate the Markdown with it, and an address,
# a code span or the `- ` of a list item is not theirs to change.
#
# So the document is taken apart here and put back together after:
#
# - the header: only the title is sent; `slug:` stays empty.
# - the body, line by line: a fenced code block, a `//--more--//` line, a
#   line of HTML and an empty line are kept as they are; anything else is
#   split into what marks it (`## `, `- `, `1. `, `> `, the spaces in front,
#   a hard break at the end) and its text, and only the text is sent.
# - inside the text, whatever must come back unchanged -- a code span, the
#   `](address)` of a link or a picture, a bare address, an HTML tag, the
#   `**` and `_` of emphasis -- is replaced by a tag the service is told to
#   keep (`<x i="3"/>`), and put back from the answer. A code span and an
#   address stand where a word of the sentence stands, so they go WITH their
#   words, in a tag the service is told not to translate
#   (`<x i="0">code</x>`): sent as an empty tag, "a heading with `code`"
#   came back as "a heading with a picture `code`" -- the service guessed a
#   noun for the gap.
#
# What comes out is checked like any other translation
# (AutoTranslate.check): an address or a number that did not survive is a
# warning, not a silence.
#
#   TRANSLATOR=deepl            TRANSLATOR_KEY (a free key ends in :fx and goes
#                               to api-free.deepl.com); TRANSLATOR_URL to point
#                               elsewhere; TRANSLATOR_DEEPL_EN=EN-GB and
#                               TRANSLATOR_DEEPL_PT=PT-BR for the other variant
#   TRANSLATOR=libretranslate   TRANSLATOR_URL (a server of one's own, http on
#                               this machine too); TRANSLATOR_KEY if it wants one
module AutoTranslate
  module Segments
    FENCE = /\A\s*(```|~~~)/
    MARKER = %r{\A//--.*--//\s*\z}
    HTML_LINE = /\A\s*<[A-Za-z!\/]/
    # What marks a line: indentation, quote markers, then a heading, a list
    # bullet or a number.
    PREFIX = /\A(\s*(?:>[ \t]?)*\s*(?:\#{1,6}[ \t]+|[-*+][ \t]+|\d+[.)][ \t]+)?)(.*?)([ \t]{2,}|\\)?\z/m
    # Kept as they are inside the text, in this order.
    # Which of KEEP go with their words (a code span, an address).
    WORDED = [0, 3, 4].freeze
    KEEP = [
      /`+[^`]*`+/,                         # a code span
      /\]\([^)]*\)/,                       # `](address "title")` of a link or a picture
      /!?\[/,                              # where a link or a picture begins
      %r{<https?://[^>]+>},                # an address in angle brackets
      %r{https?://[^\s<>"')\]]+},          # a bare address
      %r{</?[A-Za-z][^>]*>},               # an HTML tag
      /\*{1,3}|_{1,3}|~~/,                 # emphasis
      /\|/                                 # a table's column
    ].freeze

    module_function

    # Splits a document into the texts to translate and a way to put the
    # translations back: returns [texts, assemble], where assemble takes the
    # translated texts in the same order and gives the document.
    def split(document, tag: :xml)
      header = document.to_s.match(/\A---[ \t]*\n(.*?)\n---[ \t]*\n?/m)
      body = header ? document[header[0].length..] : document.to_s
      texts = []
      parts = []

      title = header && header[1][/^title:[ \t]*(.*)$/, 1].to_s.strip
      title_at = nil
      if title && !title.empty?
        title_at = texts.length
        texts << mask(title, tag)
      end

      fenced = false
      body.split("\n", -1).each do |line|
        if line.match?(FENCE)
          fenced = !fenced
          parts << line
        elsif fenced || line.strip.empty? || line.match?(MARKER) || line.match?(HTML_LINE)
          parts << line
        else
          lead, text, tail = line.match(PREFIX).captures
          if text.strip.empty?
            parts << line
          else
            parts << [lead, texts.length, tail.to_s]
            texts << mask(text, tag)
          end
        end
      end

      assemble = lambda do |translated|
        out = parts.map do |part|
          next part if part.is_a?(String)

          lead, at, tail = part
          "#{lead}#{unmask(translated[at], texts[at])}#{tail}"
        end
        new_title = title_at ? unmask(translated[title_at], texts[title_at]) : ''
        "---\ntitle: #{new_title.gsub(/\s*\n\s*/, ' ')}\nslug:\n---\n#{out.join("\n")}"
      end
      [texts.map { |masked| masked[:sent] }, assemble]
    end

    # The text as it is sent (`sent`) and what each tag stands for (`kept`).
    def mask(text, tag)
      kept = []
      glued = []
      sent = +''
      rest = text
      until rest.empty?
        found = KEEP.each_with_index.filter_map { |re, n| (m = rest.match(re)) && [m.begin(0), m, n] }.min_by(&:first)
        unless found
          sent << escape(rest)
          break
        end
        at, match, kind = found
        sent << escape(rest[0, at])
        sent << placeholder(kept.length, tag, WORDED.include?(kind) ? match[0].delete('`<>') : nil)
        kept << match[0]
        rest = rest[(at + match[0].length)..]
        glued << rest.match?(/\A[[:alpha:]]/)
      end
      { sent: sent, kept: kept, glued: glued }
    end

    # Empty, or holding the words it stands for, kept from translation:
    # DeepL by `ignore_tags`, LibreTranslate by `translate="no"`.
    def placeholder(index, tag, words = nil)
      if tag == :html
        %(<x i="#{index}" translate="no">#{escape(words.to_s)}</x>)
      elsif words
        %(<x i="#{index}">#{escape(words)}</x>)
      else
        %(<x i="#{index}"/>)
      end
    end

    # The translation with every tag put back. A tag the service lost is a
    # piece of Markdown missing -- what is left is still the text, and the
    # check against the original says what went.
    def unmask(translated, masked)
      kept = masked[:kept]
      put = ->(m) { kept[m.to_i].to_s }
      # A language that declines its nouns hangs an ending on the kept words
      # ("s `code`m"): letters stuck to the tag that the original did not
      # have there are the service's, and go.
      text = translated.to_s.gsub(%r{<x\s+i="(\d+)"[^>/]*>.*?</x>([[:alpha:]]*)}m) do
        at = Regexp.last_match(1)
        ending = Regexp.last_match(2)
        put.call(at) + (masked[:glued].to_a[at.to_i] ? ending : '')
      end
      text = text.gsub(%r{<x\s+i="(\d+)"[^>]*/>}) { put.call(Regexp.last_match(1)) }
      unescape(text.gsub(%r{</?x\b[^>]*>}, ''))
    end

    def escape(text)
      text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end

    def unescape(text)
      text.gsub('&lt;', '<').gsub('&gt;', '>').gsub('&quot;', '"').gsub('&#39;', "'").gsub('&amp;', '&')
    end
  end

  # What the two have in common: no model, the language given by its code,
  # the texts sent in batches, and the document put together here.
  class SegmentAdapter < HttpAdapter
    BATCH = 50
    attr_writer :lang

    def translate(_instructions, document)
      raise Error.new('translator_failed', 'no target language') if @lang.to_s.empty?

      texts, assemble = Segments.split(document, tag: tag)
      translated = texts.each_slice(BATCH).flat_map { |batch| request(batch) }
      raise Error.new('translator_empty') unless translated.length == texts.length

      assemble.call(translated)
    end

    private

    def needs_model?
      false
    end

    def request(batch)
      uri = address(endpoint)
      request = Net::HTTP::Post.new(uri)
      request['content-type'] = 'application/json'
      headers.each { |name, value| request[name] = value }
      request.body = JSON.generate(body_for(batch))
      response = send_request(uri, request)
      reply = parse(response.body)
      raise problem(response.code.to_i, reply, response) unless response.code.to_i == 200

      texts_of(reply)
    end
  end

  # DeepL's /v2/translate, with its tags kept (tag_handling: xml).
  class DeepLAdapter < SegmentAdapter
    DEFAULT_URL = 'https://api.deepl.com'
    FREE_URL = 'https://api-free.deepl.com'
    # The codes DeepL wants a variant of; the engine's `en` is one of two.
    VARIANTS = { 'EN' => %w[TRANSLATOR_DEEPL_EN EN-US], 'PT' => %w[TRANSLATOR_DEEPL_PT PT-PT] }.freeze

    def initialize(env, seconds)
      @env = env
      if env['TRANSLATOR_URL'].to_s.strip.empty? && env['TRANSLATOR_KEY'].to_s.strip.end_with?(':fx')
        env = env.to_h.merge('TRANSLATOR_URL' => FREE_URL)
      end
      super(env, seconds)
    end

    private

    def tag
      :xml
    end

    def endpoint
      "#{@base}/v2/translate"
    end

    def headers
      { 'authorization' => "DeepL-Auth-Key #{@key}" }
    end

    def target
      code = @lang.to_s.split(/[-_]/).first.to_s.upcase
      name, fallback = VARIANTS[code]
      name ? (@env[name].to_s.strip.empty? ? fallback : @env[name].to_s.strip.upcase) : code
    end

    def body_for(batch)
      { 'text' => batch, 'target_lang' => target, 'tag_handling' => 'xml', 'ignore_tags' => ['x'],
        'preserve_formatting' => true }
    end

    def texts_of(reply)
      Array(reply.is_a?(Hash) ? reply['translations'] : nil).map { |t| t.is_a?(Hash) ? t['text'].to_s : '' }
    end

    # DeepL says a refused key with 403 and a used-up quota with 456.
    def problem(status, reply, response)
      message = scrub((reply.is_a?(Hash) && reply['message']) || response.body.to_s)[0, 300]
      code = case status
             when 401, 403 then 'translator_invalid_key'
             when 456 then 'translator_no_credit'
             when 429 then 'translator_rate_limited'
             when 413 then 'translator_too_long'
             else status >= 500 ? 'translator_overloaded' : 'translator_failed'
             end
      Error.new(code, code == 'translator_failed' ? "HTTP #{status}: #{message}" : message)
    end
  end

  # LibreTranslate's /translate, its HTML mode keeping the tags.
  class LibreTranslateAdapter < SegmentAdapter
    DEFAULT_URL = 'https://libretranslate.com'

    private

    # A server of one's own may want no key, wherever it is.
    def needs_key?
      false
    end

    def tag
      :html
    end

    def endpoint
      "#{@base}/translate"
    end

    def headers
      {}
    end

    def body_for(batch)
      body = { 'q' => batch, 'source' => 'auto', 'target' => @lang.to_s.split(/[-_]/).first.to_s.downcase, 'format' => 'html' }
      body['api_key'] = @key unless @key.empty?
      body
    end

    def texts_of(reply)
      text = reply.is_a?(Hash) ? reply['translatedText'] : nil
      text.is_a?(Array) ? text.map(&:to_s) : [text.to_s]
    end

    def problem(status, reply, response)
      message = scrub((reply.is_a?(Hash) && reply['error']) || response.body.to_s)[0, 300]
      low = message.downcase
      code = if [401, 403].include?(status) || low.include?('api key') then 'translator_invalid_key'
             elsif status == 429 then 'translator_rate_limited'
             elsif status >= 500 then 'translator_overloaded'
             elsif status == 400 && low.include?('not supported') then 'translator_failed'
             else 'translator_failed'
             end
      Error.new(code, code == 'translator_failed' ? "HTTP #{status}: #{message}" : message)
    end
  end

  ADAPTERS['deepl'] = ->(env) { DeepLAdapter.new(env, AutoTranslate.seconds(env)) }
  ADAPTERS['libretranslate'] = ->(env) { LibreTranslateAdapter.new(env, AutoTranslate.seconds(env)) }
end
