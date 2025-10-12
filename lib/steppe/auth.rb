# frozen_string_literal: true

module Steppe
  # Authentication and authorization module for Steppe endpoints.
  # Provides security schemes for protecting API endpoints and validating access tokens.
  # Implements common security schemes supported by OpenAPI spec
  # @see https://swagger.io/docs/specification/v3_0/authentication/
  module Auth
    # Interface that security schemes must implement.
    # Required methods:
    # - name: Returns the security scheme name
    # - handle: Processes authentication/authorization for a connection
    SecuritySchemeInterface = Types::Interface[
      :name,
      :handle,
      :to_openapi
    ]

    # HTTP Bearer token authentication security scheme.
    # Validates Bearer tokens from the Authorization header and checks permissions against a token store.
    #
    # @example
    #   store = Steppe::Auth::HashTokenStore.new({
    #     'token123' => ['read:users', 'write:users']
    #   })
    #   bearer = Steppe::Auth::Bearer.new('my_auth', store: store)
    #
    #   # In a service definition:
    #   api.security_scheme bearer
    #
    #   # Then in an endpoint in the service:
    #   e.security 'my_auth', ['read:users']
    #
    class Bearer
      # Default HTTP header for Authorization
      HEADER = 'HTTP_AUTHORIZATION'

      attr_reader :name, :format, :scheme, :header_schema

      # Initialize a new Bearer authentication scheme.
      #
      # @param name [String] The security scheme name (used in OpenAPI)
      # @param store [TokenStoreInterface] Token store for validating access tokens
      # @param scheme [String] The authentication scheme (default: 'bearer')
      # @param format [String, nil] Optional bearer format hint (e.g., 'JWT')
      # @param header [String] The HTTP header to check (default: HTTP_AUTHORIZATION)
      def initialize(name, store:, scheme: 'bearer', format: nil, header: HEADER)
        @name = name
        @store = store
        @format = format.to_s
        @scheme = scheme.to_s
        @header = header
        # We mark the key as optional
        # because we don't validate presence of the header and return a 422.
        # (even though that'll most likely result in a 401 response after running #handle)
        @header_schema = Types::Hash["#{@header}?" => String]
        @matcher = %r{\A\s*#{Regexp.escape(@scheme)}\s+(.+?)\s*\z}i
      end

      # Convert this security scheme to OpenAPI 3.0 format.
      #
      # @return [Hash] OpenAPI security scheme object
      def to_openapi
        {
          'type' => 'http',
          'scheme' => scheme,
          'bearerFormat' => format
        }
      end

      # Handle authentication and authorization for a connection.
      # Validates the Bearer token from the Authorization header and checks if it has required scopes.
      #
      # @param conn [Steppe::Result] The connection/result object
      # @param required_scopes [Array<String>] The scopes required for this endpoint
      # @return [Steppe::Result::Continue, Steppe::Result::Halt] The connection, or halted with 401/403 status
      def handle(conn, required_scopes)
        header_value = conn.request.get_header(@header).to_s.strip
        return conn.respond_with(401).halt if header_value.empty?

        token = header_value[@matcher, 1]
        return conn.respond_with(401).halt if header_value.empty?

        access_token = @store.get(token)
        return conn.respond_with(401).halt if access_token.nil?

        return conn if access_token.allows?(required_scopes)

        conn.respond_with(403).halt
      end
    end

    # Interface for hash-based token stores (Hash[String => Array[String]]).
    # Maps token strings to arrays of scope strings.
    HashTokenStoreInterface = Types::Hash[String, Types::Array[String]]

    # Interface for custom token store implementations.
    # Required methods:
    # - get(token): Returns an access token object or nil
    TokenStoreInterface = Types::Interface[:get]

    # Simple hash-based token store implementation.
    # Stores tokens in memory with their associated scopes.
    #
    # @example
    #   store = HashTokenStore.new({
    #     'abc123' => ['read:users', 'write:users'],
    #     'xyz789' => ['read:posts']
    #   })
    class HashTokenStore
      # Represents an access token with associated permission scopes.
      class AccessToken < Data.define(:scopes)
        # Check if this token has any of the required scopes.
        #
        # @param required_scopes [Array<String>] Scopes to check against
        # @return [Boolean] True if token has at least one required scope
        def allows?(required_scopes)
          (scopes & required_scopes).any?
        end
      end

      # Wrap a store object, converting hashes to HashTokenStore instances.
      #
      # @param store [Hash, TokenStoreInterface] A hash or token store implementation
      # @return [TokenStoreInterface] A token store instance
      # @raise [ArgumentError] If store doesn't match expected interfaces
      def self.wrap(store)
        case store
        when HashTokenStoreInterface
          new(store)
        when TokenStoreInterface
          store
        else
          raise ArgumentError, "expected a TokenStore interface #{TokenStoreInterface}, but got #{store.inspect}"
        end
      end

      # @param hash [Hash] Hash mapping token strings to scope arrays
      def initialize(hash)
        @lookup = hash.transform_values { |scopes| AccessToken.new(scopes) }
      end

      # Retrieve an access token by its token string.
      #
      # @param token [String] The token string to look up
      # @return [AccessToken, nil] The access token or nil if not found
      def get(token)
        @lookup[token]
      end
    end
  end
end
