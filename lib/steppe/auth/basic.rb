# frozen_string_literal: true

module Steppe
  module Auth
    class Basic
      include Responses

      EXP = /^Basic\s+([A-Za-z0-9+\/=]+)\s*$/

      CredentialsStoreInterface = Types::Interface[:lookup]

      class SimpleUserPasswordStore
        # { ['joe', 'secret' => true, ['anna', 'nope'] => false }
        # { 'joe' => 'secret', 'anna' => '123' }
        Interface = Types::Hash[String, String]

        def initialize(hash)
          @lookup = hash
        end

        def lookup(username) = @lookup[username.strip]
      end

      attr_reader :name

      def initialize(name, store:)
        @name = name
        @store = case store
        when SimpleUserPasswordStore::Interface
          SimpleUserPasswordStore.new(store)
        when CredentialsStoreInterface
          store
        else
          raise ArgumentError, "expected a CredentialsStoreInterface interface #{CredentialsStoreInterface}, but got #{store.inspect}"
        end
      end

      def handle(conn)
        auth_str = conn.request.env[HTTP_AUTHORIZATION]
        return unauthorized(conn, @name) if auth_str.nil?

        match = auth_str.match(EXP)
        return unauthorized(conn, @name) if match.nil?

        username, password = decode(match[1]) 
        return forbidden(conn) if @store.lookup(username) != password

        conn
      end

      def to_openapi
        {
          'type' => 'http',
          'scheme' => 'basic'
        }
      end

      private

      def decode(auth_str)
        auth_str.to_s.unpack1('m').split(':', 2)
      end
    end
  end
end
