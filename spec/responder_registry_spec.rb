# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Steppe::ResponderRegistry do
  specify do
    registry = described_class.new

    json_responder = Steppe::Responder.new(statuses: 200, accepts: 'application/json')
    json_error_responder = Steppe::Responder.new(statuses: (400...500), accepts: 'application/json')
    html_responder = Steppe::Responder.new(statuses: 200, accepts: 'text/html')
    application_responder = Steppe::Responder.new(statuses: 200, accepts: 'application/*')
    fallback_responder = Steppe::Responder.new(statuses: (200...600), accepts: '*/*')

    registry << json_responder
    registry << json_error_responder
    registry << html_responder
    registry << application_responder
    registry << fallback_responder

    # Exact matches
    expect(registry.resolve(200, 'application/json')).to eq(json_responder)
    expect(registry.resolve(422, 'application/json')).to eq(json_error_responder)
    expect(registry.resolve(200, 'text/html')).to eq(html_responder)

    # Client wildcards should match concrete server types
    expect(registry.resolve(200, 'text/*')).to eq(html_responder)
    expect(registry.resolve(200, 'application/*')).to eq(json_responder)  # or application_responder, depending on registration order/specificity
    expect(registry.resolve(200, '*/*')).to eq(json_responder)  # Should match first registered or most specific

    # Unknown types fall back to */* responder
    expect(registry.resolve(200, 'foo/bar')).to eq(fallback_responder)

    # Quality factor: text/html (q=1.0 default) wins over application/json (q=0.9)
    expect(registry.resolve(200, 'application/json; q=0.9, text/html')).to eq(html_responder)

    # Quality factor: application/json (q=1.0 default) wins over text/html (q=0.5)
    expect(registry.resolve(200, 'application/json, text/html; q=0.5')).to eq(json_responder)

    # Multiple matches, highest quality wins
    expect(registry.resolve(200, 'text/html; q=0.9, application/json; q=0.8')).to eq(html_responder)

    # #each
    responders = registry.each.to_a
    expect(responders).to include(json_responder, json_error_responder, html_responder, application_responder, fallback_responder)
  end
end
