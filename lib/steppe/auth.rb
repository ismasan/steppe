# frozen_string_literal: true

module Steppe
  # Authentication and authorization module for Steppe endpoints.
  # Provides security schemes for protecting API endpoints and validating access tokens.
  # Implements common security schemes supported by OpenAPI spec
  # @see https://swagger.io/docs/specification/v3_0/authentication/
  module Auth
    WWW_AUTHENTICATE = 'www-authenticate'
    HTTP_AUTHORIZATION = 'HTTP_AUTHORIZATION'

    # Interface that security schemes must implement.
    # Required methods:
    # - name: Returns the security scheme name
    # - handle: Processes authentication/authorization for a connection
    SecuritySchemeInterface = Types::Interface[
      :name,
      :handle,
      :to_openapi
    ]
  end

  module Responses
    private

    def unauthorized(conn, realm)
      conn.response.add_header(Auth::WWW_AUTHENTICATE, 'Basic realm="%s"' % realm)
      conn.respond_with(401).halt
    end

    def forbidden(conn)
      conn.respond_with(403).halt
    end
  end
end

require 'steppe/auth/bearer'
require 'steppe/auth/basic'
