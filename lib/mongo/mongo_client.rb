# Copyright (C) 2009-2013 MongoDB, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Mongo

  # Instantiates and manages self.connections to MongoDB.
  class MongoClient
    include Mongo::Logging
    include Mongo::Networking
    include Mongo::WriteConcern
    include Mongo::Authentication

    # Wire version
    RELEASE_2_4_AND_BEFORE = 0 # Everything before we started tracking.
    AGG_RETURNS_CURSORS    = 1 # The aggregation command may now be requested to return cursors.
    BATCH_COMMANDS         = 2 # insert, update, and delete batch command
    MONGODB_3_0            = 3 # listCollections and listIndexes commands, SCRAM-SHA-1 auth mechanism
    MAX_WIRE_VERSION       = MONGODB_3_0 # supported by this client implementation
    MIN_WIRE_VERSION       = RELEASE_2_4_AND_BEFORE # supported by this client implementation

    # Server command headroom
    COMMAND_HEADROOM   = 16_384
    APPEND_HEADROOM    = COMMAND_HEADROOM / 2
    SERIALIZE_HEADROOM = APPEND_HEADROOM / 2

    DEFAULT_MAX_WRITE_BATCH_SIZE = 1000

    Mutex              = ::Mutex
    ConditionVariable  = ::ConditionVariable

    DEFAULT_HOST         = 'localhost'
    DEFAULT_PORT         = 27017
    DEFAULT_DB_NAME      = 'test'
    DEFAULT_OP_TIMEOUT   = 20
    GENERIC_OPTS         = [:auths, :logger, :connect, :db_name]
    TIMEOUT_OPTS         = [:timeout, :op_timeout, :connect_timeout]
    SSL_OPTS             = [:ssl, :ssl_key, :ssl_cert, :ssl_verify, :ssl_ca_cert, :ssl_key_pass_phrase]
    POOL_OPTS            = [:pool_size, :pool_timeout]
    READ_PREFERENCE_OPTS = [:read, :tag_sets, :secondary_acceptable_latency_ms]
    WRITE_CONCERN_OPTS   = [:w, :j, :fsync, :wtimeout]
    CLIENT_ONLY_OPTS     = [:slave_ok]

    mongo_thread_local_accessor :connections

    attr_reader :logger,
                :size,
                :auths,
                :primary,
                :write_concern,
                :host_to_try,
                :pool_size,
                :connect_timeout,
                :pool_timeout,
                :primary_pool,
                :socket_class,
                :socket_opts,
                :op_timeout,
                :tag_sets,
                :acceptable_latency,
                :read,
                :max_wire_version,
                :min_wire_version,
                :max_write_batch_size

    # Create a connection to single MongoDB instance.
    #
    # If no args are provided, it will check <code>ENV["MONGODB_URI"]</code>.
    #
    # You may specify whether connection to slave is permitted.
    # In all cases, the default host is "localhost" and the default port is 27017.
    #
    # If you're connecting to a replica set, you'll need to use MongoReplicaSetClient.new instead.
    #
    # Once connected to a replica set, you can find out which nodes are primary, secondary, and
    # arbiters with the corresponding accessors: MongoClient#primary, MongoClient#secondaries, and
    # MongoClient#arbiters. This is useful if your application needs to connect manually to nodes other
    # than the primary.
    #
    # @overload initialize(host, port, opts={})
    #  @param [String] host hostname for the target MongoDB server.
    #  @param [Integer] port specify a port number here if only one host is being specified.
    #  @param [Hash] opts hash of optional settings and configuration values.
    #
    #  @option opts [String, Integer, Symbol] :w (1) Set default number of nodes to which a write
    #   should be acknowledged.
    #  @option opts [Integer] :wtimeout (nil) Set replica set acknowledgement timeout.
    #  @option opts [Boolean] :j (false) If true, block until write operations have been committed
    #   to the journal. Cannot be used in combination with 'fsync'. Prior to MongoDB 2.6 this option was
    #   ignored if the server was running without journaling. Starting with MongoDB 2.6, write operations will
    #   fail with an exception if this option is used when the server is running without journaling.
    #  @option opts [Boolean] :fsync (false) If true, and the server is running without journaling, blocks until
    #   the server has synced all data files to disk. If the server is running with journaling, this acts the same as
    #   the 'j' option, blocking until write operations have been committed to the journal.
    #   Cannot be used in combination with 'j'.
    #
    #  Notes about Write-Concern Options:
    #   Write concern options are propagated to objects instantiated from this MongoClient.
    #   These defaults can be overridden upon instantiation of any object by explicitly setting an options hash
    #   on initialization.
    #
    #  @option opts [Boolean] :ssl (false) If true, create the connection to the server using SSL.
    #  @option opts [String] :ssl_cert (nil) The certificate file used to identify the local connection against MongoDB.
    #  @option opts [String] :ssl_key (nil) The private keyfile used to identify the local connection against MongoDB.
    #    Note that even if the key is stored in the same file as the certificate, both need to be explicitly specified.
    #  @option opts [String] :ssl_key_pass_phrase (nil) A passphrase for the private key.
    #  @option opts [Boolean] :ssl_verify (nil) Specifies whether or not peer certification validation should occur.
    #  @option opts [String] :ssl_ca_cert (nil) The ca_certs file contains a set of concatenated "certification authority"
    #    certificates, which are used to validate certificates passed from the other end of the connection.
    #    Required for :ssl_verify.
    #  @option opts [Boolean] :slave_ok (false) Must be set to +true+ when connecting
    #    to a single, slave node.
    #  @option opts [Logger, #debug] :logger (nil) A Logger instance for debugging driver ops. Note that
    #    logging negatively impacts performance; therefore, it should not be used for high-performance apps.
    #  @option opts [Integer] :pool_size (1) The maximum number of socket self.connections allowed per
    #    connection pool. Note: this setting is relevant only for multi-threaded applications.
    #  @option opts [Float] :pool_timeout (5.0) When all of the self.connections a pool are checked out,
    #    this is the number of seconds to wait for a new connection to be released before throwing an exception.
    #    Note: this setting is relevant only for multi-threaded applications.
    #  @option opts [Float] :op_timeout (DEFAULT_OP_TIMEOUT) The number of seconds to wait for a read operation to time out.
    #    Set to DEFAULT_OP_TIMEOUT (20) by default. A value of nil may be specified explicitly.
    #  @option opts [Float] :connect_timeout (nil) The number of seconds to wait before timing out a
    #    connection attempt.
    #
    # @example localhost, 27017 (or <code>ENV["MONGODB_URI"]</code> if available)
    #   MongoClient.new
    #
    # @example localhost, 27017
    #   MongoClient.new("localhost")
    #
    # @example localhost, 3000, max 5 self.connections, with max 5 seconds of wait time.
    #   MongoClient.new("localhost", 3000, :pool_size => 5, :pool_timeout => 5)
    #
    # @example localhost, 3000, where this node may be a slave
    #   MongoClient.new("localhost", 3000, :slave_ok => true)
    #
    # @example Unix Domain Socket
    #   MongoClient.new("/var/run/mongodb.sock")
    #
    # @see http://api.mongodb.org/ruby/current/file.REPLICA_SETS.html Replica sets in Ruby
    #
    # @raise [ReplicaSetConnectionError] This is raised if a replica set name is specified and the
    #   driver fails to connect to a replica set with that name.
    #
    # @raise [MongoArgumentError] If called with no arguments and <code>ENV["MONGODB_URI"]</code> implies a replica set.
    def initialize(*args)
      opts         = args.last.is_a?(Hash) ? args.pop : {}
      @host, @port = parse_init(args[0], args[1], opts)

      # Lock for request ids.
      @id_lock = Mutex.new

      # Connection pool for primary node
      @primary      = nil
      @primary_pool = nil
      @mongos       = false

      # Not set for direct connection
      @tag_sets           = []
      @acceptable_latency = 15

      @max_bson_size    = nil
      @max_message_size = nil
      @max_wire_version = nil
      @min_wire_version = nil
      @max_write_batch_size = nil

      check_opts(opts)
      setup(opts.dup)
    end

    # DEPRECATED
    #
    # Initialize a connection to a MongoDB replica set using an array of seed nodes.
    #
    # The seed nodes specified will be used on the initial connection to the replica set, but note
    # that this list of nodes will be replaced by the list of canonical nodes returned by running the
    # is_master command on the replica set.
    #
    # @param nodes [Array] An array of arrays, each of which specifies a host and port.
    # @param opts [Hash] Any of the available options that can be passed to MongoClient.new.
    #
    # @option opts [String] :rs_name (nil) The name of the replica set to connect to. An exception will be
    #   raised if unable to connect to a replica set with this name.
    # @option opts [Boolean] :read_secondary (false) When true, this connection object will pick a random slave
    #   to send reads to.
    #
    # @example
    #   Mongo::MongoClient.multi([["db1.example.com", 27017], ["db2.example.com", 27017]])
    #
    # @example This connection will read from a random secondary node.
    #   Mongo::MongoClient.multi([["db1.example.com", 27017], ["db2.example.com", 27017], ["db3.example.com", 27017]],
    #                   :read_secondary => true)
    #
    # @return [Mongo::MongoClient]
    #
    # @deprecated
    def self.multi(nodes, opts={})
      warn 'MongoClient.multi is now deprecated and will be removed in v2.0. Please use MongoReplicaSetClient.new instead.'
      MongoReplicaSetClient.new(nodes, opts)
    end

    # Initialize a connection to MongoDB using the MongoDB URI spec.
    #
    # Since MongoClient.new cannot be used with any <code>ENV["MONGODB_URI"]</code> that has multiple hosts (implying a replicaset),
    # you may use this when the type of your connection varies by environment and should be determined solely from <code>ENV["MONGODB_URI"]</code>.
    #
    # @param uri [String]
    #   A string of the format mongodb://[username:password@]host1[:port1][,host2[:port2],...[,hostN[:portN]]][/database]
    #
    # @param [Hash] extra_opts Any of the options available for MongoClient.new
    #
    # @return [Mongo::MongoClient, Mongo::MongoReplicaSetClient]
    def self.from_uri(uri = ENV['MONGODB_URI'], extra_opts={})
      parser = URIParser.new(uri)
      parser.connection(extra_opts)
    end

    # The host name used for this connection.
    #
    # @return [String]
    def host
      @primary_pool.host
    end

    # The port used for this connection.
    #
    # @return [Integer]
    def port
      @primary_pool.port
    end

    def host_port
      [@host, @port]
    end

    # Flush all pending writes to datafiles.
    #
    # @return [BSON::OrderedHash] the command response
    def lock!
      cmd = BSON::OrderedHash.new
      cmd[:fsync] = 1
      cmd[:lock]  = true
      self['admin'].command(cmd)
    end

    # Is this database locked against writes?
    #
    # @return [Boolean]
    def locked?
      [1, true].include? self['admin']['$cmd.sys.inprog'].find_one['fsyncLock']
    end

    # Unlock a previously fsync-locked mongod process.
    #
    # @return [BSON::OrderedHash] command response
    def unlock!
      self['admin']['$cmd.sys.unlock'].find_one
    end

    # Return a hash with all database names
    # and their respective sizes on disk.
    #
    # @return [Hash]
    def database_info
      doc = self['admin'].command({:listDatabases => 1})
      doc['databases'].inject({}) do |info, db|
        info[db['name']] = db['sizeOnDisk'].to_i
        info
      end
    end

    # Return an array of database names.
    #
    # @return [Array]
    def database_names
      database_info.keys
    end

    # Return a database with the given name.
    # See DB#new for valid options hash parameters.
    #
    # @param name [String] The name of the database.
    # @param opts [Hash] A hash of options to be passed to the DB constructor.
    #
    # @return [DB] The DB instance.
    def db(name = nil, opts = {})
      DB.new(name || @db_name || DEFAULT_DB_NAME, self, opts)
    end

    # Shortcut for returning a database. Use MongoClient#db to accept options.
    #
    # @param name [String] The name of the database.
    #
    # @return [DB] The DB instance.
    def [](name)
      DB.new(name, self)
    end

    def refresh; end

    def pinned_pool
      @primary_pool
    end

    def pin_pool(pool, read_prefs); end

    def unpin_pool; end

    # Drop a database.
    #
    # @param database [String] name of an existing database.
    def drop_database(database)
      self[database].command(:dropDatabase => 1)
    end

    # Copy the database +from+ to +to+ on localhost. The +from+ database is
    # assumed to be on localhost, but an alternate host can be specified.
    #
    # @param from [String] name of the database to copy from.
    # @param to [String] name of the database to copy to.
    # @param from_host [String] host of the 'from' database.
    # @param username [String] username (applies to 'from' db)
    # @param password [String] password (applies to 'from' db)
    #
    # @note This command only supports the MONGODB-CR authentication mechanism.
    def copy_database(
      from,
      to,
      from_host = DEFAULT_HOST,
      username = nil,
      password = nil,
      mechanism = 'SCRAM-SHA-1'
    )
      if wire_version_feature?(MONGODB_3_0) && mechanism == 'SCRAM-SHA-1'
        copy_db_scram(username, password, from_host, from, to)
      else
        copy_db_mongodb_cr(username, password, from_host, from, to)
      end
    end

    # Checks if a server is alive. This command will return immediately
    # even if the server is in a lock.
    #
    # @return [Hash]
    def ping
      self['admin'].command({:ping => 1})
    end

    # Get the build information for the current connection.
    #
    # @return [Hash]
    def server_info
      self['admin'].command({:buildinfo => 1})
    end

    # Get the build version of the current server.
    #
    # @return [Mongo::ServerVersion]
    #   object allowing easy comparability of version.
    def server_version
      ServerVersion.new(server_info['version'])
    end

    # Is it okay to connect to a slave?
    #
    # @return [Boolean]
    def slave_ok?
      @slave_ok
    end

    def mongos?
      @mongos
    end

    # Create a new socket and attempt to connect to master.
    # If successful, sets host and port to master and returns the socket.
    #
    # If connecting to a replica set, this method will replace the
    # initially-provided seed list with any nodes known to the set.
    #
    # @raise [ConnectionFailure] if unable to connect to any host or port.
    def connect
      close
      config = check_is_master(host_port)
      if config
        if config['ismaster'] == 1 || config['ismaster'] == true
          @read_primary = true
        elsif @slave_ok
          @read_primary = false
        end

        if config.has_key?('msg') && config['msg'] == 'isdbgrid'
          @mongos = true
        end

        @max_bson_size    = config['maxBsonObjectSize']
        @max_message_size = config['maxMessageSizeBytes']
        @max_wire_version = config['maxWireVersion']
        @min_wire_version = config['minWireVersion']
        @max_write_batch_size = config['maxWriteBatchSize']
        check_wire_version_in_range
        set_primary(host_port)
      end

      unless connected?
        raise ConnectionFailure,
          "Failed to connect to a master node at #{host_port.join(":")}"
      end

      true
    end
    alias :reconnect :connect

    # It's possible that we defined connected as all nodes being connected???
    # NOTE: Do check if this needs to be more stringent.
    # Probably not since if any node raises a connection failure, all nodes will be closed.
    def connected?
      !!(@primary_pool && !@primary_pool.closed?)
    end

    # Determine if the connection is active. In a normal case the *server_info* operation
    # will be performed without issues, but if the connection was dropped by the server or
    # for some reason the sockets are unsynchronized, a ConnectionFailure will be raised and
    # the return will be false.
    #
    # @return [Boolean]
    def active?
      return false unless connected?

      ping
      true

      rescue ConnectionFailure, OperationTimeout
      false
    end

    # Determine whether we're reading from a primary node. If false,
    # this connection connects to a secondary node and @slave_ok is true.
    #
    # @return [Boolean]
    def read_primary?
      @read_primary
    end
    alias :primary? :read_primary?

    # The socket pool that this connection reads from.
    #
    # @return [Mongo::Pool]
    def read_pool
      @primary_pool
    end

    # Close the connection to the database.
    def close
      @primary_pool.close if @primary_pool
      @primary_pool = nil
      @primary      = nil
    end

    # Returns the maximum BSON object size as returned by the core server.
    # Use the 4MB default when the server doesn't report this.
    #
    # @return [Integer]
    def max_bson_size
      @max_bson_size || DEFAULT_MAX_BSON_SIZE
    end

    def max_message_size
      @max_message_size || max_bson_size * MESSAGE_SIZE_FACTOR
    end

    def max_wire_version
      @max_wire_version || 0
    end

    def min_wire_version
      @min_wire_version || 0
    end

    def max_write_batch_size
      @max_write_batch_size || DEFAULT_MAX_WRITE_BATCH_SIZE
    end

    def wire_version_feature?(feature)
      min_wire_version <= feature && feature <= max_wire_version
    end

    def primary_wire_version_feature?(feature)
      min_wire_version <= feature && feature <= max_wire_version
    end

    def use_write_command?(write_concern)
      write_concern[:w] != 0 && primary_wire_version_feature?(Mongo::MongoClient::BATCH_COMMANDS)
    end

    # Checkout a socket for reading (i.e., a secondary node).
    # Note: this is overridden in MongoReplicaSetClient.
    def checkout_reader(read_preference)
      connect unless connected?
      @primary_pool.checkout
    end

    # Checkout a socket for writing (i.e., a primary node).
    # Note: this is overridden in MongoReplicaSetClient.
    def checkout_writer
      connect unless connected?
      @primary_pool.checkout
    end

    # Check a socket back into its pool.
    # Note: this is overridden in MongoReplicaSetClient.
    def checkin(socket)
      if @primary_pool && socket && socket.pool
        socket.checkin
      end
    end

    # Internal method for checking isMaster() on a given node.
    #
    # @param  node [Array] Port and host for the target node
    # @return [Hash] Response from isMaster()
    #
    # @private
    def check_is_master(node)
      begin
        host, port = *node
        config = nil
        socket = @socket_class.new(host, port, @op_timeout, @connect_timeout, @socket_opts)
        if @connect_timeout
          Timeout::timeout(@connect_timeout, OperationTimeout) do
            config = self['admin'].command({:isMaster => 1}, :socket => socket)
          end
        else
          config = self['admin'].command({:isMaster => 1}, :socket => socket)
        end
      rescue OperationFailure, SocketError, SystemCallError, IOError
        close
      ensure
        socket.close unless socket.nil? || socket.closed?
      end
      config
    end

    protected

    def valid_opts
      GENERIC_OPTS +
      CLIENT_ONLY_OPTS +
      POOL_OPTS +
      READ_PREFERENCE_OPTS +
      WRITE_CONCERN_OPTS +
      TIMEOUT_OPTS +
      SSL_OPTS
    end

    def check_opts(opts)
      bad_opts = opts.keys.reject { |opt| valid_opts.include?(opt) }

      unless bad_opts.empty?
        bad_opts.each {|opt| warn "#{opt} is not a valid option for #{self.class}"}
      end
    end

    # Parse option hash
    def setup(opts)
      @slave_ok = opts.delete(:slave_ok)
      @ssl      = opts.delete(:ssl)
      @unix     = @host ? @host.end_with?('.sock') : false

      # if ssl options are present, but ssl is nil/false raise for misconfig
      ssl_opts = opts.keys.select { |k| k.to_s.start_with?('ssl') }
      if ssl_opts.size > 0 && !@ssl
        raise MongoArgumentError, "SSL has not been enabled (:ssl=false) " +
          "but the following  SSL related options were " +
          "specified: #{ssl_opts.join(', ')}"
      end

      @socket_opts = {}
      if @ssl
        # construct ssl socket opts
        @socket_opts[:key]             = opts.delete(:ssl_key)
        @socket_opts[:cert]            = opts.delete(:ssl_cert)
        @socket_opts[:verify]          = opts.delete(:ssl_verify)
        @socket_opts[:ca_cert]         = opts.delete(:ssl_ca_cert)
        @socket_opts[:key_pass_phrase] = opts.delete(:ssl_key_pass_phrase)

        # verify peer requires ca_cert, raise if only one is present
        if @socket_opts[:verify] && !@socket_opts[:ca_cert]
          raise MongoArgumentError,
            'If :ssl_verify_mode has been specified, then you must include ' +
            ':ssl_ca_cert in order to perform server validation.'
        end

        # if we have a keyfile passphrase but no key file, raise
        if @socket_opts[:key_pass_phrase] && !@socket_opts[:key]
          raise MongoArgumentError,
            'If :ssl_key_pass_phrase has been specified, then you must include ' +
            ':ssl_key, the passphrase-protected keyfile.'
        end

        @socket_class = Mongo::SSLSocket
      elsif @unix
        @socket_class = Mongo::UNIXSocket
      else
        @socket_class = Mongo::TCPSocket
      end

      @db_name = opts.delete(:db_name)
      @auths   = opts.delete(:auths) || Set.new

      # Pool size and timeout.
      @pool_size = opts.delete(:pool_size) || 1
      if opts[:timeout]
        warn 'The :timeout option has been deprecated ' +
             'and will be removed in the 2.0 release. ' +
             'Use :pool_timeout instead.'
      end
      @pool_timeout = opts.delete(:pool_timeout) || opts.delete(:timeout) || 5.0

      # Timeout on socket read operation.
      @op_timeout = opts.key?(:op_timeout) ? opts.delete(:op_timeout) : DEFAULT_OP_TIMEOUT

      # Timeout on socket connect.
      @connect_timeout = opts.delete(:connect_timeout) || 30

      @logger = opts.delete(:logger)
      if @logger
        write_logging_startup_message
      end

      # Determine read preference
      if defined?(@slave_ok) && (@slave_ok) || defined?(@read_secondary) && @read_secondary
        @read = :secondary_preferred
      else
        @read = opts.delete(:read) || :primary
      end
      Mongo::ReadPreference::validate(@read)

      @tag_sets = opts.delete(:tag_sets) || []
      @acceptable_latency = opts.delete(:secondary_acceptable_latency_ms) || 15

      # Connection level write concern options.
      @write_concern = get_write_concern(opts)

      connect if opts.fetch(:connect, true)
    end

    private

    # Parses client initialization info from MONGODB_URI env variable
    def parse_init(host, port, opts)
      if host.nil? && port.nil? && ENV.has_key?('MONGODB_URI')
        parser = URIParser.new(ENV['MONGODB_URI'])
        if parser.replicaset?
          raise MongoArgumentError,
            'ENV[\'MONGODB_URI\'] implies a replica set.'
        end
        opts.merge!(parser.connection_options)
        [parser.host, parser.port]
      else
        host = host[1...-1] if host && host[0,1] == '[' # ipv6 support
        [host || DEFAULT_HOST, port || DEFAULT_PORT]
      end
    end

    # Set the specified node as primary
    def set_primary(node)
      host, port    = *node
      @primary      = [host, port]
      @primary_pool = Pool.new(self, host, port, :size => @pool_size, :timeout => @pool_timeout)
    end

    # calculate wire version in range
    def check_wire_version_in_range
      unless MIN_WIRE_VERSION <= max_wire_version &&
             MAX_WIRE_VERSION >= min_wire_version
        close
        raise ConnectionFailure,
            "Client wire-version range #{MIN_WIRE_VERSION} to " +
            "#{MAX_WIRE_VERSION} does not support server range " +
            "#{min_wire_version} to #{max_wire_version}, please update " +
            "clients or servers"
      end
    end
  end
end
