# frozen_string_literal: true

require 'cgi'
require 'json'
require 'fileutils'
require 'rbconfig'
require_relative 'colors_css'

# lib/palette_preview.rb -- shows a candidate palette on a real page
# BEFORE anything is written. Fourteen hex values answer nothing; the
# question a palette section actually gets asked is "what would my site
# look like", and the only honest answer is the site itself.
#
# Two sources, in order of honesty:
#   - the install's own built homepage (public.nosync/index.html), when
#     there is one -- nothing previews a palette better than the site it
#     is for;
#   - otherwise a bundled sample post rendered through the REAL builder
#     into tmp/ (BLOG_SH_CONTENT_DIR/BLOG_SH_PUBLIC_DIR overrides in
#     build/build_blog.rb), so a fresh install still previews exactly
#     what the engine produces, never a hand-kept imitation.
#
# The page is then rewritten for standing alone as a file: candidate
# colors go in via ColorsCss (the same code the build runs), site.css is
# inlined, scripts are dropped, absolute references point back into the
# built tree, and the result is two srcdoc iframes -- light and dark
# side by side, since a palette is seven colors PER MODE and judging one
# mode at a time hides half the decision.
module PalettePreview
  SAMPLE_YEAR = '2026'

  module_function

  # labels: {title:, light:, dark:, hint:} -- translated by the caller,
  # this module owns no locale strings. sample: {title:, paragraphs:,
  # tags:} for the fixture post on installs with no build yet.
  #
  # Returns {local:, site:}. `local` always exists: a standalone file in
  # tmp/ whose references point into the built tree via file://, for
  # opening right here. `site` is a second copy in public.nosync itself
  # with the references left site-absolute -- served from the site root
  # (the deployed site, or ./blog.sh preview) they resolve on their own.
  # It exists only when the install has a real build; a fixture render
  # has no site for the copy to live on, so it is nil there.
  def generate(root:, colors:, fonts:, labels:, sample:)
    public_dir = File.join(root, 'public.nosync')
    built = File.file?(File.join(public_dir, 'index.html'))
    public_dir = fixture_build(root, sample) unless built

    css = ColorsCss.generate(colors: colors, fonts: fonts, fonts_dir: File.join(root, 'assets', 'fonts'))
    page = transform(File.read(File.join(public_dir, 'index.html'), encoding: 'utf-8'), css, public_dir)

    local = File.join(root, 'tmp', 'palette-preview.html')
    FileUtils.mkdir_p(File.dirname(local))
    File.write(local, wrap(rebase(page, file_url(public_dir)), labels: labels))

    site = nil
    if built
      site = File.join(public_dir, 'palette-preview.html')
      File.write(site, wrap(page, labels: labels))
    end
    { local: local, site: site }
  end

  # The real builder over one bundled post. Slow on nothing: a one-post
  # site builds in well under a second, and the tree in tmp/ is reused as
  # a plain directory by the next preview run (the builder itself decides
  # what to rewrite).
  def fixture_build(root, sample)
    base = File.join(root, 'tmp', 'palette-preview-site')
    posts_dir = File.join(base, 'posts', SAMPLE_YEAR)
    FileUtils.mkdir_p(posts_dir)
    File.write(File.join(posts_dir, 'palette-preview-sample.json'), JSON.pretty_generate(sample_post(sample)))

    public_dir = File.join(base, 'public')
    env = { 'BLOG_SH_CONTENT_DIR' => File.join(base, 'posts'), 'BLOG_SH_PUBLIC_DIR' => public_dir }
    ok = system(env, RbConfig.ruby, File.join('build', 'build_blog.rb'), chdir: root, out: File::NULL)
    raise 'the sample build did not finish' unless ok && File.file?(File.join(public_dir, 'index.html'))

    public_dir
  end

  def sample_post(sample)
    {
      'slug' => 'palette-preview-sample',
      'title' => sample[:title],
      'date' => "#{SAMPLE_YEAR}-01-15T10:00:00+01:00",
      'state' => 'published',
      'tags' => Array(sample[:tags]),
      'content' => Array(sample[:paragraphs]).map { |p| { 'type' => 'text', 'text' => p } },
      'source' => { 'platform' => 'manual' }
    }
  end

  # Comments are stripped FIRST: the head carries a prose comment that
  # contains the literal string "<script>", and a naive script strip
  # pairs it with the first real close tag and swallows the whole page.
  # Every replacement is a block -- site.css holds backslashes
  # (content: '\203a') that String#sub would read as backreferences.
  # References stay site-absolute here; rebase() below rewrites them for
  # the copy that has to stand alone as a file.
  def transform(page, css, public_dir)
    page = page.gsub(/<!--.*?-->/m, '')
    page = page.sub(%r{<link rel="stylesheet" href="/assets/css/colors\.css[^"]*">}) { "<style>\n#{css}</style>" }
    site_css = File.read(File.join(public_dir, 'assets', 'css', 'site.css'), encoding: 'utf-8')
    page = page.sub(%r{<link rel="stylesheet" href="/assets/css/site\.css[^"]*">}) { "<style>\n#{site_css}</style>" }
    page = page.gsub(%r{<script.*?</script>}m, '')
    # ...and the page's own Content-Security-Policy with them. It allows
    # no inline script, so the click-preventer appended below never ran --
    # and clicking anything in the preview navigated away from it. Every
    # script the built page carries has just been stripped, and this copy
    # is a lone file in tmp/ that loads nothing from anywhere: there is
    # no policy left to enforce.
    page = page.gsub(%r{<meta http-equiv="Content-Security-Policy"[^>]*>}, '')

    # Hover states are half of what is being judged, so links stay live to
    # the mouse -- they just lead nowhere.
    page.sub('</body>', '<script>document.addEventListener("click",e=>e.preventDefault())</script></body>')
  end

  # Absolute references only resolve under a web server; the tmp/ copy is
  # a lone file, so its references point straight into the built tree.
  def rebase(page, base)
    page = page.gsub(/(src|href)="\//) { "#{Regexp.last_match(1)}=\"#{base}/" }
    # CSS carries addresses of its own -- a @font-face file is url(/assets/…)
    # -- and leaving those alone meant the uploaded preview lost the site's
    # fonts and fell back to whatever the phone had. Quoted or bare, all
    # three spellings.
    page = page.gsub(/url\((['"]?)\//) { "url(#{Regexp.last_match(1)}#{base}/" }
    page.gsub(/srcset="([^"]*)"/) do
      list = Regexp.last_match(1)
      %(srcset="#{list.gsub(%r{(\A|,\s*)/}) { "#{Regexp.last_match(1)}#{base}/" }}")
    end
  end

  # CGI.escape, not escapeURIComponent: the latter arrived in Ruby 3.2
  # and the engine promises 2.7. escape's one divergence is the space
  # (form-encoded as +), put back as %20.
  def file_url(path)
    encoded = path.split('/').map { |seg| CGI.escape(seg).gsub('+', '%20') }.join('/')
    "file://#{encoded}"
  end

  # One page, both modes: the site's own stylesheet switches on
  # data-theme, so each iframe is the same page told what it is. The
  # iframes render at desktop width and are scaled down -- at half-screen
  # width the site would flip to the mobile hamburger and hide the nav
  # bar, one of the seven surfaces being judged.
  def wrap(page, labels:)
    light, dark = %w[light dark].map do |mode|
      CGI.escapeHTML(page.sub(/<html([^>]*)>/) { %(<html#{Regexp.last_match(1)} data-theme="#{mode}">) })
    end
    <<~HTML
      <!doctype html>
      <html><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{CGI.escapeHTML(labels[:title])}</title>
      <style>
        body { margin:0; font: 14px/1.5 -apple-system, system-ui, sans-serif; background:#20242a; color:#e8e8e8; }
        header { padding: 12px 18px; }
        header h1 { font-size:16px; margin:0 0 4px; }
        header p { margin:0; color:#9aa3ad; }
        main { display:flex; gap:10px; padding:0 10px 10px; }
        section { flex:1; min-width:0; }
        section h2 { font-size:13px; font-weight:600; margin:6px 4px; color:#9aa3ad; }
        .frame { --zoom: 0.55; height: calc(100vh - 120px); overflow:hidden; border:1px solid #3a4048; border-radius:6px; background:#fff; }
        iframe { width:1280px; height: calc((100vh - 120px) / var(--zoom)); border:0; transform: scale(var(--zoom)); transform-origin: 0 0; }
        @media (max-width: 900px) { main { flex-direction:column; } .frame { height:80vh; } iframe { height: calc(80vh / var(--zoom)); } }
      </style></head><body>
      <header>
        <h1>#{CGI.escapeHTML(labels[:title])}</h1>
        <p>#{CGI.escapeHTML(labels[:hint])}</p>
      </header>
      <main>
        <section><h2>#{CGI.escapeHTML(labels[:light])}</h2><div class="frame"><iframe srcdoc="#{light}"></iframe></div></section>
        <section><h2>#{CGI.escapeHTML(labels[:dark])}</h2><div class="frame"><iframe srcdoc="#{dark}"></iframe></div></section>
      </main>
      <script>
        const fit = () => document.querySelectorAll(".frame").forEach(f =>
          f.style.setProperty("--zoom", (f.clientWidth / 1280).toFixed(4)));
        addEventListener("resize", fit); fit();
      </script>
      </body></html>
    HTML
  end
end
