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
require_relative '../lib/path_glob'
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
  raw = if BACKEND.respond_to?(:identity)
          BACKEND.identity.to_s
        elsif BACKEND.respond_to?(:target)
          BACKEND.target.to_s
        else
          ''
        end
  settle_target(raw)
end

# Two spellings of one place are one target. A trailing slash, a doubled
# one, `./` in front, `..` in the middle, a relative path where an
# absolute one stood -- none of them moves the site anywhere, and all of
# them used to throw the manifest away and re-upload everything (losing
# the orphan list with it, which is the expensive half). A remote address
# keeps its shape: only the path part after the colon is tidied, because
# `user@host:` is the tool's syntax, not ours.
def settle_target(raw)
  return raw if raw.empty?

  head, sep, tail = raw.rpartition(':')
  path = sep.empty? ? raw : tail
  return raw if path.empty? || path.start_with?('#')

  settled = path.start_with?('/') ? File.expand_path(path) : path.squeeze('/').chomp('/')
  settled = settled.sub(%r{\A\./}, '')
  sep.empty? ? settled : "#{head}#{sep}#{settled}"
end

def load_manifest
  return {} unless File.exist?(MANIFEST_PATH)

  data = JSON.parse(File.read(MANIFEST_PATH))
  if data.is_a?(Hash) && data.key?('_target') && data['_target'].to_s != manifest_target
    warn I18n.t('cli.deploy_manifest_foreign', path: MANIFEST_PATH,
                                               was: data['_target'], now: manifest_target)
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
rescue JSON::ParserError, SystemCallError => e
  # Treating this as "nothing was ever uploaded" silently is how orphans
  # become permanently unprunable: the target keeps files this side no
  # longer knows about. Say it out loud. The guards are unaffected either
  # way -- their reference is the accepted build, not this file -- so an
  # unreadable manifest now costs a full re-upload and the orphan list,
  # nothing more. SystemCallError as well as a parse error: a manifest left
  # root-owned by one sudo run (the uid trap this project keeps hitting on
  # its own servers) raised a raw EACCES here and killed every deploy,
  # while load_state twenty lines down already degraded gracefully on the
  # very same class.
  warn I18n.t('cli.deploy_manifest_unreadable', path: MANIFEST_PATH,
                                                reason: e.message.lines.first.to_s.strip[0, 60])
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
  true
rescue SystemCallError => e
  # The manifest is bookkeeping, exactly like the baseline save_state
  # writes -- and save_state has always refused to let bookkeeping become
  # the error the author sees. save_manifest did not: a full disk (or a
  # read-only root) at the periodic mid-upload save, or in the ensure
  # block, killed a working transfer at the 25th file with a raw backtrace
  # and left the run's own outcome record unwritten. Losing the manifest
  # costs one full re-upload next time, which is worth a sentence and not
  # worth dying over.
  warn "⚠️  #{MANIFEST_PATH}: #{e.message.lines.first.to_s.strip}"
  warn "   #{I18n.t('cli.deploy_state_unwritable')}"
  false
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
  warn I18n.t('cli.deploy_baseline_unreadable', path: BASELINE_PATH,
                                                reason: e.message.lines.first.to_s.strip[0, 60])
  {}
end

# Atomic for the same reason as the manifest: a half-written baseline would
# be indistinguishable from a deliberate one, and the guards would trust it.
def save_state(state)
  AtomicWrite.write_json(BASELINE_PATH, state)
rescue SystemCallError => e
  # A full disk is the ordinary way this fails, and it used to end the run
  # in a raw backtrace out of File#initialize -- no sentence, nothing said
  # about what had or had not been uploaded. The state file is bookkeeping:
  # losing it costs one full re-upload next time, which is worth saying and
  # not worth dying over.
  warn "⚠️  #{BASELINE_PATH}: #{e.message.lines.first.to_s.strip}"
  warn "   #{I18n.t('cli.deploy_state_unwritable')}"
  false
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

abort(I18n.t('cli.deploy_public_missing')) unless Dir.exist?(PUBLIC_DIR)

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

files = PathGlob.under(PUBLIC_DIR, '**', '*')
            .select { |f| File.file?(f) }
            .map { |f| f.delete_prefix("#{PUBLIC_DIR}/") }
            .sort

all_files = files
# The one case no percentage can express: with an empty manifest too,
# `0 < 0 * 0.8` is false, so a build that produced nothing at all used to
# sail through and (under --prune) take the live site with it.
abort(I18n.t('cli.deploy_public_empty')) if all_files.empty?

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
  abort(I18n.t('cli.deploy_only_unknown', names: unknown.join(', '))) if present.empty? && gone.empty?

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
  stat = stats[name] || abort(I18n.t('cli.deploy_file_vanished', name: name))

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

