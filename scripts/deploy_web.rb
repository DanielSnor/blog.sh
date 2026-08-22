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

# Every other entry point inherits this from lib/site_config.rb; this one
# does not load it. Without it a cron run -- where LANG is unset -- reads
# the manifest and the paths inside it as US-ASCII, so a single accented
# filename raises out of JSON.parse or out of a path comparison and BOTH
# crons die on every tick, with the deploy never completing again.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = nil

require 'digest'
require 'json'
require 'time'
require_relative '../lib/deploy_backend'
require_relative '../lib/atomic_write'
require_relative '../lib/file_size'
# This script talks to the author too (an unconfigured target below says
# so out loud), and until 1.3.1 it said it in English on a Czech install
# -- the only entry point that did. i18n arrives the way scripts/doctor.rb
# takes it, not through SiteConfig: a deploy ships a build that is ALREADY
# sitting in public.nosync, so a config too broken to parse must not be
# what stops it. An unreadable language means English, not an abort.
require 'yaml'
require_relative '../lib/yaml_compat'
require_relative '../lib/i18n'
deploy_lang = begin
  site = YamlCompat.load_file(File.join(File.expand_path('..', __dir__), 'config', 'site.yml'))
  site.is_a?(Hash) ? site.dig('site', 'lang') : nil
rescue StandardError
  nil
end
I18n.force_lang(deploy_lang.to_s.empty? ? 'en' : deploy_lang.to_s)

# Runs at the end of the cron chain too, where stdout is a block-buffered
# pipe and warn would otherwise overtake the progress lines around it.
$stdout.sync = true

DRY = ARGV.include?('--dry-run')
FORCE = ARGV.include?('--force')
PRUNE = ARGV.include?('--prune')
ONLY = ARGV.find { |a| a.start_with?('--only=') }&.delete_prefix('--only=')&.split(',')
ROOT = File.expand_path('..', __dir__)
PUBLIC_DIR = File.join(ROOT, 'public.nosync')

# The same lock the build takes: a deploy walks public.nosync file by file
# and reads the manifest, and a build rewriting it underneath produces
# either an ENOENT on a file that was there a moment ago or a manifest
# describing a tree that no longer exists.
require_relative '../lib/run_lock'
# --busy-ok is for cron wrappers: their tick skipping because another
# run holds the lock is routine, and exit 1 here read as a failure mail.
# A person's deploy keeps the loud non-zero.
RunLock.acquire!(ROOT, label: 'deploy', busy_exit: ARGV.include?('--busy-ok') ? 0 : 3)
BACKEND = DeployBackend.pick
# One manifest per backend (the suffix): the manifest records what THIS
# target already has, so switching DEPLOY_BACKEND must never inherit
# another target's state -- a fresh target starts from a full upload.
MANIFEST_PATH = File.join(ROOT, ".deploy_manifest#{BACKEND.manifest_suffix}.json")
# A snapshot backend (git) mirrors the whole build on every push, whatever
# it was asked to send. Two things downstream need to know that, so it is
# asked once here rather than re-derived and eventually diverging.
SNAPSHOT = BACKEND.respond_to?(:always_prunes?) && BACKEND.always_prunes?
# Orphans get deleted under --prune, unconditionally on a snapshot backend
# (whose every push mirrors the build exactly), and under --only -- where
# the orphan list holds nothing but the files this run was named and can no
# longer find on disk (see the --only block below). Naming a file is as
# deliberate as passing --prune, and it is the only way a deletion made
# between two cron ticks ever reaches the target.
PRUNES = PRUNE || SNAPSHOT || !ONLY.nil?
# The manifest is saved in batches, not after every file: on a large deploy
# that meant thousands of rewrites of a growing JSON file (hundreds of KB x
# thousands = gigabytes of writes). Periodic saving still has to happen
# though -- so an interrupted deploy can resume.
MANIFEST_SAVE_EVERY = 25
# The shape of the last build the guards below ACCEPTED -- file count and
# total bytes -- written before the first byte goes over the wire and
# never touched by how the upload ends.
#
# It exists because the guards used to measure the build against the
# manifest, and the manifest is the state of the TARGET: every failed
# upload knocked their reference out of true. The patch for that was a
# marker file that stood the guards down "for one run" -- except nothing
# deleted it while the failure persisted, so a file the host refuses every
# time (or expired credentials, or a target that is simply gone) left both
# guards off, silently, for good. Measuring build against build removes
# the reason the marker existed, so there is no longer anything to switch
# off.
#
# Deliberately WITHOUT manifest_suffix, unlike the manifest: this
# describes the build, which is identical for every target. Sharing it
# also closes a hole of its own -- switching DEPLOY_BACKEND hands the run
# an empty manifest, which used to disarm both guards without a word.
BASELINE_PATH = File.join(ROOT, '.deploy_baseline.json')

