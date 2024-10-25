# frozen_string_literal: true

module Mongoid
  module Slug
    class Criteria < Mongoid::Criteria
      # Find the matching document(s) in the criteria for the provided ids or slugs.
      #
      # If the document _ids are of the type BSON::ObjectId, and all the supplied parameters are
      # convertible to BSON::ObjectId (via BSON::ObjectId#from_string), finding will be
      # performed via _ids.
      #
      # If the document has any other type of _id field, and all the supplied parameters are of the same
      # type, finding will be performed via _ids.
      #
      # Otherwise finding will be performed via slugs.
      #
      # @example Find by an id.
      #   criteria.find(BSON::ObjectId.new)
      #
      # @example Find by multiple ids.
      #   criteria.find([ BSON::ObjectId.new, BSON::ObjectId.new ])
      #
      # @example Find by a slug.
      #   criteria.find('some-slug')
      #
      # @example Find by multiple slugs.
      #   criteria.find([ 'some-slug', 'some-other-slug' ])
      #
      # @param [ Array<Object> ] args The ids or slugs to search for.
      #
      # @return [ Array<Document>, Document ] The matching document(s).
      def find(*args)
        look_like_slugs?(prepare_ids_for_find(args)) ? find_by_slug!(*args) : super
      end

      # Find the matchind document(s) in the criteria for the provided slugs.
      #
      # @example Find by a slug.
      #   criteria.find('some-slug')
      #
      # @example Find by multiple slugs.
      #   criteria.find([ 'some-slug', 'some-other-slug' ])
      #
      # @param [ Array<Object> ] args The slugs to search for.
      #
      # @return [ Array<Document>, Document ] The matching document(s).
      def find_by_slug!(*args)
        slugs = prepare_ids_for_find(args)
        raise_invalid if slugs.any?(&:nil?)
        for_slugs(slugs).execute_or_raise_for_slugs(slugs, multi_args?(args))
      end

      def look_like_slugs?(args)
        return false unless args.all? { |id| id.is_a?(String) }

        id_field = @klass.fields['_id']
        @slug_strategy ||= id_field.options[:slug_id_strategy] || build_slug_strategy(id_field.type)
        args.none? { |id| @slug_strategy.call(id) }
      end

      protected

      # unless a :slug_id_strategy option is defined on the id field,
      # use object_id or string strategy depending on the id_type
      # otherwise default for all other id_types
      def build_slug_strategy(id_type)
        type_method = "#{id_type.to_s.downcase.split('::').last}_slug_strategy"
        respond_to?(type_method, true) ? method(type_method) : ->(_id) { false }
      end

      # a string will not look like a slug if it looks like a legal BSON::ObjectId
      def objectid_slug_strategy(id)
        BSON::ObjectId.legal?(id)
      end

      # a string will always look like a slug
      def string_slug_strategy(_id)
        true
      end

      def for_slugs(slugs)
        # _translations
        localized = (begin
          @klass.fields['_slugs'].options[:localize]
        rescue StandardError
          false
        end)
        if localized
          def_loc = I18n.default_locale
          query = { '$in' => slugs }
          where({ '$or' => [{ _slugs: query }, { "_slugs.#{def_loc}" => query }] }).limit(slugs.length)
        else
          where(_slugs: { '$in' => slugs }).limit(slugs.length)
        end
      end

      def execute_or_raise_for_slugs(slugs, multi)
        result = uniq
        check_for_missing_documents_for_slugs!(result, slugs)
        multi ? result : result.first
      end

      def check_for_missing_documents_for_slugs!(result, slugs)
        missing_slugs = slugs - result.map(&:slugs).flatten
        return unless !missing_slugs.blank? && Mongoid.raise_not_found_error

        raise Errors::DocumentNotFound.new(klass, slugs, missing_slugs)
      end

      private 

      # Convert args to the +#find+ method into a flat array of ids.
      # 
      # https://jira.mongodb.com/browse/MONGOID-5660
      # https://github.com/mongodb/mongoid/pull/5706
      #
      # @example Get the ids.
      #   prepare_ids_for_find([ 1, [ 2, 3 ] ])
      #
      # @param [ Array<Object> ] args The arguments.
      #
      # @return [ Array ] The array of ids.
      def prepare_ids_for_find(args)
        args.flat_map do |arg|
          case arg
          when Array, Set
            prepare_ids_for_find(arg)
          when Range
            arg.begin&.numeric? && arg.end&.numeric? ? arg.to_a : arg
          else
            arg
          end
        end.uniq(&:to_s)
      end


      # Indicates whether the given arguments array is a list of values.
      # Used by the +find+ method to determine whether to return an array
      # or single value.
      # 
      # https://jira.mongodb.com/browse/MONGOID-5669
      # https://github.com/mongodb/mongoid/pull/5702/commits
      #
      # @example Are these arguments a list of values?
      #   multi_args?([ 1, 2, 3 ]) #=> true
      #
      # @param [ Array ] args The arguments.
      #
      # @return [ true | false ] Whether the arguments are a list.
      def multi_args?(args)
        args.size > 1 || !args.first.is_a?(Hash) && args.first.resizable?
      end

    end
  end
end
