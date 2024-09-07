# frozen_string_literal: true

require 'plumb'
require 'mime/types'

require_relative 'steppe/version'

module Steppe
  class Error < StandardError; end

  module Types
    include Plumb::Types
  end

  module ContentTypes
    JSON = 'application/json'
  end

  JSON_MIME = MIME::Type.new(ContentTypes::JSON).freeze
end

require_relative 'steppe/responder'
require_relative 'steppe/endpoint'
