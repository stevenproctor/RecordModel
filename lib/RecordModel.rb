require 'RecordModelExt'

class RecordModel

  class Builder

    #
    # An array of:
    #
    #   [id, type, is_key, offset, length]
    #
    # entries.
    #
    attr_reader :fields

    def initialize
      @fields = []
      @current_offset = 0
      yield self
    end

    def key(id, type, sz=nil)
      field(id, type, sz, true)
    end

    def val(id, type, sz=nil)
      field(id, type, sz, false)
    end

    private

    def field(id, type, sz, is_key)
      size = type_size(type, sz) 
      _add_field(id.to_sym, type, is_key, @current_offset, size)
      @current_offset += size
    end

    def _add_field(id, type, is_key, offset, length)
      raise if @fields.assoc(id)
      @fields << [id, type, is_key, offset, length]
    end

    def type_size(type, sz)
      size = case type
      when :uint64 then 8
      when :uint32 then 4
      when :uint16 then 2
      when :uint8  then 1
      when :timestamp then 8
      when :timestamp_desc then 8
      when :double then 8
      when :hexstr then sz 
      else
        raise
      end
      raise if sz and size != sz
      return size
    end
  end

  def self.define(&block)
    b = Builder.new(&block)

    model = new(b.fields)
    klass = model.to_class
    fields = b.fields
    fields.freeze

    fields.each_with_index do |fld, i|
      id = fld.first
      klass.class_eval "def #{id}() self[#{i}] end" 
      klass.class_eval "def #{id}=(v) self[#{i}] = v end" 
    end

    klass.const_set(:INFO, fields)
    klass.class_eval "def self.__info() INFO end"
    klass.class_eval "def __info() INFO end"

    return klass
  end

end

class RecordModelInstance
  include Comparable

  alias old_initialize initialize

  def initialize(hash=nil)
    old_initialize()
    hash.each {|k, v| self.send(:"#{k}=", v) } if hash
  end

  def to_hash
    h = {}
    __info().each {|fld| id = fld.first; h[id] = send(id)}
    h
  end

  def _to_hash(is_key)
    h = {}
    __info().each {|fld|
      if fld[2] == is_key
        id = fld.first
        h[id] = send(id)
      end
    }
    h
  end

  def keys_to_hash
    _to_hash(true)
  end

  def values_to_hash
    _to_hash(false)
  end

  def inspect
    [self.class, keys_to_hash(), values_to_hash()]
  end

  def self.make_array(n, expandable=true)
    RecordModelInstanceArray.new(self, n, expandable)
  end

  def self.build_query(query={})
    from = new()
    to = new()

    used_keys = [] 

    __info().each_with_index {|fld, idx|
      next unless fld[2] # we only want keys!
      id = fld.first
 
      if query.has_key?(id)
        used_keys << id
        case (q = query[id])
        when Range 
          raise ArgumentError if q.exclude_end?
          from[idx] = q.first 
          to[idx] = q.last
        else
          from[idx] = to[idx] = q
        end
      else
        from.set_min(idx)
        to.set_max(idx)
      end
    }

    raise ArgumentError unless (query.keys - used_keys).empty?

    return from, to
  end

  def self.db_query(db, query={}, &block)
    from, to = build_query(query)
    item = new()
    db.query(from, to, item, &block)
  end

  def self.db_query_to_a(db, query={})
    arr = []
    db_query(db, query) do |item|
      arr << item.dup
    end
    arr
  end

  def self.db_query_into(db, itemarr=nil, query={})
    from, to = build_query(query)
    item = new()
    itemarr ||= make_array(1024)
    if db.query_into(from, to, item, itemarr)
      return itemarr
    else
      raise "query_into failed"
    end
  end

  def self.db_query_min(db, query={})
    from, to = build_query(query)
    item = new()
    return db.query_min(from, to, item)
  end

  #
  # Example usage: def_parser_descr(:uid, :campaign_id, nil, [:timestamp, :fixint, 3])
  #
  def self.def_parse_descr(*args)
    args.map {|arg|
      case arg 
      when nil
        nil # skip
      when Symbol
        idx = __info().index {|fld| fld.first == arg}
        idx || raise
      when Array
        id, type, extra = *arg
        idx = __info().index {|fld| fld.first == id} || raise
        if type == :fixint
          (((extra << 8) | 0x01) << 32) | idx
        else
          raise ArgumentError
        end
      else
        raise ArgumentError
      end
    }
  end

