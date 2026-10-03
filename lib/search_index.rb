# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'atomic_write'
require_relative 'post_text'
require_relative 'slug'
require_relative 'translations'
require_relative 'language_file'
require_relative 'yaml_compat'

# lib/search_index.rb -- the words `browse` and `list --search` search,
# kept between runs.
#
# Searching the archive meant reading every post, taking its text out of
# its blocks and folding it -- every time, for every query. Measured on
# 6,600 posts: 1.1 s to list them, 4.9 s to search them, and the 3.8 s in
# between was spent rebuilding what the previous query had already built.
# In the terminal that is one spinner per sitting; a program asking over
# SSH pays it on every question.
#
# So the index is written down: per post, what a row of `list` says about
# it, its text, and the folded form a query is matched against. An entry
# is good for as long as the post's file has the size and the modification
# time it was made from; a post that changed is read again, a post that is
# gone drops out, and the file is rewritten only when something did.
#
# WHAT IS SEARCHED is what the site's own search box searches, in every
# language at once: the title, the text, the words a reader sees that are
# not paragraphs (PostText.aside), the tags -- and, where the site
# publishes more languages, each translation's title and text and the
# label each language gives a tag (the pill on /cs/ says "filozofie", so
# "filozofie" has to find the post tagged "philosophy"). The site's pages
# are not here: they are not posts, and `list` lists posts.
#
# The whole file is thrown away when the engine changes -- any of its
# Ruby, since the folding, the text and the row all come from there -- or
# when a language's tag labels do. Like the build cache it describes this
# machine's archive, is always safe to delete, and is not in the repo.
module SearchIndex
  FILE = '.search_index.json'
  # What an entry holds. Raise it when the shape changes without the
  # engine's files changing -- which is never, but costs one integer.
  FORMAT = 1

  module_function

  # Every post file under `files`, as { file => entry }, an entry being
  # { 'summary' => ..., 'text' => ..., 'folded' => ... }. The block is
  # handed a file whose entry is missing or stale and answers with the
  # parsed post and its summary, or nil for a file that cannot be read.
  def load(root:, files:, stamp:)
    path = File.join(root, FILE)
    kept = read(path, stamp)
    entries = {}
    changed = false
    files.each do |file|
      mark = mark_of(file)
      next unless mark

      key = relative(root, file)
      hit = kept[key]
      if hit.is_a?(Hash) && hit['mark'] == mark
        entries[file] = hit
      else
        made = yield(file)
        next unless made

        entries[file] = made.merge('mark' => mark)
        changed = true
      end
    end
    changed ||= kept.size != entries.size
    write(path, stamp, root, entries) if changed
    entries
  end

  # The part of an entry that is the post's words: the text a match is
  # shown from, and the folded form it is found in.
  def words(post, labels)
    text = PostText.plain(post).gsub(/\s+/, ' ').strip
    others = Translations.languages(post).map { |lang| Translations.for_lang(post, lang) }
    other_texts = others.map { |other| PostText.plain(other).gsub(/\s+/, ' ').strip }
    tags = post['tags'] || []
    labelled = (tags + tags.flat_map { |tag| labels.fetch(Slug.slugify(tag.to_s), []) }).uniq
    folded = [PostText.searchable(post.merge('tags' => labelled), text)] +
             others.each_with_index.map { |other, i| PostText.searchable(other.merge('tags' => []), other_texts[i]) }
    { 'text' => ([text] + other_texts).reject(&:empty?).join(' '), 'folded' => folded.join(' ') }
  end

  # The label every language gives a tag, by the tag's slug:
  # { 'philosophy' => ['filozofie', 'Philosophie'] }.
  def tag_labels(root, languages)
    Array(languages).each_with_object({}) do |lang, labels|
      file = File.join(root, 'config', "site.#{lang}.yml")
      next unless File.file?(file)

      data = begin
        YamlCompat.load_file(file)
      rescue StandardError
        nil
      end
      LanguageFile.tag_labels(data) { |tag| Slug.slugify(tag) }.each do |slug, label|
        (labels[slug] ||= []) << label
      end
    end
  end

  # What every entry depends on besides its own post: the engine's Ruby
  # and the tag labels. A stat per file, not a read -- this runs on every
  # search, and the answer only has to change when a file does.
  def stamp(root, labels)
    engine = (Dir.glob(File.join(root, 'lib', '*.rb')) + [File.join(root, 'scripts', 'manage_post.rb')]).sort.map do |file|
      stat = File.stat(file)
      [File.basename(file), stat.size, stat.mtime.to_i, stat.mtime.nsec]
    rescue SystemCallError
      [File.basename(file)]
    end
    Digest::SHA256.hexdigest(JSON.generate([FORMAT, engine, labels.sort]))
  end

  def mark_of(file)
    stat = File.stat(file)
    [stat.size, stat.mtime.to_i, stat.mtime.nsec]
  rescue SystemCallError
    nil
  end

  def relative(root, file)
    file.start_with?("#{root}/") ? file[(root.length + 1)..] : file
  end

  # Anything that is not this cache, whole and for this engine, is no
  # cache: a truncated file, another format, another engine's. The posts
  # are then simply read again, which is what would have happened anyway.
  def read(path, stamp)
    data = JSON.parse(File.read(path, encoding: 'utf-8'))
    return {} unless data.is_a?(Hash) && data['stamp'] == stamp && data['entries'].is_a?(Hash)

    data['entries']
  rescue JSON::ParserError, SystemCallError, ArgumentError
    {}
  end

  # A cache that cannot be written is a search that is slow, not one that
  # fails: a read-only installation still answers.
  def write(path, stamp, root, entries)
    stored = entries.each_with_object({}) { |(file, entry), out| out[relative(root, file)] = entry }
    AtomicWrite.write(path, JSON.generate('stamp' => stamp, 'entries' => stored), durable: false)
  rescue SystemCallError
    nil
  end
end