def log(msg)
  puts msg
  $stdout.flush
end

# What the manifest is about: the same backend can be pointed at another
# target (a second site, a staging directory), and a manifest describing
# the OLD one says every file is already there -- so the new target stays
# empty while the run reports success. The target is written into the file
# and checked on the way in; a mismatch throws the manifest away out loud,
# which is the same thing a missing manifest does and is always safe.
def manifest_target
  # `identity` where a backend has one (sftp: the same server with two
  # directories is two targets), `target` otherwise. Never the connection
  # string itself -- that one has to stay exactly what the tool expects.
  return BACKEND.identity.to_s if BACKEND.respond_to?(:identity)

  BACKEND.respond_to?(:target) ? BACKEND.target.to_s : ''
end

def load_manifest
  return {} unless File.exist?(MANIFEST_PATH)

  data = JSON.parse(File.read(MANIFEST_PATH))
  if data.is_a?(Hash) && data.key?('_target') && data['_target'].to_s != manifest_target
    warn "⚠️  #{MANIFEST_PATH} was written for #{data['_target']} -- this run deploys to #{manifest_target}."
    warn '   Treating it as empty: everything will be uploaded, and orphans on the new target cannot be'
    warn '   found from here. That is the safe half of the mistake; the other half would be deleting them.'
    return {}
  end
  data = data.reject { |key, _| key == '_target' } if data.is_a?(Hash)
  # Valid JSON of the wrong shape (a bare array, a number) is as unusable
  # as unparseable text, and left alone it crashes much later on
  # `stored[name]` with a bare TypeError -- exactly the place "deleting a
  # manifest is always safe" promises can't happen. Same shape check the
  # baseline already does; fall through to the loud-and-empty branch.
  return data if data.is_a?(Hash)

  raise JSON::ParserError, "not an object (#{data.class})"
rescue JSON::ParserError => e
  # Treating this as "nothing was ever uploaded" silently is how orphans
  # become permanently unprunable: the target keeps files this side no
  # longer knows about. Say it out loud. The guards are unaffected either
  # way -- their reference is the accepted build, not this file -- so an
  # unreadable manifest now costs a full re-upload and the orphan list,
  # nothing more.
  warn "⚠️  #{MANIFEST_PATH} is unreadable (#{e.message.lines.first.to_s.strip[0, 60]}) -- treating it as empty."
  warn '   Everything will be re-uploaded. Files already on the target that this build no longer generates'
  warn '   can no longer be found automatically; check the target if you have deleted posts recently.'
  {}
end

# Atomic, like every other write of state this engine depends on: the
# previous manifest survives a write that dies halfway (a full disk, a
# killed container), instead of being truncated into the unreadable file
# the branch above has to apologise for.

# Case and unicode form removed, and nothing else: used only to ask whether
# two names could be one file on a folding filesystem.
def fold_deploy_name(name)
  name.to_s.scrub.unicode_normalize(:nfc).downcase
rescue ArgumentError, Encoding::CompatibilityError
  name.to_s.scrub.downcase
end

def save_manifest(manifest)
  manifest = manifest.merge('_target' => manifest_target)
  AtomicWrite.write_json(MANIFEST_PATH, manifest)
end

def load_state
  return {} unless File.exist?(BASELINE_PATH)

  data = JSON.parse(File.read(BASELINE_PATH))
  # Wrong-shape (array, number) is corruption, not absence, and must be
  # said rather than absorbed -- an empty {} here is indistinguishable
  # from "no baseline yet", so silently returning it would hide a
  # corrupted reference exactly like the branch below refuses to.
  return data if data.is_a?(Hash)

  raise JSON::ParserError, "not an object (#{data.class})"
