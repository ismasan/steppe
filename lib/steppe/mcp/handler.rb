# frozen_string_literal: true

require 'json'
require 'rack'
require 'securerandom'

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
    # @example With Sinatra/Rails
    #   map '/mcp' do
    #     run Steppe::MCP::Handler.new(MyService)
    #   end
    #
    # @see https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
    class Handler
      PROTOCOL_VERSION = '2025-06-18'
      JSON_TYPE = 'application/json'

      # @param service [Steppe::Service] The service to expose as MCP tools
      def initialize(service)
        @service = service
        @tools = service.endpoints.filter_map do |endpoint|
          next unless endpoint.specced?

          {
            name: endpoint.rel_name.to_s,
            description: endpoint.description,
            inputSchema: build_input_schema(endpoint)
          }
        end
      end

      # Rack interface
      # @param env [Hash] Rack environment
      # @return [Array] Rack response tuple [status, headers, body]
      def call(env)
        request = Rack::Request.new(env)
        @current_env = env

        body = parse_request_body(request)
        return error_response(400, 'Invalid JSON') unless body

        result = dispatch(body)

        if result == :accepted
          [202, {}, []]
        else
          [200, { 'Content-Type' => JSON_TYPE }, [JSON.dump(result)]]
        end
      rescue StandardError => e
        error_response(500, e.message)
      end

      private

      def parse_request_body(request)
        JSON.parse(request.body.read, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      def error_response(status, message)
        [status, { 'Content-Type' => JSON_TYPE }, [JSON.dump({ error: message })]]
      end

      def dispatch(msg)
        case msg[:method]
        when 'initialize'
          handle_initialize(msg)
        when 'notifications/initialized'
          :accepted
        when 'tools/list'
          handle_tools_list(msg)
        when 'tools/call'
          handle_tools_call(msg)
        else
          jsonrpc_error(msg[:id], -32601, "Method not found: #{msg[:method]}")
        end
      end

      # Handle MCP initialize request
      # @see https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
      def handle_initialize(msg)
        jsonrpc_result(msg[:id], {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: {
            name: @service.title,
            version: @service.version
          }
        })
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
