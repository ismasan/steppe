# frozen_string_literal: true

require 'spec_helper'

module TestSerializers
  User = Data.define(:id, :name)

  class UserSerializer < Steppe::Serializer
    attribute :id, Integer
    attribute :name, String
  end

  class UserListSerializer < Steppe::Serializer
    attribute :users, [UserSerializer]

    def users = object
  end
end

RSpec.describe Steppe::Serializer do
  specify do
    users = [TestSerializers::User.new(1, 'Alice'), TestSerializers::User.new(2, 'Bob')]
    conn = Steppe::Result::Continue.new(users, request: nil, response: nil)
    data = TestSerializers::UserListSerializer.render(conn)
    parsed = JSON.parse(data, symbolize_names: true)
    expect(parsed).to eq({ users: [{ id: 1, name: 'Alice' }, { id: 2, name: 'Bob' }] })
  end
end
