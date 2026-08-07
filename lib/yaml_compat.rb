# frozen_string_literal: true

require 'yaml'

# lib/yaml_compat.rb -- YAML.load_file across the Rubys this engine
# actually promises to run on.
#
# Psych 4 (Ruby 3.1+) gave load_file safe_load semantics, where a config
# that merely uses a YAML anchor (`<<: *defaults`) raises -- so the
# engine passes `aliases: true`. But Psych 3 (Ruby 2.7 and 3.0 -- Debian
# 11's system Ruby among them) does not KNOW that keyword and raises
# ArgumentError instead, and every call site that passed it unguarded
# was broken on the oldest Rubys the README promises: on 2.7 the setup
# and style wizards could not write a config at all, failing verify!
# with a rollback message that blamed the file.
#
# One retry in one place. site_config.rb and lib/doctor.rb carried this
# pattern locally before this file existed and keep their own copies for
# their richer error reporting; everything else comes here.
module YamlCompat
  module_function

  def load_file(path)
    YAML.load_file(path, aliases: true)
  rescue ArgumentError
    YAML.load_file(path)
  end
end
