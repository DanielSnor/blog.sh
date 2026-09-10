# frozen_string_literal: true

require 'fileutils'
require_relative '../path_safety'

module DeployBackend
  # Copies the build into a directory on this machine -- for a site served
  # by a local nginx/Caddy, a mounted volume, or just trying the engine
  # out with no remote target at all. DEPLOY_TARGET_DIR in env.sh.
  module Local
    module_function

    def label
      'local directory'
    end

    def configured?
      !dir.empty?
    end

    # env.sh.example and docs/install.md both show an absolute path, and
    # this is a hand-edited file: drop the leading slash -- the same shape
    # an unmounted mountpoint has -- and the whole site was deployed into
    # a directory of that name INSIDE the installation, quietly and
    # successfully. A relative target is not a target anybody meant.
    def problem
      return nil if dir.empty? || dir.start_with?('/')

      I18n.t('cli.deploy_target_relative', dir: dir)
    end

    def dir
      ENV['DEPLOY_TARGET_DIR'].to_s
    end

    def target
      dir
    end

    def manifest_suffix
      '.local'
    end

    def session
      yield Session.new(File.expand_path(dir))
    end

    class Session
      # The target path arrives from ENV, and ENV strings carry the
      # LOCALE's encoding -- which under cron, where LANG is unset, is
      # ASCII-8BIT. Interpolating those bytes into the UTF-8 log lines
      # below raised Encoding::CompatibilityError AFTER the copy had
      # already succeeded, so the blanket rescue reported every file as
      # failed: files on disk, an empty manifest, exit 1, and a pending
      # deploy warned about on every tick from then on. Setting
      # Encoding.default_external does not reach ENV, so the label has to
      # be fixed here.
      #
      # And normalised here rather than trusted to the caller. `delete`
      # walks UP from what it removed, taking out the directories it
      # empties, and stops on `dir != @root` -- a comparison of STRINGS. A
      # root handed over as "/var/www/blog/" is never equal to what
      # File.dirname produces, so the walk went past it and removed the
      # deploy target itself, and kept going while the parents were empty.
      # The one caller in the engine passes File.expand_path(dir), which
      # trims the slash, so nothing reached it -- but that was an
      # agreement written nowhere, and a class whose delete can remove the
      # directory it was built around should not depend on one.
      # expand_path keeps a binary string's bytes, so the encoding repair
      # below still sees what cron handed over.
      def initialize(root)
        expanded = File.expand_path(root)
        @root = expanded.dup.force_encoding(Encoding::UTF_8)
        @root = expanded.dup.force_encoding(Encoding::ASCII_8BIT) unless @root.valid_encoding?
      end

      def upload(path, logger: nil, remote_name: nil)
        dest = File.join(@root, remote_name || File.basename(path))
        # The remote name is a path relative to the site's output, and it
        # is composed from what the build wrote -- so it carries whatever
        # a post file put in an address. Held to the target root here
        # because this backend's copy is a plain filesystem write: nothing
        # between it and the disk would notice a name that climbs out of
        # the directory the operator pointed the deploy at.
        PathSafety.contained!(@root, dest, 'deploy target')
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(path, dest)
        logger&.call("  ✅ copy -> #{dest}")
        :ok
      rescue StandardError => e
        logger&.call("  ❌ copy failed: #{e.class}: #{e.message}")
        :failed
      end

      # Removes the file and then any directories the removal emptied --
      # the target-side mirror of prune_public's directory collapsing.
      def delete(remote_name, logger: nil)
        path = File.join(@root, remote_name)
        # A delete is the half that cannot be taken back, and the loop
        # below walks UP from it removing directories it empties.
        PathSafety.contained!(@root, path, 'deploy target')
        return :missing unless File.exist?(path)

        File.delete(path)
        dir = File.dirname(path)
        while dir != @root && Dir.exist?(dir) && Dir.empty?(dir)
          Dir.rmdir(dir)
          dir = File.dirname(dir)
        end
        logger&.call("  🗑️  deleted -> #{path}")
        :ok
      rescue StandardError => e
        logger&.call("  ❌ delete failed: #{e.class}: #{e.message}")
        :failed
      end
    end
  end
end
