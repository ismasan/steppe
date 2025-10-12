# frozen_string_literal: true

module Steppe
  class OpenAPIVisitor < Plumb::JSONSchemaVisitor
    ENVELOPE = {
      'openapi' => '3.0.0'
    }.freeze

    def self.call(node, root: true)
      data = new.visit(node)
      return data unless root

      ENVELOPE.merge(data)
    end

    def self.from_request(service, request)
      data = call(service)
      url = request.base_url.to_s
      return data if data['servers'].any? { |s| s['url'] == url }

      data['servers'] << { 'url' => url, 'description' => 'Current server' }
      data
    end

    on(:service) do |node, props|
      props.merge(
        'info' => {
          'title' => node.title,
          'description' => node.description,
          'version' => node.version
        },
        'servers' => node.servers.map { |s| visit(s) },
        'tags' => node.tags.map { |s| visit(s) },
        'paths' => node.endpoints.reduce({}) { |memo, e| visit(e, memo) },
        'components' => { 'securitySchemes' => visit_security_schemes(node.security_schemes) }
      )
    end

    on(:server) do |node, _props|
      { 'url' => node.url.to_s, 'description' => node.description }
    end

    on(:tag) do |node, _props|
      prop = { 'name' => node.name, 'description' => node.description }
      prop['externalDocs'] = { 'url' => node.external_docs.to_s } if node.external_docs
      prop
    end

    on(:endpoint) do |node, paths|
      return paths unless node.specced?

      path_template = node.path.to_templates.first
      path = paths[path_template] || {}
      verb = path[node.verb.to_s] || {}
      verb = verb.merge(
        'summary' => node.rel_name.to_s,
        # operationId can be used for links
        # https://swagger.io/docs/specification/links/
        'operationId' => node.rel_name.to_s,
        'description' => node.description,
        'tags' => node.tags,
        'security' => visit_endpoint_security(node.registered_security_schemes),
        'parameters' => visit_parameters(node.query_schema, node.header_schema),
        'requestBody' => visit_request_body(node.payload_schemas),
        'responses' => visit(node.responders)
      )
      path = path.merge(node.verb.to_s => verb)
      paths.merge(path_template => path)
    end

    on(:responders) do |responders, _props|
      responders.reduce({}) { |memo, r| visit(r, memo) }
    end

    on(:responder) do |responder, props|
      # Naive implementation
      # of OpenAPI responses status ranges
      # https://swagger.io/docs/specification/describing-responses/
      # TODO: OpenAPI only allows 1XX, 2XX, 3XX, 4XX, 5XX
      status = responder.statuses.size == 1 ? responder.statuses.first.to_s : "#{responder.statuses.first.to_s[0]}XX"
      status_prop = props[status]
      return props if status_prop
      return props unless responder.content_type.subtype == 'json'

      status_prop = {}
      content = status_prop['content'] || {}
      content = content.merge(
        responder.accepts.to_s => {
          'schema' => visit(responder.serializer)
        }
      )
      status_prop = status_prop.merge(
        'description' => responder.description,
        'content' => content
      )
      props.merge(status => status_prop)
    end

    on(:uploaded_file) do |_node, props|
      props.merge('type' => 'string', 'format' => 'byte')
    end

    PARAMETERS_IN = %i[query path].freeze

    def visit_endpoint_security(schemes)
      schemes.map { |name, scopes| { name => scopes } }
    end

    def visit_parameters(query_schema, header_schema)
      specs = query_schema._schema.each.with_object({}) do |(name, type), h|
        h[name.to_s] = type if PARAMETERS_IN.include?(type.metadata[:in])
      end
      params = specs.map do |name, type|
        spec = visit(type)

        ins = spec.delete('in')&.to_s

        {
          'name' => name,
          'in' => ins,
          'description' => spec.delete('description'),
          'example' => spec.delete('example'),
          'required' => (ins == 'path'),
          'schema' => spec.except('in', 'desc', 'options')
        }.compact
      end

      header_schema._schema.each.with_object(params) do |(key, type), list|
        spec = visit(type)
        list << { 
          'name' => key.to_s, 
          'in' => 'header', 
          'description' => spec.delete('description'),
          'example' => spec.delete('example'),
          'required' => !key.optional?,
          'schema' => spec.except('in', 'desc', 'options')
        }.compact
      end
    end

    def visit_request_body(schemas)
      return {} if schemas.empty?

      content = schemas.each.with_object({}) do |(content_type, schema), h|
        h[content_type] = { 'schema' => visit(schema) }
      end

      { 'required' => true, 'content' => content }
    end

    def visit_security_schemes(schemes)
      schemes.transform_values(&:to_openapi)
    end
  end
end
