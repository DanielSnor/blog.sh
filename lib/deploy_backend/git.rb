# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module DeployBackend
  # Pushes the build as a single-commit snapshot to a git branch --
  # GitHub/GitLab/Codeberg Pages then serve it, with HTTPS and hosting for
  # free. GIT_PAGES_REMOTE is any git remote URL (typically SSH);
  # GIT_PAGES_BRANCH defaults to gh-pages; GIT_PAGES_CNAME optionally
  # writes a CNAME file for a custom domain (GitHub stores custom-domain
  # config as a CNAME file *in the branch*, so a snapshot push would
  # silently wipe one configured through the UI -- setting it here
  # re-writes it on every deploy instead).
  #
  # Every deploy builds a fresh throwaway repo and force-pushes one
  # commit: no persistent clone to keep in sync, no merge conflicts, and
  # the served branch always equals the build exactly. That also means
  # orphans disappear on every push, --prune or not (always_prunes?).
  # The branch keeps no site history on purpose -- the source repo
  # already has it. A .nojekyll file is added so GitHub Pages serves the
  # files verbatim instead of running them through Jekyll.
  module Git
    module_function

    def label
      'git pages'
    end

    def configured?
      !remote.empty?
    end

    def remote
      ENV['GIT_PAGES_REMOTE'].to_s
    end

    def branch
      b = ENV['GIT_PAGES_BRANCH'].to_s
      b.empty? ? 'gh-pages' : b
    end

    def target
      "#{remote} (branch #{branch})"
    end

    def manifest_suffix
      '.git'
    end

    # A snapshot mirrors the whole build every run, so orphaned files are
    # deleted with or without --prune -- deploy_web.rb reads this to keep
    # its manifest and log messages honest about that.
    def always_prunes?
      true
    end

    # only: is ignored on purpose: a snapshot must always carry the whole
    # build -- pushing just the listed files would delete everything else
    # from the branch. public_dir already contains the full site, so a
    # full snapshot gives --only callers (refresh-sidebar.sh) what they
    # meant anyway. prune: is likewise moot (see always_prunes?), force:
    # has nothing to skip, and files:/orphans: go unused -- every push is
    # a full snapshot regardless.
    def sync(public_dir:, files: nil, orphans: nil, only: nil, prune: false, force: false, logger: nil)
      logger&.call('  (snapshot deploy: --only widens to the full build)') if only

      Dir.mktmpdir('blog-sh-git') do |tmp|
        work = File.join(tmp, 'site')
        FileUtils.mkdir_p(work)
        FileUtils.cp_r(File.join(public_dir, '.'), work)
        File.write(File.join(work, '.nojekyll'), '')
        cname = ENV['GIT_PAGES_CNAME'].to_s
        File.write(File.join(work, 'CNAME'), "#{cname}\n") unless cname.empty?

        git = ->(*cmd) { system('git', '-C', work, *cmd) }
        unless git.call('init', '-q') && git.call('symbolic-ref', 'HEAD', "refs/heads/#{branch}")
          logger&.call('  ❌ git init failed')
          return false
        end

        # Committing needs an identity; the throwaway repo inherits the
        # user's global config, and only when there is none does a neutral
        # fallback kick in -- a deploy must not fail over a missing name.
        email = IO.popen(['git', '-C', work, 'config', 'user.email'], &:read).to_s.strip
        identity = email.empty? ? ['-c', 'user.name=deploy', '-c', 'user.email=deploy@localhost'] : []

        ok = git.call('-c', 'core.excludesFile=/dev/null', 'add', '-A', '-f') &&
             system('git', '-C', work, *identity, 'commit', '-q', '-m',
                    "Deploy #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}") &&
             git.call('push', '-q', '--force', remote, "HEAD:refs/heads/#{branch}")
        logger&.call(ok ? "  ✅ pushed snapshot -> #{target}" : '  ❌ git commit/push failed')
        !!ok
      end
    end
  end
end
