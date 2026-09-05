# frozen_string_literal: true

# lib/video_remuxer.rb -- moves a video's index to the front of the file,
# and out of the QuickTime container while it is there. The bytes of the
# picture and the sound are copied across untouched: this is a repack, not
# a re-encode, so it takes a second on a phone video and changes nothing
# anybody can see.
#
# What it is for. A recorder writes the index last, because the index is
# only complete when the recording is -- so a video from a phone makes a
# reader wait for the whole file before the first frame appears. And the
# share sheet hands over .mov, which some browsers decline on the
# container alone, whatever is inside it.
#
# Off unless the site asks for it (`media: remux_video: true`), for the
# same reason the HEIC conversion is: it shells out to a tool the engine
# does not ship and cannot promise. What it does when it is off is what
# the engine has always done -- say so, name the command, and save the
# post anyway.
#
# Not a refusal when it is on and fails, either. A video that will not
# repack is still a video the great majority of readers can watch, so the
# save goes ahead and the sentence is the same one an author gets with
# the feature switched off. That is the difference from HEIC, where the
# picture would have been broken for everyone but Safari.
require 'fileutils'
require 'shellwords'

module VideoRemuxer
  module_function

  # ffmpeg or nothing. There is no second tool for this: the repack is one
  # flag of one program, and a half-implemented fallback (a Ruby box
  # rewriter of our own) would be a new parser between somebody's video
  # and their archive.
  def available?
    return @available unless @available.nil?

    @available = system('which', 'ffmpeg', out: File::NULL, err: File::NULL) ? true : false
  end

  # True only when ffmpeg left cleanly AND left a file with bytes in it --
  # the same pair the HEIC converter insists on, and for the same reason:
  # a tool that fails halfway leaves a truncated file behind, and a
  # truncated file that is treated as a success is a broken video with a
  # slug of its own.
  #
  # -y because dest is ours and freshly named; -nostdin because this runs
  # inside a command that may own a terminal, and ffmpeg reads stdin for
  # its own keys unless told not to -- it swallowed the answer to the next
  # question the wizard asked.
  def remux(src, dest)
    ok = system('ffmpeg', '-nostdin', '-loglevel', 'error', '-y', '-i', src.to_s,
                '-c', 'copy', '-movflags', '+faststart', dest.to_s,
                out: File::NULL, err: File::NULL)
    return true if ok && File.exist?(dest) && File.size(dest).positive?

    FileUtils.rm_f(dest)
    false
  end

  # What to type when the engine cannot do it for you. Names the real
  # file, like the HEIC refusal does.
  def suggested_command(src, dest)
    "ffmpeg -i #{File.basename(src.to_s).shellescape} -c copy -movflags +faststart " \
      "#{File.basename(dest.to_s).shellescape}"
  end
end