# A file whose CONTENT still matches what was uploaded, but whose size or
# mtime has moved since -- a rebuild that rewrote it byte for byte, a
# re-copy, a restored backup -- kept its old size and mtime here, because
# only an upload ever refreshed them. The fast path above then missed on
# that file on every deploy from then on and read it in full to hash it,
# for ever, with nothing to show for it: on an archive with gigabytes of
# media that is minutes per deploy. One sweep that touched the whole tree
# was enough to disarm it permanently.
#
# Safe to record even if the upload of other files fails afterwards: the
# hash is unchanged and the content matches it, so this is simply where
# that content now sits.
(files - to_upload).each do |name|
  entry = manifest[name]
  next unless entry.is_a?(Hash)

  entry['size'] = stats[name]['size']
  entry['mtime'] = stats[name]['mtime']
end

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
# Out of BOTH: `manifest` is a copy taken before this line, so deleting
# from `stored` alone left the old spelling in the file that gets written
# -- for good, since the next run compares against a name the build no
# longer produces and nothing ever takes it out.
folded_away.each do |name|
  stored.delete(name)
  manifest.delete(name)
end

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
ref_source = BASE ? I18n.t('cli.deploy_ref_baseline', at: BASE['at']) : I18n.t('cli.deploy_ref_manifest')
notices = []

# This refusal was written when deletion on a batch backend meant "mirror
# the whole tree" (rsync --delete, rclone sync), which under --only would
# have mirrored a two-file transfer over the entire target. Since those
# backends delete the orphans BY NAME, the reason is gone -- and the cost
# of keeping the refusal was not theoretical: refresh-sidebar.sh runs
# --only=comments.json every half hour, so a comments.json full of
# rejected comments stayed publicly readable while the cron announced the
# fact twice an hour and nothing ever took it down.
#
# --prune still has to be asked for; --only alone changes nothing. What is
# fixed here is that asking for both now works instead of being refused.
if ONLY && !SNAPSHOT && orphans.any? && BACKEND.respond_to?(:sync) && !BACKEND.respond_to?(:deletes_by_name?)
  notices << I18n.t('cli.deploy_orphans_no_single_delete', names: orphans.join(', '), backend: BACKEND.label)
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
  abort(I18n.t('cli.deploy_files_too_large', count: too_large.size,
                                             limit: FileSize.human(FileSize::HARD_LIMIT),
                                             list: described.call(too_large).map { |line| "     #{line}" }.join("\n")))
end

# Already on the target: refusing now would strand a site that accepted such
# a file before this limit existed, so it is named rather than fatal. The
# portability it costs is the actual news.
# ...and only for files the manifest has actually seen. Under --only,
# `shipped` is the one or two named files, so everything else in the build
# fell in here -- including files that have never been uploaded at all,
# announced as sitting on the target with a portability conclusion drawn
# from it. The neighbouring soft-limit notice is suppressed under --only
# for the same reason: refresh-sidebar.sh fires one every 30 minutes.
stale_large = sized.call((all_files - shipped).select { |name| manifest.key?(name) })
               .select { |(_, bytes)| FileSize.classify(bytes) == :hard }
if stale_large.any?
  notices << I18n.t('cli.deploy_stale_too_large', files: described.call(stale_large).join(', '),
                                                  limit: FileSize.human(FileSize::HARD_LIMIT))
end

# Suppressed under --only so a 60 MB video doesn't post the same line into
# cron mail every half hour from refresh-sidebar.sh.
unless ONLY
  soft_large = sized.call(shipped).select { |(_, bytes)| FileSize.classify(bytes) == :soft }
  if soft_large.any?
    shown = described.call(soft_large.first(5)).join(', ')
    more = soft_large.size > 5 ? I18n.t('cli.deploy_large_files_more', count: soft_large.size - 5) : ''
    notices << I18n.t('cli.deploy_large_files', files: shown, more: more,
                                                limit: FileSize.human(FileSize::HARD_LIMIT))
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
  abort(I18n.t('cli.deploy_guard_shrink_files', have: build_files, expected: shrink_files,
                                                source: ref_source,
                                                percent: (100 - (build_files * 100.0 / shrink_files)).round))
end

# What the counts cannot see: the same number of files, each of them nearly
# empty. A broken template or a lost media prefix does exactly that.
if (!ONLY || SNAPSHOT) && !FORCE && swing?(build_bytes, shrink_bytes, BYTES_SHRINK_LIMIT, SHRINK_MIN_BYTES, :down)
  abort(I18n.t('cli.deploy_guard_shrink_bytes', have: FileSize.human(build_bytes),
                                                expected: FileSize.human(shrink_bytes),
                                                source: ref_source))
end

# Typically duplicate posts (build_blog.rb has its own safeguard against a
# matching year/slug, but not against duplication of some other kind), a
# badly merged import, or an accidentally copied tree. Normal growth is a
# handful of files per published post.
if (!ONLY || SNAPSHOT) && !FORCE && swing?(build_files, growth_files, GROWTH_LIMIT, GROWTH_MIN_FILES, :up)
  abort(I18n.t('cli.deploy_guard_growth_files', have: build_files, expected: growth_files,
                                                source: ref_source,
                                                percent: ((build_files * 100.0 / growth_files) - 100).round))
