# frozen_string_literal: true

require 'spec_helper'

module TestSerializers
  User = Data.define(:id, :name)
  FullNameUser = Data.define(:id, :first_name, :last_name)

  class UserSerializer < Steppe::Serializer
    attribute :id, Integer
    attribute :name, String
  end

  class UserListSerializer < Steppe::Serializer
    attribute :users, [UserSerializer]

    def users = object
  end

  class CustomNameSerializer < Steppe::Serializer
    attribute :id, Integer
    attribute :name, String

    def name = [object.first_name, object.last_name].join(' ')
  end

  class InheritedCustomNameSerializer < CustomNameSerializer
  end

  class OverriddenCustomNameSerializer < CustomNameSerializer
    def name = object.last_name.upcase
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

  describe 'inheritance preserves custom methods' do
    let(:user) { TestSerializers::FullNameUser.new(1, 'Alice', 'Smith') }
    let(:conn) { Steppe::Result::Continue.new(user, request: nil, response: nil) }

    it 'uses the custom method in the parent class' do
      parsed = JSON.parse(TestSerializers::CustomNameSerializer.render(conn), symbolize_names: true)
      expect(parsed).to eq({ id: 1, name: 'Alice Smith' })
    end

    it 'inherits custom methods in subclasses' do
      parsed = JSON.parse(TestSerializers::InheritedCustomNameSerializer.render(conn), symbolize_names: true)
      expect(parsed).to eq({ id: 1, name: 'Alice Smith' })
    end

    it 'allows subclasses to override with their own custom methods' do
      parsed = JSON.parse(TestSerializers::OverriddenCustomNameSerializer.render(conn), symbolize_names: true)
      expect(parsed).to eq({ id: 1, name: 'SMITH' })
    end
  end
end
