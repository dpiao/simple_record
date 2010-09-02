# Usage:
# require 'simple_record'
#
# class MyModel < SimpleRecord::Base
#
#   has_attributes :name, :age
#   are_ints :age
#
# end
#
# AWS_ACCESS_KEY_ID='XXXXX'
# AWS_SECRET_ACCESS_KEY='YYYYY'
# SimpleRecord.establish_connection(AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY)
#
## Save an object
# mm = MyModel.new
# mm.name = "Travis"
# mm.age = 32
# mm.save
# id = mm.id
# # Get the object back
# mm2 = MyModel.select(id)
# puts 'got=' + mm2.name + ' and he/she is ' + mm.age.to_s + ' years old'
#
# Forked off old ActiveRecord2sdb library.

require 'aws'
require 'base64'
require 'active_model'
require File.expand_path(File.dirname(__FILE__) + "/simple_record/attributes")
require File.expand_path(File.dirname(__FILE__) + "/simple_record/active_sdb")
require File.expand_path(File.dirname(__FILE__) + "/simple_record/callbacks")
require File.expand_path(File.dirname(__FILE__) + "/simple_record/encryptor")
require File.expand_path(File.dirname(__FILE__) + "/simple_record/exceptions")
require File.expand_path(File.dirname(__FILE__) + "/simple_record/errors")
require File.expand_path(File.dirname(__FILE__) + "/simple_record/json")
require File.expand_path(File.dirname(__FILE__) + "/simple_record/logging")
require File.expand_path(File.dirname(__FILE__) + "/simple_record/password")
require File.expand_path(File.dirname(__FILE__) + "/simple_record/results_array")
require File.expand_path(File.dirname(__FILE__) + "/simple_record/stats")
require File.expand_path(File.dirname(__FILE__) + "/simple_record/translations")


module SimpleRecord

    @@options = {}
    @@stats = SimpleRecord::Stats.new
    @@logging = false

    class << self;
        attr_accessor :aws_access_key, :aws_secret_key

        def enable_logging
            @@logging = true
        end

        def disable_logging
            @@logging = false
        end

        def logging?
            @@logging
        end

        # This can be used to log queries and what not to a file.
        # Params:
        # :select=>{:filename=>"file_to_write_to", :format=>"csv"}
        def log_usage(types={})
            @usage_logging_options = {} unless @usage_logging_options
            return if types.nil?
            types.each_pair do |type, options|
                options[:lines_between_flushes] = 100 unless options[:lines_between_flushes]
                @usage_logging_options[type] = options
            end
            #puts 'SimpleRecord.usage_logging_options=' + SimpleRecord.usage_logging_options.inspect
        end

        def close_usage_log(type)
            return unless @usage_logging_options[type]
            @usage_logging_options[type][:file].close if @usage_logging_options[type][:file]
        end

        def usage_logging_options
            @usage_logging_options
        end

        def stats
            @@stats
        end


        # Create a new handle to an Sdb account. All handles share the same per process or per thread
        # HTTP connection to Amazon Sdb. Each handle is for a specific account.
        # The +params+ are passed through as-is to Aws::SdbInterface.new
        # Params:
        #    { :server       => 'sdb.amazonaws.com'  # Amazon service host: 'sdb.amazonaws.com'(default)
        #      :port         => 443                  # Amazon service port: 80(default) or 443
        #      :protocol     => 'https'              # Amazon service protocol: 'http'(default) or 'https'
        #      :signature_version => '0'             # The signature version : '0' or '1'(default)
        #      :connection_mode  => :default         # options are
        #                                                  :default (will use best known safe (as in won't need explicit close) option, may change in the future)
        #                                                  :per_request (opens and closes a connection on every request to SDB)
        #                                                  :single (one thread across entire app)
        #                                                  :per_thread (one connection per thread)
        #                                                  :pool (uses a connection pool with a maximum number of connections - NOT IMPLEMENTED YET)
        #      :logger       => Logger Object        # Logger instance: logs to STDOUT if omitted
        def establish_connection(aws_access_key=nil, aws_secret_key=nil, params={})
            @aws_access_key = aws_access_key
            @aws_secret_key = aws_secret_key
            @@options.merge!(params)
            #puts 'SimpleRecord.establish_connection with options: ' + @@options.inspect
            SimpleRecord::ActiveSdb.establish_connection(aws_access_key, aws_secret_key, @@options)
        end

        def close_connection()
            SimpleRecord::ActiveSdb.close_connection
        end

        def options
            @@options
        end

    end

    class Base < SimpleRecord::ActiveSdb::Base

        include ActiveModel::Conversion
        include ActiveModel::Naming
        include ActiveModel::Validations
        include ActiveModel::Serialization

        include SimpleRecord::Translations
