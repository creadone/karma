<p align="center">
  <img src="https://raw.githubusercontent.com/creadone/karma/master/docs/karma.png" height="200">
  <h3 align="center">Karma</h3>
</p>

Karma is a key-value database that operates on a cluster of trees, in which each tree stores a set of counters. If you need to store different counters of positive values with a granularity of one day, get the sum of values for a certain date range or the sum of all values, then Karma is probably right for you.

In simple terms, Karma is a partitioned hash tables for fast counter lookup wrapped in TCP Server.

> Karma was created to help solve the problem of exceeding limits: when you have a lot of users who create a lot of artifacts in your service every day, and you need to make sure they don't exceed the limits.

## Status

Karma has almost full functionality, but is in the early stage of development with no guarantee of stable operation. By default Karma is able to store to disk and restore its state from dumps on startup, this can reduce the chance of data loss.

## Build from source

Requirements:

* The latest version of Crystal (1.8.2)

Steps:

* Clone the repo: git clone https://github.com/creadone/karma
* Switch to repo-directory: cd bojack
* Build: `shards build --release`

## Configuration

Karma supports configuration through command-line interface:

```
./karma -h
Usage: karma [arguments]
    -b host, --bind=host       Host to bind (default: 0.0.0.0)
    -p port, --port=port       Port to listen for connection (default: 8080)
    -d path, --directory=path  Directory for storing and loading dumps (default: .)
    -r flag, --restore=flag    Load last state from dumps (default: true)
    -n flag, --nodelay=flag    Disable Nagle's algorithm (default: true)
    -h, --help                 Show this help
```

## Commands

The application is implemented as a TCP server and exchanges commands with the client through a socket. Examples of commands for Ruby client:

```Ruby
require "karma"

# Checks the server
Karma.ping
#=> {"success"=>true, "response"=>"pong"}

# Create tree 'articles'
Karma.create('articles')
#=> {"success"=>true, "response"=>"OK"}

# Increment the value
Karma.tree('articles').increment(key: 12345)
#=> {"success"=>true, "response"=>1}

# Decrement the value
Karma.tree('articles').decrement(key: 12345)
#=> {"success"=>true, "response"=>1}

# Find values between date intervals
Karma.tree('articles').find(key: 12345, time_from: 20230701, time_to: 20230703)
#=> {"success"=>true, "response"=>{"20230702"=>126, "20230703"=>7}}

# Calculate total for key
Karma.tree('articles').sum(key: 12345)
#=> {"success"=>true, "response"=>133}

# Calculate total for key between dates
Karma.tree('articles').sum(key: 12345, time_from: 20230701, time_to: 20230703)
#=> {"success"=>true, "response"=>133}

# and more...

```

## Maintenance

* Maintenance of Karma by and large comes down to regular creation of tree dumps.
* By default, if Karma receives SIGINT, it dumps all trees to the directory specified at startup.
* When application starts, if restore flag is specified, Karma tries to find last dumps in specified directory and load all trees into memory.
* If Karma receives SIGUSR1, it resets all trees from memory to dumps and continues work. This is useful if you want to make dumps on schedule from cron.

## Performance

For the Ruby client performing 1K requests on localhost takes on average about 50 seconds. ~ 20 000 requests can be done in 1 second.

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/creadone/karma/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [creadone](https://github.com/your-github-user) - creator and maintainer
