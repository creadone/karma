# CounterTree

A sectioned hash table for storing counters that allow you to store values on a specific date and fetch as a sum or slice between two dates. This is part of the [Karma](https://github.com/creadone/karma)

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     counter_tree:
       github: creadone/counter_tree
   ```

2. Run `shards install`

## Usage

```crystal
require "counter_tree"

# Init with 9 sections
tree = CounterTree::Tree.new(9)

# Increment value for key
tree.increment(1234_u64)

# Decrement value for key
tree.decrement(1234_u64)

# Fetch sum of values for key
tree.sum(1234_u64)

# Fetch sum between timestamps for key
tree.sum(1234_u64, 1684767251993, 1684767253996)

# Fetch hash between timestamps for key
tree.find(1234_u64, 1684767251993, 1684767253996)

# Fetch hash between timestamps for all counters
tree.find(1684767251993, 1684767253996)

# Delete values between timestamps for key
tree.delete(1234_u64, 1684767251993, 1684767253996)

# Delete values between timestamps over all counters
tree.delete(1684767251993, 1684767253996)

# Reset counter for key
tree.reset(1234_u64)

# Reset all counters
tree.reset

# Store tree to msgpack
CounterTree.dump(tree)

# Load tree from msgpack
CounterTree.load(tree_bytes)
```

## Contributing

1. Fork it (<https://github.com/your-github-user/counter_tree/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [creadone](https://github.com/creadone) - creator and maintainer
