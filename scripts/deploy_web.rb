#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/deploy_web.rb -- uploads public.nosync/ (the build output) to
# the configured deploy backend: Cloudron Surfer (the default), a local
# directory, or rsync -- see lib/deploy_backend.rb and DEPLOY_BACKEND in
# env.sh. Run via ./scripts/deploy-web.sh, which sources env.sh first.
#
# Smart sync: a manifest (.deploy_manifest.json at the project root, outside
# public.nosync/ so the build doesn't delete it) holds the SHA256 hash, size
# and mtime of every uploaded file -- only files that are new or have a
# different hash get uploaded. Since the build doesn't rewrite files whose
# content hasn't changed (`emit` compares before writing), a match on size
# and mtime against the stored values reliably means unchanged content --
# SHA256 (reading the whole file) is then only computed for the few files
# that are new or have a different size/mtime, not for every file in
# public.nosync/ on every deploy.
#
# Deletion: the build can also remove files (a deleted post, renumbered
# pages), but those left live URLs behind on Surfer. --prune deletes
# whatever is in the manifest but no longer in public.nosync/. Deliberately
# opt-in, not part of a normal deploy -- it's the only destructive operation
# in this whole script.
#
# Usage:
#   ./scripts/deploy-web.sh                     # uploads only new/changed files
#   ./scripts/deploy-web.sh --force             # ignores the manifest, uploads everything
#   ./scripts/deploy-web.sh --only=A[,B,...]    # uploads only the listed files
#   ./scripts/deploy-web.sh --prune             # also deletes orphaned files on Surfer
#   ./scripts/deploy-web.sh --dry-run           # only prints what it would do (doesn't need Surfer)

require 'digest'
require 'json'
require_relative '../lib/deploy_backend'
require_relative '../lib/atomic_write'

DRY = ARGV.include?('--dry-run')
FORCE = ARGV.include?('--force')
PRUNE = ARGV.include?('--prune')
ONLY = ARGV.find { |a| a.start_with?('--only=') }&.delete_prefix('--only=')&.split(',')
ROOT = File.expand_path('..', __dir__)
PUBLIC_DIR = File.join(ROOT, 'public.nosync')
BACKEND = DeployBackend.pick
# One manifest per backend (the suffix): the manifest records what THIS
# target already has, so switching DEPLOY_BACKEND must never inherit
# another target's state -- a fresh target starts from a full upload.
MANIFEST_PATH = File.join(ROOT, ".deploy_manifest#{BACKEND.manifest_suffix}.json")
# Orphans get deleted under --prune, or unconditionally on a snapshot
# backend (git), whose every push mirrors the build exactly.
PRUNES = PRUNE || (BACKEND.respond_to?(:always_prunes?) && BACKEND.always_prunes?)
# The manifest is saved in batches, not after every file: on a large deploy
# that meant thousands of rewrites of a growing JSON file (hundreds of KB x
# thousands = gigabytes of writes). Periodic saving still has to happen
# though -- so an interrupted deploy can resume.
MANIFEST_SAVE_EVERY = 25
# Marks a deploy as started and not yet finished. A run that dies halfway
# (Ctrl-C, a dropped SSH session, the target going away) leaves a manifest
# describing only part of the target -- and the two file-count guards below
# then read the next, perfectly normal run as an explosion in size and
# refuse it. That is a dead end for the flows ./blog.sh runs itself, which
# have no way to pass --force. While this file exists, the guards stand
# down for one run.
INCOMPLETE_PATH = "#{MANIFEST_PATH}.incomplete"

def log(msg)
  puts msg
  $stdout.flush
end

def load_manifest
  return {} unless File.exist?(MANIFEST_PATH)

  JSON.parse(File.read(MANIFEST_PATH))
rescue JSON::ParserError => e
  # Treating this as "nothing was ever uploaded" silently is how orphans
  # become permanently unprunable: the target keeps files this side no
  # longer knows about, and both guards below are disabled by the empty
  # manifest without anyone noticing. Say it out loud, and treat the run
  # as a resume so the guards stay off deliberately rather than by
  # accident.
  warn "⚠️  #{MANIFEST_PATH} is unreadable (#{e.message.lines.first.to_s.strip[0, 60]}) -- treating it as empty."
  warn '   Everything will be re-uploaded. Files already on the target that this build no longer generates'
  warn '   can no longer be found automatically; check the target if you have deleted posts recently.'
  {}
end

