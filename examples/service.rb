# frozen_string_literal: true

require 'steppe'

class User
  Record = Data.define(:id, :name, :age, :email, :address)

  class << self
    def data
      @data ||= [
        Record.new(1, 'Alice', 30, 'alice@server.com', '123 Great St'),
        Record.new(2, 'Bob', 25, 'bob@server.com', '23 Long Ave.'),
        Record.new(3, 'Bill', 20, 'bill@server.com', "Bill's Mansion")
      ]
    end

    def filter_by_name(name)
      return data unless name

      data.select { |u| u.name.downcase.start_with?(name.downcase) }
    end

    def find(id)
      data.find { |u| u.id == id }
    end

    def update(id, attrs)
      attrs.delete(:id)
      user = find(id)
      return unless user

      idx = data.index(user)
      user = user.with(**attrs)
      data[idx] = user
      user
    end

    def create(attrs)
      rec = Record.new(
        id: data.size + 1, 
        name: attrs[:name], 
        age: attrs[:age],
        email: attrs[:email],
        address: attrs[:address]
      )
      data << rec
      rec
    end
  end
end

module Types
  include Plumb::Types

  UserCategory = String
                 .options(%w[any admin customer guest])
                 .default('any')
                 .desc('search by category')

  DowncaseString = String.invoke(:downcase)
end

class UserSerializer < Steppe::Serializer
  attribute :id, Types::Integer.example(1)
  attribute :name, Types::String.example('Alice')
  attribute :age, Types::Integer.example('34')
  attribute :email, Types::String.example('alice@server.com')
  attribute? :address, String
end

class HashTokenStore
  def initialize(hash)
    @hash = hash
  end

  def set(claims)
    key = SecureRandom.hex
    @hash[key] = claims.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    key
  end

  def get(key)
    @hash[key]
  end
end

class BooticAuth
  attr_reader :scopes, :type, :description, :store

  def initialize(authorization_url:, scopes: [], store: {})
    @scopes = scopes
    @type = :oauth2
    @description = 'Bootic Auth'
    @store = store.is_a?(Hash) ? HashTokenStore.new(store) : store
  end
end

# bootic = BooticAuth.new(scopes: %w[admin god])

