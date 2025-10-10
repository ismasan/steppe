# frozen_string_literal: true

module Steppe
  module Auth
    class Bearer
      HEADER = 'HTTP_AUTHORIZATION'

      attr_reader :name, :format, :scheme, :type

      def initialize(name, store:, scheme: 'bearer', format: nil, header: HEADER)
        @name = name
        @store = store
        @format = format
        @scheme = scheme.to_s
        @type = :http
        @header = header
        @matcher = %r{\A\s*#{Regexp.escape(@scheme)}\s+(.+?)\s*\z}i
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
  end
end
