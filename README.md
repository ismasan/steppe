# Steppe - Composable, self-documenting REST APIs for Ruby

Steppe is a Ruby gem that provides a DSL for building REST APIs with an emphasis on:

* Composability - Built on composable pipelines, allowing endpoints to be assembled from reusable, testable validation and processing
steps
* Type Safety & Validation - Define input schemas for query parameters and request bodies, ensuring data is
validated and coerced before reaching business logic
* Expandable API - start with a terse DSL for defining endpoints, and extend with custom steps as needed.
* Self-Documentation - Automatically generates OpenAPI specifications from endpoint definitions, keeping documentation in sync with
implementation
* Content Negotiation - Handles multiple response formats through a Responder system that matches status codes and content types
* Mountable on Rack routers, and (soon) standalone with its own router.

## Usage

### Defining a service

A Service is a container for API endpoints with metadata:

```ruby
require 'steppe'

Service = Steppe::Service.new do |api|
  api.title = 'Users API'
  api.description = 'API for managing users'
  api.server(
    url: 'http://localhost:4567',
    description: 'Production server'
  )
  api.tag('users', description: 'User management operations')

  # Define endpoints here...
end
```

### Defining endpoints

Endpoints define HTTP routes with validation, processing steps, and response serialization:

```ruby
# GET endpoint with query parameter validation
api.get :users, '/users' do |e|
  e.description = 'List users'
  e.tags = %w[users]

  # Validate query parameters
  e.query_schema(
    q?: Types::String.desc('Search by name'),
    limit?: Types::Lax::Integer.default(10).desc('Number of results')
  )

  # Business logic step
  e.step do |conn|
    users = User.filter_by_name(conn.params[:q])
                .limit(conn.params[:limit])
    conn.valid users
  end

  # JSON response serialization
  e.json do
    attribute :users, [UserSerializer]

    def users
      object
    end
  end
end
```

### Query schemas

Use `#query_schema` to register steps to coerce and validate URL path and query parameters.

```ruby
api.get :list_users, '/users' do |e|
  e.description = 'List and filter users'
  # URL path and query parameters will be passed through this schema
  # You can annotate fields with .desc() and .example() to supplement
  # the generated OpenAPI specs
  e.query_schema(
    q?: Types::String.desc('full text search').example('bo, media'),
    status?: Types::String.desc('status filter').options(%w[active inactive])
  )
  
  # coerced and validated parameters are now
  # available in conn.params
  e.step do |conn|
    users = User
    users = users.search(conn.params[:q]) if conn.params[:q]
    users = users.by_status(conn.params[:status]) if conn.params[:status]
    conn.valid users
  end
end

# GET /users?status=active&q=bob
```

#### Path parameters

URL path parameters are automatically extracted and merged into a default query schema:

```ruby
# the presence of path tokens in path, such as :id
# will automatically register #query_schema(id: Types::String)
api.get :user, '/users/:id' do |e|
  e.description = 'Fetch a user by ID'
  e.step do |conn|
    # conn.params[:id] is a string
    user = User.find(conn.params[:id])
    user ? conn.valid(user) : conn.invalid(errors: { id: 'Not found' })
  end

  e.json 200...300, UserSerializer
end
```

You can extend the implicit query schema to add or update individual fields

```ruby
# Override the implicit :id field 
# to coerce it to an integer
e.query_schema(
  id: Types::Lax::Integer  
)

e.step do |conn|
  # conn.params[:id] is an Integer
  conn.valid conn.params[:id] * 10
end
```

Multiple calls to `#query_schema` will aggregate into a single `Endpoint#query_schema`

```ruby
UsersAPI[:user].query_schema # => Plumb::Types::Hash
```

### Payload schemas

Use `payload_schema` to validate request bodies:

```ruby
api.post :create_user, '/users' do |e|
  e.description = 'Create a user'
  e.tags = %w[users]

  # Validate request body
  e.payload_schema(
    user: {
      name: Types::String.desc('User name').example('Alice'),
      email: Types::Email.desc('User email').example('alice@example.com'),
      age: Types::Lax::Integer.desc('User age').example(30)
    }
  )

  # Create user (only runs if payload is valid)
  e.step do |conn|
    user = User.create(conn.params[:user])
    conn.respond_with(201).valid user
  end

  # Serialize response
  e.json 201, UserSerializer
end
```

