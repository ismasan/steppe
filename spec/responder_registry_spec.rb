# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Steppe::ResponderRegistry do
  specify do
    registry = described_class.new

    json_responder = Steppe::Responder.new(statuses: 200, content_type: 'application/json')
    json_error_responder = Steppe::Responder.new(statuses: (400...500), content_type: 'application/json')
    html_responder = Steppe::Responder.new(statuses: 200, content_type: 'text/html')
    fallback_responder = Steppe::Responder.new(statuses: (200...600), content_type: '*/*')

    registry << json_responder
    registry << json_error_responder
    registry << html_responder
    registry << fallback_responder

    expect(registry.resolve(200, 'application/json; version=1')).to eq(json_responder)
    expect(registry.resolve(422, 'application/json')).to eq(json_error_responder)
    expect(registry.resolve(200, 'text/html')).to eq(html_responder)
    expect(registry.resolve(200, 'text/*')).to eq(html_responder)
    # expect(registry.resolve(200, 'application/foo')).to eq(fallback_responder)
    expect(registry.resolve(200, '*/*')).to eq(fallback_responder)
    # expect(registry.resolve(200, 'foo/*')).to eq(fallback_responder)
    #
    # # It honours quality factor
    expect(registry.resolve(200, 'application/json; version=1; q=0.9, text/html')).to eq(html_responder)
  end
end
