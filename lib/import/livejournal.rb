# frozen_string_literal: true

require 'digest'
require 'net/http'
require 'time'
require 'uri'
require_relative '../i18n'
require_relative '../slug'
require_relative 'html_blocks'
require_relative 'permalinks'

module Import
  # Imports a LiveJournal journal through its XML-RPC API -- LJ has no
  # whole-journal export file, so everything comes live: a challenge
  # handshake before every call (the password itself never travels,
  # only md5(challenge + md5(password))), then the two-phase sync
  # protocol -- syncitems to learn what exists, getevents to fetch it --
  # advancing a lastsync timestamp instead of any page number.
  #
  # Friends-only and private entries import as drafts, counted in the
  # summary: they were never public and a static site has no lock to put
  # them behind. Comments stay behind entirely.
  class Livejournal
    ENDPOINT = URI('https://www.livejournal.com/interface/xmlrpc')
    EPOCH = '1900-01-01 00:00:00'

    # LJ puts the reason in faultString and the number in faultCode, and
    # the number appears NOWHERE in the text: the string is assembled as
    # "Client error: <reason>" (bin/upgrading/en.dat + LJ::Protocol's
    # error_message). The retry below used to test the message for '406'
    # and therefore never matched anything at all -- the first fault of
    # any kind ended the import. So the code travels with the error.
    class Fault < StandardError
      attr_reader :code

      def initialize(message, code)
        super(message)
        @code = code
      end
    end

    # The faults worth waiting out: LJ's own rate limiters (411 action
    # frequency, 413 rate limit exceeded) and its transient server side
    # (500/501 internal and database errors, 502 database unavailable,
    # 503 lock contention, 506 journal sync unavailable). Everything else
    # -- wrong password, suspended account, unknown method -- says the
    # same thing on the second try, and sleeping 45 seconds to hear it
    # again helps nobody.
    #
    # 406 is deliberately absent although it reads like throttling. It is
    # LJ's broken-client detector: ljprotocol.pl returns it once the SAME
    # lastsync has been asked for a third time, so repeating the identical
    # call is precisely what provokes it. The cure is not to repeat --
    # see the window guard in sync_times.
    RETRY_FAULTS = [411, 413, 500, 501, 502, 503, 506].freeze

    attr_accessor :keep_permalinks

    def initialize(username, password:, keep_permalinks: false)
      @username = username
      @password_md5 = Digest::MD5.hexdigest(password)
      @keep_permalinks = keep_permalinks
      @nonpublic = 0
    end

    def label
      "LiveJournal (#{@username})"
    end

    def total
      @total
    end

    def each_item
      times = sync_times
      @total = times.size
      seen = []
      lastsync = EPOCH
      loop do
        events = call('getevents', 'ver' => 1, 'selecttype' => 'syncitems',
                                   'lastsync' => lastsync, 'lineendings' => 'pc')['events']
        events = Array(events)
        fresh = events.reject { |e| seen.include?(e['itemid']) }
        break if fresh.empty?

        fresh.each do |event|
          seen << event['itemid']
          yield event
        end
        batch_times = fresh.filter_map { |e| times["L-#{e['itemid']}"] }
        break if batch_times.empty?

        lastsync = batch_times.max
        break if seen.size >= times.size
      end
    end

    def map(item, media)
      html = normalize(item['event'].to_s)
      parsed = HtmlBlocks.parse(html)
      blocks = localize_images(parsed.blocks, media)
      return :empty if blocks.empty?

      # security '' is public; 'private' and 'usemask' (friends-only)
      # were never public and a static site has no lock -- drafts, so a
      # human decides.
      public_entry = item['security'].to_s.empty?
      @nonpublic += 1 unless public_entry

      title = plain_title(item['subject'].to_s)
      url = item['url'].to_s
      slug = Slug.slugify(title.split(/\s+/).first(10).join(' '))
      # The number in the URL is ditemid (itemid*256+anum), the one
      # public identity LJ has -- never computed here, always taken from
      # the API's own url field.
      slug = Slug.slugify("entry-#{File.basename(URI.parse(url).path.to_s, '.html')}") if slug.empty?

      post = {
        'slug' => slug,
        'title' => title.empty? ? slug : title,
        'date' => item_date(item['eventtime'].to_s).iso8601,
        'state' => public_entry ? 'published' : 'draft',
        'tags' => item.dig('props', 'taglist').to_s.split(',').map(&:strip).reject(&:empty?),
        'content' => blocks,
        'source' => {
          'platform' => 'livejournal',
          'account' => @username,
          'post_url' => url.empty? ? nil : url,
          'original_id' => item['itemid'].to_s
        }.compact
      }
      if @keep_permalinks && public_entry
        origin = Permalinks.local_path(url)
        post['redirect_from'] = [origin] if origin
      end
      post
    end

    def postscript
      return nil if @nonpublic.zero?

      I18n.t('import.note.livejournal_nonpublic', count: @nonpublic)
    end

    private

    # LJ's own event markup, translated: uppercase-era tags lowercased,
    # lj-cut dropped (the content behind it stays -- an archive has no
    # fold), lj user/comm mentions become the links they meant.
    def normalize(html)
      # getevents is asked for 'pc' line endings, which LJ documents as
      # CRLF -- and CRLF survives the trip: XML-RPC escapes every CR as
      # &#xd;, a character reference the XML line-ending normalisation is
      # forbidden to touch, so what arrives really is "\r\n". There are
      # then no two \n side by side, the paragraph split at the bottom of
      # this method never fired, and every old bare-text entry -- exactly
      # the entries that branch exists for -- collapsed into one
      # paragraph, with stray CRs left inside the text. Dropped here
      # rather than by asking for a different line-ending mode, so the
      # shape of the archive never depends on what the server chose to
      # send.
      html = html.delete("\r")
      html = html.gsub(%r{<(/?)([A-Z]+)([^>]*)>}) { "<#{Regexp.last_match(1)}#{Regexp.last_match(2).downcase}#{Regexp.last_match(3)}>" }
      html = html.gsub(%r{</?lj-cut[^>]*>}i, '')
      html = html.gsub(/<lj\s+(?:user|comm)="?([A-Za-z0-9_-]+)"?[^>]*>/i) do
        name = Regexp.last_match(1)
        # A hostname cannot hold an underscore, so LJ spells it as a hyphen:
        # james_nicoll.livejournal.com answers 301 to james-nicoll.livejournal.com.
        # Dropping the underscore instead lands on a DIFFERENT journal that
        # happens to exist -- jamesnicoll and rutravel are both real, and
        # neither belongs to the person the entry was talking about. The name
        # shown to the reader keeps its underscore, only the host loses it.
        %(<a href="https://#{name.tr('_', '-')}.livejournal.com/">#{name}</a>)
      end
      # LJ auto-formatted at render time, so old bodies are bare text
      # with inline tags and newlines -- fed to an HTML parse as-is they
      # shatter into a run per tag. If nothing block-level is present,
      # the paragraphs are rebuilt from the blank lines first.
      return html if html.match?(%r{<(p|div|br|table|ul|ol|blockquote|pre|h[1-6])[\s>/]}i)

      html.split(/\n{2,}/).map { |para| "<p>#{para.strip.gsub("\n", '<br>')}</p>" }.join("\n")
    end

    def plain_title(subject)
      normalize(subject).gsub(/<[^>]+>/, '').gsub(/\s+/, ' ').strip
    end

    # "2004-04-1408:38:00" -- LJ's own bug, the missing space -- and no
    # zone either way: journal-local time, read in site.timezone.
    def item_date(value)
      value = "#{value[0, 10]} #{value[10..]}" if value.length == 18 && value[10] != ' '
      Time.parse(value)
    rescue StandardError
      Time.now
    end

    def sync_times
      times = {}
      lastsync = EPOCH
      loop do
        data = call('syncitems', 'ver' => 1, 'lastsync' => lastsync)
        items = Array(data['syncitems'])
        break if items.empty?

        items.each { |i| times[i['item']] = i['time'] if i['item'].to_s.start_with?('L-') }
        previous = lastsync
        lastsync = items.map { |i| i['time'].to_s }.max
        break if data['count'].to_i >= data['total'].to_i
        # A window that did not move asks the same question again and gets
        # the same page back, forever -- and LJ breaks that loop for us
        # with fault 406 ("client is making repeated requests") on the
        # third identical call, which reads like a server problem and is
        # ours. syncitems only ever returns items NEWER than lastsync, so
        # this never fires on a healthy answer; when it does, a short sync
        # beats a loop.
        break if lastsync <= previous
      end
      times
    end

    # --- the smallest XML-RPC client that speaks LJ ---------------------

    def call(method, params, retries = 3)
      challenge = raw_call('LJ.XMLRPC.getchallenge', {})['challenge'].to_s
      auth = { 'username' => @username, 'auth_method' => 'challenge',
               'auth_challenge' => challenge,
               'auth_response' => Digest::MD5.hexdigest(challenge + @password_md5) }
      raw_call("LJ.XMLRPC.#{method}", params.merge(auth))
    rescue Fault => e
      # Brief patience for the faults that mean "not now", then let Run
      # turn the failure into an honest partial summary a re-run picks up
      # from.
      raise unless retries.positive? && RETRY_FAULTS.include?(e.code)

      sleep 15
      call(method, params, retries - 1)
    end

    def raw_call(method, params)
      body = +"<?xml version=\"1.0\"?><methodCall><methodName>#{method}</methodName><params><param><value><struct>"
      params.each do |key, value|
        encoded = value.is_a?(Integer) ? "<int>#{value}</int>" : "<string>#{xml_escape(value.to_s)}</string>"
        body << "<member><name>#{key}</name><value>#{encoded}</value></member>"
      end
      body << '</struct></value></param></params></methodCall>'

      response = Net::HTTP.post(ENDPOINT, body, 'Content-Type' => 'text/xml')
      raise "LiveJournal answered HTTP #{response.code}" unless response.code == '200'

      require 'rexml/document'
      doc = REXML::Document.new(response.body)
      fault = doc.elements['methodResponse/fault']
      if fault
        detail = decode(fault.elements['value'])
        raise Fault.new("LiveJournal fault: #{detail['faultString']}", detail['faultCode'].to_i)
      end

      decode(doc.elements['methodResponse/params/param/value'])
    end

    def decode(value)
      return nil unless value

      child = value.elements.to_a.first
      return value.text.to_s unless child

      case child.name
      when 'struct'
        child.get_elements('member').to_h do |m|
          [m.elements['name'].text.to_s, decode(m.elements['value'])]
        end
      when 'array'
        child.get_elements('data/value').map { |v| decode(v) }
      when 'int', 'i4' then child.text.to_i
      when 'base64' then child.text.to_s.unpack1('m').force_encoding('UTF-8')
      else child.text.to_s
      end
    end

    def xml_escape(text)
      text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end

    def localize_images(blocks, media)
      blocks.filter_map do |block|
        next block unless block['type'] == 'image'

        url = block.dig('media', 0, 'url').to_s
        filename = url.start_with?('http') ? media.from_url(url) : nil
        next nil unless filename

        width, height = media.dimensions(filename)
        entry = { 'url' => filename }
        entry['width'] = width if width
        entry['height'] = height if height
        block.merge('media' => [entry])
      end
    end
  end
end
