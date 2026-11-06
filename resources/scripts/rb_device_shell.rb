#!/usr/bin/env ruby

#######################################################################
## Copyright (c) 2026 ENEO Tecnología S.L.
## This file is part of redBorder.
## redBorder is free software: you can redistribute it and/or modify
## it under the terms of the GNU Affero General Public License License as published by
## the Free Software Foundation, either version 3 of the License, or
## (at your option) any later version.
## redBorder is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU Affero General Public License License for more details.
## You should have received a copy of the GNU Affero General Public License License
## along with redBorder. If not, see <http://www.gnu.org/licenses/>.
########################################################################

# Opens an interactive (pty-backed) SSH shell on a network device that only
# this proxy can reach, types the given commands and answers the device's
# prompts, then prints the raw session transcript. redborder-webui runs it
# through redborder-hub and the proxy's redborder-satellite (the
# "device_shell" custom command) to back up devices behind a proxy, and
# parses the transcript itself.
#
# Some switches accept SSH logins but reject the "exec" channel request,
# so an interactive shell is the only thing that works across the fleet.
#
# Input (stdin, JSON):
#   host, port (22), username, password, commands: [...],
#   prompt_responses: [{ source:, options:, response: }, ...]  (Ruby regexes,
#   first match wins), connect_timeout (20), idle_timeout (20), max_session (180)
# Output (stdout, JSON):
#   transcript (gzip+base64), transcript_encoding, transcript_bytes,
#   truncated, end_reason (idle|max_session|closed|truncated), disconnect_error
# Any failure: message on stderr, exit 1. The password is never printed.
#
# All commands are typed at once, as the device's CLI reads type-ahead line
# by line. Only the last one may page its output or ask anything: keystrokes
# still queued when a pager or a prompt shows up would be taken as its input
# (e.g. ["terminal length 0", "no page", "show running-config"]).

require 'json'
require 'zlib'
require 'resolv'
require 'net/ssh'