end

# A notice, not an abort: adding a video IS authoring, not a malfunction,
# and the one genuinely fatal case -- a single enormous file -- is caught
# precisely, by name, by the per-file limit. Aborting on the total would
# just recreate the dead end this whole change removes, in the flows that
# cannot pass --force.
if (!ONLY || SNAPSHOT) && !FORCE && swing?(build_bytes, growth_bytes, BYTES_GROWTH_NOTICE, 0, :up)
  notices << I18n.t('cli.deploy_growth_notice', was: FileSize.human(growth_bytes),
                                                now: FileSize.human(build_bytes), source: ref_source)
end

log('')
log("#{I18n.t('cli.deploy_header', backend: BACKEND.label, target: BACKEND.target)}#{DRY ? '  [DRY-RUN]' : ''}")
# What the marker used to switch off is now simply reported. The previous
# run's outcome is the diagnosis the old dead end never gave: a deploy that
# keeps failing says so, every time, instead of quietly standing the guards
# down and looking healthy.
if PREV['outcome'] && PREV['outcome'] != 'ok'
  log("  #{I18n.t('cli.deploy_prev_outcome', at: PREV['at'], backend: PREV['backend'],
                                             outcome: PREV['outcome'], uploaded: PREV['uploaded'].to_i,
                                             failed: PREV['failed'].to_i)}")
end
# Deliberately a warning and not an abort, however high the streak gets:
# stopping after N attempts would rebuild the dead end from the other side.
if PREV['unfinished_streak'].to_i >= 3
  log("  #{I18n.t('cli.deploy_unfinished_streak', count: PREV['unfinished_streak'])}")
end
notices.each { |n| log("  #{n}") }
# Keyed on the reference actually in hand, not on BASE: with no baseline
# but a manifest the migration above trusts, the growth guard DOES run --
# saying otherwise would be a comforting lie about which check is live.
log("  #{I18n.t('cli.deploy_no_growth_reference')}") if growth_files.zero?
log("  #{I18n.t('cli.deploy_selection', files: files.size, bytes: FileSize.human(build_bytes),
                                        changed: to_upload.size, unchanged: skipped)}")
if orphans.any?
  why = if PRUNE then I18n.t('cli.deploy_orphans_why_prune')
        elsif SNAPSHOT then I18n.t('cli.deploy_orphans_why_snapshot')
        else I18n.t('cli.deploy_orphans_why_only')
        end
  log(PRUNES ? "  #{I18n.t('cli.deploy_orphans_delete', count: orphans.size, why: why)}" \
             : "  #{I18n.t('cli.deploy_orphans_kept', count: orphans.size)}")
end

if DRY
  to_upload.each { |name| log("  [dry] #{name} (#{File.size(File.join(PUBLIC_DIR, name))} B)") }
  dry_word = I18n.t(PRUNES ? 'cli.deploy_dry_delete' : 'cli.deploy_dry_orphan')
  orphans.each { |name| log("  [dry] #{dry_word} #{name}") }
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
        kept.each { |name| log("  #{I18n.t('cli.deploy_delete_failed_kept', name: name)}") }
      end
    else
      failed = 1
      # A batch backend that can say WHICH files landed before it stopped
      # (sftp) has them written down, exactly as failed_orphans are: an
      # upload interrupted at file 48 of 159 used to record nothing, so the
      # next run began again from the first one -- and on a slow line a
      # deploy that always restarts is a deploy that never finishes.
      landed = BACKEND.respond_to?(:uploaded) ? BACKEND.uploaded : []
      landed.each do |name|
        next unless hashes[name]

        manifest[name] = { 'hash' => hashes[name], 'size' => stats[name]['size'],
                           'mtime' => stats[name]['mtime'] }
      end
      ok = landed.size
      # What did NOT land, so uploaded + failed + unchanged adds up to the
      # number of files the run set out with. "failed 1" for a batch of
      # twenty-nine was a count of failed BATCHES, printed in a line that
      # says files.
      # ...but never fewer than one. The backend said it failed, and on a
      # backend that cannot name what landed (rsync, rclone) this
      # subtraction is 0 - 0 whenever nothing needed uploading -- the
      # ordinary shape of "I removed one unused asset and redeployed".
      # The run then recorded itself as ok, reset the unfinished streak,
      # printed "uploaded 0, deleted 0, failed 0" and exited 0, with the
      # backend's own failure line sitting in the middle of the log.
      failed = [to_upload.size - landed.size, 1].max
      log("  #{I18n.t('cli.deploy_partial_landed', count: landed.size)}") if landed.any?
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
      warn I18n.t('cli.deploy_outcome_unrecorded', path: BASELINE_PATH,
                                                   error: "#{e.class}: #{e.message.lines.first.to_s.strip}")
    end
  end
end

log('')
log(I18n.t('cli.deploy_done', uploaded: ok, deleted: deleted, failed: failed, unchanged: skipped))
log('')
exit(failed.zero? ? 0 : 1)
