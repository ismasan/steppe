# frozen_string_literal: true

require 'steppe/status_map'
require 'steppe/content_type'

module Steppe
  class ResponderRegistry
    include Enumerable

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
      @map[responder.content_type.type_key] ||= StatusMap.new
      @map[responder.content_type.subtype_key] ||= StatusMap.new

      @map[responder.content_type.type_key] << responder
      @map[responder.content_type.subtype_key] << responder
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
        status_map = @map[ct.subtype_key]
        return status_map if status_map

        status_map = @map[ct.type_key]
        return status_map if status_map
      end
      nil
    end
  end
end