rescue JSON::ParserError, SystemCallError => e
  # Same tone as an unreadable manifest, and the same refusal to pretend:
  # losing this file means losing the growth guard's only reference, so it
  # gets said rather than absorbed. The run continues -- the drop guard
  # still has the manifest as a floor, and the next run records a fresh
  # baseline.
  warn "⚠️  #{BASELINE_PATH} is unreadable (#{e.message.lines.first.to_s.strip[0, 60]}) -- treating it as absent."
  warn '   The growth guard has no reference for this one run; it is recorded again below.'
  {}
end

# Atomic for the same reason as the manifest: a half-written baseline would
# be indistinguishable from a deliberate one, and the guards would trust it.
def save_state(state)
  AtomicWrite.write_json(BASELINE_PATH, state)
end

# Older manifests (before this extension) have a bare hash string as the
# value, not { hash:, size:, mtime: } -- this recognizes that shape when
# reading an old manifest and uses it as the hash without crashing.
def manifest_hash(entry)
  entry.is_a?(Hash) ? entry['hash'] : entry
end

# One shape for all four guards below. A swing has to clear BOTH an
# absolute floor and a percentage before it counts.
#
# The floor is what makes the percentage usable on a small site: 20% of a
# 32-file build is six files, so publishing two posts at once read as an
# explosion and aborted -- out of cmd_add, which has no way to pass
# --force. Percentages alone only make sense once a site is big.
def swing?(now, was, limit, floor, direction)
  return false unless was.positive?

  delta = direction == :down ? was - now : now - was
  return false unless delta >= floor

  direction == :down ? now < was * (1 - limit) : now > was * (1 + limit)
end

abort('❌ public.nosync/ does not exist -- run the build first (ruby build/build_blog.rb).') unless Dir.exist?(PUBLIC_DIR)

# An unconfigured target skips the upload rather than failing: install.md
# promises that an unedited env.sh is enough to try everything locally,
# and the authoring flow calls this after every save -- a fresh clone
# would otherwise get a red ❌ on its very first post. Logged loudly so a
# server whose env.sh lost its values doesn't look like a clean deploy.
unless DRY || BACKEND.configured?
  # "Nowhere yet" is an answer, not a half-finished setup. An unset
  # DEPLOY_BACKEND resolves to Surfer for compatibility (see
  # DeployBackend.pick), so naming that backend here told somebody who
  # had just declined a deploy target in ./setup.sh that a product they
  # have never heard of is misconfigured -- on their very first post.
  # doctor already draws this line and says "No deploy target chosen";
  # these two describe the same install and have to agree.
  #
  # The first branch borrows doctor's own two lines instead of keeping a
  # copy of them: the comment above says the two have to agree, and texts
  # that merely started out identical are exactly how they stop agreeing.
  message =
    if ENV['DEPLOY_BACKEND'].to_s.strip.empty?
      "ℹ️  #{I18n.t('doctor.backend_unset')} #{I18n.t('doctor.backend_unset_fix')}"
    else
      "ℹ️  #{I18n.t('cli.deploy_backend_incomplete', name: BACKEND.label)}"
    end
  puts message
  exit 0
end

# Asked before anything is written. A typo in the backend's extra switches
# used to surface as a raw Shellwords backtrace from the middle of the run:
# past every guard, with the baseline already on disk and the run recorded
# as started and never finished, which is what feeds the "unfinished" streak
# the header reports.
if BACKEND.respond_to?(:problem) && (args_problem = BACKEND.problem)
  abort "❌ #{args_problem}\n   #{I18n.t('cli.deploy_args_fix')}"
end

# Read before anything writes it, because the write below happens mid-run
# and the header would otherwise report this run back to itself.
STATE = load_state
PREV = STATE['last_run'].is_a?(Hash) ? STATE['last_run'] : {}

files = Dir.glob(File.join(PUBLIC_DIR, '**', '*'))
            .select { |f| File.file?(f) }
            .map { |f| f.delete_prefix("#{PUBLIC_DIR}/") }
            .sort

all_files = files
# The one case no percentage can express: with an empty manifest too,
# `0 < 0 * 0.8` is false, so a build that produced nothing at all used to
# sail through and (under --prune) take the live site with it.
abort('❌ Stopped: public.nosync/ is empty -- run the build first (ruby build/build_blog.rb).') if all_files.empty?

