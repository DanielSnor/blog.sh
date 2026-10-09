# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

# lib/launcher.rb -- an icon in Applications that opens this site's blog.sh.
#
# For the author who does not live in a terminal: the first sentence of
# every instruction this engine has is "open Terminal, go to the folder of
# your site and type ./blog.sh", and that sentence is three things to get
# wrong before anything has been written. A launcher is that sentence as a
# thing to double-click. It opens Terminal in the site's folder and runs
# ./blog.sh there -- nothing more; it has no window of its own and knows
# nothing blog.sh does not.
#
# macOS only, and built from what macOS ships: osacompile turns four lines
# of AppleScript into an application, sips and iconutil make its icon out
# of the site's favicon, codesign seals it again afterwards. Nothing is
# installed and nothing is downloaded.
#
# The site's folder is written INTO the launcher. One site, one launcher;
# a site that moves wants its launcher made again, which is the same
# command.
#
# Two things about it are macOS's and cannot be arranged from here: the
# first double-click asks whether this application may control Terminal
# (once; refused, the launcher does nothing until it is allowed in System
# Settings), and Terminal keeps the window open after blog.sh ends unless
# its own profile says to close it. The wizard says both.
module Launcher
  module_function

  COMPILER = '/usr/bin/osacompile'
  SIGNER = '/usr/bin/codesign'
  # What iconutil wants in an iconset: each size and its double.
  ICON_SIZES = [16, 32, 128, 256, 512].freeze
  # A file inside the bundle naming the site it opens. It is how a launcher
  # is told from an application that merely has the same name -- and that
  # one is never replaced.
  MARK = 'blog-sh-site'

  def supported?
    RUBY_PLATFORM.include?('darwin') && File.executable?(COMPILER)
  end

  # Where launchers go. /Applications is where somebody looks for an
  # application; an account that may not write there has an Applications
  # folder of its own, which Launchpad and Spotlight read just the same.
  # BLOG_SH_LAUNCHER_DIR is for whoever wants it elsewhere -- and for the
  # tests, which must never put anything among a person's applications.
  def directory
    chosen = ENV['BLOG_SH_LAUNCHER_DIR'].to_s
    return chosen unless chosen.empty?

    File.writable?('/Applications') ? '/Applications' : File.join(Dir.home, 'Applications')
  end

  # Named after the site, since somebody with two sites has two of these
  # side by side. A slash and a colon cannot be in a file name on a Mac.
  def bundle_name(site_name)
    name = site_name.to_s.gsub(%r{[/:\u0000]}, ' ').gsub(/\s+/, ' ').strip.sub(/\A\.+/, '')
    "#{name.empty? ? 'blog.sh' : name}.app"
  end

  def path(site_name, dir: directory)
    File.join(dir, bundle_name(site_name))
  end

  # Whether the bundle at this path is a launcher for this very folder.
  # Asked of the folders themselves rather than of their spellings: on a
  # Mac /tmp is /private/tmp and a home folder may be reached through a
  # link, and a site asked again about a launcher it has, because the
  # wizard was started from the other spelling, is a wizard that does not
  # know what it made.
  def points_at?(bundle, root)
    same_folder?(File.read(File.join(bundle, 'Contents', 'Resources', MARK), encoding: 'utf-8').strip, root)
  rescue SystemCallError
    false
  end

  def same_folder?(one, other)
    real = lambda do |path|
      begin
        File.realpath(File.expand_path(path))
      rescue SystemCallError
        File.expand_path(path)
      end
    end
    real.call(one) == real.call(other)
  end

  def ours?(bundle)
    File.file?(File.join(bundle, 'Contents', 'Resources', MARK))
  end

  # The folder a launcher opens, as it says itself; nil for what is not one.
  def site_of(bundle)
    File.read(File.join(bundle, 'Contents', 'Resources', MARK), encoding: 'utf-8').strip
  rescue SystemCallError
    nil
  end

  # The four lines. The folder is an AppleScript string, escaped as one;
  # `quoted form of` is AppleScript's own shell quoting, so a folder with a
  # space, a quote or an apostrophe in its name reaches `cd` as one word.
  # `; exit` ends the shell when blog.sh does, whichever way it ended.
  def script_lines(root)
    literal = %("#{File.expand_path(root).gsub('\\') { '\\\\' }.gsub('"') { '\\"' }}")
    ["set blogDir to #{literal}",
     'tell application "Terminal"',
     'activate',
     'do script "cd " & quoted form of blogDir & " && ./blog.sh; exit"',
     'end tell']
  end

  # Makes the launcher, or makes it again. Answers [path, nil] when it
  # stands, [nil, reason] when it does not -- :unsupported off a Mac,
  # :taken when an application that is not a launcher has the name,
  # :other_site when a launcher has it and opens ANOTHER site that is
  # still there, or the words the system gave.
  #
  # A launcher is named after its site, and two sites may be called the
  # same -- every site nobody has named yet is "blog.sh". The second one
  # made used to replace the first without a word: one icon, opening the
  # other blog. A launcher whose folder is gone is a site that moved, and
  # is made again as before.
  #
  # Built in a scratch folder and moved into place whole, so a failure
  # half way leaves either the launcher that was there or none, never a
  # bundle that opens and does nothing.
  def create(root:, site_name:, icon: nil, dir: directory)
    return [nil, :unsupported] unless supported?

    bundle = path(site_name, dir: dir)
    return [nil, :taken] if File.exist?(bundle) && !ours?(bundle)

    if File.exist?(bundle)
      there = site_of(bundle).to_s
      return [nil, :other_site] if !there.empty? && File.directory?(there) && !same_folder?(there, root)
    end

    FileUtils.mkdir_p(dir)
    Dir.mktmpdir('blogsh-launcher') do |scratch|
      staged = File.join(scratch, File.basename(bundle))
      # One -e per line: handed over as arguments the text arrives as the
      # UTF-8 it is, where a source FILE is read in the system's legacy
      # encoding and a folder called "můj blog" comes out as something else.
      out, status = Open3.capture2e(COMPILER, '-o', staged, *script_lines(root).flat_map { |line| ['-e', line] })
      return [nil, out.strip.empty? ? 'osacompile failed' : out.strip] unless status.success? && File.directory?(staged)

      File.write(File.join(staged, 'Contents', 'Resources', MARK), "#{File.expand_path(root)}\n", encoding: 'utf-8')
      dress(staged, icon, scratch) if icon && File.file?(icon)
      # Writing into the bundle broke the seal osacompile put on it. An
      # application with a broken seal still opens, but the permission to
      # control Terminal is remembered against the seal -- so it is put back.
      Open3.capture2e(SIGNER, '--force', '--sign', '-', staged) if File.executable?(SIGNER)
      FileUtils.rm_rf(bundle)
      FileUtils.mv(staged, bundle)
    end
    [bundle, nil]
  rescue SystemCallError => e
    [nil, e.message]
  end

  # The site's favicon as the launcher's icon. Two things have to happen:
  # the icon file is replaced, and the asset catalogue beside it is taken
  # out -- macOS reads the catalogue first, so with it left in the launcher
  # keeps the generic scroll whatever the icon file holds.
  #
  # Any step failing leaves the launcher with the icon it was born with,
  # which is a launcher that works.
  def dress(bundle, icon, scratch)
    iconset = File.join(scratch, 'icon.iconset')
    FileUtils.mkdir_p(iconset)
    ICON_SIZES.each do |size|
      { size => "icon_#{size}x#{size}.png", size * 2 => "icon_#{size}x#{size}@2x.png" }.each do |pixels, name|
        _, status = Open3.capture2e('/usr/bin/sips', '-z', pixels.to_s, pixels.to_s, icon, '--out', File.join(iconset, name))
        return false unless status.success?
      end
    end
    icns = File.join(scratch, 'applet.icns')
    _, status = Open3.capture2e('/usr/bin/iconutil', '-c', 'icns', iconset, '-o', icns)
    return false unless status.success? && File.size?(icns)

    resources = File.join(bundle, 'Contents', 'Resources')
    FileUtils.cp(icns, File.join(resources, 'applet.icns'))
    FileUtils.rm_f(File.join(resources, 'Assets.car'))
    true
  rescue SystemCallError
    false
  end
end