### It's pipelines steps all the way down

Query and payload schemas are themselves steps in the processing pipeline, so you can insert steps before or after each of them.

```ruby
# Coerce and validate query parameters
e.query_schema(
  id: Types::Lax::Integer.present  
)

# Use (validated, coerced) ID to locate resource
# and do some custom authorization
e.step do |conn|
  user = User.find(conn.params[:id])
  if user.can_update_account?
    conn.continue user
  else
    conn.respond_with(401).halt
  end
end

# Only NOW parse and validate request body
e.payload_schema(
  name: Types::String.present.desc('Account name'),
  email: Types::Email.presen.desc('Account email')
)
```

A "step" is an `#call(Steppe::Result) => Steppe::Result` interface. You can use procs, or you can use your own objects.

```ruby
class FindAndAuthorizeUser
  def self.call(conn)
    user = User.find(conn.params[:id])
    return conn.respond_with(401).halt unless user.can_update_account?
    
    conn.continue(user)
  end
end

# In your endpoint
e.step FindAndAuthorizeUser
```

It's up to you how/if your custom steps manage their own state (ie. classes vs. instances). You can use instances for configuration, for example.

```ruby
# Works as long as the instance responds to #call(Result) => Result
e.step MyCustomAuthorizer.new(role: 'admin')
```

#### Halting the pipeline

A step that returns a `Continue` result passes the result on to the next step.

```ruby
e.step do |conn|
  conn.continue('hello')
end
```

A step that returns a `Halt` result signals the pipeline to stop processing.

```ruby
# This step halts the pipeline
e.step do |conn|
  conn.halt
  # Or
  # conn.invalid(errors: {name: 'is invalid'})
end

# This step will never run
e.step do |conn|
  # etc
end
```

#### Steps with schemas

A custom step that also supports `#query_schema`, `#payload_schema` and `#header_schema` will have those schemas merged into the endpoint's schemas, which can be used to generate OpenAPI documentation.

This is so that you're free to bring your own domain objects that do their own validation.

```ruby
class CreateUser
  def self.payload_schema = Types::Hash[name: String, age: Types::Integer[18..]]
  
  def self.call(conn)
    # Instantiate, manage state, run your domain logic, etc
    conn
  end
end
  
# CreateUser.payload_schema will be merged into the endpoint's own payload_schema
e.step CreateUser

# You can add fields to the payload schema
# The top-level endpoint schema will be the merge of both
e.payload_schema(
  email: Types::Email.present
)
```

### File Uploads

Handle file uploads with the `UploadedFile` type:

```ruby
api.post :upload, '/files' do |e|
  e.payload_schema(
    file: Steppe::Types::UploadedFile.where(type: 'text/plain')
  )

  e.step do |conn|
    file = conn.params[:file]
    # file.tempfile, file.filename, file.type available
    conn.valid(process_file(file))
  end

  e.json 201, FileSerializer
end
```

### Named Serializers

Define reusable serializers:

```ruby
class UserSerializer < Steppe::Serializer
  attribute :id, Types::Integer.example(1)
  attribute :name, Types::String.example('Alice')
  attribute :email, Types::Email.example('alice@example.com')
end

# Use in endpoints
e.json 200, UserSerializer
```

You can also compose serializers together:

```ruby
class UserListSerializer < Steppe::Serializer
  attribute :page, Types::Integer.example(1)
  attribute :users, [UserSerializer]

  def page = conn.params[:page] || 1
  def users = object
end
```

