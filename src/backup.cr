module Karma
  module Backup

    def self.load(cluster, file_path, tree_name)
      if File.exists?(file_path)
        File.open(file_path) do |file|
          io = IO::Memory.new(file.size.to_i)
          IO.copy(file, io)
          cluster.load(tree_name, io.to_slice)
          true
        end
      else
        raise "Dump \"#{tree_name}\" not exists"
      end
    end

    def self.dump(cluster, file_path, tree_name)
      if cluster.trees.has_key?(tree_name)
        # Ensure destination directory exists
        dir_path = File.dirname(file_path)
        Dir.mkdir_p(dir_path) unless Dir.exists?(dir_path)
        File.open(file_path, "wb") do |io|
          io.write cluster.dump(tree_name)
        end
        true
      else
        raise "Tree \"#{tree_name}\" not found"
      end
    end

  end
end