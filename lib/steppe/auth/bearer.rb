# frozen_string_literal: true

module Steppe
  module Auth
    # HTTP Bearer token authentication security scheme.
    # Validates Bearer tokens from the Authorization header and checks permissions against a token store.
    #
    # The token store must implement `#get(token)` returning an access token object or nil.
    # The access token must implement `#allows?(conn, required_scopes)` returning a boolean.
    #
    # On successful authentication, the access token is stored in the request env at
    # `Steppe::Auth::Bearer::ACCESS_TOKEN_ENV_KEY` ('steppe.access_token'), making it
    # available to downstream steps.
    #
    # @example Using the built-in hash store
    #   api.bearer_auth 'my_auth', store: { 'token123' => ['read:users'] }
    #
    # @example Accessing the token in downstream steps
    #   e.security 'my_auth', ['read:users']
    #
    #   e.step do |conn|
    #     access_token = conn.request.env[Steppe::Auth::Bearer::ACCESS_TOKEN_ENV_KEY]
    #     # Use access_token.user_id, access_token.scopes, etc.
    #     conn
    #   end
    #
    # @example Using a custom token store
    #   class MyAccessToken
    #     attr_reader :user_id, :scopes
    #
    #     def initialize(user_id, scopes)
    #       @user_id = user_id
    #       @scopes = scopes
    #     end
    #
    #     def allows?(conn, required_scopes)
    #       (@scopes & required_scopes).any?
    #     end
    #   end
    #
    #   class MyTokenStore
    #     def get(token)
    #       record = Token.find_by(value: token)
    #       MyAccessToken.new(record.user_id, record.scopes) if record
    #     end
    #   end
    #
    #   api.bearer_auth 'my_auth', store: MyTokenStore.new
    #
    class Bearer
      include Responses

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
        # Interface for hash-based token stores (Hash[String => Array[String]]).
        # Maps token strings to arrays of scope strings.
        Interface = Types::Hash[String, Types::Array[String]]

        # Represents an access token with associated permission scopes.
        class AccessToken < Data.define(:scopes)
          # Check if this token has any of the required scopes.
          #
          # @param required_scopes [Array<String>] Scopes to check against
          # @return [Boolean] True if token has at least one required scope
          def allows?(_conn, required_scopes)
            (scopes & required_scopes).any?
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

      attr_reader :name, :format, :scheme, :header_schema

      # Initialize a new Bearer authentication scheme.
      #
      # @param name [String] The security scheme name (used in OpenAPI)
      # @param store [TokenStoreInterface] Token store for validating access tokens
      # @param scheme [String] The authentication scheme (default: 'bearer')
      # @param format [String, nil] Optional bearer format hint (e.g., 'JWT')
      # @param header [String] The HTTP header to check (default: HTTP_AUTHORIZATION)
      def initialize(name, store:, scheme: 'bearer', format: nil, header: HTTP_AUTHORIZATION)
        @name = name
        @store = case store
        when HashTokenStore::Interface
          HashTokenStore.new(store)
        when TokenStoreInterface
          store
        else
          raise ArgumentError, "expected a TokenStore interface #{TokenStoreInterface}, but got #{store.inspect}"
        end

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

      # Request env key where the access token is stored after successful authentication.
      ACCESS_TOKEN_ENV_KEY = 'steppe.access_token'

      # Handle authentication and authorization for a connection.
      # Validates the Bearer token from the Authorization header and checks if it has required scopes.
      # On success, stores the access token in the request env at ACCESS_TOKEN_ENV_KEY.
      # If the request was already authenticated, still checks scopes against the existing token.
      #
      # @param conn [Steppe::Result] The connection/result object
      # @param required_scopes [Array<String>] The scopes required for this endpoint
      # @return [Steppe::Result::Continue, Steppe::Result::Halt] The connection, or halted with 401/403 status
      def handle(conn, required_scopes)
        access_token = conn.request.env[ACCESS_TOKEN_ENV_KEY]
        if access_token
          return forbidden(conn) unless access_token.allows?(conn, required_scopes)

          return conn
        end

        header_value = conn.request.get_header(@header).to_s.strip
        return unauthorized(conn) if header_value.empty?

        token = header_value[@matcher, 1]
        return unauthorized(conn) if token.nil?

        access_token = @store.get(token)
        return forbidden(conn) unless access_token&.allows?(conn, required_scopes)

        conn.request.env[ACCESS_TOKEN_ENV_KEY] = access_token
        conn
      end
    end
  end
end
