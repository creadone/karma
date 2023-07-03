require "json"
require "./commands/*"

module Karma
  module Commands

    struct Directive
      include JSON::Serializable

      property command   : String
      property tree_name : String?
      property key       : UInt64?
      property time_from : UInt64?
      property time_to   : UInt64?
    end

    COMMANDS = {
      "trees"     => Commands::Trees,
      "create"    => Commands::Create,
      "drop"      => Commands::Drop,
      "dump"      => Commands::Dump,
      "dump_all"  => Commands::DumpAll,
      "dumps"     => Commands::Dumps,
      "load"      => Commands::Load,
      "increment" => Commands::Increment,
      "decrement" => Commands::Decrement,
      "sum"       => Commands::Sum,
      "find"      => Commands::Find,
      "reset"     => Commands::Reset,
      "delete"    => Commands::Delete,
      "ping"      => Commands::Ping
    }

    def self.call(message, cluster)
      begin
        directive = Directive.from_json(message)
        if COMMANDS.has_key?(directive.command)
          response = COMMANDS[directive.command].call(directive, cluster)
          return {
            "success" => true,
            "response" => response
          }.to_json
        else
          raise "Unknown command #{directive.command}"
        end
      rescue e
        return {
          "success" => false,
          "response" => e.message
        }.to_json
      end
    end

  end
end