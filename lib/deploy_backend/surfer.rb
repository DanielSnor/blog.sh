# frozen_string_literal: true

require_relative '../surfer'

module DeployBackend
  # Cloudron Surfer (Files API) -- the original target this engine was
  # built around, and the default when DEPLOY_BACKEND is unset. A thin
  # adapter: the HTTP client itself lives in lib/surfer.rb.
  module Surfer
    module_function

    def label
      'Surfer'
    end

    def configured?
      ::Surfer.configured?
    end

    def target
      dir = ENV['SURFER_REMOTE_DIR'].to_s
      ENV['SURFER_URL'].to_s.chomp('/') + (dir.empty? ? '' : "/#{dir}")
    end

    # Deliberately empty: the manifest stays at its historical
    # .deploy_manifest.json name, so a deployment from before backends
    # existed keeps its state without re-uploading anything.
    def manifest_suffix
      ''
    end

    def session(&block)
      ::Surfer.session(&block)
    end
  end
end
