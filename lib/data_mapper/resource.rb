require 'set'

module DataMapper

  module Resource

    def self.new(default_name, &b)
      x = Class.new
      x.send(:include, self)
      x.instance_variable_set(:@storage_names, Hash.new { |h,k| h[k] = repository(k).adapter.resource_naming_convention.call(default_name) })
      x.instance_eval(&b)
      x
    end

    @@including_classes = Set.new

    # +----------------------
    # Resource module methods

    def self.included(base)
      base.extend ClassMethods
      base.extend DataMapper::Associations
      base.send(:include, DataMapper::Hook)
      base.send(:include, DataMapper::Scope)
      base.send(:include, DataMapper::AutoMigrations)
      base.send(:include, DataMapper::Types)
      @@including_classes << base
    end

    # Return all classes that include the DataMapper::Resource module
    #
    # ==== Returns
    # Set:: A Set containing the including classes
    #
    # -
    # @public
    def self.including_classes
      @@including_classes
    end

    # +---------------
    # Instance methods

    attr_accessor :collection

    def attribute_get(name)
      property  = self.class.properties(repository.name)[name]
      ivar_name = property.instance_variable_name

      unless new_record? || instance_variable_defined?(ivar_name)
        lazy_load(name)
      end

      value = instance_variable_get(ivar_name)

      if value.nil? && new_record? && !property.options[:default].nil?
        value = property.default_for(self)
      end

      property.custom? ? property.type.load(value, property) : value
    end

    def attribute_set(name, value)
      property  = self.class.properties(repository.name)[name]
      ivar_name = property.instance_variable_name

      if property.lock?
        instance_variable_set("@shadow_#{name}", instance_variable_get(ivar_name))
      end

      dirty_attributes << property

      instance_variable_set(ivar_name, property.custom? ? property.type.dump(value, property) : property.typecast(value))
    end

    def eql?(other)
      return true if object_id == other.object_id
      return false unless other === self.class
      attributes == other.attributes
    end

    alias == eql?

    def inspect
      attrs = attributes.inject([]) {|s,(k,v)| s << "#{k}=#{v.inspect}"}
      "#<#{self.class.name} #{attrs.join(" ")}>"
    end

    def pretty_print(pp)
      attrs = attributes.inject([]) {|s,(k,v)| s << [k,v]}
      pp.group(1, "#<#{self.class.name}", ">") do
        pp.breakable
        pp.seplist(attrs) do |k_v|
          pp.text k_v[0].to_s
          pp.text " = "
          pp.pp k_v[1]
        end
      end
    end

    def repository
      @collection ? @collection.repository : self.class.repository
    end

    def child_associations
      @child_associations ||= []
    end

    def parent_associations
      @parent_associations ||= []
    end

    # default id method to return the resource id when there is a
    # single key, and the model was defined with a primary key named
    # something other than id
    def id
      key = self.key
      key.first if key.size == 1
    end

    def key
      key = []
      self.class.key(repository.name).each do |property|
        value = instance_variable_get(property.instance_variable_name)
        key << value if !value.nil?
      end
      key
    end

    def readonly!
      @readonly = true
    end

    def readonly?
      @readonly == true
    end

    def save
      repository.save(self)
    end

    def destroy
      repository.destroy(self)
    end

    def attribute_loaded?(name)
      property = self.class.properties(repository.name)[name]
      instance_variable_defined?(property.instance_variable_name)
    end

    def loaded_attributes
      names = []
      self.class.properties(repository.name).each do |property|
        names << property.name if instance_variable_defined?(property.instance_variable_name)
      end
      names
    end

    def dirty_attributes
      @dirty_attributes ||= Set.new
    end

    def dirty?
      dirty_attributes.any?
    end

    def attribute_dirty?(name)
      property = self.class.properties(repository.name)[name]
      dirty_attributes.include?(property)
    end

    def shadow_attribute_get(name)
      instance_variable_get("@shadow_#{name}")
    end

    def reload
      @collection.reload(:fields => loaded_attributes)
    end
    alias reload! reload

    # Returns <tt>true</tt> if this model hasn't been saved to the
    # database, <tt>false</tt> otherwise.
    def new_record?
      !defined?(@new_record) || @new_record
    end

    def attributes
      pairs = {}

      self.class.properties(repository.name).each do |property|
        if property.reader_visibility == :public
          pairs[property.name] = send(property.getter)
        end
      end

      pairs
    end

    # Mass-assign mapped fields.
    def attributes=(values_hash)
      values_hash.each_pair do |k,v|
        setter = "#{k.to_s.sub(/\?\z/, '')}="
        # We check #public_methods and not Class#public_method_defined? to
        # account for singleton methods.
        if public_methods.include?(setter)
          send(setter, v)
        end
      end
    end

    def update_attributes(hash, *update_only)
      raise 'Update takes a hash as first parameter' unless hash.is_a?(Hash)
      loop_thru = update_only.empty? ? hash.keys : update_only
      loop_thru.each {|attr|  send("#{attr}=", hash[attr])}
    end

    #
    # Produce a new Transaction for the class of this Resource
    #
    # ==== Returns
    # DataMapper::Adapters::Transaction:: A new DataMapper::Adapters::Transaction with all
    # DataMapper::Repositories of the class of this DataMapper::Resource added.
    #
    #-
    # @public
    def transaction(&block)
      self.class.transaction(&block)
    end

    private

    def initialize(*args) # :nodoc:
      validate_resource
      initialize_with_attributes(*args) unless args.empty?
    end

    def initialize_with_attributes(details) # :nodoc:
      case details
      when Hash             then self.attributes = details
      when Resource, Struct then self.private_attributes = details.attributes
        # else raise ArgumentError, "details should be a Hash, Resource or Struct\n\t#{details.inspect}"
      end
    end

    def validate_resource # :nodoc:
      if self.class.properties.empty? && self.class.relationships.empty?
        raise IncompleteResourceError, 'Resources must have at least one property or relationship to be initialized.'
      end

      if self.class.properties.key.empty?
        raise IncompleteResourceError, 'Resources must have a key.'
      end
    end

    def lazy_load(name)
      return unless @collection
      @collection.reload(:fields => self.class.properties(repository.name).lazy_load_context(name))
    end

    def private_attributes
      pairs = {}

      self.class.properties(repository.name).each do |property|
        pairs[property.name] = send(property.getter)
      end

      pairs
    end

    def private_attributes=(values_hash)
      values_hash.each_pair do |k,v|
        setter = "#{k.to_s.sub(/\?\z/, '')}="
        if respond_to?(setter) || private_methods.include?(setter)
          send(setter, v)
        end
      end
    end

    module ClassMethods
      def self.extended(base)
        base.instance_variable_set(:@storage_names, Hash.new { |h,k| h[k] = repository(k).adapter.resource_naming_convention.call(base.name) })
        base.instance_variable_set(:@properties,    Hash.new { |h,k| h[k] = k == :default ? PropertySet.new : h[:default].dup })
      end

      def inherited(target)
        target.instance_variable_set(:@storage_names, @storage_names.dup)
        target.instance_variable_set(:@properties, Hash.new { |h,k| h[k] = k == :default ? self.properties(:default).dup(target) : h[:default].dup })
      end

      #
      # Get the repository with a given name, or the default one for the current context, or the default one for this class.
      #
      # ==== Parameters
      # name<Symbol>:: The name of the repository wanted.
      # block<Block>:: Block to execute with the fetched repository as parameter.
      #
      # ==== Returns
      # if given a block
      # Object:: Whatever the block returns.
      # else
      # DataMapper::Repository:: The asked for Repository.
      #
      #-
      # @public
      def repository(name = nil, &block)
        if name
          DataMapper.repository(name, &block)
        elsif Repository.context.last
          DataMapper.repository(nil, &block)
        else
          DataMapper.repository(default_repository_name, &block)
        end
      end

      def storage_name(repository_name = default_repository_name)
        @storage_names[repository_name]
      end

      def storage_names
        @storage_names
      end

      def property(name, type, options = {})
        property = Property.new(self, name, type, options)
        @properties[repository.name] << property

        # Add property to the other mappings as well if this is for the default repository.
        if repository.name == default_repository_name
          @properties.each_pair do |repository_name, properties|
            next if repository_name == default_repository_name
            properties << property
          end
        end

        #Add the property to the lazy_loads set for this resources repository only
        # TODO Is this right or should we add the lazy contexts to all repositories?
        if property.lazy?
          context = options.fetch(:lazy, :default)
          context = :default if context == true

          Array(context).each do |item|
            @properties[repository.name].lazy_context(item) << name
          end
        end

        property
      end

      def repositories
        [repository] + @properties.keys.collect do |repository_name| DataMapper.repository(repository_name) end
      end

      def properties(repository_name = default_repository_name)
        @properties[repository_name]
      end

      def key(repository_name = default_repository_name)
        @properties[repository_name].key
      end

      def inheritance_property(repository_name = default_repository_name)
        @properties[repository_name].inheritance_property
      end

      def get(*key)
        repository.get(self, key)
      end

      def [](key)
        get(key) || raise(ObjectNotFoundError, "Could not find #{self.name} with key: #{key.inspect}")
      end

      def all(options = {})
        repository(options[:repository]).all(self, options)
      end

      def first(options = {})
        repository(options[:repository]).first(self, options)
      end

      def create(attributes = {})
        resource = allocate
        resource.send(:initialize_with_attributes, attributes)
        resource.save
        resource
      end

      def create!(attributes = {})
        resource = create(attributes)
        raise PersistenceError, "Resource not saved: :new_record => #{resource.new_record?}, :dirty_attributes => #{resource.dirty_attributes.inspect}" if resource.new_record?
        resource
      end

      # TODO SPEC
      def copy(source, destination, options = {})
        repository(destination) do
          repository(source).all(self, options).each do |resource|
            self.create(resource)
          end
        end
      end

      #
      # Produce a new Transaction for this Resource class
      #
      # ==== Returns
      # DataMapper::Adapters::Transaction:: A new DataMapper::Adapters::Transaction with all
      # DataMapper::Repositories of this DataMapper::Resource added.
      #
      #-
      # @public
      def transaction(&block)
        DataMapper::Transaction.new(self, &block)
      end

      def exists?(repo_name = default_repository_name)
        repository(repo_name).storage_exists?(storage_name(repo_name))
      end

      private

      def default_repository_name
        Repository.default_name
      end

      def method_missing(method, *args, &block)
        if relationship = relationships(repository.name)[method]
           clazz = if self == relationship.child_model
             relationship.parent_model
           else
             relationship.child_model
           end
           return DataMapper::Query::Path.new(repository, [relationship],clazz)
        end

        if property = properties(repository.name)[method]
          return property
        end
        super
      end

    end # module ClassMethods
  end # module Resource
end # module DataMapper
