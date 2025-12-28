# typed: strict
# frozen_string_literal: true

require "tap"
require "formulary"
require "utils/output"
require "formula"
require "context"
require "api/formula_hash"

module Homebrew
  module API
    class Generator
      include Utils::Output::Mixin

      sig { params(only_core: T::Boolean, only_cask: T::Boolean, only_packages: T::Boolean, dry_run: T::Boolean).void }
      ##
      # Initialize a Generator configured for which API types to produce and whether to perform a dry run.
      # @param [Boolean] only_core - When `true`, suppress cask output (prefer core/formula output).
      # @param [Boolean] only_cask - When `true`, suppress formula output (prefer cask output).
      # @param [Boolean] only_packages - When `true`, generate only the packages API (suppress formula and cask output).
      # @param [Boolean] dry_run - When `true`, do not perform filesystem writes; run in simulation mode.
      def initialize(only_core: false, only_cask: false, only_packages: false, dry_run: false)
        @generate_formula_api = T.let(!only_cask && !only_packages, T::Boolean)
        @generate_cask_api = T.let(!only_core && !only_packages, T::Boolean)
        @generate_packages_api = T.let(!only_core && !only_cask, T::Boolean)
        @dry_run = T.let(dry_run, T::Boolean)
        @first_letter = T.let(nil, T.nilable(String))
      end

      sig { void }
      ##
      # Orchestrates generation of API data for formulas, casks, and packages based on the instance's configuration.
      # Invokes per-type generation routines when their corresponding generation flags are enabled.
      def generate!
        generate_api!(type: :formula) if generate_formula_api?
        generate_api!(type: :cask) if generate_cask_api?
        generate_packages_api! if generate_packages_api?
      end

      private

      sig { returns(T::Boolean) }
      ##
# Whether formula API data should be generated.
# @return [Boolean] `true` if the generator is configured to produce formula API data, `false` otherwise.
def generate_formula_api? = @generate_formula_api

      sig { returns(T::Boolean) }
      ##
# Whether the generator will produce Cask API data.
# @return [Boolean] `true` if the generator will produce Cask API data, `false` otherwise.
def generate_cask_api? = @generate_cask_api

      sig { returns(T::Boolean) }
      ##
# Indicates whether the packages API will be generated.
# @return [Boolean] `true` if the generator is configured to produce packages API, `false` otherwise.
def generate_packages_api? = @generate_packages_api

      sig { returns(T::Boolean) }
      ##
