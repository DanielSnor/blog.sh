# Cutting a release

A release of blog.sh is a git tag and a CHANGELOG entry. There is no
build to produce, no package to publish and no artefact to upload: an
installation upgrades with `git pull`, so what a tag means is "this is a
state of `main` somebody deliberately blessed".

That is exactly why the order below matters. Everything that can be
checked has to be checked *before* the tag, because after it there is
nothing to take back: a tag that has been pulled is a tag that lives on
other people's machines, and recutting it makes two different trees
answer to one name.

## Before the tag

**1. The suite is green, in full.** Not the files you touched --
`./tests/run_all.sh`, all of it, and read the verdict properly: the run
prints one summary line per file, so the number of `=== tests/` lines and
the number of `passed:` lines have to match. A file that ends without
reporting its own verdict exits zero with failed assertions inside it,
and the run counts it as passed.

**2. The docs describe what ships.** Every feature is documented outside
the changelog -- that is the suite's own rule and it has a test. When a
release adds a setting, `install.md` gains it; when it adds a command,
`operations.md` does. The changelog is where a change is announced, not
where it is explained.

**3. The archive still builds, on real data.** A fixture is both ends of
the same assumption. Build a real archive with the new engine -- the
biggest one available -- and diff the output against the previous
version's. What you are looking for is not "does it build" but "did
anything change that nobody asked to change": a shifted address, a
rewritten slug, a stub that stopped being emitted.

**4. `./blog.sh check` on that archive is clean.** An archive the engine
itself will not vouch for is not a release, whatever the tests say.

**5. The build has not got slower.** `ruby tests/bench.rb <last tag>`
builds one generated archive with the engine at that tag and with the
working copy, back to back on this machine, and prints the difference.
Absolute seconds from a laptop mean nothing a month later; the difference
between two engines measured a minute apart means everything. Two
identical engines report within about 3%, so anything past that is real.

Read the three rows separately. A cold build getting slower is a cost
paid once per full rebuild. An UNCHANGED rebuild getting slower is the
expensive one: that is the build cache doing less than it did, and it is
paid on every publish, forever.

**6. The version and the changelog agree.** `lib/version.rb` and the top
entry of `CHANGELOG.md` name the same version, and the entry is dated the
day the tag is actually cut. There is a test for this pair; run it last,
after the date is right.

## The tag

Cut it on `main`, from the commit the checks above were run against --
not from a later one, however harmless the difference looks.

## After the tag

**7. The installations get it.** They pull; nothing is pushed to them.

**8. The release notes go out the same day.** Hand-written, in the form
the earlier releases use -- an opening line that says what the release is
about, bold headings, em dashes, the licence and links at the foot. They
are not generated from the changelog: the changelog says what changed and
the notes say why somebody should care, and a generator can only ever
produce the first one wearing the second one's clothes.

**9. The post announcing it is part of the release, not a follow-up.**
Same day, on the project's own blog, in the same voice as the rest of it.

## What is deliberately not here

**No LTS branch.** One maintainer, one line of development, and every
installation on `main`: a maintenance branch would be a second tree to
keep honest, and the honest state of it would be "untested". If a release
ever needs fixing without the release after it, that is the moment to
make one -- not before.

**No release-notes generator.** See point 8.

**No CI badge on the public repository.** The suite is not public, so a
badge would either be a link to something nobody can open or a claim
about a run nobody can see. The suite runs on every push in the private
repository that holds it, and the verdict that matters is the one in
point 1: a full green run, read properly, on the machine cutting the tag.
