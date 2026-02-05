# frozen_string_literal: true

require 'json'
require 'rack'
require 'securerandom'
require 'steppe/mcp/prompt'

module Steppe
  module MCP
    # Rack application that exposes a Steppe::Service as an MCP (Model Context Protocol) server.
    #
    # This handler implements the MCP Streamable HTTP transport (request/response only, no SSE),
    # allowing AI models to discover and call Steppe endpoints as MCP tools.
    #
    # @example Basic usage
    #   service = Steppe::Service.new do |api|
    #     api.title = 'Users API'
    #     api.get :users, '/users' do |e|
    #       e.description = 'List all users'
    #       e.query_schema(q?: Types::String)
    #       e.step { |conn| conn.valid(User.all) }
    #       e.json 200, UserSerializer
    #     end
    #   end
    #
    #   # Mount as Rack app
    #   run Steppe::MCP::Handler.new(service)
    #
    # @example With prompts
    #   Steppe::MCP::Handler.new(service) do |mcp|
    #     mcp.prompt 'create_user_guide' do |p|
    #       p.description = 'Guide for creating a new user'
    #       p.argument :name, required: true, description: 'User name'
    #       p.messages do |args|
    #         [{ role: 'user', content: { type: 'text', text: "Create a user named #{args[:name]}" } }]
    #       end
    #     end
    #   end
    #
    # @see https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
    class Handler
      PROTOCOL_VERSION = '2025-06-18'
      JSON_TYPE = 'application/json'
      SESSION_HEADER = 'Mcp-Session-Id'
      SESSION_HEADER_ENV = 'HTTP_MCP_SESSION_ID'

      # Interface for session stores
      # Must implement:
      #   #create -> String (new session ID)
      #   #valid?(session_id) -> Boolean
      #   #delete(session_id) -> void
      SessionStoreInterface = Types::Interface[:create, :valid?, :delete]

      # Null session store - stateless, accepts any session ID
      class NullSessionStore
        def create = SecureRandom.uuid
        def valid?(_session_id) = true
        def delete(_session_id) = nil
      end

      # Instructions to include in the initialize response
      # @return [String, nil]
      attr_reader :instructions

      # Set instructions (only allowed during configuration block)
      # @param value [String, nil]
      def instructions=(value)
        raise FrozenError, "can't modify frozen #{self.class}" if @frozen
        @instructions = value
      end

      # @param service [Steppe::Service] The service to expose as MCP tools
      # @param session_store [SessionStoreInterface] Session store (defaults to stateless NullSessionStore)
      # @yield [handler] Block for configuring prompts and instructions
      def initialize(service, session_store: NullSessionStore.new, &block)
        @frozen = false
        @service = service
        session_store => SessionStoreInterface
        @session_store = session_store
        @prompts = {}
        @instructions = nil
        @tools = service.endpoints.filter_map do |endpoint|
          next unless endpoint.specced?

          {
            name: endpoint.rel_name.to_s,
            description: endpoint.description,
            inputSchema: build_input_schema(endpoint)
          }.freeze
        end

        block&.call(self)
        freeze_configuration!
      end

      # Define a prompt template (only allowed during configuration block)
      # @param name [String, Symbol] Unique identifier for the prompt
      # @yield [prompt] Block for configuring the prompt
      def prompt(name, &block)
        raise FrozenError, "can't modify frozen #{self.class}" if @frozen

        p = Prompt.new(name, &block)
        @prompts[p.name] = p
      end

      # Rack interface
      # @param env [Hash] Rack environment
      # @return [Array] Rack response tuple [status, headers, body]
      def call(env)
        request = Rack::Request.new(env)
        @current_env = env

        # Handle DELETE for session termination
        if request.delete?
          return handle_session_delete(request)
        end

        body = parse_request_body(request)
        return error_response(400, 'Invalid JSON') unless body

        # Session validation (skip for initialize)
        is_initialize = body[:method] == 'initialize'
        session_id = request.get_header(SESSION_HEADER_ENV)

        unless is_initialize
          return error_response(404, 'Session not found') unless valid_session?(session_id)
        end

        result, headers = dispatch(body)

        # Echo session ID in response (if present, or newly created for initialize)
        headers[SESSION_HEADER] ||= session_id if session_id

        if result == :accepted
          [202, headers, []]
        else
          [200, { 'Content-Type' => JSON_TYPE }.merge(headers), [JSON.dump(result)]]
        end
      rescue StandardError => e
        error_response(500, e.message)
      end

      private

      def freeze_configuration!
        @instructions = @instructions.freeze
        @prompts.freeze
        @tools.freeze
        @frozen = true
      end

      def parse_request_body(request)
        JSON.parse(request.body.read, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      def error_response(status, message)
        [status, { 'Content-Type' => JSON_TYPE }, [JSON.dump({ error: message })]]
      end

      # Session management - delegates to @session_store
      def create_session
        @session_store.create
      end

      def valid_session?(session_id)
        session_id && @session_store.valid?(session_id)
      end

      def handle_session_delete(request)
        session_id = request.get_header(SESSION_HEADER_ENV)
        return error_response(404, 'Session not found') unless valid_session?(session_id)

        @session_store.delete(session_id)
        [204, {}, []]
      end

      def dispatch(msg)
        result = case msg[:method]
        when 'initialize'
          return handle_initialize(msg)
        when 'notifications/initialized'
          :accepted
        when 'tools/list'
          handle_tools_list(msg)
        when 'tools/call'
          handle_tools_call(msg)
        when 'prompts/list'
          handle_prompts_list(msg)
        when 'prompts/get'
          handle_prompts_get(msg)
        else
          jsonrpc_error(msg[:id], -32601, "Method not found: #{msg[:method]}")
        end

        [result, {}]
      end

      # Handle MCP initialize request
      # Creates a new session and returns session ID in headers
      # @see https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
      def handle_initialize(msg)
        session_id = create_session

        capabilities = { tools: {} }
        capabilities[:prompts] = {} if @prompts.any?

        init_result = {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: capabilities,
          serverInfo: {
            name: @service.title,
            version: @service.version
          }
        }
        init_result[:instructions] = @instructions if @instructions

        result = jsonrpc_result(msg[:id], init_result)

        [result, { SESSION_HEADER => session_id }]
      end

      # Handle MCP tools/list request
      # Returns all specced endpoints as MCP tool definitions
      def handle_tools_list(msg)
        jsonrpc_result(msg[:id], { tools: @tools })
      end

      # Handle MCP tools/call request
      # Executes the corresponding Steppe endpoint
      def handle_tools_call(msg)
        name = msg.dig(:params, :name)
        arguments = msg.dig(:params, :arguments) || {}

        endpoint = @service[name&.to_sym]
        return jsonrpc_error(msg[:id], -32602, "Unknown tool: #{name}") unless endpoint

        result = call_endpoint(endpoint, arguments)
        build_tool_response(msg[:id], result)
      end

      # Handle MCP prompts/list request
      # Returns all defined prompts
      def handle_prompts_list(msg)
        prompts = @prompts.values.map(&:to_definition)
        jsonrpc_result(msg[:id], { prompts: prompts })
      end

      # Handle MCP prompts/get request
      # Returns the prompt with generated messages
      def handle_prompts_get(msg)
        name = msg.dig(:params, :name)
        arguments = msg.dig(:params, :arguments) || {}

        prompt = @prompts[name]
        return jsonrpc_error(msg[:id], -32602, "Unknown prompt: #{name}") unless prompt

        jsonrpc_result(msg[:id], prompt.to_result(arguments))
      end

      # Execute a Steppe endpoint with the given arguments
      # @param endpoint [Steppe::Endpoint]
      # @param args [Hash] Tool arguments (merged path, query, and body params)
      # @return [Steppe::Result]
      def call_endpoint(endpoint, args)
        args = args.transform_keys(&:to_sym)

        # Split args into path params vs others
        path_param_names = endpoint.path.names.map(&:to_sym)
        path_params = args.slice(*path_param_names)
        other_params = args.except(*path_param_names)

        # Build the request path with substituted path params
        path = if path_params.any?
                 endpoint.path.expand(path_params.transform_keys(&:to_s))
               else
                 endpoint.path.to_s
               end

        # Build mock Rack environment
        env = build_rack_env(endpoint, path, other_params)
        # Path params must be strings (as they would be extracted from URL)
        env[Steppe::Request::ROUTER_PARAMS] = path_params.transform_keys(&:to_s).transform_values(&:to_s)

        request = Steppe::Request.new(env)
        endpoint.run(request)
      end

      # Build a Rack environment for the endpoint call
      # Forwards HTTP headers from the original MCP request
      # NOTE: we only dump to JSON so that the endpoint can deserialize it again
      # because Steppe will add a body parsers if the request is application/json
      # We could provide our own internal content type (ex. application/steppe-mcp)
      # to skip the endpoint's JSON parser and just pass the params Hash
      def build_rack_env(endpoint, path, params)
        env = Rack::MockRequest.env_for(
          path,
          method: endpoint.verb.to_s.upcase,
          input: StringIO.new(JSON.dump(params))
        )

        # Forward HTTP_* headers from the original request
        @current_env.each do |key, value|
          env[key] = value if key.start_with?('HTTP_')
        end

        # Override content type and accept for JSON
        env['CONTENT_TYPE'] = JSON_TYPE
        env['HTTP_ACCEPT'] = JSON_TYPE

        # For GET requests, also set query string
        if endpoint.verb == :get && params.any?
          env['QUERY_STRING'] = Rack::Utils.build_query(params)
        end

        env
      end

      # Build MCP tool response from Steppe result
      def build_tool_response(id, result)
        response = result.response
        body = extract_response_body(response)

        # Check response status for errors (4xx, 5xx)
        # Note: result.valid? is unreliable because the endpoint converts
        # Halt back to Continue for responder processing
        is_error = response.status >= 400

        jsonrpc_result(id, {
          content: [{ type: 'text', text: body }],
          isError: is_error
        })
      end

      # Extract body content from Rack response
      def extract_response_body(response)
        body_parts = []
        response.body.each { |part| body_parts << part }
        body_parts.join
      end

      # Build JSON Schema for an endpoint's combined inputs
      # Merges query_schema and payload_schemas into a single schema
      def build_input_schema(endpoint)
        merged = endpoint.query_schema

        endpoint.payload_schemas.each_value do |schema|
          merged = merged + schema if schema.respond_to?(:+)
        end

        merged.to_json_schema
      end

      # JSON-RPC 2.0 success response
      def jsonrpc_result(id, result)
        { jsonrpc: '2.0', id: id, result: result }
      end

      # JSON-RPC 2.0 error response
      # @param code [Integer] Error code (-32600 to -32699 for JSON-RPC errors)
      def jsonrpc_error(id, code, message)
        { jsonrpc: '2.0', id: id, error: { code: code, message: message } }
      end
    end
  end
end