Service = Steppe::Service.new do |api|
  api.title = 'Users API'
  api.description = 'API for managing users'
  api.server(
    url: 'http://localhost:9292',
    description: 'prod server'
  )
  api.tag(
    'users',
    description: 'Users operations',
    external_docs: 'https://example.com/docs/users'
  )

  api.specs('/')

  # An endpoint to list users
  api.get :users, '/users' do |e|
    e.description = 'List users'
    e.tags = %w[users]
    # Custom steps, authentication, etc.
    e.step do |conn|
      puts conn.request.env['HTTP_AUTHORIZATION'].inspect
      conn
    end

    # Validate and coerce URL parameters
    e.query_schema(
      q?: Types::DowncaseString.desc('search by name, supports partial matches').example('Bil, Jo'),
      cat?: Types::UserCategory
    )

    # A step with your business logic
    # In this case filtering users by name
    # This step will only run if the params are valid
    e.step do |conn|
      users = User.filter_by_name(conn.params[:q])
      conn.valid users
    end

    e.json do
      attribute :users, [UserSerializer]

      def users
        object
      end
    end

    # Or, use a named serializer class
    # e.json 200, UserListSerializer
    #
    # Or, use #respond for more detailed control
    # e.respond 200...300, :json, UserListSerializer
    #
    # Or, expand into a responder block
    # e.respond 200...300, :json do |r|
    #   r.description = "A list of users"
    #   r.step CustomStep1
    #   r.serializer UserListSerializer
    #   r.step CustomStep1
    # end
    #
    # Or, register named responder
    # e.respond UserListResponder

    # Respond with HTML
    e.html do |conn|
      html5 {
        body {
          h1 'Users'
          ul {
            conn.value.each do |user|
              li {
                text "#{user.id}:"
                a(user.name, href: "/users/#{user.id}")
                text " (#{user.age})"
              }
            end
          }
        }
      }
    end
  end

  UserName = Plumb::Types::String.desc('User name').example('Alice').present
  UserAge = Steppe::Types::Lax::Integer[18..]
  UserEmail = Steppe::Types::Email.desc('User email').example('alice@email.com')
  UserAddress = Steppe::Types::String.desc('User address').example('123 Great St')

  # A Standalone action class
  # with its own schema
  # FIXME: classes with their own payload_schema
  # don't automatically register body parses, nor actually validate the schema
  # because it's up to them to validate the params
  class UpdateUser
    QUERY_SCHEMA = Plumb::Types::Hash[id: Steppe::Types::Lax::Integer]
    SCHEMA = Plumb::Types::Hash[
      name?: UserName,
      age?: UserAge,
      email?: UserEmail,
      address?: UserAddress
    ]

    def self.query_schema = QUERY_SCHEMA
    def self.payload_schema = SCHEMA

    def self.call(conn)
      p conn.params.inspect
      return conn
      user = User.update(conn.params[:id], conn.params)
      return conn.invalid(errors: { id: 'User not found' }) unless user

      conn.valid user
    end
  end

  # Another standalone action 
  # with its own schema
  class ProcessFile
    def self.payload_schema = Plumb::Types::Hash[
      file: Steppe::Types::UploadedFile.where(type: 'text/plain')
    ]

    def self.call(conn)
      # process the uploaded file
      conn
    end
  end

  api.put :update_user, '/users/:id' do |e|
    e.description = 'Update a user'
    e.tags = %w[users]

    e.query_schema(
      id: Steppe::Types::Lax::Integer.desc('User ID')
    )

    # Endpoint will consolidate schemas from steps
    # that respond to .payload_schema
    # e.step UpdateUser
    e.payload_schema(
      name?: UserName,
      age?: UserAge,
      email?: UserEmail,
      address?: UserAddress
    )
    e.step do |conn|
      user = User.update(conn.params[:id], conn.params)
      user ? conn.valid(user) : conn.invalid(errors: { id: 'User not found' })
    end

    e.json 200, UserSerializer

    # e.payload_schema(
    #   name: Steppe::Types::String.present,
    #   age: Steppe::Types::Lax::Integer[18..],
    #   file?: Steppe::Types::UploadedFile.with(type: 'text/plain')
    # )
  end

  api.get :user, '/users/:id' do |e|
    e.description = 'Fetch information for a user, by ID'
    e.tags = %w[users]
    e.query_schema(
      id: Types::Lax::Integer.desc('User ID')
    )
    e.step do |conn|
      user = User.find(conn.params[:id])
      if user
        conn.valid user
      else
        conn.response.status = 404
        conn.invalid(errors: { id: 'User not found' })
      end
    end

    e.json 200...300, UserSerializer

    e.html do |conn|
      html5 {
        body {
          a('users', href: '/users')
          h1 'User'
          dl {
            dt 'ID'
            dd conn.value.id
            dt 'name'
            dd conn.value.name
          }
        }
      }
    end
  end

  api.post :create_user, '/users' do |e|
    e.tags = %w[users]
    e.description = 'Create a user'

    # Validate request BODY payload
    # request body is parsed at this point in the pipeline
    e.payload_schema(
      name: UserName,
      age: UserAge,
      email: UserEmail,
      address?: UserAddress
    )

    # Create a user, only if params above are valid
    e.step do |conn|
      user = User.create(conn.params)
      conn.respond_with(201).valid user
    end

    # Serialize the user (valid case)
    # status 422 (invalid) will be handled by default responder
    e.json 201, UserSerializer

    # Or, register a custom responder for 422
    # e.serialize 422 do
    #   attribute :errors, Types::Hash
    #   private def errors = conn.errors
    # end
  end
end