# The manifest is always loaded, even with --force: --force only forces
# re-uploading everything, but the list of previously uploaded files is
# still needed to find orphans. It is loaded before --only is resolved
# because what the target already has is the only thing that tells a name
# no longer being built apart from a name that never existed.
stored = load_manifest
# --force means "upload everything again", not "forget what the target
# has": starting from an empty manifest dropped every orphan still
# pending at that moment, and an orphan the manifest has forgotten can
# never be pruned -- it stays live on the target for good. The forcing
# happens in the upload selection below instead.
manifest = stored.dup

# `--only` names the files this run answers for, and a name says something
# about the file whether or not the build produced it. Three cases:
#
# * built now -- upload it.
# * not built, but the manifest says the target has it -- take it OFF the
#   target (the orphan block below). This used to abort, and that abort is
#   why deleting a file between two cron ticks never reached the site:
#   switching comment moderation off deletes comments.json locally, and
#   the rejected words stayed readable at a public URL until somebody
#   happened to run a full deploy with --prune. docs/operations.md
#   promises the opposite in as many words.
# * neither built nor on the target -- nothing to do, silently. Every tick
#   of scripts/refresh-sidebar.sh names the widget JSONs a site has not
#   configured; aborting on those stopped the cron dead, and remarking on
#   them every half hour would be cron mail nobody reads. It is worth a
#   word only when NOTHING named resolves to anything, which is what a
#   mistyped name on the command line looks like -- so that case keeps the
#   abort it always had.
if ONLY
  present = ONLY & all_files
  gone = (ONLY & stored.keys) - all_files
  unknown = ONLY - all_files - stored.keys
  abort("❌ #{unknown.join(', ')}: not found in public.nosync/.") if present.empty? && gone.empty?

  files = present
end
stats = {}
# Every file in the build gets stat'd, not just the ones this run uploads:
# the byte guards and the per-file size check both describe the BUILD, and
# under --only `files` is a name or two. Reading no contents, this is a few
# thousand stat calls -- milliseconds -- and it is what lets a snapshot
# backend (where --only widens to the whole build anyway) be checked
# honestly.
all_files.each do |name|
  stat = File.stat(File.join(PUBLIC_DIR, name))
  # Full (sub-second) mtime precision, not just whole seconds: the build can
  # finish and write hundreds of files within one second, so a timestamp
  # rounded to whole seconds could in theory make two different contents
  # written in the same second look identical, and the fast path would miss
  # the change. With a sub-second timestamp (ext4/APFS both carry one), this
  # collision window is effectively zero in practice.
  stats[name] = { 'size' => stat.size, 'mtime' => stat.mtime.to_f }
rescue Errno::ENOENT
  # Vanished between the glob and the stat -- a rebuild running in parallel.
  # Skipping it here means the guards measure what is actually on disk; a
  # file this run was asked to upload is caught below instead.
  next
end

hashes = {}
files.each do |name|
  path = File.join(PUBLIC_DIR, name)
  stat = stats[name] || abort("❌ #{name} disappeared from public.nosync/ mid-deploy -- run the build again.")

  prev = stored[name]
  # Fast path: both size and mtime match what was stored from the last
  # successful upload -- so the content couldn't have changed (see comment
  # above), no need to read and hash the whole file.
  if !FORCE && prev.is_a?(Hash) && prev['size'] == stat['size'] && prev['mtime'] == stat['mtime']
    hashes[name] = prev['hash']
  else
    hashes[name] = Digest::SHA256.file(path).hexdigest
  end
end

to_upload = ONLY || FORCE ? files : files.select { |name| manifest_hash(manifest[name]) != hashes[name] }
skipped = files.size - to_upload.size

# Orphans = uploaded at some point, but no longer in public.nosync/ (a
# deleted post, renumbered pages). Under --only the scan is narrowed to
# the named files, and that narrowing is the whole safety of it: a run
# shipping three JSONs knows nothing about the rest of the build and must
# not delete on the strength of it -- but it does know about the files it
# was named for, and one of them being gone is a deletion it was asked to
# carry out. A snapshot backend is the exception in the other direction:
# it mirrors the entire build on every push whatever it was handed, so
# there the list is the whole one even under --only.
orphan_source = ONLY && !SNAPSHOT ? ONLY & stored.keys : stored.keys
orphans = (orphan_source - all_files).sort

