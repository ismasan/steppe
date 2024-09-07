# frozen_string_literal: true

require 'steppe/responder'
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
      @responders = {}
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
            responses: @responders.values.each.reduce({}) { |ret, r| ret.merge(r.to_open_api) }
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

    def respond(status, responder = nil, &)
      @responders[status] = responder || Responder.new(status:, &)
      self
    end

    def run(request)
      result = Result::Continue.new(nil, request:)
      call(result)
    end

    def call(result)
      result = super(result)
      status = result.response.status
      responder = @responders.find { |st, re| st === status }&.last || DEFAULT_RESPONDER
      responder.call(result)
    end
  end
end
