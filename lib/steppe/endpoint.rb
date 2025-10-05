# frozen_string_literal: true

require 'mustermann'
require 'steppe/responder'
require 'steppe/responder_registry'
require 'steppe/result'

module Steppe
  class Endpoint < Plumb::Pipeline
    FALLBACK_RESPONDER = Responder.new(statuses: (100..599), accepts: 'application/json') do |r|
      r.serialize do
        attribute :message, String
        def message = "no responder registered for response status: #{result.response.status}"
      end
    end

    class DefaultEntitySerializer < Steppe::Serializer
      attribute :http, Steppe::Types::Hash[status: Types::Integer.example(200)]
      attribute :params, Steppe::Types::Hash.example({'param' => 'value'}.freeze)
      attribute :errors, Steppe::Types::Hash.example({'param' => 'is invalid'}.freeze)

      def http = { status: result.response.status }
      def params = result.params
      def errors = result.errors
    end

    class QueryValidator
      attr_reader :query_schema

      def initialize(query_schema)
        @query_schema = query_schema.is_a?(Hash) ? Types::Hash[query_schema] : query_schema
      end

      def call(conn)
        result = query_schema.resolve(conn.request.steppe_url_params)
        conn = conn.copy(params: conn.params.merge(result.value))
        return conn if result.valid?

        conn.respond_with(422).invalid(errors: result.errors)
      end
    end

    class PayloadValidator
      attr_reader :content_type, :payload_schema

      def initialize(content_type, payload_schema)
        @content_type = content_type
        @payload_schema = payload_schema.is_a?(Hash) ? Types::Hash[payload_schema] : payload_schema
      end

      def call(conn)
        return conn unless content_type == conn.request.content_type

        result = payload_schema.resolve(conn.request.body)
        conn = conn.copy(params: conn.params.merge(result.value))
        return conn if result.valid?

        conn.respond_with(422).invalid(errors: result.errors)
      end
    end

    class BodyParser
      MissingParserError = Class.new(ArgumentError)

      include Plumb::Composable

      def self.parsers
        @parsers ||= {}
      end

      parsers[ContentTypes::JSON] = proc do |body|
        ::JSON.parse(body.read, symbolize_names: true)
      end

      parsers[ContentTypes::TEXT] = proc do |body|
        body.read
      end

      def self.build(content_type)
        parser = parsers[content_type]
        raise MissingParserError, "No parser for content type: #{content_type}" unless parser

        new(content_type, parser)
      end

      def initialize(content_type, parser)
        @content_type = content_type
        @parser = parser
      end

      def call(conn)
        if conn.request.body
          body = @parser.call(conn.request.body)
          request = Rack::Request.new(conn.request.env.merge(::Rack::RACK_INPUT => body))
          return conn.copy(request:)
        end
        conn
      rescue StandardError => e
        conn.respond_with(400).invalid(errors: { body: e.message })
      end
    end

    attr_reader :rel_name, :payload_schemas, :responders
    attr_accessor :description, :tags

    def initialize(rel_name, verb, path: '/', &)
      @rel_name = rel_name
      @verb = verb
      @path = Mustermann.new('')
      @responders = ResponderRegistry.new
      @query_schema = Types::Hash
      @payload_schemas = {}
      @body_parsers = {}
      @description = 'An endpoint'
      @tags = []
      self.path = path
      super(freeze_after: false, &)

      # Fallback responders
      respond 204, :json
      respond 304, :json
      respond 200..299, :json, DefaultEntitySerializer
      # TODO: match any content type
      # respond 304, '*/*'
      respond 404, :json, DefaultEntitySerializer
      respond 422, :json, DefaultEntitySerializer
      freeze
    end

    def node_name = :endpoint

    def query_schema(sc = nil)
      if sc
        step(QueryValidator.new(sc))
      else
        @query_schema
      end
    end

    def payload_schema(*args)
      ctype, stp = case args
      in [Hash => sc]
        [ContentTypes::JSON, sc]
      in [Plumb::Composable => sc]
        [ContentTypes::JSON, sc]
      in [String => content_type, Hash => sc]
        [content_type, sc]
      in [String => content_type, Plumb::Composable => sc]
        [content_type, sc]
      else
        raise ArgumentError, "Invalid arguments: #{args.inspect}. Expects [Hash] or [Plumb::Composable], and an optional content type."
      end

      unless @body_parsers[ctype]
        step BodyParser.build(ctype)
        @body_parsers[ctype] = true
      end
      step PayloadValidator.new(ctype, stp)
    end

    def verb(vrb = nil)
      @verb = vrb if vrb
      @verb
    end

    def path(pth = nil)
      if pth
        @path = Mustermann.new(pth)
        merge_path_params_into_params_schema!
      end
      @path
    end

    def json(statuses = (200...300), serializer = nil, &block)
      respond(statuses:, accepts: :json) do |r|
        r.description = "Response for status #{statuses}"
        r.serialize serializer || block
      end

      self
    end

    def html(statuses = (200...300), view = nil, &block)
      respond(statuses:, accepts: :html) do |r|
        r.serialize view || block
      end

      self
    end

    # Define how the endpoint responds to specific HTTP status codes and content types.
    #
    # Responders are registered in order and when ranges overlap, the first registered
    # responder wins. This allows you to define specific handlers first, then fallback
    # handlers for broader ranges.
    #
    # @overload respond(status)
    #   Basic responder for a single status code
    #   @param status [Integer] HTTP status code
    #   @yield [responder] Optional configuration block
    #   @example
    #     respond 200  # Basic 200 response
    #     respond 404 do |r|
    #       r.serialize ErrorSerializer
    #     end
    #
    # @overload respond(status, accepts)
    #   Responder for specific status and content type
    #   @param status [Integer] HTTP status code
    #   @param accepts [String, Symbol] Content type (e.g., :json, 'application/json')
    #   @yield [responder] Optional configuration block
    #   @example
    #     respond 200, :json
    #     respond 404, 'text/html' do |r|
    #       r.serialize ErrorPageView
    #     end
    #
    # @overload respond(status, accepts, serializer)
    #   Responder with predefined serializer
    #   @param status [Integer] HTTP status code
    #   @param accepts [String, Symbol] Content type
    #   @param serializer [Class, Proc] Serializer class or block
    #   @yield [responder] Optional configuration block
    #   @example
    #     respond 200, :json, UserListSerializer
    #     respond 404, :json, ErrorSerializer
    #
    # @overload respond(status_range, accepts, serializer)
    #   Responder for a range of status codes
    #   @param status_range [Range] Range of HTTP status codes
    #   @param accepts [String, Symbol] Content type
    #   @param serializer [Class, Proc] Serializer class or block
    #   @yield [responder] Optional configuration block
    #   @example
    #     # First registered wins in overlaps
    #     respond 201, :json, CreatedSerializer     # Specific handler for 201
    #     respond 200..299, :json, SuccessSerializer # Fallback for other 2xx
    #
    # @overload respond(responder)
    #   Add a pre-configured Responder instance
    #   @param responder [Responder] Pre-configured responder
    #   @example
    #     custom = Steppe::Responder.new(statuses: 200, accepts: :xml) do |r|
    #       r.serialize XMLUserSerializer
    #     end
    #     respond custom
    #
    # @overload respond(**options)
    #   Responder with keyword arguments
    #   @option statuses [Integer, Range] Status code(s)
    #   @option accepts [String, Symbol] Content type
    #   @option content_type [String, Symbol] specific Content-Type header to add to response
    #   @option serializer [Class, Proc] Optional serializer
    #   @yield [responder] Optional configuration block
    #   @example
    #     respond statuses: 200..299, accepts: :json do |r|
    #       r.serialize SuccessSerializer
    #     end
    #
    # @return [self] Returns self for method chaining
    # @raise [ArgumentError] When invalid argument combinations are provided
    #
    # @note Responders are resolved by ResponderRegistry using status code and Accept header
    # @note When ranges overlap, first registered responder wins
    # @note Default accept type is :json (application/json) when not specified
    #
    # @see Responder
    # @see ResponderRegistry
    # @see Serializer
    Accepts = Types::String[ContentType::MIME_TYPE] | Types::Symbol
    Status = Types::Integer | Types::Any[Range]

    def respond(*args, &)
      case args
      in [Responder => responder]
        @responders << responder

      in [statuses] if Status === statuses
        @responders << Responder.new(statuses:, &)

      in [statuses, accepts] if Status === statuses && Accepts === accepts
        @responders << Responder.new(statuses:, accepts:, &)

      in [statuses, accepts, Object => serializer] if Status === statuses && Accepts === accepts
        @responders << Responder.new(statuses:, accepts:, serializer:, &)

      in [Hash => kargs]
        @responders << Responder.new(**kargs, &)

      else
        raise ArgumentError, "Invalid arguments: #{args.inspect}"
      end

      self
    end

    def debug!
      step do |conn|
        debugger
        conn
      end
    end

    def to_rack
      proc do |env|
      end
    end

    def run(request)
      result = Result::Continue.new(nil, request:)
      call(result)
    end

    def call(conn)
      conn = super(conn)
      accepts = conn.request.get_header('HTTP_ACCEPT') || ContentTypes::JSON
      responder = responders.resolve(conn.response.status, accepts)# || FALLBACK_RESPONDER
      # Conn might be a Halt now, because a step halted processing.
      # We set it back to Continue so that the responder pipeline
      # can process it through its steps.
      responder.call(conn.valid)
    end

    private

    def prepare_step(callable)
      merge_query_schema(callable.query_schema) if callable.respond_to?(:query_schema)
      merge_payload_schema(callable) if callable.respond_to?(:payload_schema)
      callable
    end

    def merge_query_schema(sc)
      annotated_sc = sc._schema.each_with_object({}) do |(k, v), h|
        pin = @path.names.include?(k.to_s) ? :path : :query
        h[k] = Plumb::Composable.wrap(v).metadata(in: pin)
      end
      @query_schema += annotated_sc
    end

    def merge_payload_schema(callable)
      content_type = callable.respond_to?(:content_type) ? callable.content_type : ContentTypes::JSON

      existing = @payload_schemas[content_type]
      if existing && existing.respond_to?(:+)
        existing += callable.payload_schema
      else
        existing = callable.payload_schema
      end
      @payload_schemas[content_type] = existing
    end

    def path=(pt)
      @path = Mustermann.new(pt)
      sc = @path.names.each_with_object({}) do |name, h| 
        name = name.to_sym
        field = @query_schema.at_key(name) || Steppe::Types::String
        field = field.metadata(in: :path)
        h[name] = field
      end
      @query_schema += sc
      @path
    end
  end
end