# An "orphan" that is only the OLD SPELLING of a file the build still has --
# IMG_2043.JPG against img_2043.jpg -- is not an orphan. On a target whose
# filesystem folds case or unicode form, the upload lands in that very
# entry, so deleting it takes the picture with it. This is measured against
# the WHOLE build, not against what this run happens to upload: measured
# against the upload list it only held for one run, and the next deploy
# (which uploads nothing) deleted the file after all. The manifest loses
# the old key too, or the same orphan is re-derived on every future run.
built_folded = all_files.to_h { |name| [fold_deploy_name(name), true] }
folded_away, orphans = orphans.partition { |name| built_folded[fold_deploy_name(name)] }
folded_away.each { |name| stored.delete(name) }

# --- what the guards measure against ------------------------------------
#
# A safeguard against a broken build. If the build only produced a fraction
# of the pages (a typo in a path, an empty content dir, a crashed run),
# --prune would happily delete the rest of the live site and the deploy
# would upload wreckage. The mirror case matters too: a sharp INCREASE is
# just as likely to be duplicate posts or an accidentally copied tree.
#
# The two directions do NOT get the same reference, and that asymmetry is
# the whole fix:
#
# * A DROP measures against the largest reference available -- the accepted
#   build, or the manifest if it happens to be bigger. Every manifest entry
#   is a file that really did upload, so a partial manifest can only ever
#   UNDERSTATE the site. As a floor it can therefore hide a drop, never
#   invent one, which makes it safe to take the maximum and keeps the guard
#   armed on an install that has no baseline yet.
# * GROWTH measures against the accepted build ONLY. The manifest
#   legitimately lags the build (a failed upload, a fresh target, a
#   switched backend), and reading that lag as growth IS the defect this
#   replaces.
BASE = STATE['build'].is_a?(Hash) ? STATE['build'] : nil
build_files = all_files.size
build_bytes = stats.values.sum { |s| s['size'] }
# Legacy manifests store a bare hash string, so they contribute no bytes at
# all -- inside the max() below that simply loses, and the byte guard
# correctly holds its fire instead of reading 0 as a collapse.
stored_bytes = stored.values.sum { |e| e.is_a?(Hash) ? e['size'].to_i : 0 }

shrink_files = [BASE.to_h['files'].to_i, stored.size].max
shrink_bytes = [BASE.to_h['bytes'].to_i, stored_bytes].max
growth_files = BASE.to_h['files'].to_i
growth_bytes = BASE.to_h['bytes'].to_i

# One-time migration off the old marker. It carried exactly one bit --
# "did the previous run finish?" -- and 1.0.1 deleted it precisely when a
# run finished with nothing failing, which is also when the manifest is
# complete. So no marker means the manifest is an honest reference, and the
# growth guard can borrow it for this one run instead of the upgrade
# costing a run with that guard asleep.
#
# Counts only, never bytes. Every manifest entry IS a file, so the count
# carries over honestly -- but entries written before the manifest grew its
# size field are bare hash strings and contribute nothing to the byte
# total. On a long-lived archive that makes stored_bytes a fraction of the
# truth (measured on the reference archive: 121 MB recorded against a
# 514 MB build), and reading that gap as growth would greet the upgrade
# with an alarming notice about media nobody added. Bytes wait one run for
# a real baseline. The same understated number stays safe as a DROP floor,
# where it can only ever hide a drop rather than invent one.
#
# All of it inside `unless ONLY` because refresh-sidebar.sh runs from cron
# every half hour with --only: it must not consume a marker that the full
# recovery run has not read yet. And !DRY because a dry run changes
# nothing. Delete this block in 1.2.
unless ONLY
  LEGACY_MARKER = "#{MANIFEST_PATH}.incomplete"
  legacy_pending = File.exist?(LEGACY_MARKER)
  growth_files = stored.size if growth_files.zero? && !legacy_pending
  File.delete(LEGACY_MARKER) if legacy_pending && !DRY
end

# Where the numbers in an abort came from. Without this the author reads
# "5000 files were expected" and goes looking in the manifest, which may
# not be what was compared at all.
ref_source = BASE ? "the last accepted build (#{BASE['at']})" : 'the manifest (no accepted build recorded yet)'
notices = []

# A batch backend can only express deletion as "mirror the whole tree"
# (rsync --delete, rclone sync), which under --only would mirror a
# two-file transfer over the entire target -- so those backends refuse the
# combination, and the named file stays live. That has to be said: the
# alternative is dropping it from the manifest as though it had been
# deleted, after which nothing on this side knows the target still serves
# it and no later --prune can find it.
if ONLY && !SNAPSHOT && orphans.any? && BACKEND.respond_to?(:sync)
  notices << "⚠️  #{orphans.join(', ')}: no longer in the build, but #{BACKEND.label} cannot delete " \
             'single files -- run ./scripts/deploy-web.sh --prune to take them off the target.'
  orphans = []
