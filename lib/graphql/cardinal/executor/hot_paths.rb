# frozen_string_literal: true

module GraphQL::Cardinal
  class Executor
    module HotPaths
      # DANGER: HOT PATH!
      # Overhead added here scales dramatically...
      def build_composite_response(field_type, source, next_sources, next_responses)
        # if object authorization check implemented, then...
        # unless Authorization.can_access_object?(return_type, source, @context)

        if source.nil? || source.is_a?(ExecutionError)
          build_missing_value(field_type, source)
        elsif field_type.list?
          unless source.is_a?(Array)
            report_exception("Incorrect result for list field. Expected Array, got #{source.class}")
            return build_missing_value(field_type, nil)
          end

          field_type = field_type.of_type while field_type.non_null?

          source.map do |src|
            build_composite_response(field_type.of_type, src, next_sources, next_responses)
          end
        else
          next_sources << source
          next_responses << ResponseHash.new
          next_responses.last
        end
      end

      # DANGER: HOT PATH!
      # Overhead added here scales dramatically...
      def build_missing_value(field_type, val)
        # the provided value should always be nil or an error object

        if field_type.non_null?
          val ||= InvalidNullError.new(path: @path.dup)
        end

        if val
          val.replace_path(@path.dup) unless val.path
          @errors << val unless val.base_error?
        end

        val
      end

      # DANGER: HOT PATH!
      # Overhead added here scales dramatically...
      def coerce_scalar_value(type, value)
        case type.graphql_name
        when "String"
          value.is_a?(String) ? value : value.to_s
        when "ID"
          value.is_a?(String) || value.is_a?(Numeric) ? value : value.to_s
        when "Int"
          value.is_a?(Integer) ? value : Integer(value)
        when "Float"
          value.is_a?(Float) ? value : Float(value)
        when "Boolean"
          value == TrueClass || value == FalseClass ? value : !!value
        else
          value
        end
      end

      # DANGER: HOT PATH!
      # Overhead added here scales dramatically...
      def coerce_enum_value(type, value)
        value
      end
    end
  end
end