# Indicates whether the generator is performing a dry run.
# @return [Boolean] `true` if the generator is in dry-run mode, `false` otherwise.
def dry_run? = @dry_run

      sig { params(type: Symbol).void }
      ##
      # Generate API data files for the given package type (`:formula` or `:cask`).
      # Writes per-package JSON under `_data/<type>`, API JSON templates under `api/<type>`,
      # HTML redirect pages under `<type>`, tap migrations under `api/<type>_tap_migrations.json`,
      # and a canonical renames JSON at `_data/<type>_canonical.json`. When running in dry-run
      # mode, no files are created.
      # @param [Symbol] type - The package type to generate (`:formula` or `:cask`).
      # @raise [TapUnavailableError] if the corresponding core tap for the given type is not installed.
      def generate_api!(type:)
        ohai "Generating #{type} API data..."

        tap = if type == :formula
          CoreTap.instance
        else
          CoreCaskTap.instance
        end
        raise TapUnavailableError, tap.name unless tap.installed?

        unless dry_run?
          directories = ["_data/#{type}", "api/#{type}", type.to_s]
          directories << "api/cask_source" if type == :cask

          FileUtils.rm_rf "_data/formula_canonical.json" if type == :formula
          FileUtils.rm_rf directories
          FileUtils.mkdir_p directories
        end

        Homebrew.with_no_api_env do
          tap_migrations_json = JSON.dump(tap.tap_migrations)
          File.write("api/#{type}_tap_migrations.json", tap_migrations_json) unless dry_run?

          if type == :formula
            Formulary.enable_factory_cache!
            ::Formula.generating_hash!
          else
            ::Cask::Cask.generating_hash!
          end

          # TODO: double check that this is fine for formulae, since they used -1 before for some reason
          latest_macos = MacOSVersion.new(HOMEBREW_MACOS_NEWEST_SUPPORTED).to_sym
          Homebrew::SimulateSystem.with(os: latest_macos, arch: :arm) do
            all_packages = if type == :formula
              formulae(tap)
            else
              casks(tap)
            end

            return if dry_run?

            all_packages.each do |name, hash|
              json = JSON.pretty_generate(hash)

              # TODO: add cask-source
              File.write("_data/#{type}/#{name.tr("+", "_")}.json", "#{json}\n")
              File.write("api/#{type}/#{name}.json", json_template(type: type))
              File.write("#{type}/#{name}.html", html_template(name, type: type))
            end
          end

          renames = if type == :formula
            tap.formula_renames.merge(tap.alias_table)
          else
            tap.cask_renames
          end

          canonical_json = JSON.pretty_generate(renames)
          File.write("_data/#{type}_canonical.json", "#{canonical_json}\n") unless dry_run?
        end
      end

      sig { void }
      ##
      # Generate internal packages API JSON files for each supported OS/architecture tag.
      #
      # For each supported bottle tag, collects formula and cask data with per-tag variations,
      # merges in core and cask renames, aliases, and tap migration data, and writes the
      # resulting JSON to "api/internal/packages.<bottle_tag>.json".
      #
      # If the generator is in dry-run mode, no files are written.
      def generate_packages_api!
        ohai "Generating packages API data..."

        core_tap = CoreTap.instance
        cask_tap = CoreCaskTap.instance

        OnSystem::VALID_OS_ARCH_TAGS.each do |bottle_tag|
          formulae = formulae(core_tap).transform_values do |hash|
            # FormulaHash.from_hash(hash, bottle_tag:)
            FormulaHash.from_hash(hash, bottle_tag:)
          end

          casks = casks(cask_tap).transform_values do |hash|
            # InternalCaskHash.from_hash(hash, bottle_tag:)
            Homebrew::API.merge_variations(hash, bottle_tag: bottle_tag)
          end

          next if dry_run?

          # TODO: renames and aliases can be inferred from the formula data. They should only be kept in one of these places.
          # TODO: add tap git heads to this top-level data
          packages_hash = {
            formulae:            formulae,
            casks:               casks,
            core_aliases:        core_tap.alias_table,
            core_renames:        core_tap.formula_renames,
            core_tap_migrations: core_tap.tap_migrations,
            cask_renames:        cask_tap.cask_renames,
            cask_tap_migrations: cask_tap.tap_migrations,
          }

          FileUtils.mkdir_p "api/internal"
          File.write("api/internal/packages.#{bottle_tag}.json", JSON.generate(packages_hash))
        end
      end

      sig { params(tap: Tap).returns(T::Hash[String, T.untyped]) }
      ##
      # Collects all formulae from the given tap and returns a mapping from formula name to its serialized hash with variations.
      # If a formula fails to load, an error message is printed and the exception is re-raised.
      # @param [Tap] tap - The tap from which to load formulae.
      # @return [Hash<String, Object>, nil] A hash mapping each formula's canonical name to its serialized representation, or `nil` if unavailable.
      def formulae(tap)
        reset_debugging!
        # @formulae ||= T.let(["act_runner", "black", "dotnet@6", "gcc", "readline", "wownero", "xboard"].to_h do |name|
        # @formulae ||= T.let(T.must(tap.formula_names.slice(0, 2000)).to_h do |name|
        # @formulae ||= T.let(["macpine"].to_h do |name|
        @formulae ||= T.let(tap.formula_names.to_h do |name|
          debug_load!(name, type: :formula)
          formula = Formulary.factory(name)
          [formula.name, formula.to_hash_with_variations]
        rescue
          onoe "Error while generating data for formula '#{name}'."
          raise
        end, T.nilable(T::Hash[String, T.untyped]))
      end

      sig { params(tap: Tap).returns(T::Hash[String, T.untyped]) }
      ##
      # Builds and memoizes a mapping of cask token to its hash representation (including variations) for all casks in the given tap.
      # Resets debug state and loads each cask file; if a cask fails to load, an error message is output and the exception is re-raised.
      # @param [Tap] tap - The tap whose cask files should be loaded.
      # @return [Hash<String, Object>, nil] A hash mapping each cask token to its serialized hash with variations, or `nil` if not available.
      # @raise [StandardError] If loading a cask file fails (the original exception is re-raised after logging).
      def casks(tap)
        reset_debugging!
        # @casks ||= T.let(tap.cask_files.to_h do |path|
        @casks ||= T.let(T.must(tap.cask_files.slice(0, 0)).to_h do |path|
          debug_load!(path.stem, type: :cask)
          cask = ::Cask::CaskLoader.load(path)
          [cask.token, cask.to_hash_with_variations]
        rescue
          onoe "Error while generating data for cask '#{path.stem}'."
          raise
        end, T.nilable(T::Hash[String, T.untyped]))
      end

      sig { params(title: String, type: Symbol).returns(String) }
      ##
      # Builds a page template containing YAML front matter and a content placeholder for a package.
      # @param [String] title - The page title (package name) to include in the front matter.
      # @param [Symbol] type - The layout type, e.g., :formula or :cask; when `:formula`, adds a Linux redirect.
      # @return [String] A string with YAML front matter (including `title`, `layout` and optional `redirect_from`) followed by the `{{ content }}` placeholder.
      def html_template(title, type:)
        redirect_from_string = ("redirect_from: /formula-linux/#{title}\n" if type == :formula)

        <<~EOS
          ---
          title: '#{title}'
          layout: #{type}
          #{redirect_from_string}---
          {{ content }}
        EOS
      end

      sig { params(type: Symbol).returns(String) }
      ##
      # Generate a JSON-layout page template with YAML front matter for the given API type.
      # @param [Symbol, String] type - The API type (e.g., :formula, :cask) used to set the layout name.
      # @return [String] A string containing YAML front matter with `layout: <type>_json` and a `{{ content }}` placeholder.
      def json_template(type:)
        <<~EOS
          ---
          layout: #{type}_json
          ---
          {{ content }}
        EOS
      end

      sig { void }
      ##
      # Resets the cached first-letter state so subsequent debug load messages can be emitted again.
      # Used to force debug_load! to report loading for the next package name's initial letter.
      def reset_debugging!
        @first_letter = nil
      end

      sig { params(name: String, type: Symbol).void }
      ##
      # Prints a single progress message when beginning to load items whose name starts with a new initial letter, but only when verbose mode is enabled.
      # Updates the generator's internal first-letter tracker so the message is emitted at most once per leading letter.
      # @param [String] name - The item name whose first character is used to decide whether to emit the message.
      # @param [Symbol] type - The item type label (for example `:formula` or `:cask`) shown in the message.
      def debug_load!(name, type:)
        return if name[0] == @first_letter
        return unless Context.current.verbose?

        @first_letter = name[0]
        puts "Loading #{type} starting with letter #{@first_letter}"
      end
    end

    module CompactSerializable
      extend T::Helpers

      requires_ancestor { T::Struct }

      sig { params(args: T.untyped).returns(String) }
      ##
      # Produce a compact JSON representation of the object.
      # The object is serialized, nil-valued top-level keys are removed from the resulting hash, and the result is converted to JSON.
      # @param [Array] args - Arguments forwarded to `JSON#to_json`.
      # @return [String] The JSON string.
      def to_json(*args)
        # TODO: this should recursively remove nils from nested hashes/arrays too
        serialize.compact.to_json(*args)
      end
    end

    class InternalCaskHash < T::Struct
      include CompactSerializable

      # TODO: simplify these types when possible
      PROPERTIES = T.let({
        artifacts:          T::Array[T.untyped],
        auto_updates:       T::Boolean,
        caveats:            T::Array[String],
        conflicts_with:     T::Array[String],
        container:          T::Hash[String, T.untyped],
        depends_on:         ::Cask::DSL::DependsOn,
        deprecation_date:   String,
        deprecation_reason: String,
        desc:               String,
        disable_date:       String,
        disable_reason:     String,
        homepage:           String,
        name:               T::Array[String],
        rename:             T::Array[String],
        sha256:             Checksum,
        url:                ::Cask::URL,
        url_specs:          T::Hash[Symbol, T.untyped],
        version:            String,
      }.freeze, T::Hash[Symbol, T.untyped])

      PROPERTIES.each do |property, type|
        const property, T.nilable(type)
      end

      sig { params(hash: T::Hash[String, T.untyped], bottle_tag: ::Utils::Bottles::Tag).returns(InternalCaskHash) }
      def self.from_hash(hash, bottle_tag:)
        hash = Homebrew::API.merge_variations(hash, bottle_tag: bottle_tag).transform_keys(&:to_sym)
        new(**hash.slice(*PROPERTIES.keys))
      end
    end
  end
end