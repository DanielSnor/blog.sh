# frozen_string_literal: true

require 'fileutils'

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
      def initialize(root)
        @root = root.dup.force_encoding(Encoding::UTF_8)
        @root = root.dup.force_encoding(Encoding::ASCII_8BIT) unless @root.valid_encoding?
      end

      def upload(path, logger: nil, remote_name: nil)
        dest = File.join(@root, remote_name || File.basename(path))
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