end

# --- per-file size, before the guards -----------------------------------
#
# Deliberately ahead of the swing guards: "this file is 152 MB" is
# something the author can act on, "the file count moved 23%" is not, so
# the specific message wins when both would fire. Ahead of the baseline
# write too, so a build the target can never accept never becomes the
# reference other runs are measured against.
#
# Scoped to what this run actually puts on the wire. A snapshot backend
# copies and force-pushes the whole build every time regardless of what it
# was handed (see deploy_backend/git.rb), so there an oversized file
# anywhere in the build really does bring the push down; a per-file backend
# must not refuse to run over a file it never sends.
shipped = SNAPSHOT ? all_files : to_upload
sized = ->(list) { list.map { |name| [name, stats.dig(name, 'size').to_i] } }
described = ->(list) { list.map { |(name, bytes)| "#{name} (#{FileSize.human(bytes)})" } }

too_large = sized.call(shipped).select { |(_, bytes)| FileSize.classify(bytes) == :hard }
if too_large.any?
  abort(<<~MSG)
    ❌ Stopped: #{too_large.size} file(s) are over the #{FileSize.human(FileSize::HARD_LIMIT)} per-file limit.
    #{described.call(too_large).map { |line| "     #{line}" }.join("\n")}
       One limit applies to every backend, so the site stays portable between them -- the strictest
       supported target (git pages) refuses anything larger, and --force does not lift this: the
       target would refuse the file on every run. Shrink it, or take it out of the post.
  MSG
end

# Already on the target: refusing now would strand a site that accepted such
# a file before this limit existed, so it is named rather than fatal. The
# portability it costs is the actual news.
stale_large = sized.call(all_files - shipped).select { |(_, bytes)| FileSize.classify(bytes) == :hard }
if stale_large.any?
  notices << "⚠️  #{described.call(stale_large).join(', ')} already on the target, over the " \
             "#{FileSize.human(FileSize::HARD_LIMIT)} per-file limit -- this site can no longer be moved " \
             'to a target that enforces it.'
end

# Suppressed under --only so a 60 MB video doesn't post the same line into
# cron mail every half hour from refresh-sidebar.sh.
unless ONLY
  soft_large = sized.call(shipped).select { |(_, bytes)| FileSize.classify(bytes) == :soft }
  if soft_large.any?
    shown = described.call(soft_large.first(5)).join(', ')
    more = soft_large.size > 5 ? " and #{soft_large.size - 5} more" : ''
    notices << "⚠️  Large file(s): #{shown}#{more} -- under the " \
               "#{FileSize.human(FileSize::HARD_LIMIT)} limit, but every reader pays for those bytes."
  end
end

SHRINK_LIMIT = 0.2
GROWTH_LIMIT = 0.2
# Bytes swing far more freely than file counts -- one photo is worth a
# hundred pages -- so the percentage is looser in both directions.
BYTES_SHRINK_LIMIT = 0.5
BYTES_GROWTH_NOTICE = 0.5
# Absolute floors, asymmetric on purpose. A missed growth costs transferred
# bytes that the next --prune takes back; a missed drop deletes live pages,
# and rebuild_and_deploy always passes --prune. So the drop gets a small
# floor (deleting one post from a tiny site still passes, a 32 -> 5
# collapse is a delta of 27 and stops) and growth a large one.
SHRINK_MIN_FILES = 8
GROWTH_MIN_FILES = 25
SHRINK_MIN_BYTES = 25_000_000

# `--only` stands the guards down because a run that ships three named
# files has nothing to say about the shape of the whole build -- true for
# every per-file backend, and false for a snapshot one. git pages copies
# and force-pushes the ENTIRE build whatever it was handed (see
# deploy_backend/git.rb, and `sync`'s own "--only widens to the full
# build"), so there `--only` disarms four guards over a push that replaces
# the live site. The half-hourly refresh-sidebar cron is exactly such a
# run: a broken build it never looked at would go out unexamined, and a
# force-push leaves nothing to restore from. Same reasoning, and the same
# SNAPSHOT test, as the per-file size limit above.

