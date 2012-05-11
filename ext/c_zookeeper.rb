require_relative '../lib/zookeeper/common'
require_relative '../lib/zookeeper/constants'
require_relative 'zookeeper_c'

# require File.expand_path('../zookeeper_c', __FILE__)

# TODO: see if we can get the destructor to handle thread/event queue teardown
#       when we're garbage collected
module Zookeeper
class CZookeeper
  include Zookeeper::Forked
  include Zookeeper::Constants
  include Zookeeper::Exceptions

  DEFAULT_SESSION_TIMEOUT_MSEC = 10000

  class GotNilEventException < StandardError; end

  class Pipe < Struct.new(:io_pipe)
    def initialize
      self.io_pipe = IO.pipe
    end

    def reader
      io_pipe.first
    end

    def writer
      io_pipe.last
    end

    def close
      io_pipe.each { |i| i.close unless i.closed? }
    end
  end

  attr_accessor :original_pid

  # assume we're at debug level
  def self.get_debug_level
    @debug_level ||= ZOO_LOG_LEVEL_INFO
  end

  def self.set_debug_level(value)
    @debug_level = value
    set_zkrb_debug_level(value)
  end

  def initialize(host, event_queue, opts={})
    @host = host
    @event_queue = event_queue

    # keep track of the pid that created us
    update_pid!
    
    # used by the C layer. CZookeeper sets this to true when the init method
    # has completed. once this is set to true, it stays true.
    #
    # you should grab the @start_stop_mutex before messing with this flag
    @_running = nil

    # This is set to true after destroy_zkrb_instance has been called and all
    # CZookeeper state has been cleaned up
    @_closed = false  # also used by the C layer

    # set by the ruby side to indicate we are in shutdown mode used by method_get_next_event
    @_shutting_down = false

    # the actual C data is stashed in this ivar. never *ever* touch this
    @_data = nil

    @_session_timeout_msec = DEFAULT_SESSION_TIMEOUT_MSEC

    @start_stop_mutex = Monitor.new
    
    # used to signal that we're running
    @running_cond = @start_stop_mutex.new_cond

    # used to signal we've received the connected event
    @connected_cond = @start_stop_mutex.new_cond
    
    @event_thread = nil

    @pipe = Pipe.new

    zkrb_init(@host, :zkc_log_level => Constants::ZOO_LOG_LEVEL_DEBUG)

    setup_event_thread!

    logger.debug { "init returned!" }
  end

  def closed?
    @start_stop_mutex.synchronize { !!@_closed }
  end

  def running?
    @start_stop_mutex.synchronize { !!@_running }
  end

  def shutting_down?
    @start_stop_mutex.synchronize { !!@_shutting_down }
  end

  def connected?
    state == ZOO_CONNECTED_STATE
  end

  def connecting?
    state == ZOO_CONNECTING_STATE
  end

  def associating?
    state == ZOO_ASSOCIATING_STATE
  end

  def close
    return if closed?

    fn_close = proc do
      if !@_closed and @_data
        logger.debug { "CALLING CLOSE HANDLE!!" }
        close_handle
      end
    end

    if forked?
      fn_close.call
    else
#       shut_down!
      stop_event_thread!
      @start_stop_mutex.synchronize(&fn_close)
    end

    nil
  end

  def state
    return ZOO_CLOSED_STATE if closed?
    zkrb_state
  end

  # this implementation is gross, but i don't really see another way of doing it
  # without more grossness
  #
  # returns true if we're connected, false if we're not
  #
  # if timeout is nil, we never time out, and wait forever for CONNECTED state
  #
  def wait_until_connected(timeout=10)
    @start_stop_mutex.synchronize do
      wait_until_running(timeout)
      @connected_cond.wait(timeout) unless connected?
    end

    connected?
  end

  private
    # will wait until the client has entered the running? state
    # or until timeout seconds have passed.
    #
    # returns true if we're running, false if we timed out
    def wait_until_running(timeout=5)
      @start_stop_mutex.synchronize do
        return true if @_running
        @running_cond.wait(timeout)
        !!@_running
      end
    end

    def setup_event_thread!
      @event_thread ||= Thread.new(&method(:_event_thread_body))
    end

    def _event_thread_body
      Thread.current.abort_on_exception = true

      logger.debug { "event_thread waiting until running: #{@_running}" }

      @start_stop_mutex.synchronize do
        @running_cond.wait_until { @_running }

        if @_shutting_down
          logger.error { "event thread saw @_shutting_down, bailing without entering loop" }
          return
        end
      end

      logger.debug { "event_thread running: #{@_running}" }

      until @_shutting_down
        zkrb_iterate_event_loop # XXX: check rc here
        _iterate_event_delivery
      end
    end

    def _iterate_event_delivery
      if hash = zkrb_get_next_event_st()

        # TODO: should push notify_connected! up so that it's common to both java and C impl.
        if hash.values_at(:req_id, :type, :state) == CONNECTED_EVENT_VALUES
          notify_connected!
        end

        @event_queue.push(hash)
      end
    end

    # use this method to set the @_shutting_down flag to true
    def shut_down!
      logger.debug { "#{self.class}##{__method__}" }

      @start_stop_mutex.synchronize do
        @_shutting_down = true
      end
    end

    # this method is part of the reopen/close code, and is responsible for
    # shutting down the dispatch thread. 
    #
    # @dispatch will be nil when this method exits
    #
    def stop_event_thread!
      logger.debug { "#{self.class}##{__method__}" }

      if @event_thread
#         unless @_closed
#           wake_event_loop! # this is a C method
#         end
        shut_down!
        @event_thread.join 
        @event_thread = nil
      end
    end

    def logger
      Zookeeper.logger
    end

    # called by underlying C code to signal we're running
    def zkc_set_running_and_notify!
      logger.debug { "#{self.class}##{__method__}" }

      @start_stop_mutex.synchronize do
        @_running = true
        @running_cond.broadcast
      end
    end

    def notify_connected!
      @start_stop_mutex.synchronize do
        @connected_cond.broadcast
      end
    end
end
end
