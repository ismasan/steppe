# frozen_string_literal: true

module Steppe
  class ResponderRegistry
    include Enumerable

    attr_reader :node_name

    def initialize
      @responders = []
      @node_name = :responders
    end

    def <<(responder)
      @responders << responder
      self
    end

    def each(&block)
      @responders.each(&block)
    end

    def resolve(result)
      @responders.find do |responder|
        responder.statuses === result.response.status # && responder.accepts?(result.request)
      end
    end
  end
end
