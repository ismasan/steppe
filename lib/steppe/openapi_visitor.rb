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
        'paths' => node.endpoints.reduce({}) { |memo, e| visit(e, memo) }
      )
    end

    on(:server) do |node, _props|
      { 'url' => node.url.to_s, 'description' => node.description }
    end

    on(:endpoint) do |node, paths|
      path_template = node.path.to_templates.first
      path = paths[path_template] || {}
      verb = path[node.verb.to_s] || {}
      verb = verb.merge(
        'summary' => node.rel_name.to_s,
        # operationId can be used for links
        # https://swagger.io/docs/specification/links/
        'operationId' => node.rel_name.to_s,
        'description' => node.description,
        'parameters' => visit_parameters(node.query_schema),
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

    PARAMETERS_IN = %i[query path].freeze

    def visit_parameters(schema)
      specs = schema._schema.each.with_object({}) do |(name, type), h|
        h[name.to_s] = type if PARAMETERS_IN.include?(type.metadata[:in])
      end
      specs.map do |name, type|
        spec = visit(type)
        # Here we should recursively visit the type
        # to extract metadata, etc.
        meta = type.metadata.reduce({}) { |m, (k, v)| m.merge(k.to_s => v.to_s.downcase) }

        {
          'name' => name,
          'in' => meta['in'],
          'description' => meta['description'],
          'required' => (meta['in'] == 'path'),
          'schema' => spec.except('in')
        }
      end
    end

    def visit_request_body(schemas)
      return {} if schemas.empty?

      content = schemas.each.with_object({}) do |(content_type, schema), h|
        h[content_type] = { 'schema' => visit(schema) }
      end

      { 'required' => true, 'content' => content }
    end
  end
end
