# frozen_string_literal: true

require_relative 'deploy_backend/surfer'
require_relative 'deploy_backend/local'
require_relative 'deploy_backend/rsync'
require_relative 'deploy_backend/git'
require_relative 'deploy_backend/rclone'

# lib/deploy_backend.rb -- picks where ./scripts/deploy-web.sh ships the
# build. Selected by DEPLOY_BACKEND in env.sh (surfer | local | rsync |
# git | rclone); unset falls back to Surfer, which was the only target
# before backends existed -- an old env.sh with just the SURFER_* values
# keeps working untouched.
#
# The contract every backend implements:
#   label            human name for the deploy log
#   configured?      are its env.sh settings present
#   target           destination string for the log header
#   manifest_suffix  distinguishes .deploy_manifest*.json per target, so
#                    switching backends can't reuse another target's state
# plus ONE of:
#   session { |s| }  per-file: yields a handle whose upload/delete return
#                    :ok/:failed/:missing/:skipped, like lib/surfer.rb
#   sync(...)        batch: one run covers the whole build (e.g. rsync,
#                    which does its own delta-diffing against the target)
# and optionally:
#   always_prunes?   true for snapshot backends (git) whose every deploy
#                    mirrors the build exactly, deleting orphans with or
#                    without --prune -- deploy_web.rb keeps its manifest
#                    and messages honest about that
#
# deploy_web.rb's manifest diff and the shrink/growth safeguards run
# BEFORE either path -- they're target-independent on purpose, so even a
# batch backend with its own diffing (rsync --delete would happily mirror
# a broken build) stays behind the same guards.
#
# Roadmap: an SFTP backend (openssh's `sftp -b` batch mode) would fit the
# same contract for hosts that offer neither rsync nor git.
module DeployBackend
  BACKENDS = {
    'surfer' => Surfer,
    'local' => Local,
    'rsync' => Rsync,
    'git' => Git,
    'rclone' => Rclone
  }.freeze

  def self.pick
    name = ENV['DEPLOY_BACKEND'].to_s
    return Surfer if name.empty?

    BACKENDS.fetch(name) do
      abort("❌ Unknown DEPLOY_BACKEND '#{name}' -- known backends: #{BACKENDS.keys.join(', ')}")
    end
  end
end
