# frozen_string_literal: true

# lib/forge_address.rb -- what a Gitea/Forgejo widget's settings may look
# like, in one place.
#
# The rules used to be written twice and half-written at that: the fetcher
# and `doctor` each carried their own copy of a regular expression for the
# instance, and neither of them looked at the username at all -- which is
# how a username with a slash in it could be pasted straight into a request
# path, and how a perfectly ordinary instance living under a path
# (https://firma.cz/gitea) was refused as "not a server address".
module ForgeAddress
  # What a forge lets people call themselves: letters, digits, and the three
  # separators, starting with an alphanumeric. Deliberately not a URL
  # component escape -- a name outside this shape is a mistake worth
  # naming, not a string worth encoding and sending.
  USERNAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,39}\z/
  # Scheme, host, and any number of path segments; no query, no fragment.
  BASE = %r{\Ahttps?://[^/\s?#]+(/[^/\s?#]+)*\z}

  module_function

  def username(value)
    name = value.to_s.strip
    name.match?(USERNAME) ? name : nil
  end

  def base(value)
    address = value.to_s.strip.sub(%r{/+\z}, '')
    address.match?(BASE) ? address : nil
  end

  # Any path at all is worth a second look. A forge that really does live
  # under a path (https://firma.cz/gitea) is unusual but real, so this is
  # never a refusal -- but so is a profile (https://codeberg.org/someone)
  # and a repository, and those two look exactly the same from here. The
  # difference only shows when somebody asks the address, which is what
  # the warning tells the author to do.
  def path_under_host?(value)
    address = base(value)
    return false if address.nil?

    !address.sub(%r{\Ahttps?://[^/]+}, '').split('/').reject(&:empty?).empty?
  end

  def version_url(address)
    "#{address}/api/v1/version"
  end
end
