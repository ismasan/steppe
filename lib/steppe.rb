# frozen_string_literal: true

require 'plumb'
require 'mime/types'

require_relative 'steppe/version'

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
  end

  module ContentTypes
    JSON = 'application/json'
  end

  JSON_MIME = MIME::Type.new(ContentTypes::JSON).freeze
end

require_relative 'steppe/responder'
require_relative 'steppe/service'
require_relative 'steppe/endpoint'
require_relative 'steppe/openapi_visitor'