# Atomic, like every other write of state this engine depends on: the
# previous manifest survives a write that dies halfway (a full disk, a
# killed container), instead of being truncated into the unreadable file
# the branch above has to apologise for.
def save_manifest(manifest)
  AtomicWrite.write_json(MANIFEST_PATH, manifest)
end

# Older manifests (before this extension) have a bare hash string as the
# value, not { hash:, size:, mtime: } -- this recognizes that shape when
# reading an old manifest and uses it as the hash without crashing.
def manifest_hash(entry)
  entry.is_a?(Hash) ? entry['hash'] : entry
end

abort('❌ public.nosync/ does not exist -- run the build first (ruby build/build_blog.rb).') unless Dir.exist?(PUBLIC_DIR)

# An unconfigured target skips the upload rather than failing: install.md
# promises that an unedited env.sh is enough to try everything locally,
# and the authoring flow calls this after every save -- a fresh clone
# would otherwise get a red ❌ on its very first post. Logged loudly so a
# server whose env.sh lost its values doesn't look like a clean deploy.
unless DRY || BACKEND.configured?
  puts "ℹ️  Deploy backend '#{BACKEND.label}' is not configured -- skipping the upload. " \
       'The build in public.nosync/ is complete; view it with ./blog.sh preview. ' \
       'To actually deploy, set DEPLOY_BACKEND and its values in env.sh (see env.sh.example).'
  exit 0
end

files = Dir.glob(File.join(PUBLIC_DIR, '**', '*'))
            .select { |f| File.file?(f) }
            .map { |f| f.delete_prefix("#{PUBLIC_DIR}/") }
            .sort

all_files = files
if ONLY
  missing = ONLY - files
  abort("❌ #{missing.join(', ')}: not found in public.nosync/.") unless missing.empty?

  files = ONLY
end

# The manifest is always loaded, even with --force: --force only forces
# re-uploading everything, but the list of previously uploaded files is
# still needed to find orphans.
stored = load_manifest
# --force means "upload everything again", not "forget what the target
# has": starting from an empty manifest dropped every orphan still
# pending at that moment, and an orphan the manifest has forgotten can
# never be pruned -- it stays live on the target for good. The forcing
# happens in the upload selection below instead.
manifest = stored.dup
hashes = {}
stats = {}
files.each do |name|
  path = File.join(PUBLIC_DIR, name)
  stat = File.stat(path)
  # Full (sub-second) mtime precision, not just whole seconds: the build can
  # finish and write hundreds of files within one second, so a timestamp
  # rounded to whole seconds could in theory make two different contents
  # written in the same second look identical, and the fast path would miss
  # the change. With a sub-second timestamp (ext4/APFS both carry one), this
  # collision window is effectively zero in practice.
  stats[name] = { 'size' => stat.size, 'mtime' => stat.mtime.to_f }

  prev = stored[name]
  # Fast path: both size and mtime match what was stored from the last
  # successful upload -- so the content couldn't have changed (see comment
  # above), no need to read and hash the whole file.
  if !FORCE && prev.is_a?(Hash) && prev['size'] == stats[name]['size'] && prev['mtime'] == stats[name]['mtime']
    hashes[name] = prev['hash']
  else
    hashes[name] = Digest::SHA256.file(path).hexdigest
  end
end

to_upload = ONLY || FORCE ? files : files.select { |name| manifest_hash(manifest[name]) != hashes[name] }
skipped = files.size - to_upload.size

# Orphans = uploaded at some point, but no longer in public.nosync/ (a
# deleted post, renumbered pages). Not handled with --only -- there, only
# the listed files are known about.
orphans = ONLY ? [] : (stored.keys - all_files).sort

# A safeguard against a broken build. If the build only produced a fraction
# of the pages (a typo in a path, an empty content dir, a crashed run),
# --prune would happily delete the rest of the live site and the deploy
# would upload wreckage. A drop of more than a fifth is almost certainly a
# bug, not intent -- and if you really are deleting hundreds of posts,
# --force gets it through.
RESUMING = File.exist?(INCOMPLETE_PATH)

SHRINK_LIMIT = 0.2
if !ONLY && !FORCE && !RESUMING && !stored.empty? && all_files.size < stored.size * (1 - SHRINK_LIMIT)
  abort(<<~MSG)
    ❌ Stopped: public.nosync/ has #{all_files.size} files, but #{stored.size} were uploaded last time.
       That's a #{(100 - (all_files.size * 100.0 / stored.size)).round}% drop -- looks like a broken build.
       Check the build output. If the drop is expected (you deleted a lot of posts), run again with --force.
  MSG
