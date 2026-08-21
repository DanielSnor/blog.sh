# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'atomic_write'
require_relative 'checker'

# lib/repair.rb -- turns a finding into the one repair it allows, and
# applies it when a human says so.
#
# The rule this module exists to keep is the one the checker's own comment
# states: a checker that also acts has to be trusted twice. So the acting
# half is separate, it is never automatic, and it is deliberately narrow --
# it proposes for the four kinds where the right answer is not a matter of
# taste, and says nothing at all for the rest. A finding with no proposal
# is shown and skipped, never guessed at.
#
# Three rules hold for every proposal here:
#
#   Add rather than rewrite, wherever adding is possible. A dead link to
#   an old address is repaired on the TARGET post, by writing the old
#   address into its redirect_from -- one new line, the author's twenty
#   year old text untouched, and every link to that address fixed at once,
#   including the ones from outside the site that no check can see.
#
#   Never delete. A file nobody references goes to the trash the engine
#   already has, where `restore` can reach it.
#
#   Nothing happens twice. A second run over a repaired archive proposes
#   nothing, because the finding it would have proposed for is gone.
module Repair
  # A repair, as data rather than a closure: it can be printed, counted,
  # tested and applied by something other than whoever proposed it.
  Proposal = Struct.new(:action, :data, keyword_init: true)

  # The first segments of a redirect_from that belong to the site itself --
  # the build refuses these with a warning, so proposing one would be
  # proposing a change that quietly does nothing. Kept in step with
  # REDIRECT_FROM_RESERVED in build/build_blog.rb.
  RESERVED = %w[posts page tag type assets search markdown].freeze

  module_function

  # An index of the archive by slug, plus the prefix lookup an import's
  # truncated slugs need: a slug cut at 50 characters still identifies its
  # post as long as nothing else starts the same way.
  def index(posts)
    by_slug = posts.to_h { |post| [post['slug'].to_s, post] }
    { 'by_slug' => by_slug, 'slugs' => by_slug.keys }
  end

  def target_for(url, idx)
    path = url.to_s.split('#').first.to_s.split('?').first.to_s
    tail = path.sub(%r{/\z}, '').split('/').last.to_s
    return nil if tail.empty?
    return idx['by_slug'][tail] if idx['by_slug'].key?(tail)

    # One candidate or none: two posts whose slugs both start with what an
    # importer left behind is exactly the case where a machine must not
    # choose.
    candidates = idx['slugs'].select { |s| s.start_with?(tail[0, 40]) || tail.start_with?(s) }.uniq
    candidates.size == 1 ? idx['by_slug'][candidates.first] : nil
  end

  def post_path(post)
    "/posts/#{post['date'].to_s[0, 4]}/#{post['slug']}/"
  end

  # Whether an address can be a redirect_from at all. The build refuses a
  # query string, a fragment and the site's own first segments, so a
  # proposal carrying one of those would be a promise the build breaks.
  def redirectable?(origin)
    parts = origin.to_s.split('/').reject(&:empty?)
    return false if parts.empty?
    return false if parts.any? { |p| p == '.' || p == '..' || p.match?(/[?#]/) }

    !RESERVED.include?(parts.first)
  end

  # The one repair a finding allows, or nil when the answer is a person's
  # to give.
  def propose(finding, idx)
    data = finding.data || {}
    case finding.kind
    when :link_dead then propose_redirect(data, idx)
    when :link_relative then propose_rewrite(data, idx)
    when :media_orphan
      Proposal.new(action: :trash, data: { 'path' => File.join('media.nosync', data['dir'].to_s) })
    when :media_stray
      Proposal.new(action: :trash,
                   data: { 'path' => File.join('media.nosync', data['year'].to_s, data['slug'].to_s, data['file'].to_s) })
    end
  end

  def propose_redirect(data, idx)
    origin = data['url'].to_s.split('#').first.to_s
    return nil unless redirectable?(origin)

    target = target_for(origin, idx)
    return nil if target.nil?

    Proposal.new(action: :add_redirect,
                 data: { 'slug' => target['slug'], 'year' => target['date'].to_s[0, 4],
                         'origin' => origin, 'to' => post_path(target) })
  end

  # A relative link often carries its target in the QUERY rather than in the
  # path -- `./?item=another-post` is the shape a dynamic site left behind,
  # and it was the commonest of the 73 found in one real archive. The path
  # of that address says nothing at all ("."), so the query is asked next.
  def target_in_query(url, idx)
    query = url.to_s.split('#').first.to_s.split('?')[1].to_s
    query.split('&').filter_map do |pair|
      value = pair.split('=', 2)[1].to_s
      next if value.empty?

      idx['by_slug'][value] || target_for(value, idx)
    end.first
  end

  def propose_rewrite(data, idx)
    target = target_for(data['url'], idx) || target_in_query(data['url'], idx)
    return nil if target.nil?

    Proposal.new(action: :rewrite_link,
                 data: { 'slug' => data['slug'].to_s, 'from' => data['url'].to_s, 'to' => post_path(target) })
  end

  # --- applying -------------------------------------------------------------

  def apply!(proposal, root)
    case proposal.action
    when :add_redirect then add_redirect(proposal.data, root)
    when :rewrite_link then rewrite_link(proposal.data, root)
    when :trash then trash(proposal.data, root)
    else false
    end
  end

  def post_file(root, year, slug)
    File.join(root, 'content.nosync', 'posts', year.to_s, "#{slug}.json")
  end

  def add_redirect(data, root)
    path = post_file(root, data['year'], data['slug'])
    return false unless File.exist?(path)

    post = JSON.parse(File.read(path, encoding: 'utf-8'))
    list = Array(post['redirect_from'])
    return true if list.include?(data['origin']) # already there: nothing to do, and that is a success

    post['redirect_from'] = list + [data['origin']]
    AtomicWrite.write_json(path, post)
    true
  end

  # The link lives in a formatting span or in a link block, and both shapes
  # occur in one archive -- the same two places Checker.all_links reads, for
  # the same reason.
  def rewrite_link(data, root)
    path = Dir.glob(File.join(root, 'content.nosync', 'posts', '*', "#{data['slug']}.json")).first
    return false unless path

    post = JSON.parse(File.read(path, encoding: 'utf-8'))
    touched = false
    Array(post['content']).each do |block|
      next unless block.is_a?(Hash)

      if block['url'].to_s == data['from']
        block['url'] = data['to']
        touched = true
      end
      [block['formatting'], *Array(block['items']).map { |i| i.is_a?(Hash) ? i['formatting'] : nil }].each do |spans|
        Array(spans).each do |span|
          next unless span.is_a?(Hash) && span['url'].to_s == data['from']

          span['url'] = data['to']
          touched = true
        end
      end
    end
    return false unless touched

    AtomicWrite.write_json(path, post)
    true
  end

  # The trash the engine already has, with the archive's own shape kept
  # inside it, so what came out of media.nosync/2014/a-post goes back there
  # by hand if anyone wants it. Never a delete: the whole point of a repair
  # that runs over somebody's twenty-year archive is that it can be undone.
  def trash(data, root)
    source = File.join(root, data['path'])
    return false unless File.exist?(source)

    target = File.join(root, 'trash', data['path'])
    FileUtils.mkdir_p(File.dirname(target))
    target = "#{target}.#{Time.now.strftime('%Y%m%d%H%M%S')}" if File.exist?(target)
    FileUtils.mv(source, target)
    true
  end
end