Serializers are based on [Plumb's Data structs](PostSerializer).

### Multiple Response Formats

Support multiple content types:

```ruby
api.get :user, '/users/:id' do |e|
  e.step { |conn| conn.valid(User.find(conn.params[:id])) }

  # JSON response
  e.json 200, UserSerializer

  # HTML response (using Papercraft)
  e.html do |conn|
    html5 {
      body {
        h1 conn.value.name
        p "Email: #{conn.value.email}"
      }
    }
  end
end
```

#### HTML templates

HTML templates rely on [Papercraft](https://papercraft.noteflakes.com). It's possible to register your own templating though.

You can pass inline templates like in the example above, or named constants pointing to HTML components.

```ruby
# Somewhere in your app:
UserTemplate = proc do |conn|
  html5 {
    body {
      h1 conn.value.name
      p "Email: #{conn.value.email}"
    }
  }
end

# In your endpoint
e.html(200..299, UserTemplate)
```

See Papercraft's documentation to learn how to work with [layouts](https://papercraft.noteflakes.com/docs/03-template-composition/02-working-with-layouts), nested [components](https://papercraft.noteflakes.com/docs/03-template-composition/01-component-templates), and more.

### Reusable Action Classes

Encapsulate logic in action classes:

```ruby
class UpdateUser
  # A Plumb::Types::Hash schema to validate
  # input parameters for this class
  # Here we define it once as a constant
  # but it can be dynamic too
  # @see https://ismasan.github.io/plumb/#typeshash
  SCHEMA = Types::Hash[
    name: Types::String.present,
    age: Types::Lax::Integer[18..]
  ]

  # Expose the #payload_schema interface
  # Steppe will merge this schema onto the 
  # Endpoint's #payload_schema, which is automatically
  # documented in OpenAPI format
  # @return [Plumb::Types::Hash]
  def self.payload_schema = SCHEMA

  # The Step interface that makes this class composable into
  # a Steppe::Endpoint's pipeline.
  # @param conn [Steppe::Result::Continue]
  # @return [Steppe::Result::Continue, Steppe::Result::Halt]
  def self.call(conn)
    user = User.update(conn.params[:id], conn.params)
    conn.valid user
  end
end

# Use in endpoint
api.put :update_user, '/users/:id' do |e|
  e.step UpdateUser
  e.json 200, UserSerializer
end
```

### OpenAPI Documentation

Use a service's `#specs` helper to mount a GET route to automatically serve OpenAPI schemas from.

```ruby
MyAPI = Steppe::Service.new do |api|
  api.title = 'Users API'
  api.description = 'API for managing users'
  
  # OpenAPI JSON schemas for this service
  # will be available at GET /schemas (defaults to /)
  api.specs('/schemas')
  
  # Define API endpoints
  api.get :list_users, '/users' do |e|
    # etc
  end
end
```

Or use the `OpenAPIVisitor` directly

```ruby
# Get OpenAPI JSON
openapi_spec = Steppe::OpenAPIVisitor.from_request(MyAPI, rack_request)

# Or generate manually
openapi_spec = Steppe::OpenAPIVisitor.call(MyAPI)
```

<img width="831" height="855" alt="CleanShot 2025-10-06 at 18 04 55" src="https://github.com/user-attachments/assets/fea61225-538b-4653-bdd0-9f8b21c8c389" />
Using the [Swagger UI](https://swagger.io/tools/swagger-ui/) tool to view a Steppe API definition.

### Custom Types

Define custom validation types using [Plumb](https://github.com/ismasan/plumb):

```ruby
module Types
  include Plumb::Types

  UserCategory = String
    .options(%w[admin customer guest])
    .default('guest')
    .desc('User category')

  DowncaseString = String.invoke(:downcase)
end

# Use in schemas
e.query_schema(
  category?: Types::UserCategory
)
```

### Error Handling

Endpoints automatically handle validation errors with 422 responses. Customize error responses:

```ruby
e.json 422 do
  attribute :errors, Types::Hash

  def errors
    object
  end
end
```

### Content negotiation

The `#json` and `#html` Endpoint methods are shortcuts for `Responder` objects that can be tailored to specific combinations of request accepted content types, and response status.

```ruby
# equivalent to e.json(200, UserSerializer)
e.respond 200, :json do |r|
  r.description = "JSON response"
  r.serialize UserSerializer
end
```

Responders switch their serializer type depending on their resulting content type. 

This is a responder that accepts HTML requests, and responds with JSON.

```ruby
e.respond statuses: 200..299, accepts: :html, content_type: :json do |r|
  # Using an inline JSON serializer this time
  r.serialize do
    attribute :name, String
    attribute :age, Integer
  end
end
```

Responders can accept wildcard media types, and an endpoint can define multiple responders, from more to less specific.

```ruby
e.respond 200, :json, UserSerializer
e.respond 200, 'text/*', UserTextSerializer
```

### Header schemas

 `Endpoint#header_schema` is similar to `#query_schema` and `#payload_schema`, and it allows to define schemas to validate and/or coerce request headers.

```ruby
api.get :list_users, '/users' do |e|
  # Coerce some expected request headers
  # This coerces the APIVersion header to a number
  e.header_schema(
    'APIVersion' => Steppe::Types::Lax::Numeric
  )
  
  # Downstream handlers will get a numeric header value
  e.step do |conn|
    Logger.info conn.request.env['APIVersion'] # a number
    conn
  end
end
```

These header schemas are inclusive: they don't remove other headers not included in the schemas.

They also generate OpenAPI docs.

<img width="850" height="595" alt="CleanShot 2025-10-11 at 23 59 05" src="https://github.com/user-attachments/assets/c25e65f7-8733-42d9-a1b6-b93d815e2981" />

#### Header schema order matters

Like most things in Steppe, header schemas are registered as steps in a pipeline, so the order of registration matters.

```ruby
# No header schema coercion yet, the header is a string here.
e.step do |conn|
  Logger.info conn.request.env['APIVersion'] # a STRING
  conn
end

# Register the schema as a step in the endpoint's pipeline
e.header_schema(
    'APIVersion' => Steppe::Types::Lax::Numeric
)

# By the time this new step runs
# the header schema above has coerced the headers
e.step do |conn|
  Logger.info conn.request.env['APIVersion'] # a NUMBER
  conn
end
```

#### Multiple header schemas

Like with `#query_schema` and `#payload_schema`, `#header_schema` can be invoked multiple times, which will register individual validation steps, but it will also merge those schemas into the top-level `Endpoint#header_schema`, which goes into OpenAPI docs.

```ruby
api.get :list_users, '/users' do |e|
  e.header_schema('ApiVersion' => Steppe::Types::Lax::Numeric)
  # some more steps
  e.step SomeHandler
  # add to endpoint's header schema
  e.header_schema('HTTP_AUTHORIZATION' => JWTParser)
  # more steps ...
end

# Endpoint's header_schema includes all fields
UserAPI[:list_users].header_schema
# is a 
Steppe::Types::Hash[
   'ApiVersion' => Steppe::Types::Lax::Numeric,
   'HTTP_AUTHORISATION' => JWTParser
]
```

#### Header schema composition

Custom steps that define their own `#header_schema` will also have their schemas merged into the endpoint's `#header_schema`, and automatically documented in OpenAPI.

```ruby
class ListUsersAction
  HEADER_SCHEMA = Steppe::Types::Hash['ClientVersion' => String]
  
  # responding to this method will cause
  # Steppe to merge this schema into the endpoint's
  def header_schema = HEADER_SCHEMA
  
  # The Step interface to handle requests
  def call(conn)
    Logger.info conn.request.env['ClientVersion']
    # do something
    users = User.page(conn.params[:page])
    conn.valid users
  end
end
```

Note that this also applies to Security Schemes below. For example, the built-in `Steppe::Auth::Bearer` scheme defines a header schema to declare the `Authorization` header.

### Security Schemes (authentication and authorization)

Steppe follows the same design as [OpenAPI security schemes](https://swagger.io/docs/specification/v3_0/authentication/).

A service defines one or more security schemes, which can then be opted-in either by individual endpoints, or for all endpoints at once.

Steppe provides two built-in schemes: **Bearer token** authentication (with scopes) and **Basic** HTTP authentication. More coming later.

```ruby
UsersAPI = Steppe::Service.new do |api|
  api.title = 'Users API'
  api.description = 'API for managing users'
  api.server(
    url: 'http://localhost:9292',
    description: 'local server'
  )

  # Bearer token authentication with scopes
  api.bearer_auth(
    'BearerToken',
    store: {
      'admintoken' => %w[users:read users:write],
      'publictoken' => %w[users:read],
    }
  )

  # Basic HTTP authentication (username/password)
  api.basic_auth(
    'BasicAuth',
    store: {
      'admin' => 'secret123',
      'user' => 'password456'
    }
  )

  # Endpoint definitions here
  api.get :list_users, '/users' do |e|
    # etc
  end

  api.post :create_user, '/users' do |e|
    # etc
  end
end
```

#### 1.a Per-endpoint security

```ruby
  # Each endpoint can opt-in to using registered security schemes
  api.get :list_users, '/users' do |e|
    e.description = 'List users'

    # Bearer auth with scopes
    e.security 'BearerToken', ['users:read']
    # etc
  end

  api.post :create_user, '/users' do |e|
    e.description = 'Create user'

    # Basic auth (no scopes)
    e.security 'BasicAuth'
    # etc
  end
```

A request without the Authorization header responds with 401

```
curl -i http://localhost:9292/users

HTTP/1.1 401 Unauthorized
content-type: application/json
vary: Origin
content-length: 47

{"http":{"status":401},"params":{},"errors":{}}
```

A request with the wrong access token responds with 403

```
curl -i -H "Authorization: Bearer nope" http://localhost:9292/users

HTTP/1.1 401 Unauthorized
content-type: application/json
vary: Origin
content-length: 47

{"http":{"status":401},"params":{},"errors":{}}
```

A response with valid token succeeds

```
curl -i -H "Authorization: Bearer publictoken" http://localhost:9292/users

HTTP/1.1 200 OK
content-type: application/json
vary: Origin
content-length: 262

{"users":[{"id":1,"name":"Alice","age":30,"email":"alice@server.com","address":"123 Great St"},{"id":2,"name":"Bob","age":25,"email":"bob@server.com","address":"23 Long Ave."},{"id":3,"name":"Bill","age":20,"email":"bill@server.com","address":"Bill's Mansion"}]}
```

#### 1.b. Service-level security

Using the `#security` method at the service level registers that scheme for all endpoints defined after that

```ruby
UsersAPI = Steppe::Service.new do |api|
  # etc
  # Define the security scheme
  api.bearer_auth('BearerToken', ...)

  # Now apply the scheme to all endpoints in this service, with the same scopes
  api.security 'BearerToken', ['users:read']

  # all endpoints here enforce a bearer token with scope 'users:read'
  api.get :list_users, '/users'
  api.post :create_user, '/users'
  # etc
end
```

Note that the order of the `security` invocation matters. 
The following example defines an un-authenticated `:root` endpoint, and then protects all further endpoints with the 'BearerToken` scheme.

```ruby
api.get :root, '/' # <= public endpoint

api.security 'BearerToken', ['users:read'] # <= applies to all endpoints after this

api.get :list_users, '/users'
api.post :create_user, '/users'
```

#### Automatic OpenAPI docs

The OpenAPI endpoint mounted via `api.specs('/openapi.json')` will include these security schemas.
This is how that shows in the [SwaggerUI](https://swagger.io/tools/swagger-ui/) tool.

<img width="922" height="812" alt="CleanShot 2025-10-11 at 23 46 02" src="https://github.com/user-attachments/assets/3bdecb81-8248-4437-a78a-c80dd7d44ebd" />

#### Custom bearer token store

A custom token store must implement `#get(token)` which returns an access token object or `nil`. The access token object must implement `#allows?(conn, required_scopes)` to determine if the token grants access.

```ruby
# Custom access token with context-aware authorization
class MyAccessToken
  attr_reader :user_id, :scopes

  def initialize(user_id, scopes)
    @user_id = user_id
    @scopes = scopes
  end

  # @param conn [Steppe::Result] The current connection (access to request, params, etc.)
  # @param required_scopes [Array<String>] Scopes required by the endpoint
  # @return [Boolean] True if access is allowed
  def allows?(conn, required_scopes)
    # Example: check scopes, or use conn for context-aware decisions
    (scopes & required_scopes).any? || conn.request.path.start_with?('/public')
  end
end

# Custom token store
class DatabaseTokenStore
  def get(token)
    record = AccessToken.find_by(token: token)
    return nil unless record

    MyAccessToken.new(record.user_id, record.scopes)
  end
end

api.bearer_auth 'BearerToken', store: DatabaseTokenStore.new
```

The `conn` argument gives your access token access to the full request context, allowing for path-based, parameter-based, or other context-aware authorization decisions.

#### Accessing the access token in downstream steps

On successful authentication, the access token is stored in the request env and can be accessed in downstream steps:

```ruby
api.get :profile, '/profile' do |e|
  e.security 'BearerToken', ['read:profile']

  e.step do |conn|
    access_token = conn.request.env[Steppe::Auth::Bearer::ACCESS_TOKEN_ENV_KEY]
    user = User.find(access_token.user_id)
    conn.valid(user)
  end

  e.json 200, UserSerializer
end
```

#### Custom basic credential stores

See the comments and interfaces in `lib/steppe/auth/basic.rb` to learn how to provide custom credential stores to the Basic auth scheme.

#### Custom security schemes

`Service#bearer_auth` and `#basic_auth` are shortcuts to register built-in security schemes. You can use `Service#security_scheme` to register custom implementations.

```ruby
api.security_scheme MyCustomAuthentication.new(name: 'BulletProof')
```

The custom security scheme is expected to implement the following interface:

```
#name() => String
#handle(Steppe::Result, endpoint_expected_scopes) => Steppe::Result
#to_openapi() => Hash
```

An example:

```ruby
class MyCustomAuthentication
  HEADER_NAME = 'X-API-Key'
  
  attr_reader :name
  
  def initialize(name:)
    @name = name
  end
  
   # @param conn [Steppe::Result::Continue]
   # @param endpoint_scopes [Array<String>] scopes expected by this endpoint (if any)
   # @return [Steppe::Result::Continue, Steppe::Result::Halt]
  def handle(conn, _endpoint_scopes)
     api_token = conn.request.env[HEADER_NAME]
     return conn.respond_with(401).halt if api_token.nil?
     
     return conn.respond_with(403).halt if api_token != 'super-secure-token'
     
     # all good, continue handling the request
     conn
  end
  
  # This data will be included in the OpenAPI specification
  # for this security scheme
  # @see https://swagger.io/docs/specification/v3_0/authentication/
  # @return [Hash]
  def to_openapi
    {
      'type' => 'apiKey',
      'in' => 'header',
      'name' => HEADER_NAME
    }
  end
end
```

Security schemes can optionally implement [#query_schema](#query-schemas), [#payload_schemas](#payload-schemas) and [#header_schema](#header-schemas), which will be merged onto the endpoint's equivalents, and automatically added to OpenAPI documentation.

## MCP (Model Context Protocol) Server

Steppe services can be exposed as [MCP](https://modelcontextprotocol.io/) servers, allowing AI assistants like Claude to discover and call your API endpoints as tools.

### Basic Usage

```ruby
require 'steppe/mcp/handler'

# Create an MCP handler from your service
mcp = Steppe::MCP::Handler.new(MyService)

# Mount as a Rack app
run mcp
```

### Mounting in config.ru

Use `Rack::Builder` to mount the MCP handler alongside your REST API:

```ruby
# config.ru
require 'steppe/mcp/handler'
require_relative 'my_service'

mcp = Steppe::MCP::Handler.new(MyService) do |m|
  m.instructions = 'API for managing users.'
end

# Mount REST API at root, MCP at /mcp
app = Rack::Builder.new do
  map '/mcp' do
    run mcp
  end

  map '/' do
    run MyService.route_with(Hanami::Router.new)
  end
end

run app
```

The MCP endpoint will be available at `http://localhost:9292/mcp`.

The handler implements the [MCP Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports), exposing your Steppe endpoints as MCP tools. Each endpoint becomes a tool with:

- **name**: The endpoint's `rel_name` (e.g., `:list_users` becomes `"list_users"`)
- **description**: The endpoint's description
- **inputSchema**: JSON Schema derived from `query_schema` and `payload_schema`

### Configuration

The handler accepts a block for configuration:

```ruby
mcp = Steppe::MCP::Handler.new(MyService) do |m|
  # Instructions guide the AI on how to use your API
  m.instructions = <<~TEXT
    This API manages users. Use list_users to search for users by name.
    Always use get_user to fetch details before updating a user.
  TEXT

  # Define prompts (reusable message templates)
  m.prompt 'create_user_guide' do |p|
    p.description = 'Guide for creating a new user'
    p.argument :name, required: true, description: 'User name to create'
    p.messages do |args|
      [
        { role: 'user', content: { type: 'text', text: "Create a user named #{args[:name]} with a valid email" } }
      ]
    end
  end
end
```

### Prompts

MCP prompts are reusable message templates that guide AI behavior. They're useful for:

- Providing context-specific instructions
- Few-shot examples (user/assistant message pairs)
- Standardizing common workflows

```ruby
m.prompt 'code_review' do |p|
  p.description = 'Review code for issues'
  p.argument :code, required: true
  p.argument :language, required: false, description: 'Programming language'
  p.messages do |args|
    [
      { role: 'user', content: { type: 'text', text: "Review this #{args[:language]} code:\n#{args[:code]}" } },
      { role: 'assistant', content: { type: 'text', text: "I'll analyze this code for quality issues..." } }
    ]
  end
end
```

### Session Management

By default, the handler is stateless and accepts any session ID. For session validation, provide a session store:

```ruby
class RedisSessionStore
  def initialize(redis)
    @redis = redis
  end

  def create
    id = SecureRandom.uuid
    @redis.set("mcp:session:#{id}", "1", ex: 3600)
    id
  end

  def valid?(id)
    @redis.exists?("mcp:session:#{id}")
  end

  def delete(id)
    @redis.del("mcp:session:#{id}")
  end
end

mcp = Steppe::MCP::Handler.new(MyService, session_store: RedisSessionStore.new(Redis.new))
```

### Authentication Passthrough

HTTP headers from the MCP request are forwarded to endpoint calls. This means your existing authentication works automatically:

```ruby
# Service with bearer auth
MyService = Steppe::Service.new do |api|
  api.bearer_auth 'BearerToken', store: MyTokenStore.new

  api.get :protected, '/protected' do |e|
    e.security 'BearerToken', ['read']
    e.step { |conn| conn.valid({ secret: 'data' }) }
    e.json 200
  end
end

# MCP handler forwards Authorization header
mcp = Steppe::MCP::Handler.new(MyService)
```

When an AI client calls the `protected` tool with an `Authorization` header, it's passed through to the endpoint.

### MCP Protocol Methods

The handler implements these MCP methods:

| Method | Description |
|--------|-------------|
| `initialize` | Handshake, returns server capabilities and session ID |
| `notifications/initialized` | Client acknowledgment (returns 202) |
| `tools/list` | Returns all endpoints as tool definitions |
| `tools/call` | Executes an endpoint with provided arguments |
| `prompts/list` | Returns all defined prompts |
| `prompts/get` | Returns a prompt with generated messages |

### Example: Mounting with Hanami::Router

```ruby
require 'hanami/router'
require 'steppe/mcp/handler'

mcp = Steppe::MCP::Handler.new(MyService) do |m|
  m.instructions = 'Use this API to manage users.'
end

app = Hanami::Router.new do
  # REST API
  scope '/api' do
    MyService.route_with(self)
  end

  # MCP endpoint
  post '/mcp', to: mcp
  delete '/mcp', to: mcp
end

run app
```

## Mount in Rack-compliant routers

`Steppe::Enpoint` instances include a `#to_rack` method that turns them into Rack apps, and they have attributes like `#path` and `#verb` which allows you to mount them onto any Rack-compliant routing library.

### Sinatra

Mount Steppe services in a Sinatra app:

```ruby
require 'sinatra/base'

class App < Sinatra::Base
  MyService.endpoints.each do |endpoint|
    public_send(endpoint.verb, endpoint.path.to_templates.first) do
      resp = endpoint.run(request).response
      resp.finish
    end
  end
end
```

### `Hanami::Router`

The excellent and fast [Hanami::Router]() can be used as a standalone router for Steppe services. Or you can mount them into an existing Hanami app.
Use the `Steppe::Service#route_with` helper to mount all endpoints in a service at once.

```ruby
# hanami_service.ru
# run with
#   bundle exec rackup ./hanami_service.ru
require 'hanami/router'
require 'rack/cors'

app = MyService.route_with(Hanami::Router.new)

# Or mount within a router block
app = Hanami::Router.new do
  scope '/api' do
    MyService.route_with(self)
  end
end

# Allowing all origins
# to make Swagger UI work
use Rack::Cors do
  allow do
    origins '*'
    resource '*', headers: :any, methods: :any
  end
end

run app
```

See `examples/hanami.ru`

## Installation

Install the gem and add to the application's Gemfile by executing:

    $ bundle add steppe

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install steppe


## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ismasan/steppe.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Credits

Created by [Ismael Celis](https://ismaelcelis.com)