#        include SimpleRecord::Attributes
        extend SimpleRecord::Attributes
        include SimpleRecord::Callbacks
        include SimpleRecord::Json
        include SimpleRecord::Logging
        extend SimpleRecord::Logging::ClassMethods


        def self.extended(base)

        end

        def initialize(attrs={})
            # todo: Need to deal with objects passed in. iterate through belongs_to perhaps and if in attrs, set the objects id rather than the object itself

            initialize_base(attrs)

            # Convert attributes to sdb values
            attrs.each_pair do |name, value|
                set(name, value, true)
            end
        end

        def initialize_base(attrs={})

            #we have to handle the virtuals.
            Attributes.handle_virtuals(attrs)

            # todo: we could try replacing this with ActiveModel::Errors.new, http://github.com/rails/rails/tree/master/activemodel
            @errors=SimpleRecord_errors.new
            @dirty = {}

            @attributes = {} # sdb values
            @attributes_rb = {} # ruby values
            @lobs = {}
            @new_record = true

        end

        def initialize_from_db(attrs={})
            initialize_base(attrs)
            attrs.each_pair do |k, v|
                @attributes[k.to_s] = v
            end
        end


        def self.inherited(base)
            #puts 'SimpleRecord::Base is inherited by ' + base.inspect
            Callbacks.setup_callbacks(base)

#            base.has_strings :id
            base.has_dates :created, :updated
            base.before_create :set_created, :set_updated
            base.before_update :set_updated

        end


        def defined_attributes_local
            # todo: store this somewhere so it doesn't keep going through this
            ret = self.class.defined_attributes
            ret.merge!(self.class.superclass.defined_attributes) if self.class.superclass.respond_to?(:defined_attributes)
        end


        attr_accessor :errors

        class << self;
            attr_accessor :domain_prefix, :use_module_names
        end

        #@domain_name_for_class = nil

        @@cache_store = nil
        # Set the cache to use
        def self.cache_store=(cache)
            @@cache_store = cache
        end

        def self.cache_store
            return @@cache_store
        end

        # If you want a domain prefix for all your models, set it here.
        def self.set_domain_prefix(prefix)
            #puts 'set_domain_prefix=' + prefix
            self.domain_prefix = prefix
        end

        # Same as set_table_name
        def self.set_table_name(table_name)
            set_domain_name table_name
        end

        # Sets the domain name for this class
        def self.set_domain_name(table_name)
            super
        end


        def domain
            self.class.domain
        end


        def self.domain
            unless @domain
                if SimpleRecord::Base.use_module_names
                    # TODO: THIS DOESN'T WORK YET
                    @domain = ""
                    name_split = name.split('::')
                    name_split.each_with_index do |n1, i|
                        # we'll pluralize the class name only
                        if i == name_split.size-1
                            if n1.respond_to?(:tableize)
                                @domain = n1.tableize
                            else
                                @domain = n1.downcase
                            end
                        end

                    end
                    puts 'n2=' + n2
                    set_domain_name @domain
                else
                    # This strips off the module if there is one.
                    n2 = name.split('::').last || name
                    puts 'n2=' + n2
                    if n2.respond_to?(:tableize)
#                    puts 'responds to tableize'
                        @domain = n2.tableize
                    else
                        @domain = n2.downcase
                    end
                    set_domain_name @domain
                end

            end
            # We do this here in case user changes the domain_prefix on the fly
            domain_name_for_class = (SimpleRecord::Base.domain_prefix || "") + @domain.to_s
            domain_name_for_class
        end

        def get_attribute_sdb(name)
            name = name.to_sym
            ret = strip_array(@attributes[sdb_att_name(name)])
            return ret
        end

        def has_id_on_end(name_s)
            name_s = name_s.to_s
            name_s.length > 3 && name_s[-3..-1] == "_id"
        end

        def get_att_meta(name)
            name_s = name.to_s
            att_meta = defined_attributes_local[name.to_sym]
            if att_meta.nil? && has_id_on_end(name_s)
                att_meta = defined_attributes_local[name_s[0..-4].to_sym]
            end
            return att_meta
        end

        def sdb_att_name(name)
            att_meta = get_att_meta(name)
            if att_meta.type == :belongs_to && !has_id_on_end(name.to_s)
                return "#{name}_id"
            end
            name.to_s
        end

        def strip_array(arg)
            if arg.class==Array
                if arg.length==1
                    ret = arg[0]
                else
                    ret = arg
                end
            else
                ret = arg
            end
            return ret
        end


        def make_dirty(arg, value)
            sdb_att_name = sdb_att_name(arg)
            arg = arg.to_s