end

class RecordModelInstanceArray
  alias old_initialize initialize

  attr_reader :model_klass

  def initialize(model_klass, n=16, expandable=true)
    @model_klass = model_klass
    old_initialize(model_klass, n, expandable)
  end

  include Enumerable

  alias old_each each
  def each(instance=nil, &block)
    old_each(instance || @model_klass.new, &block)
  end

  def inspect
    [self.class, to_a]
  end

  def to_a
    a = []
    each {|i| a << i.dup}
    a
  end
end


class RecordModel::LineParser
  require 'thread'

  def self.import(io, db, item_class, array_item_class, line_parse_descr, array_sz=2**22,
    report_failures=false, report_progress_every=1_000_000, &block)

    parser = new(db, item_class, array_item_class, line_parse_descr, array_sz,
                 report_failures, report_progress_every)
    parser.start
    res = parser.import(io, &block)
    parser.start
    return res
  end

  def initialize(db, item_class, array_item_class, line_parse_descr, array_sz=2**22,
    report_failures=false, report_progress_every=1_000_000)
    @db = db
    @item_class = item_class
    @item = @item_class.new
    @array_item_class = array_item_class
    @line_parse_descr = line_parse_descr
    @report_failures = report_failures
    @report_progress_every = report_progress_every

    @lines_read, @lines_ok = 0, 0

    @inq, @outq = Queue.new, Queue.new
    # two arrays so that the log line parser and DB insert can work in parallel
    2.times { @outq << @array_item_class.make_array(array_sz, false) }
  end

  def start
    raise unless @outq.size == 2
    raise unless @inq.size == 0
    raise if @thread
    @thread = start_db_thread(@inq, @outq) 
  end

  def stop
    # Remove all packets from @outq and send it back into @inq to be processed
    # in case there are some records left.
    (1..2).map { @outq.pop }.each {|packet| @inq << packet }
    @inq << :end
    @thread.join
    @thread = nil
  end

  #
  # Method import has to be used together with start() and stop().
  #
  def import(io, &block)
    line_parse_descr = @line_parse_descr
    report_failures = @report_failures
    report_progress_every = @report_progress_every

    item = @item

    arr = @outq.pop
    lines_read = @lines_read
    lines_ok = @lines_ok

    while line = io.gets
      lines_read += 1
      begin
        if arr.full?
          @inq << arr 
	  arr = @outq.pop
        end

        item.zero!
        error = item.parse_line(line, line_parse_descr)
        if new_item = convert_item(error, item)
          arr << new_item
          lines_ok += 1
        end
      rescue 
        if block and report_failures
	  block.call(:failure, [$!, line])
        end
      end # begin .. rescue
      if block and report_progress_every and (lines_read % report_progress_every) == 0
        block.call(:progress, [lines_read, lines_ok])
      end
    end # while

    @outq << arr

    diff_lines_read = lines_read - @lines_read 
    diff_lines_ok = lines_ok - @lines_ok
    @lines_read = lines_read
    @lines_ok = lines_ok

    return diff_lines_read, diff_lines_ok 
  end

  protected

  def convert_item(error, item)
    raise if error and error != -1
    return item
  end

  def store_packet(packet)
    begin
      @db.put_bulk(packet)
    rescue
      p $!
    end
  end

  def start_db_thread(inq, outq)
    Thread.new {
      loop do
        packet = inq.pop
        break if packet == :end
        store_packet(packet)
        packet.reset
        outq << packet
      end
    }
  end
end
