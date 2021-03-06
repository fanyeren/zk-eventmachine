module ZK
  module ZKEventMachine
    # some improvements (one hopes) around the zookeeper gem's somewhat (ahem)
    # minimal Callback class
    #
    module Callback
      
      # Used by ZooKeeper to return an asynchronous result. 
      #
      # If callbacks or errbacks are set on the instance, they will be called
      # with just the data returned from the call (much like their synchronous
      # versions). 
      #
      # If a block was given to #new or #on_result, then that block is called
      # with a ZK::Exceptions::KeeperException instance or nil, then the rest
      # of the arguments defined for that callback type
      #
      # the node-style and deferred-style results are *NOT* exclusive, so if
      # you use both _you will be called with results in both formats_.
      #
      class Base
        include Deferred
        include ZK::Logging

        # set the result keys that should be used by node_style_result and to
        # call the deferred_style_result blocks
        #
        def self.async_result_keys(*syms)
          if syms.empty? 
            @async_result_keys || []
          else
            @async_result_keys = syms.map { |n| n.to_sym }
          end
        end

        # save a context object, used for associating delivered events with the request that created them
        attr_accessor :context

        # saves the request id of this call
        attr_reader :req_id

        def initialize(prok=nil, &block)
          on_result(prok, &block)
        end

        # register a block that should be called (node.js style) with the
        # results
        #
        # @note replaces the block given to #new 
        #
        def on_result(prok=nil, &block)
          @block = (prok || block)
        end

        # Checks the return code from the async call. If the return code was not ZOK,
        # then fire the errbacks and do the node-style error call
        # otherwise, does nothing
        #
        # in this call we also stash the outgoing req_id so we can sync it up
        def check_async_rc(hash)
          @req_id = hash[:req_id]
          logger.debug { "#{__method__}: got #{hash.inspect}" } 
          call(hash) unless success?(hash)
        end

        # ZK will call this instance with a hash of data, which is the result
        # of the asynchronous call. Depending on the style of callback in use,
        # we take the appropriate actions
        #
        # delegates to #deferred_style_result and #node_style_result
        def call(result)
          logger.debug { "\n#{self.class.name}##{__method__}\n\treq_id: #{req_id.inspect}\n\tcontext: #{context.inspect}\n\tresult: #{result.inspect}" }
          EM.schedule do
            deferred_style_result(result) 
            node_style_result(result)
          end
        end

        # returns true if the request was successful (if return_code was Zookeeper::ZOK)
        #
        # @param [Hash] hash the result of the async call 
        # 
        # @return [true, false] for success, failure 
        def success?(hash)
          hash[:rc] == Zookeeper::ZOK
        end

        # Returns an instance of a sublcass ZK::Exceptions::KeeperException
        # based on the asynchronous return_code.
        #
        # facilitates using case statements for error handling
        #
        # @param [Hash] hash the result of the async call 
        #
        # @raise [RuntimeError] if the return_code is not known by ZK (this should never
        #   happen and if it does, you should report a bug)
        #
        # @return [ZK::Exceptions::KeeperException, nil] subclass based on
        #   return_code if there was an error, nil otherwise
        #
        def exception_for(hash)
          return nil if success?(hash)
          return_code = hash.fetch(:rc)
          ZK::Exceptions::KeeperException.by_code(return_code).new
        end

        # @abstract should call set_deferred_status with the appropriate args
        #   for the result and type of call
        def deferred_style_result(hash)
          # ensure this calls the callback on the reactor

          if success?(hash)
            vals = hash.values_at(*async_result_keys)
#             logger.debug { "#{self.class.name}#deferred_style_result async_result_keys: #{async_result_keys.inspect}, vals: #{vals.inspect}" }
            self.succeed(*hash.values_at(*async_result_keys))
          else
            self.fail(exception_for(hash))
          end
        end

        # call the user block with the correct Exception class as the first arg
        # (or nil if no error) and then the appropriate args for the type of
        # asynchronous call
        def node_style_result(hash)
          return unless @block
          vals = hash.values_at(*async_result_keys)
