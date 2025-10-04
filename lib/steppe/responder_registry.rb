# frozen_string_literal: true

require 'steppe/status_map'
require 'steppe/content_type'

module Steppe
  class ResponderRegistry
    include Enumerable

    WILDCARD = '*'

    attr_reader :node_name

    def initialize
      @map = {}
      @node_name = :responders
    end

    def freeze
      @map.each_value(&:freeze)
      @map.freeze
      super
    end

    def <<(responder)
      accepts = responder.accepts
      @map[accepts.type] ||= {}
      @map[accepts.type][accepts.subtype] ||= StatusMap.new
      @map[accepts.type][accepts.subtype] << responder
      self
    end

    def each(&block)
      @responders.each(&block)
    end

    def resolve(response_status, accepted_content_types)
      content_types = ContentType.parse_accept(accepted_content_types)
      status_map = find_status_map(content_types)
      status_map&.find(response_status.to_i)
    end

    private

    def find_status_map(content_types)
      content_types.each do |ct|
        # For each content type, try to find the most specific match
        # 1. application/json
        # 2. application/* return first available subtype
        # If no match, try the next content type in the list
        # If no match, return try '*/*'
        # If no match, return nil
        #
        # If accepts is '*/*', return the first available responder
        return @map.values.first.values.first if ct.type == WILDCARD

        type_level = @map[ct.type] # 'application'
        next unless type_level

        if ct.subtype == WILDCARD # find first available subtype. More specific ones should be first
          return type_level.values.first
        else
          status_map = type_level[ct.subtype] # 'application/json'
          status_map ||= type_level[WILDCARD] # 'application/*'
          return status_map if status_map
        end
      end

      wildcard_level = @map[WILDCARD]
      wildcard_level ? wildcard_level[WILDCARD] : nil
    end
  end
end
