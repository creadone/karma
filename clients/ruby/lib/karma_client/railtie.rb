# frozen_string_literal: true

begin
  require "active_support"
  require "rails/railtie"
rescue LoadError
  # Rails is optional; non-Rails Ruby applications can use the client directly.
else
  module KarmaClient
    class Railtie < Rails::Railtie
      config.karma_client = ActiveSupport::OrderedOptions.new

      initializer "karma_client.configure" do |app|
        options = app.config.karma_client

        KarmaClient.configure do |client_config|
          options.each do |key, value|
            setter = "#{key}="
            client_config.public_send(setter, value) if client_config.respond_to?(setter)
          end

          client_config.instrumenter ||= ActiveSupport::Notifications if defined?(ActiveSupport::Notifications)
          client_config.logger ||= Rails.logger if defined?(Rails.logger)
        end
      end

      initializer "karma_client.close_on_shutdown" do |app|
        app.config.after_initialize do
          at_exit { KarmaClient.close }
        end
      end
    end
  end
end