end

# The mirror image of SHRINK_LIMIT: a sharp INCREASE in file count is just as
# much a sign of something broken as intentional -- typically duplicate
# posts (build_blog.rb has its own safeguard against a matching year/slug,
# but not against duplication of some other kind), a badly merged import, or
# an accidentally copied tree. Normal growth is a handful of files per
# published post; a jump of more than a fifth doesn't happen in normal use.
GROWTH_LIMIT = 0.2
if !ONLY && !FORCE && !RESUMING && !stored.empty? && all_files.size > stored.size * (1 + GROWTH_LIMIT)
  abort(<<~MSG)
    ❌ Stopped: public.nosync/ has #{all_files.size} files, only #{stored.size} were uploaded last time.
       That's a #{((all_files.size * 100.0 / stored.size) - 100).round}% increase -- looks like a duplicated or broken build.
       Check the build output. If the increase is expected (a bulk import/migration), run again with --force.
  MSG
end

log('')
log("Deploy web -> #{BACKEND.label}: #{BACKEND.target}#{DRY ? '  [DRY-RUN]' : ''}")
log('  ℹ️  The last deploy did not finish -- resuming it, so the file-count guards are skipped this once.') if RESUMING
log("  #{files.size} file(s) total, #{to_upload.size} new/changed, #{skipped} unchanged (skipped)")
if orphans.any?
  log(PRUNES ? "  #{orphans.size} orphan(s) to delete#{PRUNE ? ' (--prune)' : ' (snapshot deploy)'}" \
             : "  ⚠️  #{orphans.size} orphaned file(s) on the target -- delete them with --prune")
end

if DRY
  to_upload.each { |name| log("  [dry] #{name} (#{File.size(File.join(PUBLIC_DIR, name))} B)") }
  orphans.each { |name| log("  [dry] #{PRUNES ? 'delete' : 'orphan'} #{name}") }
  exit 0
end

log('') if to_upload.any? || (PRUNES && orphans.any?)

ok = failed = deleted = 0
completed = false
File.write(INCOMPLETE_PATH, Time.now.to_s)
begin
  if BACKEND.respond_to?(:sync)
    # Batch backend (rsync): one run covers everything, so the manifest is
    # updated wholesale on success -- and not at all on failure, since a
    # batch backend re-diffs against the target on the next run anyway.
    if BACKEND.sync(public_dir: PUBLIC_DIR, files: to_upload, orphans: orphans,
                    only: ONLY, prune: PRUNES && orphans.any?,
                    force: FORCE, logger: method(:log))
      to_upload.each do |name|
        manifest[name] = { 'hash' => hashes[name], 'size' => stats[name]['size'], 'mtime' => stats[name]['mtime'] }
      end
      ok = to_upload.size
      if PRUNES
        orphans.each { |name| manifest.delete(name) }
        deleted = orphans.size
      end
    else
      failed = 1
    end
  else
    BACKEND.session do |session|
      to_upload.each do |name|
        path = File.join(PUBLIC_DIR, name)
        case session.upload(path, logger: method(:log), remote_name: name)
        when :ok
          ok += 1
          manifest[name] = { 'hash' => hashes[name], 'size' => stats[name]['size'], 'mtime' => stats[name]['mtime'] }
          save_manifest(manifest) if ((ok + deleted) % MANIFEST_SAVE_EVERY).zero?
        else
          failed += 1
        end
      end

      next unless PRUNES

      orphans.each do |name|
        case session.delete(name, logger: method(:log))
        when :ok, :missing
          deleted += 1
          manifest.delete(name)
          save_manifest(manifest) if ((ok + deleted) % MANIFEST_SAVE_EVERY).zero?
        else
          failed += 1
        end
      end
    end
  end
  completed = true
ensure
  save_manifest(manifest)
  # Cleared only by a run that got all the way through with nothing
  # failing -- an interruption (or a partial failure) leaves the marker so
  # the next run knows the manifest describes an unfinished upload.
  File.delete(INCOMPLETE_PATH) if completed && failed.zero? && File.exist?(INCOMPLETE_PATH)
end

log('')
log("Done: uploaded #{ok}, deleted #{deleted}, failed #{failed}, unchanged #{skipped}")
log('')
exit(failed.zero? ? 0 : 1)
