# frozen_string_literal: true

# lib/icons.rb -- the drawings the engine ships, in one place.
#
# Two groups with one lookup. CONTENT is the eight that name a KIND of
# post; they appear on a date badge whether or not anybody configured
# anything, and their names are the type names, so nothing may be added to
# that group without a content type behind it. SET is everything else: the
# things blogs are about, offered to `tag_icons` (and to a footer link) by
# name, so that giving a tag a picture does not have to mean writing SVG.
#
# Why a Ruby hash and not a directory of .svg files. Everything under
# assets/ is copied onto the site wholesale, so a directory of fifty
# drawings would publish fifty files to serve a site that uses two -- and
# the icons are inlined into the page anyway, never fetched. The same
# reasoning made lib/social_icons.rb a hash, and this file is its
# neighbour: that one holds the brand marks of the networks (filled,
# somebody else's shapes), this one holds our own line drawings.
#
# Where the shapes come from: the eight content icons are this project's,
# and so is most of the set below -- but an icon set converges on the
# obvious drawing for an obvious thing, and several of these (the speech
# bubble, the pen, the spanner among them) are the same paths as Feather
# Icons, which is MIT licensed. NOTICE says so and carries the licence.
#
# The house style, and the rule for anything added here: a 24-unit grid,
# `fill="none"`, `stroke="currentColor"`, stroke width 2, and 20x20 as the
# drawn size. currentColor is what makes an icon follow the light and dark
# themes without a second copy; a fill or a hard-coded colour would show
# up as a black square on a dark page. doctor checks a hand-written icon
# against the same rules.
module Icons
  # The eight kinds of post. Moved here from build/build_blog.rb, which is
  # where they were written and where doctor could not see them -- it kept
  # its own hand-typed copy of the names, and the two went out of step the
  # moment either changed.
  CONTENT = {
    'text' => '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><line x1="4" y1="6" x2="20" y2="6"/><line x1="4" y1="12" x2="20" y2="12"/><line x1="4" y1="18" x2="14" y2="18"/></svg>',
    'image' => '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="8.5" cy="10.5" r="1.5"/><path d="M21 15l-5-5L5 19"/></svg>',
    'video' => '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="5" width="14" height="14" rx="2"/><path d="M17 9l4-2v10l-4-2"/></svg>',
    'link' => '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><path d="M10 14a4 4 0 005.66 0l2-2a4 4 0 00-5.66-5.66l-1 1"/><path d="M14 10a4 4 0 00-5.66 0l-2 2a4 4 0 005.66 5.66l1-1"/></svg>',
    'audio' => '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><path d="M11 5L6 9H3v6h3l5 4V5z"/><path d="M15.5 8.5a5 5 0 010 7"/><path d="M18.5 6a8.5 8.5 0 010 12"/></svg>',
    'quote' => '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><path d="M16 3a2 2 0 00-2 2v6a2 2 0 002 2 1 1 0 011 1v1a2 2 0 01-2 2 1 1 0 00-1 1v2a1 1 0 001 1 6 6 0 006-6V5a2 2 0 00-2-2z"/><path d="M5 3a2 2 0 00-2 2v6a2 2 0 002 2 1 1 0 011 1v1a2 2 0 01-2 2 1 1 0 00-1 1v2a1 1 0 001 1 6 6 0 006-6V5a2 2 0 00-2-2z"/></svg>',
    'document' => '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8z"/><path d="M14 3v5h5"/></svg>',
    'chat' => '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2z"/></svg>'
  }.freeze

  # The opening of every drawing below, so the file reads as shapes rather
  # than as forty copies of the same attribute list. Round joins because
  # these are line drawings of things rather than diagrams: a mitred
  # corner on a two-unit stroke reads as a spike at 20 pixels.
  HEAD = '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" ' \
         'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'

  # What a blog is about. Chosen from what people actually tag: places,
  # ways of getting to them, weather, food, making things, machines,
  # animals, and the handful of abstractions a personal archive keeps
  # coming back to. Names are plain English nouns in the singular -- the
  # config is read by people, and `bike` is what somebody looking for a
  # bicycle types first.
  SHAPES = {
    # getting about
    'bike' => '<circle cx="6" cy="17" r="3.5"/><circle cx="18" cy="17" r="3.5"/><path d="M6 17l4-9h4"/><path d="M9.5 8h3.5l3.2 9"/><path d="M13 8l1.5-3"/>',
    'car' => '<path d="M4 16v2.5"/><path d="M20 16v2.5"/><path d="M3 16v-3.2L5 7h14l2 5.8V16z"/><path d="M3 12.8h18"/><circle cx="7.5" cy="16" r="1"/><circle cx="16.5" cy="16" r="1"/>',
    'train' => '<rect x="5" y="3" width="14" height="13" rx="2"/><path d="M5 10h14"/><circle cx="9" cy="13" r="1"/><circle cx="15" cy="13" r="1"/><path d="M8 16l-2 5"/><path d="M16 16l2 5"/>',
    'plane' => '<path d="M10 3.5a1.5 1.5 0 013 0V9l8 4.5v2.5l-8-2.5v4l2.5 2v2L11.5 20 8 21.5v-2l2.5-2v-4L2.5 16v-2.5L10 9z"/>',
    'boat' => '<path d="M2.5 16.5h19l-2.3 4.2a1 1 0 01-.9.55H5.7a1 1 0 01-.9-.55z"/><path d="M12 16.5V2.5"/><path d="M12.8 5.5l5.7 8.5h-5.7z"/><path d="M11.2 8.5L6.5 14h4.7z"/>',
    'walk' => '<circle cx="13" cy="4" r="1.6"/><path d="M13 8l-3.5 3 2 3 1 7"/><path d="M11.5 14l-3 3-1.5 4"/><path d="M13 8l3.5 2 1.5 4"/>',
    # places and weather
    'map' => '<path d="M9 4L3 6.5v14L9 18l6 2.5 6-2.5v-14L15 6.5z"/><path d="M9 4v14"/><path d="M15 6.5v14"/>',
    'pin' => '<path d="M12 21s7-6.2 7-11a7 7 0 10-14 0c0 4.8 7 11 7 11z"/><circle cx="12" cy="10" r="2.6"/>',
    'mountain' => '<path d="M2.5 19h19L15 6l-3.6 6.5L9.4 10z"/><path d="M9.4 10l2 3.5"/>',
    'tree' => '<path d="M12 3l5.5 8h-3l4 6H5.5l4-6h-3z"/><path d="M12 17v4"/>',
    'sun' => '<circle cx="12" cy="12" r="4.2"/><path d="M12 2v2.4M12 19.6V22M4.2 12H2M22 12h-2.2M6 6L4.4 4.4M19.6 19.6L18 18M18 6l1.6-1.6M4.4 19.6L6 18"/>',
    'cloud' => '<path d="M7 18a4 4 0 01-.4-8A5.5 5.5 0 0117 9.6 3.9 3.9 0 0117 18z"/>',
    'rain' => '<path d="M7 15a4 4 0 01-.4-8A5.5 5.5 0 0117 6.6 3.9 3.9 0 0117 15z"/><path d="M8 18l-1 3M12.5 18l-1 3M17 18l-1 3"/>',
    'snow' => '<path d="M12 2v20M3.4 7l17.2 10M20.6 7L3.4 17"/><path d="M9 4.2L12 6l3-1.8M9 19.8L12 18l3 1.8"/>',
    # what a day is made of
    'coffee' => '<path d="M4 8h13v6a5 5 0 01-5 5H9a5 5 0 01-5-5z"/><path d="M17 9.5h1.5a2.5 2.5 0 010 5H17"/><path d="M7 3v2M11 3v2"/>',
    'beer' => '<path d="M6 9.5h9V19a2 2 0 01-2 2H8a2 2 0 01-2-2z"/><path d="M15 11.5h2.3a2 2 0 012 2v1.6a2 2 0 01-2 2H15"/><path d="M6 9.5a2.6 2.6 0 012.6-2.6c.3-1.2 1.4-2.1 2.7-2.1s2.4.9 2.7 2.1A2.6 2.6 0 0115 9.5z"/><path d="M9 12.5v5M12 12.5v5"/>',
    'food' => '<path d="M6 3v8a2 2 0 002 2 2 2 0 002-2V3"/><path d="M8 13v8"/><path d="M17.5 3c-1.4 1.4-2 3-2 5.5 0 1.6.7 2.5 2 2.5V3z"/><path d="M17.5 11v10"/>',
    'wine' => '<path d="M8 3h8l-.7 6a3.4 3.4 0 01-6.6 0z"/><path d="M12 15v6"/><path d="M9 21h6"/>',
    'clock' => '<circle cx="12" cy="12" r="9"/><path d="M12 7v5.2l3.2 2"/>',
    'calendar' => '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18"/><path d="M8 3v4M16 3v4"/>',
    'home' => '<path d="M3.5 11L12 4l8.5 7"/><path d="M5.5 9.5V20h13V9.5"/><path d="M10 20v-5.5h4V20"/>',
    'heart' => '<path d="M12 20s-8-4.8-8-10.2A4.8 4.8 0 0112 6a4.8 4.8 0 018 3.8C20 15.2 12 20 12 20z"/>',
    'star' => '<path d="M12 3.5l2.7 5.6 6.1.8-4.5 4.3 1.2 6.1L12 17.4l-5.5 2.9 1.2-6.1L3.2 9.9l6.1-.8z"/>',
    'gift' => '<rect x="3" y="9" width="18" height="4"/><path d="M5 13v8h14v-8"/><path d="M12 9v12"/><path d="M12 9S9.5 3 7.5 4.5 10 9 12 9zM12 9s2.5-6 4.5-4.5S14 9 12 9z"/>',
    # making things
    'pen' => '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 013 3L7 19l-4 1 1-4z"/>',
    'brush' => '<path d="M14 3l7 7-7.5 7.5H6.5L14 3z"/><path d="M6.5 17.5C5 19 5.5 21 3 21c0-2.5 2-2 3.5-3.5z"/>',
    'camera' => '<path d="M3 8h4l1.6-2.4h6.8L17 8h4v12H3z"/><circle cx="12" cy="13.5" r="3.6"/>',
    'film' => '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M8 4v16M16 4v16"/><path d="M3 9h5M3 15h5M16 9h5M16 15h5"/>',
    'mic' => '<rect x="9" y="2.5" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0013 0"/><path d="M12 17.5V21"/><path d="M8.5 21h7"/>',
    'music' => '<path d="M9 18V5l11-2v13"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="17.5" cy="16" r="2.5"/>',
    'book' => '<path d="M4 4.5A2 2 0 016 3h13v15H6a2 2 0 00-2 2z"/><path d="M4 19.5A2 2 0 016 18h13v3H6a2 2 0 01-2-1.5z"/>',
    'tools' => '<path d="M14.7 6.3a1 1 0 000 1.4l1.6 1.6a1 1 0 001.4 0l3.8-3.8a6 6 0 01-7.9 7.9l-6.9 6.9a2.1 2.1 0 01-3-3l6.9-6.9a6 6 0 017.9-7.9z"/>',
    'hammer' => '<path d="M14 6l-2-2-6 6 2 2z"/><path d="M12 4l3-1 6 6-1 3z"/><path d="M10 12l-6.5 6.5a1.8 1.8 0 002.5 2.5L12.5 15z"/>',
    # machines
    'laptop' => '<rect x="4" y="5" width="16" height="10" rx="1.5"/><path d="M2.5 18.5h19"/><path d="M10 18.5h4"/>',
    'phone' => '<rect x="6" y="2.5" width="12" height="19" rx="2.5"/><path d="M10.5 5.5h3"/><path d="M11 18.5h2"/>',
    'code' => '<path d="M9 7l-5 5 5 5"/><path d="M15 7l5 5-5 5"/>',
    'terminal' => '<rect x="2.5" y="4" width="19" height="16" rx="2"/><path d="M6.5 9.5L9.5 12l-3 2.5"/><path d="M12.5 15h5"/>',
    'server' => '<rect x="3" y="4" width="18" height="6" rx="1.5"/><rect x="3" y="14" width="18" height="6" rx="1.5"/><path d="M7 7h.01M7 17h.01"/>',
    'bug' => '<rect x="8" y="7.5" width="8" height="11.5" rx="4"/><path d="M12 7.5V5.5"/><path d="M9.8 5.6L8 3.5M14.2 5.6L16 3.5"/><path d="M8 10.5H4.2M16 10.5h3.8M8 14.5H3.8M16 14.5h4.2M8.6 17.6L6.2 19.8M15.4 17.6l2.4 2.2"/>',
    'lock' => '<rect x="4.5" y="10" width="15" height="11" rx="2"/><path d="M8 10V7a4 4 0 018 0v3"/>',
    'key' => '<circle cx="8" cy="16" r="4"/><path d="M10.8 13.2L20 4"/><path d="M17 7l2.5 2.5"/>',
    # living things
    'paw' => '<ellipse cx="7" cy="9" rx="1.9" ry="2.4"/><ellipse cx="12" cy="7" rx="1.9" ry="2.4"/><ellipse cx="17" cy="9" rx="1.9" ry="2.4"/><path d="M12 12c3 0 5 2.2 5 4.4 0 2-1.6 3.2-3.4 2.8L12 19l-1.6.2C8.6 19.6 7 18.4 7 16.4 7 14.2 9 12 12 12z"/>',
    'bird' => '<circle cx="15.5" cy="6.5" r="2.2"/><path d="M17.7 6h3.8l-2.6 2.2"/><path d="M13.6 8.2c-3 .9-5.2 2.6-6.6 5.1-.9 1.6-2.2 2.4-3.9 2.4l6.4-.5"/><path d="M9.5 15.2c2.7 1.9 6.2 1.1 8.2-1.7 1.1-1.5 1.5-3.2 1.2-4.9"/><path d="M12.4 16.6V20"/>',
    'leaf' => '<path d="M20 4C9 4 4 9 4 15a5 5 0 005 5c6 0 11-5 11-16z"/><path d="M4 20L14 10"/>',
    'flower' => '<path d="M12 12.5c-3.2 0-5.2-2.1-5.2-5.2 0-1.1.3-2.1.9-3.1 1 1 2.2 1.6 3.3 1.6.6-1.5 1.6-2.5 3-3.2 1.4.7 2.4 1.7 3 3.2 1.1 0 2.3-.6 3.3-1.6.6 1 .9 2 .9 3.1 0 3.1-2 5.2-5.2 5.2z"/><path d="M12 12.5V21"/><path d="M12 17c-2.6 0-4.2-1.3-4.2-3.2 2.6 0 4.2 1.3 4.2 3.2z"/>',
    # ideas
    'bulb' => '<path d="M9 18h6"/><path d="M10 21.5h4"/><path d="M12 2.5a7 7 0 00-4 12.7c.6.5 1 1.3 1 2.3h6c0-1 .4-1.8 1-2.3A7 7 0 0012 2.5z"/>',
    'flag' => '<path d="M5 21V3"/><path d="M5 4h11l-1.6 3.5L16 11H5z"/>',
    'globe' => '<circle cx="12" cy="12" r="9"/><path d="M3.2 9h17.6M3.2 15h17.6"/><path d="M12 3c2.5 2.4 3.8 5.4 3.8 9s-1.3 6.6-3.8 9c-2.5-2.4-3.8-5.4-3.8-9S9.5 5.4 12 3z"/>',
    'eye' => '<path d="M1.8 12S5.5 5.5 12 5.5 22.2 12 22.2 12 18.5 18.5 12 18.5 1.8 12 1.8 12z"/><circle cx="12" cy="12" r="3"/>',
    'chart' => '<path d="M4 20V4"/><path d="M4 20h16"/><path d="M8 17v-5M12.5 17V8M17 17v-7"/>',
    'target' => '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="4.5"/><circle cx="12" cy="12" r="1"/>',
    'rocket' => '<path d="M12 2.5c3 2.4 4.5 5.6 4.5 9.5L14 15h-4l-2.5-3c0-3.9 1.5-7.1 4.5-9.5z"/><circle cx="12" cy="10" r="1.8"/><path d="M10 15l-2 3.5 2.5-.5M14 15l2 3.5-2.5-.5"/><path d="M11 19.5l1 2 1-2"/>',
    'mail' => '<rect x="2.5" y="5" width="19" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
    'briefcase' => '<rect x="2.5" y="7" width="19" height="13" rx="2"/><path d="M8.5 7V5.5a2 2 0 012-2h3a2 2 0 012 2V7"/><path d="M2.5 12.5h19"/>',
    'box' => '<path d="M3 7.5L12 3l9 4.5V17L12 21.5 3 17z"/><path d="M3 7.5l9 4.5 9-4.5"/><path d="M12 12v9.5"/>'
  }.freeze

  SET = SHAPES.transform_values { |shape| "#{HEAD}#{shape}</svg>" }.freeze

  # One lookup for both groups, so a name resolves the same way wherever
  # it is written -- in `tag_icons`, and in doctor's report about it.
  ALL = CONTENT.merge(SET).freeze
  NAMES = ALL.keys.freeze

  module_function

  def find(name)
    ALL[name.to_s]
  end

  # Whether what somebody wrote in `icon_svg` is a drawing at all. A
  # filename, an address, an emoji or a sentence is not one, and the build
  # used to paste whatever it found straight into the page where the glyph
  # goes: the date badge of every post carrying that tag read
  # `assets/icons/bike.svg` in words, on its own page and on every listing
  # it appeared in.
  #
  # One question in one place, because the build and doctor were asking it
  # separately and answering differently -- doctor said an `icon_svg`
  # without an <svg> would draw nothing while the build was drawing the
  # text of it, which is the one kind of report nobody can act on. Same
  # rule as NAMES above: what decides lives with the drawings, and both
  # callers ask it rather than keeping a copy.
  #
  # Case-insensitive, and the same `\b` heading_icon_dress matches on: a
  # browser draws `<SVG>` exactly as it draws `<svg>`, so refusing one
  # would take away an icon that works today, and doctor's own warning
  # about it was wrong in the other direction.
  def own_svg?(value)
    value.to_s.match?(/<svg\b/i)
  end
end
