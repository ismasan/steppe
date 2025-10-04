# frozen_string_literal: true

module Steppe
  class ContentType < Data.define(:type, :subtype, :params, :type_key, :subtype_key)
    def self.new(type, subtype, params = {})
      super(type, subtype, params.freeze, type, "#{type}/#{subtype}")
    end

    TOKEN = /[!#$%&'*+\-.^_`|~0-9A-Z]+/i
    MIME_TYPE = /(?<type>#{TOKEN})\/(?<subtype>#{TOKEN})/
    QUOTED_STRING = /"(?:\\.|[^"\\])*"/
    PARAMETER = /\s*;\s*(?<key>#{TOKEN})=(?<value>#{TOKEN}|#{QUOTED_STRING})/

    def self.parse(str)
      return str if str.is_a?(ContentType)

      m = MIME_TYPE.match(str) or
      raise ArgumentError, "invalid content type: #{str.inspect}"

      params = {}
      str.scan(PARAMETER) do
        key, value = Regexp.last_match.values_at(:key, :value)
        value = value[1..-2] if value&.start_with?('"') # unquote
        params[key.downcase] = value
      end

      new(m[:type].downcase, m[:subtype].downcase, params)
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

        new(m[:type].downcase, m[:subtype].downcase, params)
      end.compact.sort_by { |ct| -ct.quality }
    end

    def qualified? = !(type == '*' && subtype == '*')

    def to_s
      param_str = params.map { |k, v| "#{k}=#{v}" }.join('; ')
      [ "#{type}/#{subtype}", param_str ].reject(&:empty?).join('; ')
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
