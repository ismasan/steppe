# frozen_string_literal: true

require 'mustermann'
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
      @path = Mustermann.new('/')
      @responders = ResponderRegistry.new
      @query_schema = Types::Hash
      @payload_schema = Types::Hash
      super(&)
    end

    class QueryValidator
      attr_reader :query_schema

      def initialize(schema)
        @query_schema = schema
      end

      def call(result)
        result
      end
    end

    def query_schema(sc = nil)
      return @query_schema unless sc

      step(QueryValidator.new(sc))
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
      if pth
        @path = Mustermann.new(pth)
        build_query_schema_from_path!
      end
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
      responder = @responders.resolve(result) || DEFAULT_RESPONDER
      responder.call(result)
    end

    private

    def prepare_step(callable)
      merge_query_schema(callable.query_schema) if callable.respond_to?(:query_schema)
      callable
    end

    def merge_query_schema(sc)
      sc = sc._schema if sc.respond_to?(:_schema)
      annotated_sc = sc.each_with_object({}) do |(k, v), h|
        pin = @path.names.include?(k.to_s) ? :path : :query
        h[k] = v.metadata(in: pin)
      end
      @query_schema += annotated_sc
    end

    def build_query_schema_from_path!
      sc = @path.names.each_with_object({}) do |name, h| 
        name = name.to_sym
        field = @query_schema.at_key(name) || Steppe::Types::String
        field = field.metadata(in: :path)
        h[name] = field
      end
      @query_schema += sc
    end
  end
end
