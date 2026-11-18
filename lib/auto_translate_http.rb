# frozen_string_literal: true

# The translators that live behind a web address: OpenAI and everything
# that speaks its chat API (Mistral, OpenRouter, Ollama, LM Studio, any
# server by its address), Anthropic, and Google's Gemini. Plain Ruby, no
# gem: `Net::HTTP` and `JSON`. Text in, text out -- no schema, no tools, no
# pictures; a translation needs none of them.
#
#   TRANSLATOR=openai | anthropic | gemini
#   TRANSLATOR_MODEL=<the model's name>        (always)
#   TRANSLATOR_KEY=<the provider's key>        (always, but for a server on this machine)
#   TRANSLATOR_URL=<where the API is>          (OpenAI-style: its /v1 base; the others: only to point elsewhere)
#   TRANSLATOR_MAX_TOKENS=16000                (how long an answer may be)
#
# The engine keeps no table of models: the name is the person's, and what
# a model does with a language is theirs to find out -- a small one writes
# a Czech number out in words, and the check against the original says so.
#
# What a request may be sent to: https, or http to this machine. A key sent
# in clear to another host is a key given away, so that is refused.
require 'net/http'
require 'json'
require 'uri'
require 'timeout'
require 'openssl'
require 'zlib'

module AutoTranslate
  class HttpAdapter
    DEFAULT_TOKENS = 16_000
    LOOPBACK = %w[localhost 127.0.0.1 ::1 [::1]].freeze

    def initialize(env, seconds)
      @seconds = seconds
      @model = env['TRANSLATOR_MODEL'].to_s.strip
      @key = env['TRANSLATOR_KEY'].to_s.strip
      @base = (env['TRANSLATOR_URL'].to_s.strip.empty? ? self.class::DEFAULT_URL : env['TRANSLATOR_URL'].to_s.strip).sub(%r{/+\z}, '')
      value = env['TRANSLATOR_MAX_TOKENS'].to_s.strip
      @tokens = value.match?(/\A\d+\z/) && value.to_i.positive? ? value.to_i : DEFAULT_TOKENS
      raise Error.new('translator_missing_setting', 'TRANSLATOR_MODEL') if @model.empty?

      uri = address(@base)
      raise Error.new('translator_missing_setting', 'TRANSLATOR_KEY') if @key.empty? && !loopback?(uri)
    end

    def translate(instructions, document)
      uri = address(endpoint)
      request = Net::HTTP::Post.new(uri)
      request['content-type'] = 'application/json'
      headers.each { |name, value| request[name] = value }
      request.body = JSON.generate(body(instructions, document))
      response = send_request(uri, request)
      reply = parse(response.body)
      raise problem(response.code.to_i, reply, response) unless response.code.to_i == 200

      text(reply)
    end

    private

    # The web address, or an Error: http and https only, a host in it, and
    # http only where nothing leaves the machine.
    def address(text)
      uri = URI.parse(text)
      raise Error.new('translator_bad_address', text) unless %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
      raise Error.new('translator_bad_address', "#{text} (a key does not go over http to another host)") if uri.scheme == 'http' && !loopback?(uri)

      uri
    rescue URI::InvalidURIError
      raise Error.new('translator_bad_address', text)
    end

    def loopback?(uri)
      LOOPBACK.include?(uri.host.to_s.downcase)
    end

    def send_request(uri, request)
      Timeout.timeout(@seconds) do
        # hostname, not host: an IPv6 literal is `[::1]` in the address and
        # `::1` to the network.
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', open_timeout: [15, @seconds].min,
                                            read_timeout: @seconds) { |http| http.request(request) }
      end
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout
      raise Error.new('translator_timeout', @seconds)
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, EOFError, Zlib::Error => e
      raise Error.new('translator_network', scrub("#{e.class}: #{e.message}"))
    end

    def parse(text)
      JSON.parse(text.to_s.dup.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError
      nil
    end

    # What a provider's refusal stands for -- said so that the person can
    # do something about it. A key never appears in what is said.
    def problem(status, reply, response)
      error = reply.is_a?(Hash) && reply['error'].is_a?(Hash) ? reply['error'] : {}
      # Scrubbed whole, then cut: cut first, a key echoed across the cut was
      # no longer the key the scrub looked for, and its start stayed.
      message = scrub((error['message'] || response.body).to_s)[0, 300]
      # The first of them that is a word: Gemini's `code` is the number 400,
      # and its `status` (INVALID_ARGUMENT) is the one that says what it was.
      type = [error['type'], error['status'], error['code']].find { |v| v.is_a?(String) && !v.empty? }.to_s
      low = message.downcase
      code = if (status == 403 && low.include?('subscription tier')) || (status == 429 && response['x-ratelimit-limit-req-minute'] == '0')
               'translator_not_in_plan'
             elsif status == 401 then 'translator_invalid_key'
             # A refusal is not always the key: a country the provider does
             # not serve, an API not switched on for the project, a key
             # without the right to this model. Said as what it is.
             elsif status == 403 then 'translator_forbidden'
             elsif status == 402 || (status == 429 && (type == 'insufficient_quota' || low.include?('quota') || low.include?('billing')))
               'translator_no_credit'
             elsif status == 429 then 'translator_rate_limited'
             elsif status >= 500 then 'translator_overloaded'
             elsif status == 400 && (low.include?('credit') || type == 'billing_error') then 'translator_no_credit'
             elsif status == 400 && (low.include?('context length') || low.include?('too many tokens') || low.include?('maximum context'))
               'translator_too_long'
             elsif status == 400 && type == 'INVALID_ARGUMENT' && low.include?('api key') then 'translator_invalid_key'
             elsif status == 404 && low.include?('model') then 'translator_unknown_model'
             else 'translator_failed'
             end
      Error.new(code, code == 'translator_failed' ? "HTTP #{status}: #{message}" : message)
    end

    def scrub(text)
      text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      @key.empty? ? text : text.gsub(@key, '***')
    end

    def need_text(text, finished_badly)
      raise Error.new('translator_cut_off') if finished_badly == :cut
      raise Error.new('translator_refused') if finished_badly == :refused
      raise Error.new('translator_empty') if text.to_s.strip.empty?

      text
    end
  end

  # Chat completions in the style of OpenAI.
  class OpenAIAdapter < HttpAdapter
    DEFAULT_URL = 'https://api.openai.com/v1'

    private

    def endpoint
      "#{@base}/chat/completions"
    end

    def headers
      @key.empty? ? {} : { 'authorization' => "Bearer #{@key}" }
    end

    def body(instructions, document)
      { 'model' => @model, 'max_completion_tokens' => @tokens,
        'messages' => [{ 'role' => 'system', 'content' => instructions }, { 'role' => 'user', 'content' => document }] }
    end

    def text(reply)
      choice = reply.is_a?(Hash) ? Array(reply['choices']).first : nil
      message = choice.is_a?(Hash) ? choice['message'] : nil
      finished = case choice.is_a?(Hash) ? choice['finish_reason'] : nil
                 when 'length' then :cut
                 when 'content_filter' then :refused
                 end
      finished = :refused if message.is_a?(Hash) && message['refusal'].is_a?(String)
      content = message.is_a?(Hash) ? message['content'] : nil
      # Some servers (Mistral's reasoning models) answer with blocks: the
      # text is in the ones that are text, the thinking is not the answer.
      if content.is_a?(Array)
        content = content.select { |b| b.is_a?(Hash) && b['type'] == 'text' }.map { |b| b['text'].to_s }.join
      end
      need_text(content, finished)
    end
  end

  # Anthropic's messages API.
  class AnthropicAdapter < HttpAdapter
    DEFAULT_URL = 'https://api.anthropic.com'

    private

    def endpoint
      "#{@base}/v1/messages"
    end

    def headers
      { 'x-api-key' => @key, 'anthropic-version' => '2023-06-01' }
    end

    def body(instructions, document)
      { 'model' => @model, 'max_tokens' => @tokens, 'system' => instructions,
        'messages' => [{ 'role' => 'user', 'content' => document }] }
    end

    def text(reply)
      blocks = reply.is_a?(Hash) ? Array(reply['content']) : []
      words = blocks.select { |b| b.is_a?(Hash) && b['type'] == 'text' }.map { |b| b['text'].to_s }.join
      finished = case reply.is_a?(Hash) ? reply['stop_reason'] : nil
                 when 'max_tokens' then :cut
                 when 'refusal' then :refused
                 end
      need_text(words, finished)
    end
  end

  # Google's generateContent.
  class GeminiAdapter < HttpAdapter
    DEFAULT_URL = 'https://generativelanguage.googleapis.com'

    private

    def endpoint
      "#{@base}/v1beta/models/#{URI.encode_www_form_component(@model)}:generateContent"
    end

    def headers
      { 'x-goog-api-key' => @key }
    end

    def body(instructions, document)
      generation = { 'maxOutputTokens' => @tokens }
      # Gemini 3 thinks at length unless told not to: a draft took a minute.
      generation['thinkingConfig'] = { 'thinkingLevel' => 'low' } if @model.start_with?('gemini-3')
      { 'systemInstruction' => { 'parts' => [{ 'text' => instructions }] },
        'contents' => [{ 'role' => 'user', 'parts' => [{ 'text' => document }] }],
        'generationConfig' => generation }
    end

    def text(reply)
      reply = {} unless reply.is_a?(Hash)
      blocked = reply['promptFeedback'].is_a?(Hash) && reply['promptFeedback']['blockReason']
      candidate = Array(reply['candidates']).first
      candidate = {} unless candidate.is_a?(Hash)
      words = Array(candidate.dig('content', 'parts')).map { |part| part.is_a?(Hash) ? part['text'].to_s : '' }.join
      finished = if blocked || %w[SAFETY RECITATION PROHIBITED_CONTENT BLOCKLIST].include?(candidate['finishReason']) then :refused
                 elsif candidate['finishReason'] == 'MAX_TOKENS' then :cut
                 end
      need_text(words, finished)
    end
  end

  ADAPTERS['openai'] = ->(env) { OpenAIAdapter.new(env, AutoTranslate.seconds(env)) }
  ADAPTERS['anthropic'] = ->(env) { AnthropicAdapter.new(env, AutoTranslate.seconds(env)) }
  ADAPTERS['gemini'] = ->(env) { GeminiAdapter.new(env, AutoTranslate.seconds(env)) }
end
