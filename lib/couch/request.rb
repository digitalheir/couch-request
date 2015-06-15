require 'couch/request/version'
require 'net/http'
require 'cgi'
require 'json'
require 'objspace'
require 'openssl'

module Couch
  module BasicRequest
    def delete(uri)
      req=Net::HTTP::Delete.new(uri)
      req.basic_auth @options[:name], @options[:password]
      request(req)
    end

    def head(uri)
      req = Net::HTTP::Head.new(uri)
      req.basic_auth @options[:name], @options[:password]
      request(req, fail_silent=true)
    end

    def get(uri)
      req = Net::HTTP::Get.new(uri)
      req.basic_auth @options[:name], @options[:password]
      request(req)
    end

    def put(uri, json)
      req = Net::HTTP::Put.new(uri)
      req.basic_auth @options[:name], @options[:password]
      req['Content-Type'] = 'text/plain;charset=utf-8'
      req.body = json
      request(req)
    end

    def post(uri, json)
      req = Net::HTTP::Post.new(uri)
      req.basic_auth @options[:name], @options[:password]
      req['Content-Type'] = 'application/json;charset=UTF-8'
      req.body = json
      request(req)
    end


    def request(req, open_timeout=5*30, read_timeout=5*30, fail_silent=false)
      res = Net::HTTP.start(@url.host, @url.port,
                            :use_ssl => @url.scheme =='https') do |http|
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        http.request(req)
      end
      unless fail_silent or res.kind_of?(Net::HTTPSuccess)
        # puts "CouchDb responsed with error code #{res.code}"
        handle_error(req, res)
      end
      res
    end

    def create_postfix(query_params, default='')
      if query_params
        params_a = []
        query_params.each do |key, value|
          params_a << "#{key}=#{value}"
        end
        postfix = "?#{params_a.join('&')}"
      else
        postfix = default
      end
      postfix
    end

    def handle_error(req, res)
      raise RuntimeError.new("#{res.code}:#{res.message}\nMETHOD:#{req.method}\nURI:#{req.path}\n#{res.body}")
    end

    module Get
      # Returns parsed doc from database
      def get_doc(database, id)
        res = get("/#{database}/#{CGI.escape(id)}")
        JSON.parse(res.body)
      end

      def get_attachment_str(db, id, attachment)
        uri = URI::encode "/#{db}/#{id}/#{attachment}"
        get(uri).body
      end
    end

    module Head
      # Returns revision for given document
      def get_rev(database, id)
        res = head("/#{database}/#{CGI.escape(id)}")
        if res.code == '200'
          res['etag'].gsub(/^"|"$/, '')
        else
          nil
        end
      end
    end
  end

  # Bulk requests; use methods from Couch::BasicRequest
  module BulkRequest
    module Get
      # Returns an array of the full documents for given database, possibly filtered with given parameters.
      # We recommend you use all_docs instead.
      #
      # Note that the 'include_docs' parameter must be set to true for this.
      def get_all_docs(database, params)
        unless params.include? 'include_docs' or params.include? :include_docs
          params.merge!({:include_docs => true})
        end
        postfix = create_postfix(params)
        uri = URI::encode "/#{database}/_all_docs#{postfix}"
        res = get(uri)
        result = JSON.parse(res.body)
        docs = []
        result['rows'].each do |row|
          if row['error'] or !row['doc']
            puts 'Found row with error:'
            puts "#{row['key']}: #{row['error']}"
            puts "#{row['reason']}"
          else
            docs << row['doc']
          end
        end
        docs
      end

      # If a block is given, performs the block for each +limit+-sized slice of _all_docs.
      # If no block is given, returns all docs by appending +limit+-sized slices of _all_docs.
      #
      # This method assumes your docs dont have the high-value Unicode character \ufff0. If it does, then behaviour is undefined. The reason why we use the startkey parameter instead of skip is that startkey is faster.
      def all_docs(db, limit=500, opts={}, &block)
        all_docs=[]
        start_key=nil
        loop do
          opts = opts.merge({limit: limit})
          if start_key
            opts[:startkey]=start_key
          end
          docs = get_all_docs(db, opts)
          if docs.length <= 0
            break
          else
            start_key = handle_new_bulk_get(all_docs, block, docs)
          end
        end
        all_docs.flatten
      end

      # Returns an array of all rows for given view.
      #
      # We recommend you use rows_for_view instead.
      def get_rows_for_view(database, design_doc, view, query_params=nil)
        postfix = create_postfix(query_params)
        uri = URI::encode "/#{database}/_design/#{design_doc}/_view/#{view}#{postfix}"
        res = get(uri)
        JSON.parse(res.body.force_encoding('utf-8'))['rows']
      end

      # If a block is given, performs the block for each +limit+-sized slice of rows for the given view.
      # If no block is given, returns all rows by appending +limit+-sized slices of the given view.
      #
      # This method assumes your keys dont have the high-value Unicode character \ufff0. If it does, then behaviour is undefined. The reason why we use the startkey parameter instead of skip is that startkey is faster.
      def rows_for_view(db, design_doc, view, limit=500, opts={}, &block)
        all_docs=[]
        start_key=nil
        loop do
          opts = opts.merge({limit: limit})
          if start_key
            opts[:startkey]=start_key
          end
          docs = get_rows_for_view(db, design_doc, view, opts)
          if docs.length <= 0
            break
          else
            start_key = handle_new_bulk_get(all_docs, block, docs)
          end
        end
        all_docs.flatten
      end

      # Returns an array of all ids in the database
      def get_all_ids(database, params)
        ids=[]
        postfix = create_postfix(params)

        uri = URI::encode "/#{database}/_all_docs#{postfix}"
        res = get(uri)
        result = JSON.parse(res.body)
        result['rows'].each do |row|
          if row['error']
            puts "#{row['key']}: #{row['error']}"
            puts "#{row['reason']}"
          else
            ids << row['id']
          end
        end
        ids
      end

      # Returns an array of all ids in the database
      def all_ids(db, limit=500, opts={}, &block)
        all_docs=[]
        start_key=nil
        loop do
          opts = opts.merge({limit: limit})
          if start_key
            opts[:startkey]=start_key
          end
          docs = get_all_ids(db, opts)
          if docs.length <= 0
            break
          else
            start_key = handle_new_bulk_get(all_docs, block, docs)
          end
        end
        all_docs.flatten
      end

      # Returns an array of the full documents for given view, possibly filtered with given parameters. Note that the 'include_docs' parameter must be set to true for this.
      #
      # Also consider using `docs_for_view`
      def get_docs_for_view(db, design_doc, view, params={})
        params.merge!({:include_docs => true})
        rows = get_rows_for_view(db, design_doc, view, params)
        docs = []
        rows.each do |row|
          docs << row['doc']
        end
        docs
      end

      # If a block is given, performs the block for each +limit+-sized slice of documents for the given view.
      # If no block is given, returns all docs by appending +limit+-sized slices of the given view.
      #
      # This method assumes your keys dont have the high-value Unicode character \ufff0. If it does, then behaviour is undefined. The reason why we use the startkey parameter instead of skip is that startkey is faster.
      def docs_for_view(db, design_doc, view, limit=500, opts={}, &block)
        all_docs=[]
        start_key=nil
        loop do
          opts = opts.merge({limit: limit})
          if start_key
            opts[:startkey]=start_key
          end
          docs = get_docs_for_view(db, design_doc, view, opts)
          if docs.length <= 0
            break
          else
            start_key = handle_new_bulk_get(all_docs, block, docs)
          end
        end
        all_docs.flatten
      end

      private
      def handle_new_bulk_get(all_docs, block, docs)
        if block
          block.call(docs)
        else
          all_docs < docs
        end
        "\"#{docs.last['_id']}\\ufff0\""
      end
    end

    module Delete
      def bulk_delete(database, docs)
        docs.each do |doc|
          doc[:_deleted]=true
        end
        json = {:docs => docs}.to_json
        post("/#{database}/_bulk_docs", json)
      end
    end

    module Flush
      # Flushes the given hashes to CouchDB
      def flush_bulk(database, docs)
        body = {:docs => docs}.to_json #.force_encoding('utf-8')
        post("/#{database}/_bulk_docs", body)
      end

      def flush_bulk_throttled(db, docs, max_size_mb: 15, max_array_length: 300, &block)
        # puts "Flushing #{docs.length} docs"
        bulk = []
        bytesize = 0
        docs.each do |doc|
          bulk << doc
          # TODO: Note that this may be inexact; see documentation for ObjectSpace.memsize_of
          bytesize += ObjectSpace.memsize_of doc
          if bytesize/1024/1024 > max_size_mb or bulk.length >= max_array_length
            handle_bulk_flush(bulk, db, block)
            bytesize=0
          end
        end
        if bulk.length > 0
          handle_bulk_flush(bulk, db, block)
        end
      end


      def flush_bulk_if_big_enough(db, docs, flush_size_mb=10, max_array_length=300)
        if get_bytesize_array(docs) >= flush_size_mb*1024*1024 or docs.length >= max_array_length
          flush_bulk_throttled(db, docs)
          docs.clear
        end
      end

      def get_bytesize_array(docs)
        bytesize = 0
        docs.each do |doc|
          # TODO: Note that this may be inexact; see documentation for ObjectSpace.memsize_of
          bytesize += ObjectSpace.memsize_of doc
        end
        bytesize
      end

      private
      def handle_bulk_flush(bulk, db, block)
        res = flush_bulk(db, bulk)
        error_count=0
        if res.body
          begin
            JSON.parse(res.body).each do |d|
              error_count+=1 if d['error']
            end
          end
        end
        if error_count > 0
          puts "Bulk request completed with #{error_count} errors"
        end
        if block
          block.call(res)
        end
        bulk.clear
      end
    end
  end

  class Server
    def initialize(url, options)
      if url.is_a? String
        url = URI(url)
      end
      @url = url
      @options = options
      @options[:use_ssl] ||= true
    end

    include BasicRequest
    include BasicRequest::Head
    include BasicRequest::Get
    include BulkRequest::Get
    include BulkRequest::Delete
    include BulkRequest::Flush

    private
  end
end
