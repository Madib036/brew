# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "api/generator"

module Homebrew
  module DevCmd
    class GenerateCaskApi < AbstractCommand
      cmd_args do
        description <<~EOS
          Generate `homebrew/cask` API data files for <#{HOMEBREW_API_WWW}>.
          The generated files are written to the current directory.
        EOS
        switch "-n", "--dry-run",
               description: "Generate API data without writing it to files."

        named_args :none
      end

      sig { override.void }
      ##
      # Generates homebrew/cask API data files for HOMEBREW_API_WWW in the current directory.
      # If the dry-run switch is set, performs a generation simulation without writing files.
      def run
        # odeprecated "brew generate-cask-api", "brew generate-package-api --only-cask"

        Homebrew::API::Generator.new(
          only_cask: true,
          dry_run:   args.dry_run?,
        ).generate!
      end
    end
  end
end