class DeviceShell
  class RequestError < StandardError; end

  HOSTNAME_REGEX = /\A[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\z/.freeze
  MAX_COMMANDS = 20
  MAX_PROMPT_RESPONSES = 20
  MAX_PATTERN_LENGTH = 512
  MAX_RESPONSE_LENGTH = 1024
  # Defaults and upper bounds, in seconds. connect_timeout + max_session stays
  # within 600s, the longest redborder-hub waits for a /dispatch.
  TIMEOUTS = {
    'connect_timeout' => [20, 60],
    'idle_timeout' => [20, 300],
    'max_session' => [180, 540],
  }.freeze
  # Stop reading once the device has printed this much
  MAX_TRANSCRIPT_BYTES = 16 * 1024 * 1024
  # The encoded transcript has to fit in the satellite's max_bytes for this
  # command (480 KB, under redborder-hub's 512 KB message limit) with room for
  # the rest of the JSON; otherwise the satellite would cut the JSON short.
  MAX_ENCODED_TRANSCRIPT_BYTES = 450 * 1024
  # Only the tail of what arrived since the last answer is matched against
  # the prompt regexes
  PROMPT_WINDOW = 200
  # Some older switches (still shipping in the field) only support the SHA1
  # key-exchange algorithms, which net-ssh excludes from its defaults as
  # deprecated. Append them (lowest priority) so those devices can still be
  # reached while modern devices keep negotiating a stronger kex.
  LEGACY_KEX_ALGORITHMS = Net::SSH::Transport::Algorithms::DEFAULT_ALGORITHMS[:kex] +
                          %w[diffie-hellman-group-exchange-sha1 diffie-hellman-group1-sha1]

  attr_reader :host, :port, :username, :commands, :prompt_responses, :timeouts

  def initialize(request)
    raise RequestError, 'request must be a JSON object' unless request.is_a?(Hash)

    @host = request['host'].to_s.strip
    @port = (request['port'] || 22).to_i
    @username = request['username'].to_s.strip
    @password = request['password'].to_s
    @commands = request['commands']
    @prompt_responses = build_prompt_responses(request['prompt_responses'] || [])
    @timeouts = TIMEOUTS.each_with_object({}) { |(name, limits), h| h[name] = timeout_value(request, name, *limits) }
    validate!
  end

  def run
    transcript, end_reason, disconnect_error = run_session
    truncated = end_reason == 'truncated'
    # pack('m0') is strict base64; avoids the base64 gem (not a default gem since Ruby 3.4)
    encoded = [Zlib.gzip(transcript)].pack('m0')
    if encoded.bytesize > MAX_ENCODED_TRANSCRIPT_BYTES
      truncated = true
      encoded = ''
    end
    {
      transcript: encoded,
      transcript_encoding: 'gzip+base64',
      transcript_bytes: transcript.bytesize,
      truncated: truncated,
      end_reason: truncated ? 'truncated' : end_reason,
      disconnect_error: disconnect_error,
    }
  end

  # The first rule whose regex matches the end of what the device printed
  # since our last answer, or nil. Carriage returns and ANSI/VT100 escapes are
  # stripped first: some devices redraw the line after a prompt, which would
  # otherwise sit past the regexes' \z anchor.
  def prompt_response(pending)
    window = pending[-PROMPT_WINDOW..-1] || pending
    window = window.gsub(/\r\n?/, "\n")
    window = window.gsub(/\e\[[0-9;?]*[A-Za-z]/, '')
    window = window.gsub(/\e[@-_]/, '')
    # First match only, in order: a prompt can match more than one regex (e.g.
    # "(yes/no)?" also ends in "?"), and answering it twice would feed the extra
    # keystrokes to whatever the device asks next.
    _, response = @prompt_responses.find { |regex, _| window =~ regex }
    response
  end

  private

  def validate!
    raise RequestError, 'host cannot be empty' if @host.empty?
    raise RequestError, 'invalid host address' unless @host =~ Resolv::IPv4::Regex || @host =~ Resolv::IPv6::Regex || @host =~ HOSTNAME_REGEX
    raise RequestError, 'port must be between 1 and 65535' unless (1..65_535).cover?(@port)
    raise RequestError, 'username cannot be empty' if @username.empty?
    raise RequestError, 'commands must be a non-empty list' unless @commands.is_a?(Array) && !@commands.empty?
    raise RequestError, "too many commands (max #{MAX_COMMANDS})" if @commands.size > MAX_COMMANDS
    raise RequestError, 'commands must be strings' unless @commands.all? { |c| c.is_a?(String) }
    # Each command is typed followed by a newline; an embedded one would sneak
    # in an extra command.
    raise RequestError, 'commands cannot contain line breaks' if @commands.any? { |c| c.match?(/[\r\n]/) }
  end

  def build_prompt_responses(rules)
    raise RequestError, 'prompt_responses must be a list' unless rules.is_a?(Array)
    raise RequestError, "too many prompt responses (max #{MAX_PROMPT_RESPONSES})" if rules.size > MAX_PROMPT_RESPONSES

    rules.map do |rule|
      raise RequestError, 'each prompt response must be an object' unless rule.is_a?(Hash)

      source = rule['source'].to_s
      response = rule['response'].to_s
      raise RequestError, "prompt source must be between 1 and #{MAX_PATTERN_LENGTH} characters" if source.empty? || source.size > MAX_PATTERN_LENGTH
      raise RequestError, "prompt response exceeds #{MAX_RESPONSE_LENGTH} characters" if response.size > MAX_RESPONSE_LENGTH

      begin
        [Regexp.new(source, rule['options'].to_i), response]
      rescue RegexpError => e
        raise RequestError, "invalid prompt source #{source.inspect}: #{e.message}"
      end
    end
  end

  def timeout_value(request, name, default, max)
    value = request[name].to_i
    return default if value <= 0
    raise RequestError, "#{name} exceeds maximum allowed value (#{max} seconds)" if value > max

    value
  end

  # Returns [transcript, end_reason, disconnect_error]
  def run_session
    transcript = +''
    # Transcript length right after our last prompt answer; see prompt_response
    answered_upto = 0
    pty_granted = nil
    shell_started = nil
    closed_by_device = false
    end_reason = nil
    disconnect_error = nil
    last_activity_at = Time.now
    deadline = Time.now + @timeouts['max_session']
    channel = nil

    begin
      Net::SSH.start(@host, @username,
                     port: @port,
                     password: @password,
                     non_interactive: true,
                     verify_host_key: :never,
                     kex: LEGACY_KEX_ALGORITHMS,
                     timeout: @timeouts['connect_timeout']) do |ssh|
        channel = ssh.open_channel do |ch|
          # Flag failures instead of raising inside net-ssh's callbacks: raising
          # there can break Net::SSH.start's own cleanup, whose error would then
          # mask the real one. They are checked after the loop below.
          # Request a "dumb" terminal; devices that still send VT100 escapes
          # (e.g. HP/Aruba ProCurve) have them stripped by the caller.
          ch.request_pty(term: 'dumb') do |_, granted|
            pty_granted = granted
            next unless granted

            ch.send_channel_request('shell') do |_, started|
              shell_started = started
              next unless started

              ch.on_data do |_, data|
                # Some devices' output isn't valid UTF-8; sanitize as it arrives.
                transcript << data.dup.force_encoding(Encoding::UTF_8).scrub
                last_activity_at = Time.now
                # Only what arrived since our last answer: a prompt whose answer
                # isn't echoed (a password) would otherwise still sit at the \z
                # anchor and get answered again, the extra keystrokes landing on
                # the next prompt.
                response = prompt_response(transcript[answered_upto..-1] || '')
                if response
                  ch.send_data(response)
                  answered_upto = transcript.length
                end
              end
              ch.on_close { closed_by_device = true }
              @commands.each { |command| ch.send_data("#{command}\n") }
            end
          end
        end

        # Idle timeout instead of a flat deadline: a large config paged through
        # screen by screen can legitimately take a while, so only give up once
        # no new data has arrived for a stretch (capped by max_session).
        ssh.loop(1) do
          if !channel.active?
            false
          elsif transcript.bytesize > MAX_TRANSCRIPT_BYTES
            end_reason = 'truncated'
            false
          elsif Time.now >= deadline
            end_reason = 'max_session'
            false
          elsif (Time.now - last_activity_at) >= @timeouts['idle_timeout']
            end_reason = 'idle'
            false
          else
            true
          end
        end

        # Going idle means the device finished and is back at its prompt. Close
        # the channel ourselves rather than typing "exit": those keystrokes could
        # land while a pager is still consuming input.
        channel.close if channel.active?
      end
    rescue IOError, EOFError => e
      # Embedded switch SSH servers often drop the TCP connection instead of
      # closing the session cleanly. Not a failure by itself: the caller
      # decides from the transcript whether it got what it needed.
      disconnect_error = e.message
    end

    raise 'Could not allocate a pty for the interactive SSH session' if pty_granted == false
    raise 'Could not start an interactive shell session' if shell_started == false

    end_reason ||= closed_by_device || disconnect_error ? 'closed' : 'idle'
    [transcript, end_reason, disconnect_error]
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    request = JSON.parse($stdin.read)
    puts DeviceShell.new(request).run.to_json
  rescue JSON::ParserError => e
    warn "Invalid request JSON: #{e.message}"
    exit 1
  rescue DeviceShell::RequestError => e
    warn "Invalid request: #{e.message}"
    exit 1
  rescue Net::SSH::AuthenticationFailed
    warn 'SSH authentication failed'
    exit 1
  rescue StandardError, Timeout::Error => e
    warn "Device shell failed: #{e.class}: #{e.message}"
    exit 1
  end
end