#            puts "Marking #{arg} dirty with #{value}" if SimpleRecord.logging?
            if @dirty.include?(sdb_att_name)
                old = @dirty[sdb_att_name]
#                puts "#{sdb_att_name} was already dirty #{old}"
                @dirty.delete(sdb_att_name) if value == old
            else
                old = get_attribute(arg)
#                puts "dirtifying #{sdb_att_name} old=#{old.inspect} to new=#{value.inspect}" if SimpleRecord.logging?
                @dirty[sdb_att_name] = old if value != old
            end
        end

        def clear_errors
            @errors=SimpleRecord_errors.new
        end

        def []=(attribute, values)
            make_dirty(attribute, values)
            super
        end

        def [](attribute)
            super
        end


        def set_created
            set(:created, Time.now)
        end

        def set_updated
            set(:updated, Time.now)
        end

        # an aliased method since many people use created_at/updated_at naming convention
        def created_at
            self.created
        end

        # an aliased method since many people use created_at/updated_at naming convention
        def updated_at
            self.updated
        end

        def cache_store
            @@cache_store
        end

        def domain_ok(ex)
            if (ex.message().index("NoSuchDomain") != nil)
                #puts "Creating new SimpleDB Domain: " + domain
                self.class.create_domain
                return true
            end
            return false
        end

        def valid?
            errors.clear

#            run_callbacks(:validate)
            validate

            if new_record?
#                run_callbacks(:validate_on_create)
                validate_on_create
            else
#                run_callbacks(:validate_on_update)
                validate_on_update
            end

            errors.empty?
        end

        def new_record?
            # todo: new_record in activesdb should align with how we're defining a new record here, ie: if id is nil
            super
        end

        # Returns if the record is persisted, i.e. it�s not a new record and it was not destroyed.
        def persisted?
            !new_record?
        end

        def invalid?
            !valid?
        end

        def validate
            true
        end

        def validate_on_create
            true
        end

        def validate_on_update
            true
        end

        @create_domain_called = false

        # Options:
        #   - :except => Array of attributes to NOT save
        #   - :dirty => true - Will only store attributes that were modified. To make it save regardless and have it update the :updated value, include this and set it to false.
        #
        def save(options={})
#            puts 'SAVING: ' + self.inspect if SimpleRecord.logging?
            # todo: Clean out undefined values in @attributes (in case someone set the attributes hash with values that they hadn't defined)
            clear_errors
            # todo: decide whether this should go before pre_save or after pre_save? pre_save dirties "updated" and perhaps other items due to callbacks
            if options[:dirty]
#                puts '@dirtyA=' + @dirty.inspect
                return true if @dirty.size == 0 # Nothing to save so skip it
            end
            is_create = self[:id].nil?
            ok = pre_save(options)
            if ok
                begin
                    dirty = @dirty
#                    puts 'dirty before=' + @dirty.inspect
                    if options[:dirty]
#                        puts '@dirty=' + @dirty.inspect
                        return true if @dirty.size == 0 # This should probably never happen because after pre_save, created/updated dates are changed
                        options[:dirty_atts] = @dirty
                    end
                    to_delete = get_atts_to_delete
                    SimpleRecord.stats.saves += 1
#                    puts 'SELF BEFORE super=' + self.inspect
#                    puts 'dirty before2=' + @dirty.inspect
                    if super(options)
#                        puts 'dirty super=' + @dirty.inspect
#                        puts 'SELF AFTER super=' + self.inspect
                        self.class.cache_results(self)
                        delete_niled(to_delete)
                        save_lobs(dirty)
                        after_save_cleanup
                        if (is_create ? run_after_create : run_after_update) && run_after_save
