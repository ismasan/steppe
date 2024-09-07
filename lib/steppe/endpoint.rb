# frozen_string_literal: true

require 'steppe/responder'
require 'steppe/responder_registry'
require 'steppe/serializer'
require 'steppe/result'

module Steppe
  class Endpoint < Plumb::Pipeline
    DEFAULT_RESPONDER = Responder.new

    attr_reader :name

    def initialize(name, &)
      @name = name
      @verb = :get
      @path = '/'
      @responders = ResponderRegistry.new
      @query_schema = Types::Any
      @payload_schema = Types::Any
      super(&)
    end

    class QueryValidator
      def initialize(schema)
        @schema = schema
      end

      def call(result)
        result
      end
    end

    def query_schema(sc = {})
      @query_schema = Types::Hash[sc]
      step QueryValidator.new(@query_schema)
    end

    # def payload_schema(sc = {})
    #   @payload_schema = Types::Hash[sc]
    #   step PayloadValidator.new(@payload_schema)
    # end

    def verb(vrb = nil)
      @verb = vrb if vrb
      @verb
    end

    def path(pth = nil)
      @path = pth if pth
      @path
    end

    def to_open_api
      {
        path => {
          verb => {
            summary: 'TODO',
            description: 'TODO',
            parameters: [],
            responses: @responders.each.reduce({}) { |ret, r| ret.merge(r.to_open_api) }
          }
        }
      }
    end

    def serialize(status = (200...300), serializer = nil, &block)
      serializer ||= Class.new(Serializer, &block)
      respond(status) do |r|
        r.serialize serializer
      end
      self
    end

    def respond(*args, &)
      case args
      in [Integer => status] if block_given?
        @responders << Responder.new(statuses: (status..status), &)
      in [Integer => status, String => accepts] if block_given?
        @responders << Responder.new(statuses: status, accepts:, &)
      in [Range => statuses] if block_given?
        @responders << Responder.new(statuses:, &)
      in [Range => statuses, String => accepts] if block_given?
        @responders << Responder.new(statuses:, accepts:, &)
      in [Responder => responder]
        @responders << responder
      else
        raise ArgumentError, "Invalid arguments: #{args.inspect}"
      end
      self
    end

    def run(request)
      result = Result::Continue.new(nil, request:)
      call(result)
    end

    def call(result)
      result = super(result)
      status = result.response.status
      # responder = @responders.find { |st, re| st === status }&.last || DEFAULT_RESPONDER
      responder = @responders.resolve(result) || DEFAULT_RESPONDER
      responder.call(result)
    end
  end
end
