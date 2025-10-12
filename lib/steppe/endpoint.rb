# frozen_string_literal: true

require 'mustermann'
require 'steppe/responder'
require 'steppe/responder_registry'
require 'steppe/result'

module Steppe
  # Endpoint represents a single API endpoint with request validation, processing, and response handling.
  #
  # Inherits from Plumb::Pipeline to provide composable request processing through steps.
  # Each endpoint defines an HTTP verb, URL path pattern, input validation schemas, processing
  # logic, and response serialization strategies.
  #
  # @example Basic endpoint definition
  #   endpoint = Endpoint.new(:users_list, :get, path: '/users') do |e|
  #     # Define query parameter validation
  #     e.query_schema(
  #       page: Types::Integer.default(1),
  #       per_page: Types::Integer.default(20)
  #     )
  #
  #     # Add processing steps
  #     e.step do |result|
  #       users = User.limit(result.params[:per_page]).offset((result.params[:page] - 1) * result.params[:per_page])
  #       result.continue(data: users)
  #     end
  #
  #     # Define response serialization
  #     e.respond 200, :json, UserListSerializer
  #   end
  #
  # @example Endpoint with payload validation
  #   endpoint = Endpoint.new(:create_user, :post, path: '/users') do |e|
  #     e.payload_schema(
  #       name: Types::String,
  #       email: Types::String.email
  #     )
  #
  #     e.step do |result|
  #       user = User.create(result.params)
  #       result.respond_with(201).continue(data: user)
  #     end
  #
  #     e.respond 201, :json, UserSerializer
  #   end
  #
  # @see Plumb::Pipeline
  # @see Result
  # @see Responder
  # @see ResponderRegistry
  class Endpoint < Plumb::Pipeline
    # These types are used in the respond method pattern matching.
    MatchContentType = Types::String[ContentType::MIME_TYPE] | Types::Symbol
    MatchStatus = Types::Integer | Types::Any[Range]

    # Fallback responder used when no matching responder is found for a status/content-type combination.
    # Returns a JSON error message indicating the missing responder configuration.
    FALLBACK_RESPONDER = Responder.new(statuses: (100..599), accepts: 'application/json') do |r|
      r.serialize do
        attribute :message, String
        def message = "no responder registered for response status: #{result.response.status}"
      end
    end

    # Default serializer used for successful and error responses when no custom serializer is provided.
    # Returns the HTTP status, params, and validation errors.
    class DefaultEntitySerializer < Steppe::Serializer
      attribute :http, Steppe::Types::Hash[status: Types::Integer.example(200)]
      attribute :params, Steppe::Types::Hash.example({'param' => 'value'}.freeze)
      attribute :errors, Steppe::Types::Hash.example({'param' => 'is invalid'}.freeze)

      def http = { status: result.response.status }
      def params = result.params
      def errors = result.errors
    end

    DefaultHTMLSerializer = -> (conn) {
      html5 {
        head {
          title "Default #{conn.response.status}"
        }
        body {
          h1 "Default view"
          dl {
            dt "Response status:"
            dd conn.response.status.to_s
            dt "Parameters:"
            dd conn.params.inspect
            dt "Errors:"
            dd conn.errors.inspect
          }
        }
      }
    }

    # Internal step that validates HTTP headers against a schema.
    # Validates headers from the Rack env and merges validated values back into the env.
    # Returns 422 Unprocessable Entity if validation fails.
    #
    # @note HTTP header names in Rack env use the format 'HTTP_*' (e.g., 'HTTP_AUTHORIZATION')
    # @note Security schemes often use this to validate required headers (e.g., Authorization)
    class HeaderValidator
      attr_reader :header_schema

      # @param header_schema [Hash, Plumb::Composable] Schema definition for HTTP headers
      def initialize(header_schema)
        @header_schema = header_schema.is_a?(Hash) ? Types::Hash[header_schema] : header_schema
      end

      # Validates headers from the request environment.
      #
      # @param conn [Result] The current result/connection object
      # @return [Result] Updated result with validated env or error response
      def call(conn)
        result = header_schema.resolve(conn.request.env)
        conn.request.env.merge!(result.value)
        return conn.respond_with(422).invalid(errors: { headers: result.errors }) unless result.valid?

        conn.valid
      end
    end

    # Internal step that validates query parameters against a schema.
    # Merges validated query params into the result params hash.
    # Returns 422 Unprocessable Entity if validation fails.
    class QueryValidator
      attr_reader :query_schema

      # @param query_schema [Hash, Plumb::Composable] Schema definition for query parameters
      def initialize(query_schema)
        @query_schema = query_schema.is_a?(Hash) ? Types::Hash[query_schema] : query_schema
      end

      # @param conn [Result] The current result/connection object
      # @return [Result] Updated result with validated params or error response
      def call(conn)
        result = query_schema.resolve(conn.request.steppe_url_params)
        conn = conn.copy(params: conn.params.merge(result.value))
        return conn if result.valid?

        conn.respond_with(422).invalid(errors: result.errors)
      end
    end

    # Internal step that validates request payload against a schema for a specific content type.
    # Only validates if the request content type matches. 
    # Or if the request is form or multipart, which Rack::Request parses by default.
    # Merges validated payload into result params.
    # Returns 422 Unprocessable Entity if validation fails.
    class PayloadValidator
      attr_reader :content_type, :payload_schema

      # @param content_type [String] Content type to validate (e.g., 'application/json')
      def initialize(content_type, payload_schema)
        @content_type = content_type
        @payload_schema = payload_schema.is_a?(Hash) ? Types::Hash[payload_schema] : payload_schema
      end

      # @param conn [Result] The current result/connection object
      # @return [Result] Updated result with validated params or error response
      def call(conn)
        # If form or multipart, treat as form data
        data = nil
        if conn.request.form_data?
          data = Utils.deep_symbolize_keys(conn.request.POST)
        elsif content_type.media_type == conn.request.media_type
          # request.body was already parsed by parser associated to this media type
          data = conn.request.body
        else
          return conn
        end

        result = payload_schema.resolve(data)
        conn = conn.copy(params: conn.params.merge(result.value))
        return conn if result.valid?

        conn.respond_with(422).invalid(errors: result.errors)
      end
    end

    # Internal step that parses request body based on content type.
    # Supports JSON and plain text parsing out of the box.
    # Returns 400 Bad Request if parsing fails.
    class BodyParser
      MissingParserError = Class.new(ArgumentError)

      include Plumb::Composable

      # Registry of content type parsers
      def self.parsers
        @parsers ||= {}
      end

      # Default JSON parser - parses body and symbolizes keys
      parsers[ContentTypes::JSON.media_type] = proc do |request|
        ::JSON.parse(request.body.read, symbolize_names: true)
      end

      # Default text parser - reads body as string
      parsers[ContentTypes::TEXT.media_type] = proc do |request|
        request.body.read
      end

      # Builds a parser for the given content type
      # @raise [MissingParserError] if no parser is registered for the content type
      def self.build(content_type)
        parser = parsers[content_type.media_type]
        raise MissingParserError, "No parser for content type: #{content_type}" unless parser

        new(content_type, parser)
      end

      def initialize(content_type, parser)
        @content_type = content_type
        @parser = parser
      end

      def call(conn)
        return conn unless @content_type.media_type == conn.request.media_type

        if conn.request.body
          body = @parser.call(conn.request)
          # Maybe here we can just mutate the request?
          conn.request.env[::Rack::RACK_INPUT] = body
          return conn
          # request = Steppe::Request.new(conn.request.env.merge(::Rack::RACK_INPUT => body))
          # return conn.copy(request:)
        end
        conn
      rescue StandardError => e
        conn.respond_with(400).invalid(errors: { body: e.message })
      end
    end

    attr_reader :rel_name, :payload_schemas, :responders, :path, :registered_security_schemes
    attr_accessor :description, :tags

    # Creates a new endpoint instance.
    #
    # @param rel_name [Symbol] Relation name for this endpoint (e.g., :users_list, :create_user)
    # @param verb [Symbol] HTTP verb (:get, :post, :put, :patch, :delete, etc.)
    # @param path [String] URL path pattern (supports Mustermann syntax, e.g., '/users/:id')
    # @yield [endpoint] Configuration block that receives the endpoint instance
    #
    # @example
    #   Endpoint.new(:users_show, :get, path: '/users/:id') do |e|
    #     e.step { |result| result.continue(data: User.find(result.params[:id])) }
    #     e.respond 200, :json, UserSerializer
    #   end
    def initialize(service, rel_name, verb, path: '/', &)
      # Do not setup with block yet
      super(freeze_after: false, &nil)
      @service = service
      @rel_name = rel_name
      @verb = verb
      @responders = ResponderRegistry.new
      @query_schema = Types::Hash
      @header_schema = Types::Hash
      @payload_schemas = {}
      @body_parsers = {}
      @registered_security_schemes = {}
      @description = 'An endpoint'
      @specced = true
      @tags = []

      # This registers security schemes declared in the service
      # which may declare their own header, query or payload schemas
      service.registered_security_schemes.each do |name, scopes|
        security name, scopes
      end

      # This registers a query_schema
      # and a QueryValidator step
      self.path = path

      configure(&) if block_given?

      # Register default responders for common status codes
      respond 204, :json
      respond 304, :json
      respond 200..299, :json, DefaultEntitySerializer
      # TODO: match any content type
      # respond 304, '*/*'
      respond 401..422, :json, DefaultEntitySerializer
      respond 401..422, :html, DefaultHTMLSerializer
      freeze
    end

    def inspect
      %(<#{self.class}##{object_id} [#{rel_name}] #{verb.to_s.upcase} #{path}>)
    end

    # @return [Proc] Rack-compatible application callable
    def to_rack
      proc { |env| run(Steppe::Request.new(env)).response }
    end

    def specced? = @specced
    def no_spec! = @specced = false

    # Node name for OpenAPI documentation
    def node_name = :endpoint

    class SecurityStep
      attr_reader :header_schema, :query_schema

      def initialize(scheme, scopes: [])
        @scheme = scheme
        @scopes = scopes
        @header_schema = scheme.respond_to?(:header_schema) ? scheme.header_schema : Types::Hash
        @query_schema = scheme.respond_to?(:query_schema) ? scheme.query_schema : Types::Hash
      end

      def call(conn)
        @scheme.handle(conn, @scopes) 
      end
    end

    # Apply a security scheme to this endpoint with required scopes.
    # The security scheme must be registered in the parent Service using #security_scheme or #bearer_auth.
    # This adds a processing step that validates authentication/authorization before other endpoint logic runs.
    #
    # @param scheme_name [String] Name of the security scheme (must match a registered scheme)
    # @param scopes [Array<String>] Required permission scopes for this endpoint
    # @return [void]
    #
    # @raise [KeyError] If the security scheme is not registered in the parent service
    #
    # @example Basic usage with Bearer authentication
    #   service.bearer_auth 'api_key', store: {
    #     'token123' => ['read:users', 'write:users']
    #   }
    #
    #   service.get :users, '/users' do |e|
    #     e.security 'api_key', ['read:users']  # Only tokens with read:users scope can access
    #     e.step { |result| result.continue(data: User.all) }
    #     e.json 200, UserListSerializer
    #   end
    #
    # @example Multiple scopes required
    #   service.get :admin_users, '/admin/users' do |e|
    #     e.security 'api_key', ['read:users', 'admin:access']
    #     # ... endpoint definition
    #   end
    #
    # @note If authentication fails, returns 401 Unauthorized
    # @note If authorization fails (missing required scopes), returns 403 Forbidden
    # @see Service#security_scheme
    # @see Service#bearer_auth
    # @see Auth::Bearer#handle
    def security(scheme_name, scopes = [])
      scheme = service.security_schemes.fetch(scheme_name)
      scheme_step = SecurityStep.new(scheme, scopes:)
      @registered_security_schemes[scheme.name] = scopes
      step scheme_step
    end

    # Defines or returns the HTTP header validation schema.
    #
    # When called with a schema argument, registers a HeaderValidator step to validate
    # HTTP headers. When called without arguments, returns the current header schema.
    # Header schemas are automatically merged from security schemes and other composable steps.
    #
    # @overload header_schema(schema)
    #   Define header validation schema
    #   @param schema [Hash, Plumb::Composable] Schema definition for HTTP headers
    #   @return [void]
    #   @example Validate custom header
    #     header_schema(
    #       'HTTP_X_API_VERSION' => Types::String.options(['v1', 'v2']),
    #       'HTTP_X_REQUEST_ID?' => Types::String.present
    #     )
    #
    #   @example Validate Authorization header manually
    #     header_schema(
    #       'HTTP_AUTHORIZATION' => Types::String[/^Bearer .+/]
    #     )
    #
    # @overload header_schema
    #   Get current header schema
    #   @return [Plumb::Composable] Current header schema
    #
    # @note HTTP header names in Rack env use the format 'HTTP_*' (e.g., 'HTTP_AUTHORIZATION')
    # @note Optional headers can be specified with a '?' suffix (e.g., 'HTTP_X_CUSTOM?')
    # @note Security schemes automatically add their header requirements via SecurityStep
    #
    # @see HeaderValidator
    # @see Auth::Bearer#header_schema
    def header_schema(sc = nil)
      if sc
        step(HeaderValidator.new(sc))
      else
        @header_schema
      end
    end

    # Defines or returns the query parameter validation schema.
    #
    # When called with a schema argument, registers a QueryValidator step to validate
    # query parameters. When called without arguments, returns the current query schema.
    #
    # @overload query_schema(schema)
    #   @param schema [Hash, Plumb::Composable] Schema definition for query parameters
    #   @return [void]
    #   @example
    #     query_schema(
    #       page: Types::Integer.default(1),
    #       search: Types::String.optional
    #     )
    #
    # @overload query_schema
    #   @return [Plumb::Composable] Current query schema
    def query_schema(sc = nil)
      if sc
        step(QueryValidator.new(sc))
      else
        @query_schema
      end
    end

    # Defines request body validation schema for a specific content type.
    #
    # Automatically registers a BodyParser step for the content type if not already registered,
    # then registers a PayloadValidator step to validate the parsed body.
    #
    # @overload payload_schema(schema)
    #   Define JSON payload schema (default content type)
    #   @param schema [Hash, Plumb::Composable] Schema definition
    #   @example
    #     payload_schema(
    #       name: Types::String,
    #       email: Types::String.email
    #     )
    #
    # @overload payload_schema(content_type, schema)
    #   Define payload schema for specific content type
    #   @param content_type [String] Content type (e.g., 'application/xml')
    #   @param schema [Hash, Plumb::Composable] Schema definition
    #   @example
    #     payload_schema('application/xml', XMLUserSchema)
    #
    # @raise [ArgumentError] if arguments don't match expected patterns
    def payload_schema(*args)
      ctype, stp = case args
      in [Hash => sc]
        [ContentTypes::JSON, sc]
      in [Plumb::Composable => sc]
        [ContentTypes::JSON, sc]
      in [MatchContentType => content_type, Hash => sc]
        [content_type, sc]
      in [MatchContentType => content_type, Plumb::Composable => sc]
        [content_type, sc]
      else
        raise ArgumentError, "Invalid arguments: #{args.inspect}. Expects [Hash] or [Plumb::Composable], and an optional content type."
      end

      content_type = ContentType.parse(ctype)
      unless @body_parsers[content_type]
        step BodyParser.build(content_type)
        @body_parsers[ctype] = true
      end
      step PayloadValidator.new(content_type, stp)
    end

    # Gets or sets the HTTP verb for this endpoint.
    #
    # @overload verb(verb)
    #   Sets the HTTP verb
    #   @param verb [Symbol] HTTP verb (:get, :post, :put, :patch, :delete, etc.)
    #   @return [Symbol] The set verb
    #
    # @overload verb
    #   Gets the current HTTP verb
    #   @return [Symbol] Current verb
    def verb(vrb = nil)
      @verb = vrb if vrb
      @verb
    end

    # Convenience method to define a JSON responder.
    #
    # @param statuses [Integer, Range] Status code(s) to respond to (default: 200-299)
    # @param serializer [Class, Proc, nil] Optional serializer class or block
    # @yield [serializer] Optional block defining serializer inline
    # @return [self] Returns self for method chaining
    #
    # @example With serializer class
    #   json 200, UserSerializer
    #
    # @example With inline block
    #   json 200 do
    #     attribute :name, String
    #     def name = result.data[:name]
    #   end
    def json(statuses = (200...300), serializer = nil, &block)
      respond(statuses:, accepts: :json) do |r|
        r.description = "Response for status #{statuses}"
        r.serialize serializer || block
      end

      self
    end

    # Convenience method to define an HTML responder.
    #
    # @param statuses [Integer, Range] Status code(s) to respond to (default: 200-299)
    # @param view [Class, Proc, nil] Optional view class or block
    # @yield Optional block defining view inline
    # @return [self] Returns self for method chaining
    #
    # @example
    #   html 200, UserShowView
    def html(statuses = (200...300), view = nil, &block)
      respond(statuses, :html, view || block)

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
    def respond(*args, &)
      case args
      in [Responder => responder]
        @responders << responder

      in [MatchStatus => statuses]
        @responders << Responder.new(statuses:, &)

      in [MatchStatus => statuses, MatchContentType => accepts]
        @responders << Responder.new(statuses:, accepts:, &)

      in [MatchStatus => statuses, MatchContentType => accepts, Object => serializer]
        @responders << Responder.new(statuses:, accepts:, serializer:, &)

      in [Hash => kargs]
        @responders << Responder.new(**kargs, &)

      else
        raise ArgumentError, "Invalid arguments: #{args.inspect}"
      end

      self
    end

    # Adds a debugging breakpoint step to the endpoint pipeline.
    # Useful for development and troubleshooting.
    #
    # @return [void]
    def debug!
      step do |conn|
        debugger
        conn
      end
    end

    # Executes the endpoint pipeline for a given request.
    #
    # Creates an initial Continue result and runs it through the pipeline.
    #
    # @param request [Steppe::Request, Rack::Request] The request object
    # @return [Result] Processing result (Continue or Halt)
    def run(request)
      result = Result::Continue.new(nil, request:)
      call(result)
    end

    # Main processing method that runs the endpoint pipeline and handles response.
    #
    # Flow:
    # 1. Runs all registered steps (query validation, payload validation, business logic)
    # 2. Resolves appropriate responder based on status code and Accept header
    # 3. Runs responder pipeline to serialize and format response
    #
    # @param conn [Result] Initial result/connection object
    # @return [Result] Final result with serialized response
    def call(conn)
      known_query_names = query_schema._schema.keys.map(&:to_sym)
      known_query = conn.request.steppe_url_params.slice(*known_query_names)
      conn.request.set_url_params!(known_query)
      conn = super(conn)
      accepts = conn.request.get_header('HTTP_ACCEPT') || ContentTypes::JSON
      responder = responders.resolve(conn.response.status, accepts) || FALLBACK_RESPONDER
      # Conn might be a Halt now, because a step halted processing.
      # We set it back to Continue so that the responder pipeline
      # can process it through its steps.
      responder.call(conn.valid)
    end

    # Sets the URL path pattern and extracts path parameters into the query schema.
    # Path parameters are marked with metadata(in: :path) for OpenAPI documentation.
    # @param pt [String] URL path with tokens
    # @return [Mustermann]
    def path=(pt)
      @path = Mustermann.new(pt)
      sc = @path.names.each_with_object({}) do |name, h| 
        name = name.to_sym
        field = @query_schema.at_key(name) || Steppe::Types::String
        # field = field.metadata(in: :path)
        h[name] = field
      end
      # Setup a new query validator
      # and merge into @query_schema
      query_schema(sc)

      @path
    end

    private

    attr_reader :service

    # Hook called when adding steps to the pipeline.
    # Automatically merges query and payload schemas from composable steps.
    def prepare_step(callable)
      merge_header_schema(callable.header_schema) if callable.respond_to?(:header_schema)
      merge_query_schema(callable.query_schema) if callable.respond_to?(:query_schema)
      merge_payload_schema(callable) if callable.respond_to?(:payload_schema)
      callable
    end

    def merge_header_schema(sc)
      @header_schema += sc
    end

    # Merges a query schema from a step into the endpoint's query schema.
    # Annotates each parameter with metadata indicating whether it's a path or query parameter.
    def merge_query_schema(sc)
      annotated_sc = sc._schema.each_with_object({}) do |(k, v), h|
        pin = @path.names.include?(k.to_s) ? :path : :query
        h[k] = Plumb::Composable.wrap(v).metadata(in: pin)
      end
      @query_schema += annotated_sc
    end

    # Merges a payload schema from a step into the endpoint's payload schemas.
    # Handles multiple content types and merges schemas if they support the + operator.
    def merge_payload_schema(callable)
      content_type = callable.respond_to?(:content_type) ? callable.content_type : ContentTypes::JSON
      media_type = content_type.media_type

      existing = @payload_schemas[media_type]
      if existing && existing.respond_to?(:+)
        existing += callable.payload_schema
      else
        existing = callable.payload_schema
      end
      @payload_schemas[media_type] = existing
    end
  end
end
