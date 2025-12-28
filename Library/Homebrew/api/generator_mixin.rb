# typed: strict
# frozen_string_literal: true

module Homebrew
  module API
    module GeneratorMixin
      extend T::Helpers

      requires_ancestor { Kernel }

      PackageHash = T.type_alias { T::Hash[String, T.untyped] }

      module ClassMethods
        extend T::Helpers

        requires_ancestor { T.class_of(T::Struct) }

        BOTTLE_TAG_PLACEHOLDER = "@@BOTTLE_TAG_PLACEHOLDER@@"

        FromHashBlock = T.type_alias { T.proc.params(hash: PackageHash).returns(T.untyped) }

        class Property < T::Struct
          const :key, String
          const :type, T.anything
          const :hash_as, T.nilable(ClassMethods)
          const :default, T.anything
          const :from, T.nilable(T::Array[String])
          const :block, T.nilable(FromHashBlock)
        end

        sig { returns(T::Array[Property]) }
        ##
        # Retrieve the class's array of property descriptors, initializing it to an empty array if none exists.
        # @return [Array<Homebrew::API::GeneratorMixin::ClassMethods::Property>] The array of property descriptors stored in `@properties`.
        def properties
          instance_variable_get(:@properties) || instance_variable_set(:@properties, [])
        end

        sig { returns(String) }
        ##
        # Returns the placeholder token used in `from` paths to mark where a bottle tag should be substituted.
        # @return [String] The placeholder string `"@@BOTTLE_TAG_PLACEHOLDER@@"`.
        def bottle_tag
          BOTTLE_TAG_PLACEHOLDER
        end

        sig {
          params(
            key:     Symbol,
            type:    T.anything,
            hash_as: T.nilable(ClassMethods),
            default: T.anything,
            from:    T.nilable(T.any(String, T::Array[String])),
            block:   T.nilable(FromHashBlock),
          ).void
        }
        ##
        # Declares a property for the generated API object with metadata used by from_hash and serialization.
        # @param [String, Symbol] key - The property name used as the output key and constant name.
        # @param [Class, Module, nil] type - The Ruby type for the property value; mutually exclusive with `hash_as`.
        # @param [Class, nil] hash_as - A nested generator class (mixing in ClassMethods) to convert a sub-hash into a typed value; mutually exclusive with `type`.
        # @param [Object, nil] default - A default value for the property; if provided a constant with this default is defined on the class.
        # @param [String, Array<String>, nil] from - One or more keys (or key path segments) to extract the value from an input hash; may be omitted to use the property key.
        # @yield [hash] Optional block that receives the source hash and returns the extracted value for this property; mutually exclusive with `from`.
        # @raise [ArgumentError] If both `from` and a block are provided.
        # @raise [ArgumentError] If neither or both of `type` and `hash_as` are specified.
        def elem(key, type = nil, hash_as: nil, default: nil, from: nil, &block)
          raise ArgumentError, "Cannot specify both from: and a block for property #{key}" if from && block
          if [type, hash_as].compact.size != 1
            raise ArgumentError, "Must specify either a type or hash_as: for property #{key}"
          end

          type ||= hash_as
          from = Array(from) if from
          properties << Property.new(key: key.to_s, type:, hash_as:, default:, from:, block:)
          if default
            const key, type, default: default
          else
            const key, T.nilable(T.unsafe(type))
          end
        end

        sig { params(hash: PackageHash, bottle_tag: Utils::Bottles::Tag).returns(T.self_type) }
        ##
        # Build an instance of the including class from a nested hash, applying property mappings and bottle tag substitution.
        # Processes each declared property, extracting its source value from `hash`, substituting `bottle_tag` where the placeholder appears, and delegating to a property's `hash_as.from_hash` when present to construct nested objects.
        # @param [Hash] hash - The input hash to transform into an instance.
        # @param [Object] bottle_tag - Value to substitute for the internal bottle tag placeholder when encountered in property paths.
        # @return [Object] A new instance of the including class populated from the transformed hash.
        def from_hash(hash, bottle_tag:)
          transformed_hash = properties.to_h do |property|
            source = if (block = property.block)
              block.call(hash)
            else
              from = property.from || [property.key]
              from.reduce(hash) do |h, key|
                key = bottle_tag.to_s if key == BOTTLE_TAG_PLACEHOLDER
                h[key] if h
              end
            end

            if source && (hash_class = property.hash_as)
              [property.key, hash_class.from_hash(source, bottle_tag:)]
            else
              [property.key, source]
            end
          end

          T.unsafe(self).new(**transformed_hash.compact_blank.transform_keys(&:to_sym))
        end
      end

      mixes_in_class_methods ClassMethods

      sig { returns(T::Hash[String, T.untyped]) }
      ##
      # Builds a hash representation of the object's declared properties.
      # Values equal to a property's default or to `0` are omitted; values that respond to `to_h` via GeneratorMixin are converted to hashes.
      # Blank values are removed from the result.
      # @return [Hash] A hash with string keys for each included property and corresponding values (nested GeneratorMixin instances converted to hashes).
      def to_h
        self.class.properties.to_h do |property|
          value = case (value = send(property.key.to_sym))
          when property.default || 0
            nil
          when GeneratorMixin
            value.to_h
          else
            # Other blank values are filtered out by compact_blank
            value
          end

          [property.key, value]
        end.to_h.compact_blank
      end

      sig { params(args: T.untyped).returns(String) }
      # @return [String] The JSON string representation of the object.
      def to_json(*args)
        to_h.to_json(*args)
      end
    end
  end
end