if (!ONLY || SNAPSHOT) && !FORCE && swing?(build_files, shrink_files, SHRINK_LIMIT, SHRINK_MIN_FILES, :down)
  abort(<<~MSG)
    ❌ Stopped: public.nosync/ has #{build_files} files, but #{shrink_files} were expected from #{ref_source}.
       That's a #{(100 - (build_files * 100.0 / shrink_files)).round}% drop -- looks like a broken build.
       Check the build output. If the drop is expected (you deleted a lot of posts), run again with --force.
  MSG
end

# What the counts cannot see: the same number of files, each of them nearly
# empty. A broken template or a lost media prefix does exactly that.
if (!ONLY || SNAPSHOT) && !FORCE && swing?(build_bytes, shrink_bytes, BYTES_SHRINK_LIMIT, SHRINK_MIN_BYTES, :down)
  abort(<<~MSG)
    ❌ Stopped: public.nosync/ holds #{FileSize.human(build_bytes)}, but #{FileSize.human(shrink_bytes)} were expected from #{ref_source}.
       The file count looks reasonable, so this is content going missing inside the pages rather than pages going missing.
       Check the build output. If the drop is expected, run again with --force.
  MSG
end

# Typically duplicate posts (build_blog.rb has its own safeguard against a
# matching year/slug, but not against duplication of some other kind), a
# badly merged import, or an accidentally copied tree. Normal growth is a
# handful of files per published post.
if (!ONLY || SNAPSHOT) && !FORCE && swing?(build_files, growth_files, GROWTH_LIMIT, GROWTH_MIN_FILES, :up)
  abort(<<~MSG)
    ❌ Stopped: public.nosync/ has #{build_files} files, only #{growth_files} were expected from #{ref_source}.
       That's a #{((build_files * 100.0 / growth_files) - 100).round}% increase -- looks like a duplicated or broken build.
       Check the build output. If the increase is expected (a bulk import/migration), run again with --force.
  MSG
end

# A notice, not an abort: adding a video IS authoring, not a malfunction,
# and the one genuinely fatal case -- a single enormous file -- is caught
# precisely, by name, by the per-file limit. Aborting on the total would
# just recreate the dead end this whole change removes, in the flows that
# cannot pass --force.
if (!ONLY || SNAPSHOT) && !FORCE && swing?(build_bytes, growth_bytes, BYTES_GROWTH_NOTICE, 0, :up)
  notices << "⚠️  The build grew from #{FileSize.human(growth_bytes)} to #{FileSize.human(build_bytes)} " \
             "since #{ref_source} -- expected if you added media, worth a look if you didn't."
end

log('')
log("Deploy web -> #{BACKEND.label}: #{BACKEND.target}#{DRY ? '  [DRY-RUN]' : ''}")
# What the marker used to switch off is now simply reported. The previous
# run's outcome is the diagnosis the old dead end never gave: a deploy that
# keeps failing says so, every time, instead of quietly standing the guards
# down and looking healthy.
if PREV['outcome'] && PREV['outcome'] != 'ok'
  log("  ℹ️  Previous deploy (#{PREV['at']}, #{PREV['backend']}) ended as '#{PREV['outcome']}': " \
      "uploaded #{PREV['uploaded'].to_i}, failed #{PREV['failed'].to_i}. " \
      'This run re-diffs against the manifest; the guards apply as normal.')
end
# Deliberately a warning and not an abort, however high the streak gets:
# stopping after N attempts would rebuild the dead end from the other side.
if PREV['unfinished_streak'].to_i >= 3
  log("  ⚠️  #{PREV['unfinished_streak']} deploys in a row have not finished -- something is being refused every " \
      'time (an oversized file, credentials, the target). The guards are on; the failures below say what.')
end
notices.each { |n| log("  #{n}") }
# Keyed on the reference actually in hand, not on BASE: with no baseline
# but a manifest the migration above trusts, the growth guard DOES run --
# saying otherwise would be a comforting lie about which check is live.
if growth_files.zero?
  log('  ℹ️  Nothing to measure growth against yet -- that guard stands down for this one run ' \
      '(the drop guard still measures against the manifest).')
end
log("  #{files.size} file(s) selected, #{FileSize.human(build_bytes)} in the build, " \
    "#{to_upload.size} new/changed, #{skipped} unchanged (skipped)")
