# frozen_string_literal: true

module Steppe
  module Auth
    # HTTP Basic authentication security scheme.
    # Validates username and password credentials from the Authorization header against a credentials store.
    #
    # @example Using a simple hash store
    #   store = {
    #     'joe' => 'secret123',
    #     'anna' => 'password456'
    #   }
    #   basic_auth = Steppe::Auth::Basic.new('my_auth', store: store)
    #
    #   # In a service definition:
    #   api.security_scheme basic_auth
    #
    #   # Or use the shortcut
    #   api.basic_auth 'my_auth', store: { 'joe' => 'secret123' }
    #
    #   # Then in an endpoint in the service:
    #   e.security 'my_auth'
    #
    # @example Using a custom credentials store
    #   class DatabaseCredentialsStore
    #     def lookup(username)
    #       user = User.find_by(username: username)
    #       user&.password_digest
    #     end
    #   end
    #
    #   store = DatabaseCredentialsStore.new
    #   api.basic_auth 'my_auth', store: store
    #
    class Basic
      include Responses

      SCHEME = 'basic'
      EXP = /^Basic\s+([A-Za-z0-9+\/=]+)\s*$/

      # Interface for custom credentials store implementations.
      # Required methods:
      # - lookup(username): Returns the password for the given username, or nil if not found
      CredentialsStoreInterface = Types::Interface[:lookup]

      # Simple hash-based credentials store implementation.
      # Stores username/password pairs in memory.
      #
      # @example
      #   store = SimpleUserPasswordStore.new({
      #     'joe' => 'secret123',
      #     'anna' => 'password456'
      #   })
      class SimpleUserPasswordStore
        # Interface for hash-based credentials stores (Hash[String => String]).
        # Maps username strings to password strings.
        HashInterface = Types::Hash[String, String]

        # @param hash [Hash] Hash mapping usernames to passwords
        def initialize(hash)
          @lookup = hash
        end

        # Retrieve a password by username.
        #
        # @param username [String] The username to look up
        # @return [String, nil] The password or nil if not found
        def lookup(username) = @lookup[username.strip]
      end

      attr_reader :name

      # @param name [String] The security scheme name (used in OpenAPI)
      # @param store [CredentialsStoreInterface] Credentials store for validating username/password pairs
      def initialize(name, store:)
        @name = name
        @scheme = SCHEME
        @store = case store
        when SimpleUserPasswordStore::HashInterface
          SimpleUserPasswordStore.new(store)
        when CredentialsStoreInterface
          store
        else
          raise ArgumentError, "expected a CredentialsStoreInterface interface #{CredentialsStoreInterface}, but got #{store.inspect}"
        end
      end

      # Handle authentication for a connection.
      # Validates the Basic credentials from the Authorization header and checks username/password match.
      #
      # @param conn [Steppe::Result] The connection/result object
      # @param _required_scopes [nil] Unused parameter (Basic auth does not support scopes)
      # @param authorizer [nil] Unused parameter. Accepted for interface consistency with {Bearer#handle}
      #   but ignored — Basic auth does not support custom authorization.
      # @return [Steppe::Result::Continue, Steppe::Result::Halt] The connection, or halted with 401/403 status
      def handle(conn, _required_scopes = nil, authorizer: nil)
        auth_str = conn.request.env[HTTP_AUTHORIZATION]
        return unauthorized(conn) if auth_str.nil?

        match = auth_str.match(EXP)
        return unauthorized(conn) if match.nil?

        username, password = decode(match[1])
        return forbidden(conn) if @store.lookup(username) != password

        conn
      end

      # Convert this security scheme to OpenAPI 3.0 format.
      #
      # @return [Hash] OpenAPI security scheme object
      def to_openapi
        {
          'type' => 'http',
          'scheme' => scheme
        }
      end

      private

      attr_reader :scheme

      # Decode Base64-encoded Basic authentication credentials.
      #
      # @param auth_str [String] The Base64-encoded credentials string
      # @return [Array<String>] Array containing [username, password]
      def decode(auth_str)
        auth_str.to_s.unpack1('m').split(':', 2)
      end
    end
  end
end
