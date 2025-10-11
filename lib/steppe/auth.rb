# frozen_string_literal: true

module Steppe
  module Auth
    SecuritySchemeInterface = Types::Interface[
      :name, 
      :handle
    ]

    class Bearer
      HEADER = 'HTTP_AUTHORIZATION'

      attr_reader :name, :format, :scheme

      def initialize(name, store:, scheme: 'bearer', format: nil, header: HEADER)
        @name = name
        @store = store
        @format = format.to_s
        @scheme = scheme.to_s
        @header = header
        @matcher = %r{\A\s*#{Regexp.escape(@scheme)}\s+(.+?)\s*\z}i
      end

      def to_openapi
        {
          'type' => 'http',
          'scheme' => scheme,
          'bearerFormat' => format
        }
      end

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

    HashTokenStoreInterface = Types::Hash[String, Types::Array[String]]
    TokenStoreInterface = Types::Interface[:get]

    class HashTokenStore
      class AccessToken < Data.define(:scopes)
        def allows?(required_scopes)
          (scopes & required_scopes).any?
        end
      end

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

      def initialize(hash)
        @lookup = hash.transform_values { |scopes| AccessToken.new(scopes) }
      end

      def get(token)
        @lookup[token]
      end
    end
  end
end
