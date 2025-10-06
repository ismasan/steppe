# frozen_string_literal: true

require 'plumb'
require 'tempfile'

require_relative 'steppe/version'
require_relative 'steppe/content_type'

module Steppe
  class Error < StandardError; end

  Plumb.policy :desc, helper: true do |type, description|
    type.metadata(description:)
  end

  Plumb.policy :example, helper: true do |type, example|
    type.metadata(example:)
  end

  module Types
    include Plumb::Types

    class UploadedFile < Data
      attribute :filename, String
      attribute :type, String
      attribute :name, String
      attribute :tempfile, ::Tempfile
      attribute :head, String

      def self.node_name = :uploaded_file
    end
  end

  module ContentTypes
    JSON = ContentType.parse('application/json')
    TEXT = ContentType.parse('text/plain')
  end
end

require_relative 'steppe/request'
require_relative 'steppe/responder'
require_relative 'steppe/service'
require_relative 'steppe/endpoint'
require_relative 'steppe/openapi_visitor'