#                            puts 'all good?'
                            return true
                        else
                            return false
                        end
                    else
                        return false
                    end
                rescue Aws::AwsError
                    # puts "RESCUED in save: " + $!
                    if (domain_ok($!))
                        if !@create_domain_called
                            @create_domain_called = true
                            save(options)
                        else
                            raise $!
                        end
                    else
                        raise $!
                    end
                end
            else
                #@debug = "not saved"
                return false
            end
        end

        def save_lobs(dirty=nil)
#            puts 'dirty.inspect=' + dirty.inspect
            dirty = @dirty if dirty.nil?
            defined_attributes_local.each_pair do |k, v|
                if v.type == :clob
#                    puts 'storing clob '
                    if dirty.include?(k.to_s)
                        begin
                            val = @lobs[k]
#                            puts 'val=' + val.inspect
                            s3_bucket.put(s3_lob_id(k), val)
                        rescue Aws::AwsError => ex
                            if ex.include? /NoSuchBucket/
                                s3_bucket(true).put(s3_lob_id(k), val)
                            else
                                raise ex
                            end
                        end
                        SimpleRecord.stats.s3_puts += 1
                    else
#                        puts 'NOT DIRTY'
                    end

                end
            end
        end

        def is_dirty?(name)
            # todo: should change all the dirty stuff to symbols?
#            puts '@dirty=' + @dirty.inspect
#            puts 'name=' +name.to_s
            @dirty.include? name.to_s
        end

        def s3
            Aws::S3.new(SimpleRecord.aws_access_key, SimpleRecord.aws_secret_key)
        end

        def s3_bucket(create=false)
            s3.bucket(s3_bucket_name, create)
        end

        def s3_bucket_name
            SimpleRecord.aws_access_key + "_lobs"
        end

        def s3_lob_id(name)
            self.id + "_" + name.to_s
        end

        def save!(options={})
            save(options) || raise(RecordNotSaved)
        end

        def save_with_validation!(options={})
            if valid?
                save
            else
                raise RecordInvalid.new(self)
            end
        end


        def self.get_encryption_key()
            key = SimpleRecord.options[:encryption_key]
#            if key.nil?
#                puts 'WARNING: Encrypting attributes with your AWS Access Key. You should use your own :encryption_key so it doesn\'t change'
#                key = connection.aws_access_key_id # default to aws access key. NOT recommended in case you start using a new key
#            end
            return key
        end


        def pre_save(options)

            is_create = self[:id].nil?
            ok = run_before_validation && (is_create ? run_before_validation_on_create : run_before_validation_on_update)
            return false unless ok

            validate()

            is_create ? validate_on_create : validate_on_update
#      puts 'AFTER VALIDATIONS, ERRORS=' + errors.inspect
            if (!@errors.nil? && @errors.length > 0)
#        puts 'THERE ARE ERRORS, returning false'
                return false
            end

            ok = run_after_validation && (is_create ? run_after_validation_on_create : run_after_validation_on_update)
            return false unless ok

            ok = respond_to?('before_save') ? before_save : true
            if ok
                if is_create && respond_to?('before_create')
                    ok = before_create
                elsif !is_create && respond_to?('before_update')
                    ok = before_update
                end
            end
            if ok
                ok = run_before_save && (is_create ? run_before_create : run_before_update)
            end
            if ok
                # Now translate all fields into SimpleDB friendly strings
#                convert_all_atts_to_sdb()
            end
            ok
        end


        def get_atts_to_delete
            to_delete = []
            changes.each_pair do |key, v|
                if v[1].nil?
                    to_delete << key
                    @attributes.delete(key)
                end
            end
