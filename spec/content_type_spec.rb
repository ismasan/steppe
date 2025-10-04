# frozen_string_literal: true

require 'spec_helper'
require 'steppe/content_type'

RSpec.describe Steppe::ContentType do
  describe '.parse' do
    it 'parses string into a ContentType struct' do
      ct = described_class.parse('application/json; version=1.0')
      expect(ct.type).to eq('application')
      expect(ct.subtype).to eq('json')
      expect(ct.params).to eq('version' => '1.0')
      expect(ct.quality).to eq(1.0)
      expect(ct.to_s).to eq('application/json; version=1.0')
    end

    it 'parses quality factor, if available' do
      ct = described_class.parse('application/json; version=1.0; q=0.5')
      expect(ct.quality).to eq(0.5)
    end

    it 'builds from type symbol' do
      ct = described_class.parse(:json)
      expect(ct.type).to eq('application')
      expect(ct.subtype).to eq('json')

      ct = described_class.parse(:html)
      expect(ct.type).to eq('text')
      expect(ct.subtype).to eq('html')
    end

    specify '#==' do
      ct1 = described_class.parse('application/json; version=1.0')
      ct2 = described_class.parse('application/json; version=1.0')
      ct3 = described_class.parse('application/json; version=2.0')

      expect(ct1).to eq(ct2)
      expect(ct1).not_to eq(ct3)
    end
  end

  describe '.parse_accept' do
    it 'parses Accept header into an array of ContentType structs, sorted by quality factor' do
      header = 'text/html;q=0.7, application/xhtml+xml, application/xml;q=0.9, */*;q=0.6'
      list = described_class.parse_accept(header)
      expect(list.map(&:to_s)).to eq(['application/xhtml+xml', 'application/xml; q=0.9', 'text/html; q=0.7', '*/*; q=0.6'])
    end
  end
end
