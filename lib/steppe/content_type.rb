# frozen_string_literal: true

require 'rack/mime'

module Steppe
  class ContentType
    TOKEN = /[!#$%&'*+\-.^_`|~0-9A-Z]+/i
    MIME_TYPE = /(?<type>#{TOKEN})\/(?<subtype>#{TOKEN})/
    QUOTED_STRING = /"(?:\\.|[^"\\])*"/
    PARAMETER = /\s*;\s*(?<key>#{TOKEN})=(?<value>#{TOKEN}|#{QUOTED_STRING})/

    def self.parse(str)
      return str if str.is_a?(ContentType)

      if str.is_a?(Symbol)
        str = Rack::Mime.mime_type(".#{str}")
      end

      m = MIME_TYPE.match(str) or
      raise ArgumentError, "invalid content type: #{str.inspect}"

      params = {}
      str.scan(PARAMETER) do
        key, value = Regexp.last_match.values_at(:key, :value)
        value = value[1..-2] if value&.start_with?('"') # unquote
        params[key.downcase] = value
      end

      new(m[:type], m[:subtype], params)
    end

    def self.parse_accept(header)
      header.split(/\s*,\s*/).map do |entry|
        # Match the MIME type part
        m = MIME_TYPE.match(entry)
        next unless m

        params = {}
        # Iterate over all parameters
        entry.scan(PARAMETER) do |match|
          key, value = Regexp.last_match.values_at(:key, :value)
          # Remove quotes if quoted
          value = value[1..-2] if value&.start_with?('"')
          params[key.downcase] = value
        end

        new(m[:type], m[:subtype], params)
      end.compact.sort_by { |ct| -ct.quality }
    end

    attr_reader :type, :subtype, :params, :media_type

    def initialize(type, subtype, params)
      @type = type.downcase
      @subtype = subtype.downcase
      @params = params
      @media_type = "#{type}/#{subtype}"
      freeze
    end

    def qualified? = !(type == '*' && subtype == '*')

    def to_s
      param_str = params.map { |k, v| "#{k}=#{v}" }.join('; ')
      [ media_type, param_str ].reject(&:empty?).join('; ')
    end

    def ==(other)
      other.is_a?(ContentType) &&
        type == other.type &&
        subtype == other.subtype &&
        params == other.params
    end

    alias eql? ==
    def hash = [type, subtype, params].hash

    def quality = params.fetch('q', 1.0).to_f
  end
end
