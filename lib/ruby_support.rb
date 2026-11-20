# frozen_string_literal: true

# Whether the Ruby the engine runs on is still one that gets security fixes.
#
# The engine's own floor is 2.7 (blog.sh and setup.sh refuse anything
# older), and that is a floor for what the code can run on, not for what is
# safe to run. On 18 November 2026 Ruby fixed seven flaws in Regexp and in
# changing the case of a string, among them a one-byte heap overflow that a
# crafted string may turn into running code (GHSA-34m4-m9fh-gqp5,
# https://www.ruby-lang.org/en/news/2026/11/18/multiple-vulnerabilities-in-regexp-and-string/).
# The fixes are 3.3.14, 3.4.13 and 4.0.10; 3.2 and older have reached their
# end of life and get none.
#
# Nothing in the engine is known to be hit by them: the site is static, the
# preview listens on 127.0.0.1, the apps come in over SSH and the importers
# make text UTF-8 before they change its case. But the same Ruby runs
# everything else on the machine, and the engine is often the reason it was
# installed. So doctor and check say so, once, with what to do.
#
# A branch newer than the ones listed is taken as fixed: it was released
# after the fix, from a tree that has it.
module RubySupport
  # The oldest release of each maintained branch that has the fix.
  FIXED = {
    [3, 3] => [3, 3, 14],
    [3, 4] => [3, 4, 13],
    [4, 0] => [4, 0, 10]
  }.freeze

  # The oldest branch that still gets fixes at all.
  SUPPORTED_FROM = [3, 3].freeze

  module_function

  # The version being judged: the interpreter's, unless BLOG_SH_RUBY_VERSION
  # names another. That is for the test suite, whose findings must not
  # depend on the Ruby of the machine it happens to run on (its harness sets
  # a fixed release); RUBY_VERSION itself cannot be changed.
  def current
    named = ENV['BLOG_SH_RUBY_VERSION'].to_s.strip
    named.empty? ? RUBY_VERSION : named
  end

  # :end_of_life for a branch that gets no fixes any more, :unpatched for a
  # maintained branch below its fixed release, nil for a Ruby that is fine.
  def status(version = current)
    parts = version.to_s.split('.').map(&:to_i)
    parts << 0 while parts.size < 3
    branch = parts.first(2)
    return :end_of_life if (branch <=> SUPPORTED_FROM).negative?

    fixed = FIXED[branch]
    return :unpatched if fixed && (parts.first(3) <=> fixed).negative?

    nil
  end

  # The fixed release of the branch `version` is on, as "3.4.13", or nil.
  def fixed_for(version = current)
    fixed = FIXED[version.to_s.split('.').map(&:to_i).first(2)]
    fixed&.join('.')
  end

  # Every fixed release, as "3.3.14, 3.4.13, 4.0.10" for a message.
  def fixed_list
    FIXED.values.map { |v| v.join('.') }.join(', ')
  end
end
