require "model/configure"
require "model/template"
require 'tree'
require 'pp'
require 'base64'
require "model/data_processor"
require "json"
require "fileutils"
require "model/hash_extend"
require 'model/trace_cache'
class Trace
  attr_reader :data,:userid,:traceid,:start_time_ns,:start_time,:duration,:type,:frames,:http_response,:http_request,:endpoint,:body_type
  attr_accessor :start_time,:traceid
  @@root = Configuration::ROOT
  @@cache = TraceCache.new(1024*64,15*60)
  include DataProcessor
  include Comparable
  def initialize data 
    @data = JSON.parse data
    @userid = @data["user_id"]
    @duration = @data["trace_duration"]
    @traceid = @data["trace_id"]
    @endpoint = @data["endpoint"]
    @type = @data["trace_group"]
    @start_time = @data["trace_start_time"].to_i
    @start_time_ns = @data["trace_start_time_ns"].to_i
    @frames = @data["frames"]
    @endpoint = @data["endpoint"]
    @http_response =  @data["http_response"]
    @http_request = @data["http_request"]
	if @http_response
		filter @http_response
		body_file = write_body @http_response["body"] if @http_response["body"]
	    @body_type = get_body_type body_file if body_file
    end
    filter @http_request  if @http_request
	@frame_tree_root_node = createTree(self)
  end
  #search operation_id that matched keyword
  def search keyword
	result = Set.new
	matched = Array.new
    @frame_tree_root_node.each{|node|
	  if node.content =~ /#{keyword}/i
	    matched << node.name
	  end
	}	
	@frame_tree_root_node.each{|node|
	  if node.is_root?
	    result << node.name
	  elsif matched.include? node.name
		result << node.name #add id
		node.parentage.each{|item|
		  result << item.name
		}
	  end
	}
	@frame_tree_root_node.print_tree
	result
  end
  def get_body_type filename
    result = %x(file -b #{filename})
	return :png if result =~ /png/i
	:normal
  end
  def filter map
    map["headers"]=format(map["headers"])
    map.delete_invalid_entrys Configuration::INVALID_VALUES,:value
    map.delete_invalid_entrys Configuration::INVALID_KEYS,:key
  end 
  def read_body 
	begin
	  body = File.read(body_file_name)
	  return Base64.encode64(body) if @body_type == :png
	  body.delete("\000")
	rescue Exception => err
	  Log.log.warn("#{err}")
	  ""
	end
  end
  def self.active_time
    Configuration::ACTIVE_TIME
  end
  def self.cache
    @@cache
  end
  
  def body_file_name
    filename()+"_body"
  end
  def write_body string
	p "string #{string.length}"
	str = Base64.decode64(string)
	content_len = @http_response['contentLength']
    file = body_file_name
    f = File.new(file,'w')
	str = str[0...content_len.to_i]if content_len
    f.write(str)
    f.close
	file
  end
  def get_http_response_headers
    (@http_response==nil)?nil:@http_response["headers"]
  end
  def get_http_request_headers
    (@http_request==nil)?nil:@http_request["headers"]
  end
  def isHttp?
    return true if @type.casecmp("http")
    false
  end
  
  def self.users
    @@traces.keys
  end
  def self.get_traces_by_user user
    @@traces[user]
  end
  #as trace active time's 15min(max),so check if the trace is expire
  def expires? 
    (Time.now.to_f*1000 - Trace.active_time) > @start_time
  end
  
  def filename
    date = Time.at(@start_time.to_f/1000.0).strftime("%Y-%m-%d");
    File.join(@@root,@userid,date,@traceid)    
  end
  def persist
     file = filename()
     dir = File.dirname(file)    
     FileUtils.mkdir_p dir unless  File.exists? dir
     File.open(file,'w') do |f|
       f.puts JSON.pretty_generate(@data)  
     end
  end
  #actually not here 
   def dispatch userid
    traces = Trace.get_traces_by_user userid
    group_by_time Time.now.to_f*1000,15,15*1000,traces
  end 

  def self.get_trace userid,traceid
    dirname = Trace.get_user_dir_by_userid userid
    files = DataProcessor::find_file dirname,traceid
    p "may be some error in your program,as traceid is unique." if files.length >1
    unless files.empty?
      return  Trace.get_trace_from_file files[0]
    end
    return nil
  end
  
  def <=> o 
    self.duration <=> o.duration
  end 
 
  def self.get_trace_from_file path
    data = File.read(path)
    Trace.new data
  end
  def self.get_user_dir_by_userid userid
    File.join(@@root,userid) 
  end
  def self.get_all_traceids_by_userid userid
    dirname = Trace.get_user_dir_by_userid userid
    return unless File.exists? dirname
    traceids = Hash.new
    DataProcessor::traverse_dir dirname,traceids
    #p "traceid"
	
    return Template.template_all_traces traceids   #=>{date=>[trace]}
  end
end

