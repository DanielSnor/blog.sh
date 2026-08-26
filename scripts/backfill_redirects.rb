#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds redirect_from to posts that were imported BEFORE the importers
# learned to write it. Every importer has always stored the post's
# original address as source.post_url, so this reads what is already on
# disk -- no re-import, no network, nothing else about the post touched.
#
# Usage:
#   ruby scripts/backfill_redirects.rb example.com            # preview
#   WRITE=1 ruby scripts/backfill_redirects.rb example.com    # apply
#
# The domain names the OLD site, and only posts whose source.post_url
# lives on it are touched -- the same contract as the importers' own
# permalink question: old addresses are only yours to answer if the new
# site runs on the domain that used to serve them. Preview is the
# default because this walks the whole archive; WRITE=1 is the same run
# writing what it just showed.
#
# Re-running is safe: a path already present is left alone, so the script
# converges instead of stacking duplicates.

require 'json'
require 'uri'
require_relative '../lib/atomic_write'
require_relative '../lib/import/permalinks'
require_relative '../lib/path_glob'
require_relative '../lib/post_address'

ROOT = File.expand_path('..', __dir__)
CONTENT_DIR = File.join(ROOT, 'content.nosync', 'posts')

# Mirrors the build's REDIRECT_FROM_RESERVED: entries under these would be
# refused there with a warning on every build -- better never written.
RESERVED = PostAddress::REDIRECT_RESERVED

domain = ARGV[0] || abort('usage: backfill_redirects.rb <old-domain>   (WRITE=1 to apply)')
domain = domain.sub(/\Awww\./, '').downcase
write = ENV['WRITE'] == '1'

scanned = 0
added = 0
already = 0
skipped_domain = 0
unusable = 0

PathGlob.under(CONTENT_DIR, '*', '*.json').sort.each do |file|
  post = JSON.parse(File.read(file, encoding: 'utf-8'))
  next unless post['state'] == 'published'

  scanned += 1
  url = post.dig('source', 'post_url')
  host = begin
    URI.parse(url.to_s).host.to_s.sub(/\Awww\./, '').downcase
  rescue URI::InvalidURIError
    ''
  end
  if host.empty? || host != domain
    skipped_domain += 1
    next
  end

  path = Import::Permalinks.local_path(url)
  if path.nil? || RESERVED.include?(path.split('/').reject(&:empty?).first)
    unusable += 1
    next
  end

  existing = Array(post['redirect_from']).map(&:to_s)
  if existing.include?(path)
    already += 1
    next
  end

  added += 1
  puts "  #{post['slug']}: #{path}"
  next unless write

  post['redirect_from'] = existing + [path]
  AtomicWrite.write_json(file, post)
end

puts
puts "#{scanned} published post(s): #{added} redirect(s) #{write ? 'written' : 'to write'}, " \
     "#{already} already present, #{skipped_domain} on other domains, #{unusable} with no usable path."
puts 'Preview only -- re-run with WRITE=1 to apply, then rebuild.' unless write