if orphans.any?
  why = if PRUNE then ' (--prune)'
        elsif SNAPSHOT then ' (snapshot deploy)'
        else ' (named in --only, no longer in the build)'
        end
  log(PRUNES ? "  #{orphans.size} orphan(s) to delete#{why}" \
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
# The guards accepted this build, so it becomes their reference -- recorded
# BEFORE the first byte moves and regardless of how the upload ends. That
# ordering is what separates "the target went away" from "the build is
# broken": the next run knows what shape was last considered sane, whether
# or not it made it onto the target.
#
# --only never touches this. Its build shape was never validated (the
# guards don't run under --only), so promoting it would let the sidebar
# cron launder a broken build into the reference.
#
# 'started' is the value that survives in the file when the process never
# reaches `ensure` (SIGKILL, power loss) -- that's the diagnosis, not a
# special case to code around.
unless ONLY
  STATE['version'] = 1
  STATE['build'] = { 'files' => build_files, 'bytes' => build_bytes, 'at' => Time.now.iso8601 }
  STATE['last_run'] = { 'at' => Time.now.iso8601, 'backend' => BACKEND.label, 'outcome' => 'started',
                        'to_upload' => to_upload.size,
                        'unfinished_streak' => PREV['unfinished_streak'].to_i + 1 }
  save_state(STATE)
end
begin
  if BACKEND.respond_to?(:sync)
    # Batch backend (rsync): one run covers everything, so the manifest is
    # updated wholesale on success -- and not at all on failure, since a
    # batch backend re-diffs against the target on the next run anyway.
    # `files`, not ONLY: a name the build no longer produces has been taken
    # out of it above, and handing it to --files-from would fail the whole
    # transfer over a file that is meant to be gone.
    if BACKEND.sync(public_dir: PUBLIC_DIR, files: to_upload, orphans: orphans,
                    only: ONLY && files, prune: PRUNES && orphans.any?,
                    force: FORCE, logger: method(:log))
      to_upload.each do |name|
        manifest[name] = { 'hash' => hashes[name], 'size' => stats[name]['size'], 'mtime' => stats[name]['mtime'] }
      end
      ok = to_upload.size
      if PRUNES
        # A backend that can tell WHICH deletes failed (sftp) keeps those
        # in the manifest, so the prune is retried next run instead of the
        # file staying live on the target with nothing left knowing it.
        kept = BACKEND.respond_to?(:failed_orphans) ? BACKEND.failed_orphans : []
        orphans.each { |name| manifest.delete(name) unless kept.include?(name) }
        deleted = orphans.size - kept.size
        failed += kept.size
        kept.each { |name| log("  ❌ delete failed, kept in manifest: #{name}") }
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
rescue Surfer::Unreachable => e
  # The one failure that means NOTHING happened on the target: the
  # connection never opened. The ensure below still runs, so the state
  # file records this run as 'interrupted' and the next one says so in
  # its header -- what must not happen is the raw backtrace this used
  # to be, on the likeliest beginner mistakes there are: the app is
  # stopped, or SURFER_URL points at a machine where nothing listens.
  abort(I18n.t('cli.surfer_unreachable', url: ENV['SURFER_URL'].to_s, reason: e.message))
ensure
  save_manifest(manifest)
  # `completed` no longer decides whether a marker survives -- it is how a
  # run that finished with N files failing is told apart from one that
  # unwound through here, and that distinction is now reported in the next
  # run's header instead of silently changing what the guards do.
  unless ONLY
    outcome = completed ? (failed.zero? ? 'ok' : 'failed') : 'interrupted'
    STATE['last_run'] = STATE['last_run'].to_h.merge(
      'at' => Time.now.iso8601, 'outcome' => outcome,
      'uploaded' => ok, 'deleted' => deleted, 'failed' => failed,
      'unfinished_streak' => outcome == 'ok' ? 0 : STATE['last_run'].to_h['unfinished_streak'].to_i
    )
    begin
      save_state(STATE)
    rescue StandardError => e
      # Bookkeeping must not become the error the author sees: without this
      # a dropped SSH session would surface as a JSON write failure.
      warn "⚠️  Could not record the deploy outcome in #{BASELINE_PATH}: #{e.class}: #{e.message.lines.first.to_s.strip}"
    end
  end
end

log('')
log("Done: uploaded #{ok}, deleted #{deleted}, failed #{failed}, unchanged #{skipped}")
log('')
exit(failed.zero? ? 0 : 1)
