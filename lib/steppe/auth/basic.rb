# frozen_string_literal: true

module Steppe
  module Auth
    class Basic
      include Responses

      SCHEME = 'basic'
      EXP = /^Basic\s+([A-Za-z0-9+\/=]+)\s*$/

      CredentialsStoreInterface = Types::Interface[:lookup]

      class SimpleUserPasswordStore
        # { ['joe', 'secret' => true, ['anna', 'nope'] => false }
        # { 'joe' => 'secret', 'anna' => '123' }
        HashInterface = Types::Hash[String, String]

        def initialize(hash)
          @lookup = hash
        end

        def lookup(username) = @lookup[username.strip]
      end

      attr_reader :name

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

      def handle(conn, _required_scopes = nil)
        auth_str = conn.request.env[HTTP_AUTHORIZATION]
        return unauthorized(conn) if auth_str.nil?

        match = auth_str.match(EXP)
        return unauthorized(conn) if match.nil?

        username, password = decode(match[1]) 
        return forbidden(conn) if @store.lookup(username) != password

        conn
      end

      def to_openapi
        {
          'type' => 'http',
          'scheme' => scheme
        }
      end

      private

      attr_reader :scheme

      def decode(auth_str)
        auth_str.to_s.unpack1('m').split(':', 2)
      end
    end
  end
end