#            @attributes.each do |key, value|
##                puts 'key=' + key.inspect + ' value=' + value.inspect
#                if value.nil? || (value.is_a?(Array) && value.size == 0) || (value.is_a?(Array) && value.size == 1 && value[0] == nil)
#                    to_delete << key
#                    @attributes.delete(key)
#                end
#            end
            return to_delete
        end

        # Run pre_save on each object, then runs batch_put_attributes
        # Returns
        def self.batch_save(objects, options={})
            results = []
            to_save = []
            if objects && objects.size > 0
                objects.each do |o|
                    ok = o.pre_save(options)
                    raise "Pre save failed on object [" + o.inspect + "]" if !ok
                    results << ok
                    next if !ok # todo: this shouldn't be here should it?  raises above
                    o.pre_save2
                    to_save << Aws::SdbInterface::Item.new(o.id, o.attributes, true)
                    if to_save.size == 25 # Max amount SDB will accept
                        connection.batch_put_attributes(domain, to_save)
                        to_save.clear
                    end
                end
            end
            connection.batch_put_attributes(domain, to_save) if to_save.size > 0
            objects.each do |o|
                o.save_lobs(nil)
            end
            results
        end

        #
        # Usage: ClassName.delete id
        #
        def self.delete(id)
            connection.delete_attributes(domain, id)
        end

        def self.delete_all(*params)
            # could make this quicker by just getting item_names and deleting attributes rather than creating objects
            obs = self.find(params)
            i = 0
            obs.each do |a|
                a.delete
                i+=1
            end
            return i
        end

        def self.destroy_all(*params)
            obs = self.find(params)
            i = 0
            obs.each do |a|
                a.destroy
                i+=1
            end
            return i
        end

        def delete()
            super
        end

        def destroy
            return run_before_destroy && delete && run_after_destroy
        end


        # Since SimpleDB supports multiple attributes per value, the values are an array.
        # This method will return the value unwrapped if it's the only, otherwise it will return the array.
        def get_attribute(name)
#            puts "GET #{arg}"
            # Check if this arg is already converted
            name_s = name.to_s
            name = name.to_sym
            att_meta = get_att_meta(name)
#            puts "att_meta for #{name}: " + att_meta.inspect
            if att_meta && att_meta.type == :clob
                ret = @lobs[name]
#                puts 'get_attribute clob ' + ret.inspect
                if ret
                    if ret.is_a? RemoteNil
                        return nil
                    else
                        return ret
                    end
                end
                # get it from s3
                unless new_record?
                    begin
                        ret = s3_bucket.get(s3_lob_id(name))
#                        puts 'got from s3 ' + ret.inspect
                        SimpleRecord.stats.s3_gets += 1
                    rescue Aws::AwsError => ex
                        if ex.include? /NoSuchKey/
                            ret = nil
                        else
                            raise ex
                        end
                    end

                    if ret.nil?
                        ret = RemoteNil.new
                    end
                end
                @lobs[name] = ret
                return nil if ret.is_a? RemoteNil
                return ret
            else
                @attributes_rb = {} unless @attributes_rb # was getting errors after upgrade.
                ret = @attributes_rb[name_s] # instance_variable_get(instance_var)
                return ret unless ret.nil?
                return nil if ret.is_a? RemoteNil
                ret = get_attribute_sdb(name)
                ret = sdb_to_ruby(name, ret)
                @attributes_rb[name_s] = ret
                return ret
            end

        end

        def set(name, value, dirtify=true)
#            puts "SET #{name}=#{value.inspect}" if SimpleRecord.logging?
#            puts "self=" + self.inspect
            attname = name.to_s # default attname
            name = name.to_sym
            att_meta = get_att_meta(name)
            store_rb_val = false
            if att_meta.nil?
                # check if it ends with id and see if att_meta is there
                ends_with = name.to_s[-3, 3]
                if ends_with == "_id"
#                    puts 'ends with id'
                    n2 = name.to_s[0, name.length-3]
#                    puts 'n2=' + n2
                    att_meta = defined_attributes_local[n2.to_sym]
#                    puts 'defined_attributes_local=' + defined_attributes_local.inspect
                    attname = name.to_s
                    attvalue = value
                    name = n2.to_sym
                end
                return if att_meta.nil?
            else
                if att_meta.type == :belongs_to
                    ends_with = name.to_s[-3, 3]
                    if ends_with == "_id"
                        att_name = name.to_s
                        attvalue = value
                    else
                        attname = name.to_s + '_id'
                        attvalue = value.nil? ? nil : value.id
                        store_rb_val = true
                    end
                elsif att_meta.type == :clob
                    make_dirty(name, value) if dirtify
                    @lobs[name] = value
                    return
                else
                    attname = name.to_s
                    attvalue = att_meta.init_value(value)
#                  attvalue = value
                    #puts 'converted ' + value.inspect + ' to ' + attvalue.inspect
                end
            end
            attvalue = strip_array(attvalue)
            make_dirty(name, attvalue) if dirtify
#            puts "ARG=#{attname.to_s} setting to #{attvalue}"
            sdb_val = ruby_to_sdb(name, attvalue)
#            puts "sdb_val=" + sdb_val.to_s
            @attributes[attname] = sdb_val
