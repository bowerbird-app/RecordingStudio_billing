# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module RecordingStudioBilling
  module Generators
    # Generator to install RecordingStudioBilling migrations into the host application.
    #
    # Usage:
    #   rails generate recording_studio_billing:migrations
    #
    # Options:
    #   --skip-existing  Skip migrations that already exist in the host app
    #
    class MigrationsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("../../../..", __dir__)

      desc "Copy RecordingStudioBilling migrations to your application"

      class_option :skip_existing, type: :boolean, default: true,
                                   desc: "Skip migrations that already exist (based on name, ignoring timestamp)"

      def copy_migrations
        migrations_dir = File.join(self.class.source_root, "db", "migrate")

        unless File.directory?(migrations_dir)
          say "No migrations found in RecordingStudioBilling engine.", :yellow
          return
        end

        migration_files = Dir.glob(File.join(migrations_dir, "*.rb")).sort

        if migration_files.empty?
          say "No migrations found in RecordingStudioBilling engine.", :yellow
          return
        end

        say "Found #{migration_files.size} migration(s) to install:", :green

        migration_files.each do |source_path|
          filename = File.basename(source_path)
          # Extract migration name without timestamp.
          migration_name = filename.sub(/^\d+_/, "")

          if options[:skip_existing] && migration_exists?(migration_name)
            say "  skip  #{migration_name} (already exists)", :yellow
            next
          end

          version = filename.split("_", 2).first
          if migration_version_exists?(version)
            raise Thor::Error,
                  "Migration version #{version} is already used; canonical RecordingStudioBilling versions cannot be remapped."
          end

          destination_path = File.join("db/migrate", filename)

          copy_file source_path, destination_path
          say "  create  #{destination_path}", :green
        end

        say "\nRun 'bin/rails db:migrate' to apply the migrations.", :green
        say "Commit db/structure.sql; schema.rb cannot preserve the billing integrity triggers.", :green
      end

      private

      def migration_exists?(migration_name)
        Dir.glob(File.join(destination_root, "db/migrate", "*_#{migration_name}")).any?
      end

      def migration_version_exists?(version)
        Dir.glob(File.join(destination_root, "db/migrate", "#{version}_*.rb")).any?
      end

    end
  end
end
