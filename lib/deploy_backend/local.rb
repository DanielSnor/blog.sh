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
      def initialize(root)
        @root = root
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
