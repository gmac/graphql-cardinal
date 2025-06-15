# frozen_string_literal: true

module GraphQL
  module Cardinal
    class BreadthExecutor
      include Scalars

      attr_reader :exec_count

      def initialize(schema, resolvers, document, root_object)
        @schema = schema
        @resolvers = resolvers
        @document = document
        @root_object = root_object
        @data = {}
        @exec_count = 0
        @non_null_violation = false
      end

      def perform
        @query = GraphQL::Query.new(@schema, document: @document) # << for schema reference
        operation = @query.selected_operation
        parent_type = @query.root_type_for_operation(operation.operation_type)
        exec_scope(parent_type, operation.selections, [@root_object], [@data], path: [])
        @non_null_violation ? Cardinal::Shaper.perform(@query, @data) : @data
      end

      private

      def exec_scope(parent_type, selections, sources, responses, path:)
        selections.each do |node|
          case node
          when GraphQL::Language::Nodes::Field
            field = @query.get_field(parent_type, node.name)
            field_type = field.type.unwrap
            field_key = node.alias || node.name
            path.push(field_key)

            resolved_sources = begin
              @resolvers.dig(parent_type.graphql_name, node.name).call(sources)
            rescue StandardError
              # oh shit...
            end

            @exec_count += 1
            raise ExecutionError, "Incorrect results" if resolved_sources.length != sources.length

            if field_type.kind.leaf?
              resolved_sources.each_with_index do |val, i|
                responses[i][field_key] = if val.nil? || val.is_a?(StandardError)
                  @non_null_violation = true if field.type.non_null?
                  # format error if val (error)...
                  nil
                elsif field_type.kind.scalar?
                  coerce_scalar_value(field_type, val)
                else
                  val
                end
              end
            else
              next_sources = []
              next_responses = []
              resolved_sources.each_with_index do |src, i|
                responses[i][field_key] = if val.nil? || val.is_a?(StandardError)
                  @non_null_violation = true if field.type.non_null?
                  # format error if val (error)...
                  nil
                elsif field.type.list?
                  build_list_response(field.type, src, next_sources, next_responses)
                else
                  next_sources << src
                  next_responses << {}
                  next_responses.last
                end
              end

              exec_scope(field_type, node.selections, next_sources, next_responses, path: path)
            end
            path.pop

          when GraphQL::Language::Nodes::InlineFragment
            fragment_type = node.type ? @query.get_type(node.type.name) : parent_type
            exec_scope(fragment_type, node.selections, sources, responses, path: path)

          when GraphQL::Language::Nodes::FragmentSpread
            fragment = @query.fragments[node.name]
            fragment_type = @query.get_type(fragment.type.name)
            exec_scope(fragment_type, node.selections, sources, responses, path: path)

          else
            raise DocumentError.new("selection node type")
          end
        end
      end

      def build_list_response(list_type, sources, next_sources, next_responses)
        list_type = list_type.of_type while list_type.non_null?
        next_type = list_type.of_type

        sources.map do |src|
          if src.nil? || src.is_a?(StandardError)
            @non_null_violation = true if next_type.non_null?
            # format error if val (error)...
            nil
          elsif next_type.list?
            build_list_response(next_type, src, next_sources, next_responses)
          else
            next_sources << src
            next_responses << {}
            next_responses.last
          end
        end
      end
    end
  end
end