#            attvalue = wrap_if_required(name, attvalue, sdb_val)
#            puts 'attvalue2=' + attvalue.to_s

            if store_rb_val
                @attributes_rb[name.to_s] = value
            else
                @attributes_rb.delete(name.to_s)
            end

        end

        def set_attribute_sdb(name, val)
            @attributes[sdb_att_name(name)] = val
        end

        def delete_niled(to_delete)
#            puts 'to_delete=' + to_delete.inspect
            if to_delete.size > 0
#      puts 'Deleting attributes=' + to_delete.inspect
                SimpleRecord.stats.deletes += 1
                delete_attributes to_delete
                to_delete.each do |att|
                    att_meta = get_att_meta(att)
                    if att_meta.type == :clob
                        s3_bucket.key(s3_lob_id(att)).delete
                    end
                end
            end
        end

        def reload
            super()
        end


        def update_attributes(atts)
            set_attributes(atts)
            save
        end

        def update_attributes!(atts)
            set_attributes(atts)
            save!
        end


        def self.quote_regexp(a, re)
            a =~ re
            #was there a match?
            if $&
                before=$`
                middle=$&
                after=$'

                before =~ /'$/ #is there already a quote immediately before the match?
                unless $&
                    return "#{before}'#{middle}'#{quote_regexp(after, re)}" #if not, put quotes around the match
                else
                    return "#{before}#{middle}#{quote_regexp(after, re)}" #if so, assume it is quoted already and move on
                end
            else
                #no match, just return the string
                return a
            end
        end

        def self.create(attributes={})
#            puts "About to create in domain #{domain}"
            super
        end

        @@regex_no_id = /.*Couldn't find.*with ID.*/

        #
        # Usage:
        # Find by ID:
        #   MyModel.find(ID)
        #
        # Query example:
        #   MyModel.find(:all, :conditions=>["name = ?", name], :order=>"created desc", :limit=>10)
        #
        # Extra options:
        #   :per_token => the number of results to return per next_token, max is 2500.
        #   :consistent_read => true/false  --  as per http://developer.amazonwebservices.com/connect/entry.jspa?externalID=3572
        def self.find(*params)
            #puts 'params=' + params.inspect
            q_type = :all
            select_attributes=[]

            if params.size > 0
                q_type = params[0]
            end

            # Pad and Offset number attributes
            options = {}
            if params.size > 1
                options = params[1]
                #puts 'options=' + options.inspect
                #puts 'after collect=' + options.inspect
                convert_condition_params(options)
                per_token = options[:per_token]
                consistent_read = options[:consistent_read]
                if per_token || consistent_read then
                    op_dup = options.dup
                    op_dup[:limit] = per_token # simpledb uses Limit as a paging thing, not what is normal
                    op_dup[:consistent_read] = consistent_read
                    params[1] = op_dup
                end

            end
#            puts 'params2=' + params.inspect

            ret = q_type == :all ? [] : nil
            begin
                results=find_with_metadata(*params)
#                puts "RESULT=" + results.inspect
                write_usage(:select, domain, q_type, options, results)
                #puts 'params3=' + params.inspect
                SimpleRecord.stats.selects += 1
                if q_type == :count
                    ret = results[:count]
                elsif q_type == :first
                    ret = results[:items].first
                    # todo: we should store request_id and box_usage with the object maybe?
                    cache_results(ret)
                elsif results[:single]
                    ret = results[:single]
                    cache_results(ret)
                else
                    if results[:items] #.is_a?(Array)
                        cache_results(results[:items])
                        ret = SimpleRecord::ResultsArray.new(self, params, results, next_token)
                    end
                end
            rescue Aws::AwsError, SimpleRecord::ActiveSdb::ActiveSdbError => ex
#                puts "RESCUED: " + ex.message
                if (ex.message().index("NoSuchDomain") != nil)
                    # this is ok
                elsif (ex.message() =~ @@regex_no_id)
                    ret = nil
                else
                    raise ex
                end
            end
#            puts 'single2=' + ret.inspect
            return ret
        end

        def self.select(*params)
            return find(*params)
        end

        def self.all(*args)
            find(:all, *args)
        end

        def self.first(*args)
            find(:first, *args)
        end

        def self.count(*args)
            find(:count, *args)
        end

        # This gets less and less efficient the higher the page since SimpleDB has no way
        # to start at a specific row. So it will iterate from the first record and pull out the specific pages.
        def self.paginate(options={})
#            options = args.pop
#            puts 'paginate options=' + options.inspect if SimpleRecord.logging?
            page     = options[:page] || 1
            per_page = options[:per_page] || 50
#            total    = options[:total_entries].to_i
            options[:page] = page.to_i # makes sure it's to_i
            options[:per_page] = per_page.to_i
            options[:limit] = options[:page] * options[:per_page]
#            puts 'paging options=' + options.inspect
            fr = find(:all, options)
            return fr

        end


        def self.convert_condition_params(options)
            return if options.nil?
            conditions = options[:conditions]
            if !conditions.nil? && conditions.size > 1
                # all after first are values
                conditions.collect! { |x|
                    Translations.pad_and_offset(x)
                }
            end

        end

        def self.cache_results(results)
            if !cache_store.nil? && !results.nil?
                if results.is_a?(Array)
                    # todo: cache each result
                    results.each do |item|
                        class_name = item.class.name
                        id = item.id
                        cache_key = self.cache_key(class_name, id)
                        #puts 'caching result at ' + cache_key + ': ' + results.inspect
                        cache_store.write(cache_key, item, :expires_in =>30)
                    end
                else
                    class_name = results.class.name
                    id = results.id
                    cache_key = self.cache_key(class_name, id)
                    #puts 'caching result at ' + cache_key + ': ' + results.inspect
                    cache_store.write(cache_key, results, :expires_in =>30)
                end
            end
        end

        def self.cache_key(class_name, id)
            return class_name + "/" + id.to_s
        end

        @@debug=""

        def self.debug
            @@debug
        end

        def self.sanitize_sql(*params)
            return ActiveRecord::Base.sanitize_sql(*params)
        end

        def self.table_name
            return domain
        end

        def changed
            return @dirty.keys
        end

        def changed?
            return @dirty.size > 0
        end

        def changes
            ret = {}
            #puts 'in CHANGES=' + @dirty.inspect
            @dirty.each_pair { |key, value| ret[key] = [value, get_attribute(key)] }
            return ret
        end

        def after_save_cleanup
            @dirty = {}
        end

        def hash
            # same as ActiveRecord
            id.hash
        end

        private
        def set_attributes(atts)
            atts.each_pair do |k, v|
                set(k, v)
            end
        end

    end


    class Activerecordtosdb_subrecord_array
        def initialize(subname, referencename, referencevalue)
            @subname=subname.classify
            @referencename=referencename.tableize.singularize + "_id"
            @referencevalue=referencevalue
        end

        # Performance optimization if you know the array should be empty

        def init_empty
            @records = []
        end

        def load
            if @records.nil?
                @records = find_all
            end
            return @records
        end

        def [](key)
            return load[key]
        end

        def <<(ob)
            return load << ob
        end

        def count
            return load.count
        end

        def size
            return count
        end

        def each(*params, &block)
            return load.each(*params) { |record| block.call(record) }
        end

        def find_all(*params)
            find(:all, *params)
        end

        def empty?
            return load.empty?
        end

        def build(*params)
            params[0][@referencename]=@referencevalue
            eval(@subname).new(*params)
        end

        def create(*params)
            params[0][@referencename]=@referencevalue
            record = eval(@subname).new(*params)
            record.save
        end

        def find(*params)
            query=[:first, {}]
            #{:conditions=>"id=>1"}
            if params[0]
                if params[0]==:all
                    query[0]=:all
                end
            end

            if params[1]
                query[1]=params[1]
                if query[1][:conditions]
                    query[1][:conditions]=SimpleRecord::Base.sanitize_sql(query[1][:conditions])+" AND "+ SimpleRecord::Base.sanitize_sql(["#{@referencename} = ?", @referencevalue])
                    #query[1][:conditions]=Activerecordtosdb.sanitize_sql(query[1][:conditions])+" AND id='#{@id}'"
                else
                    query[1][:conditions]=["#{@referencename} = ?", @referencevalue]
                    #query[1][:conditions]="id='#{@id}'"
                end
            else
                query[1][:conditions]=["#{@referencename} = ?", @referencevalue]
                #query[1][:conditions]="id='#{@id}'"
            end

            return eval(@subname).find(*query)
        end

    end

    # This is simply a place holder so we don't keep doing gets to s3 or simpledb if already checked.
    class RemoteNil

    end


end

