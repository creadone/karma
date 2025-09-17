module Karma
  module Commands
    module Dumps

      def self.call(directive, cluster)
        dump_dir = File.expand_path(Karma.config.dump_dir)
        pattern = File.join(dump_dir, "*.tree")

        Dir.glob(pattern)
          .select{ |path| File.file?(path) }
          .sort{ |a, b| a.split("_").first.to_i32 <=> b.split("_").first.to_i32 }
          .reverse
      end

    end
  end
end