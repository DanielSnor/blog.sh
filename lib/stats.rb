# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'post_text'
require_relative 'slug'
require_relative 'content_type'
require_relative 'post_address'
require_relative 'path_glob'

# lib/stats.rb -- what `./blog.sh stats` counts. Numbers only: this
# module never prints, never colours and never translates, so the same
# figures can come out as a screen for a person or as JSON for a script
# (see scripts/stats.rb).
#
# It reads the archive rather than the built site -- the same choice
# lib/checker.rb makes, and for the same reason: the answer must not
# depend on a build having run, and a draft is part of an archive even
# though no page exists for it.
#
# Deliberately no config, no network, no media decoding: it walks the
# post JSON and stats the media directory, nothing else. On 4,422 posts
# it comes back in about two seconds.
module Stats
  # Words per minute, matching the reading time the build puts on a post
  # page -- two places answering "how long is this" must not disagree.
  READING_WORDS_PER_MINUTE = 200

  # Enough to see the shape of a tag cloud without printing 1,798 of them.
  TOP_TAGS = 8

  module_function

  def collect(root:)
    posts = load_posts(root)
    return nil if posts.empty?

    counts = word_counts(posts)
    {
      'posts' => post_counts(posts),
      'span' => span(posts),
      'years' => years(posts),
      'types' => types(posts),
      'words' => words(posts, counts),
      'tags' => tags(posts),
      'media' => media(root, posts),
      'sources' => sources(posts)
    }
  end

  def load_posts(root)
    dir = File.join(root, 'content.nosync', 'posts')
    PathGlob.under(dir, '*', '*.json').sort.filter_map do |path|
      post = JSON.parse(File.read(path, encoding: 'utf-8'))
      next unless post.is_a?(Hash)

      post['__year'] = File.basename(File.dirname(path))
      post
    rescue JSON::ParserError
      # `check` reports these by name; a count that refused to run over
      # one bad file would be no count at all.
      nil
    end
  end

  # --- the pieces ----------------------------------------------------------

  # Disjoint on purpose, so the four numbers add up to the total. A page
  # can also be a draft, and counting it in both columns produced a
  # breakdown that was larger than the archive.
  def post_counts(posts)
    pages = posts.select { |p| page?(p) }
    rest = posts - pages
    scheduled = rest.select { |p| p['scheduled'] }
    drafts = (rest - scheduled).select { |p| draft?(p) }
    { 'total' => posts.size, 'published' => (rest - scheduled - drafts).size,
      'drafts' => drafts.size, 'scheduled' => scheduled.size, 'pages' => pages.size }
  end

  def span(posts)
    times = posts.map { |p| time_of(p) }
    first = times.min
    last = times.max
    busiest = years(posts).max_by { |_, count| count }
    { 'first' => first.strftime('%Y-%m-%d'), 'last' => last.strftime('%Y-%m-%d'),
      'days' => ((last - first) / 86_400).to_i,
      'busiest_year' => { 'year' => busiest[0], 'posts' => busiest[1] } }
  end

  # By the archive's own directory rather than by parsing every date: that
  # is the year the post's address carries, so a listing and this table
  # cannot disagree.
  def years(posts)
    posts.group_by { |p| p['__year'].to_s }.transform_values(&:size).sort.to_h
  end

  def types(posts)
    posts.group_by { |p| ContentType.dominant(p) }
         .transform_values(&:size)
         .sort_by { |type, count| [-count, type] }.to_h
  end

  # Mean AND median, because on a real archive they answer different
  # questions: sean.cz averages 55 words a post, which says less about
  # the writing than about the 2,136 imported tweets underneath it.
  def words(posts, counts)
    total = counts.values.sum
    sorted = counts.values.sort
    longest = counts.max_by { |_, count| count }
    # One decimal, like tags.per_post: integer division called a 2.7-word
    # average "2", and the two averages on the same screen should not
    # round by different rules.
    { 'total' => total,
      'mean' => posts.empty? ? 0.0 : (total.to_f / posts.size).round(1),
      'median' => median(sorted),
      'longest' => { 'slug' => longest[0]['slug'].to_s, 'words' => longest[1] },
      'reading_hours' => (total.to_f / READING_WORDS_PER_MINUTE / 60).round(1) }
  end

  def median(sorted)
    return 0 if sorted.empty?

    middle = sorted.size / 2
    sorted.size.odd? ? sorted[middle] : ((sorted[middle - 1] + sorted[middle]) / 2)
  end

  def tags(posts)
    counts = Hash.new(0)
    posts.each { |p| Array(p['tags']).each { |tag| counts[tag.to_s] += 1 } }
    { 'unique' => counts.size,
      'per_post' => posts.empty? ? 0.0 : (counts.values.sum.to_f / posts.size).round(1),
      'top' => counts.sort_by { |tag, count| [-count, Slug.fold(tag.to_s)] }.first(TOP_TAGS).map { |tag, count| [tag, count] } }
  end

  # Both numbers, because they answer different questions and can differ
  # honestly: `files` is what is on disk, `referenced` is what the posts
  # ask for. A gap between them is `check`'s business (an orphan or a
  # missing file), not this command's -- it only reports.
  def media(root, posts)
    files = PathGlob.under(root, 'media.nosync', '*', '*', '*').select { |f| File.file?(f) }
    { 'files' => files.size,
      'bytes' => files.sum { |f| File.size(f) },
      'referenced' => posts.sum { |p| Array(p['content']).sum { |b| Array(b['media']).size + Array(b['poster']).size } },
      'posts_with_media' => posts.count { |p| Array(p['content']).any? { |b| b['media'] } } }
  end

  # Which platforms the archive is actually made of -- not how many the
  # engine can import from, which is a different and much larger number.
  def sources(posts)
    counts = Hash.new(0)
    posts.each do |post|
      platform = post.dig('source', 'platform').to_s
      counts[platform.empty? ? 'unknown' : platform] += 1
    end
    counts.sort_by { |platform, count| [-count, platform] }.to_h
  end

  # --- shared predicates ---------------------------------------------------

  def word_counts(posts)
    posts.to_h { |post| [post, PostText.plain(post).split(/\s+/).reject(&:empty?).size] }
  end

  def draft?(post)
    post['state'].to_s == 'draft'
  end

  def page?(post)
    PostAddress.page?(post)
  end

  def truthy?(value)
    return false if value.nil? || value == false

    !%w[false no 0].include?(value.to_s.strip.downcase)
  end

  def time_of(post)
    Time.parse(post['date'].to_s)
  rescue ArgumentError, TypeError
    Time.at(0)
  end
end
