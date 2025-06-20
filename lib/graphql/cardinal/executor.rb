# frozen_string_literal: true

require_relative "./executor/execution_scope"
require_relative "./executor/execution_field"
require_relative "./executor/authorization"
require_relative "./executor/hot_paths"
require_relative "./executor/response_hash"
require_relative "./executor/error_formatting"

module GraphQL
  module Cardinal
    class Executor
      include HotPaths
      include ErrorFormatting

      TYPENAME_FIELD = "__typename"
      TYPENAME_FIELD_RESOLVER = TypenameResolver.new

      attr_reader :exec_count

      def initialize(schema, resolvers, document, root_object, variables: {}, context: {}, tracers: [])
        @query = GraphQL::Query.new(schema, document: document) # << for schema reference
        @resolvers = resolvers
        @document = document
        @root_object = root_object
        @tracers = tracers
        @variables = variables
        @context = context
        @data = {}
        @errors = []
        @path = []
        @exec_queue = []
        @exec_count = 0
        @context[:query] = @query
      end

      def perform
        operation = @query.selected_operation

        root_scopes = case operation.operation_type
        when "query"
          # query fields can run in parallel
          [
            ExecutionScope.new(
              parent_type: @query.root_type_for_operation(operation.operation_type),
              selections: operation.selections,
              sources: [@root_object],
              responses: [@data],
            )
          ]
        when "mutation"
          # each mutation field must run serially as its own scope
          mutation_type = @query.root_type_for_operation(operation.operation_type)
          execution_fields_by_key(mutation_type, operation.selections).each_value.map do |exec_field|
            ExecutionScope.new(
              parent_type: mutation_type,
              selections: exec_field.nodes,
              sources: [@root_object],
              responses: [@data],
            )
          end
        else
          raise DocumentError.new("Unsupported operation type: #{operation.operation_type}")
        end

        root_scopes.each do |scope|
          @exec_queue << scope
          # execute until no more scopes (without using recursion)...
          execute_scope(@exec_queue.shift) until @exec_queue.empty?
        end

        response = { "data" => @errors.empty? ? @data : format_inline_errors(@data, @errors) }
        response["errors"] = @errors.map(&:to_h) unless @errors.empty?
        response
      end

      private

      def execute_scope(exec_scope)
        unless exec_scope.fields
          lazy_field_keys = []
          exec_scope.fields = execution_fields_by_key(exec_scope.parent_type, exec_scope.selections)
          exec_scope.fields.each_value do |exec_field|
            @path.push(exec_field.key)
            parent_type = exec_scope.parent_type
            parent_sources = exec_scope.sources
            field_name = exec_field.name

            exec_field.type = @query.get_field(parent_type, field_name).type
            value_type = exec_field.type.unwrap

            field_resolver = @resolvers.dig(parent_type.graphql_name, field_name)
            unless field_resolver
              if field_name == TYPENAME_FIELD
                field_resolver = TYPENAME_FIELD_RESOLVER
              else
                raise NotImplementedError, "No field resolver for `#{parent_type.graphql_name}.#{field_name}`"
              end
            end

            resolved_sources = if !field_resolver.authorized?(@context)
              @errors << AuthorizationError.new(type_name: parent_type.graphql_name, field_name: field_name, path: @path.dup, base: true)
              Array.new(parent_sources.length, @errors.last)
            elsif !Authorization.can_access_type?(value_type, @context)
              @errors << AuthorizationError.new(type_name: value_type.graphql_name, path: @path.dup, base: true)
              Array.new(parent_sources.length, @errors.last)
            else
              begin
                @tracers.each { _1.before_resolve_field(parent_type, field_name, parent_sources.length, @context) }
                field_resolver.resolve(parent_sources, exec_field.arguments(@variables), @context, exec_scope)
              rescue StandardError => e
                report_exception(error: e)
                @errors << InternalError.new(path: @path.dup, base: true)
                Array.new(parent_sources.length, @errors.last)
              ensure
                @tracers.each { _1.after_resolve_field(parent_type, field_name, parent_sources.length, @context) }
                @exec_count += 1
              end
            end

            if resolved_sources.is_a?(Promise)
              exec_field.promise = resolved_sources
              lazy_field_keys << exec_field.key
            else
              resolve_execution_field(exec_scope, exec_field, resolved_sources, lazy_field_keys)
              lazy_field_keys.clear
            end

            @path.pop
          end
        end

        if exec_scope.lazy_fields_pending?
          if exec_scope.lazy_fields_ready?
            exec_scope.method(:lazy_exec!).call # << noop for loaders that have already run
            exec_scope.fields.each_value do |exec_field|
              next unless exec_field.promise

              @path.push(exec_field.key)
              resolve_execution_field(exec_scope, exec_field, exec_field.promise.value)
              @path.pop
            end
          else
            # requeue the scope to wait on others that haven't built fields yet
            @exec_queue << exec_scope
          end
        end

        nil
      end

      def resolve_execution_field(exec_scope, exec_field, resolved_sources, lazy_field_keys = nil)
        parent_sources = exec_scope.sources
        parent_responses = exec_scope.responses
        field_key = exec_field.key
        field_name = exec_field.name
        field_type = exec_field.type
        return_type = field_type.unwrap

        if resolved_sources.length != parent_sources.length
          report_exception("Incorrect number of results resolved. Expected #{parent_sources.length}, got #{resolved_sources.length}")
          resolved_sources = Array.new(parent_sources.length, nil)
        end

        if return_type.kind.composite?
          # build results with child selections
          next_sources = []
          next_responses = []
          resolved_sources.each_with_index do |source, i|
            # DANGER: HOT PATH!
            response = parent_responses[i]
            lazy_field_keys.each { |k| response[k] = nil } if lazy_field_keys && !lazy_field_keys.empty?
            response[field_key] = build_composite_response(field_type, source, next_sources, next_responses)
          end

          if return_type.kind.abstract?
            type_resolver = @resolvers.dig(return_type.graphql_name, "__type__")
            unless type_resolver
              raise NotImplementedError, "No type resolver for `#{return_type.graphql_name}`"
            end

            next_sources_by_type = Hash.new { |h, k| h[k] = [] }
            next_responses_by_type = Hash.new { |h, k| h[k] = [] }
            next_sources.each_with_index do |source, i|
              # DANGER: HOT PATH!
              impl_type = type_resolver.call(source, @context)
              next_sources_by_type[impl_type] << (field_name == TYPENAME_FIELD ? impl_type.graphql_name : source)
              next_responses_by_type[impl_type] << next_responses[i].tap { |r| r.typename = impl_type.graphql_name }
            end

            loader_cache = {} # << all scopes in the abstract generation share a loader cache
            loader_group = []
            next_sources_by_type.each do |impl_type, impl_type_sources|
              # check concrete type access only once per resolved type...
              unless Authorization.can_access_type?(impl_type, @context)
                @errors << AuthorizationError.new(type_name: impl_type.graphql_name, path: @path.dup, base: true)
                impl_type_sources = Array.new(impl_type_sources.length, @errors.last)
              end

              loader_group << ExecutionScope.new(
                parent_type: impl_type,
                selections: exec_field.selections,
                sources: impl_type_sources,
                responses: next_responses_by_type[impl_type],
                loader_cache: loader_cache,
                loader_group: loader_group,
                parent: exec_scope,
              )
            end

            @exec_queue.concat(loader_group)
          else
            @exec_queue << ExecutionScope.new(
              parent_type: return_type,
              selections: exec_field.selections,
              sources: next_sources,
              responses: next_responses,
              parent: exec_scope,
            )
          end
        else
          # build leaf results
          resolved_sources.each_with_index do |val, i|
            # DANGER: HOT PATH!
            response = parent_responses[i]
            lazy_field_keys.each { |k| response[k] = nil } if lazy_field_keys && !lazy_field_keys.empty?
            response[field_key] = if val.nil? || val.is_a?(StandardError)
              build_missing_value(field_type, val)
            elsif return_type.kind.scalar?
              coerce_scalar_value(return_type, val)
            elsif return_type.kind.enum?
              coerce_enum_value(return_type, val)
            else
              val
            end
          end
        end
      end

      def execution_fields_by_key(parent_type, selections, map: Hash.new { |h, k| h[k] = ExecutionField.new(k) })
        selections.each do |node|
          next if node_skipped?(node)

          case node
          when GraphQL::Language::Nodes::Field
            map[node.alias || node.name].add_node(node)
          when GraphQL::Language::Nodes::InlineFragment
            fragment_type = node.type ? @query.get_type(node.type.name) : parent_type
            if @query.possible_types(fragment_type).include?(parent_type)
              execution_fields_by_key(parent_type, node.selections, map: map)
            end

          when GraphQL::Language::Nodes::FragmentSpread
            fragment = @query.fragments[node.name]
            fragment_type = @query.get_type(fragment.type.name)
            if @query.possible_types(fragment_type).include?(parent_type)
              execution_fields_by_key(parent_type, node.selections, map: map)
            end

          else
            raise DocumentError.new("Invalid selection node type")
          end
        end
        map
      end

      def node_skipped?(node)
        return false if node.directives.empty?

        node.directives.any? do |directive|
          if directive.name == "skip"
            if_argument?(directive.arguments.first)
          elsif directive.name == "include"
            !if_argument?(directive.arguments.first)
          else
            false
          end
        end
      end

      def if_argument?(bool_arg)
        if bool_arg.value.is_a?(GraphQL::Language::Nodes::VariableIdentifier)
          @variables[bool_arg.value.name] || @variables[bool_arg.value.name.to_sym]
        else
          bool_arg.value
        end
      end

      def report_exception(message = nil, error: nil, path: @path.dup)
        # todo: add real error reporting...
        puts "Error at #{path.join(".")}: #{message || error&.message}"
        puts error.backtrace.join("\n") if error
      end
    end
  end
end