#           logger.debug { "#{self.class.name}#node_style_result async_result_keys: #{async_result_keys.inspect}, vals: #{vals.inspect}" }
          if exc = exception_for(hash)
            @block.call(exc)
          else
            @block.call(nil, *vals)
          end
        end

        protected
          def async_result_keys
            self.class.async_result_keys
          end
      end

      # used with Client#get call
      class DataCallback < Base
        async_result_keys :data, :stat
      end

      # used with Client#children call
      class ChildrenCallback < Base
        async_result_keys :strings, :stat
      end

      # used with Client#create
      class StringCallback < Base
        async_result_keys :string
      end

      # used with Client#stat and Client#exists?
      class StatCallback < Base
        async_result_keys :stat

        # stat has a different concept of 'success', stat on a node that doesn't 
        # exist is not an exception, it's a certain kind of stat (like a null stat).
        def success?(hash)
          rc = hash[:rc] 
          (rc == Zookeeper::ZOK) || (rc == Zookeeper::ZNONODE)
        end
      end

      # supports the syntactic sugar exists? call
      class ExistsCallback < StatCallback
        async_result_keys :stat

        # @abstract should call set_deferred_status with the appropriate args
        #   for the result and type of call
        def deferred_style_result(hash)
          # ensure this calls the callback on the reactor

          if success?(hash)
            succeed(hash[:stat].exists?)
          else
            fail(exception_for(hash))
          end
        end

        # call the user block with the correct Exception class as the first arg
        # (or nil if no error) and then the appropriate args for the type of
        # asynchronous call
        def node_style_result(hash)
          return unless @block
          @block.call(exception_for(hash), hash[:stat].exists?)
        end
      end

      # set operation returns a stat object, but in this case a NONODE is an
      # error (unlike with StatCallback)
      class SetCallback < Base
        async_result_keys :stat
      end

      # used with Client#delete and Client#set_acl
      class VoidCallback < Base
      end

      # used with Client#get_acl
      class ACLCallback < Base
        async_result_keys :acl, :stat
      end

      class << self
        def new_data_cb(njs_block)
          DataCallback.new(njs_block).tap do |cb| # create the callback with the user-provided block
            cb.check_async_rc(yield(cb))          # yield the callback to the caller, check the return result 
                                                  # of the async operation (not the async result)
          end                                     # return the callback
        end
        alias :new_get_cb :new_data_cb    # create alias so that this matches the client API name

        def new_string_cb(njs_block)
          StringCallback.new(njs_block).tap do |cb|
            cb.check_async_rc(yield(cb))
          end
        end
        alias :new_create_cb :new_string_cb

        def new_stat_cb(njs_block)
          StatCallback.new(njs_block).tap do |cb|
            cb.check_async_rc(yield(cb))
          end
        end

        def new_exists_cb(njs_block)
          ExistsCallback.new(njs_block).tap do |cb|
            cb.check_async_rc(yield(cb))
          end
        end

        def new_set_cb(njs_block)
          SetCallback.new(njs_block).tap do |cb|
            cb.check_async_rc(yield(cb))
          end
        end

        def new_void_cb(njs_block)
          VoidCallback.new(njs_block).tap do |cb|
            cb.check_async_rc(yield(cb))
          end
        end
        alias :new_delete_cb :new_void_cb
        alias :new_set_acl_cb :new_void_cb

        def new_children_cb(njs_block)
          ChildrenCallback.new(njs_block).tap do |cb|
            cb.check_async_rc(yield(cb))
          end
        end

        def new_acl_cb(njs_block)
          ACLCallback.new(njs_block).tap do |cb|
            cb.check_async_rc(yield(cb))
          end
        end
        alias :new_get_acl_cb :new_acl_cb
      end
    end
  end
end

