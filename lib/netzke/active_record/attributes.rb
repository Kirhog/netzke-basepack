module Netzke::ActiveRecord::Attributes
  extend ActiveSupport::Concern

  module ClassMethods
    # Define or configure an attribute.
    # Example:
    #   netzke_attribute :recent, :type => :boolean, :read_only => true
    def netzke_attribute(name, options = {})
      name = name.to_s
      options[:attr_type] = options.delete(:type) || :string
      declared_attrs = read_inheritable_attribute(:netzke_declared_attributes) || []
      # if the attr was declared already, simply merge it with the new options
      existing = declared_attrs.detect{ |va| va[:name] == name }
      if existing
        existing.merge!(options)
      else
        attr_config = {:name => name}.merge(options)
        # if primary_key, insert in front, otherwise append
        if name == self.primary_key
          declared_attrs.insert(0, attr_config)
        else
          declared_attrs << {:name => name}.merge(options)
        end
      end
      write_inheritable_attribute(:netzke_declared_attributes, declared_attrs)
    end

    # Exclude attributes from being picked up by grids and forms.
    # Accepts an array of attribute names (as symbols).
    # Example:
    #   netzke_expose_attributes :created_at, :updated_at, :crypted_password
    def netzke_exclude_attributes(*args)
      write_inheritable_attribute(:netzke_excluded_attributes, args.map(&:to_s))
    end

    # Explicitly expose attributes that should be picked up by grids and forms.
    # Accepts an array of attribute names (as symbols).
    # Takes precedence over <tt>netzke_exclude_attributes</tt>.
    # Example:
    #   netzke_expose_attributes :name, :role__name
    def netzke_expose_attributes(*args)
      write_inheritable_attribute(:netzke_exposed_attributes, args.map(&:to_s))
    end

    # Returns the attributes that will be picked up by grids and forms.
    def netzke_attributes
      exposed = netzke_exposed_attributes
      exposed ? netzke_attrs_in_forced_order(exposed) : netzke_attrs_in_natural_order
    end

    def netzke_exposed_attributes
      exposed = read_inheritable_attribute(:netzke_exposed_attributes)
      if exposed && !exposed.include?(self.primary_key)
        # automatically declare primary key as a netzke attribute
        netzke_attribute(self.primary_key)
        exposed.insert(0, self.primary_key)
      end
      exposed
    end

    private
      def netzke_declared_attributes
        read_inheritable_attribute(:netzke_declared_attributes) || []
      end

      def netzke_excluded_attributes
        read_inheritable_attribute(:netzke_excluded_attributes) || []
      end

      def netzke_attrs_in_forced_order(attrs)
        attrs.collect do |attr_name|
          declared = netzke_declared_attributes.detect { |va| va[:name] == attr_name } || {}
          in_columns_hash = columns_hash[attr_name] && {:name => attr_name, :attr_type => columns_hash[attr_name].type, :default_value => columns_hash[attr_name].default} || {} # {:virtual => true} # if nothing found in columns, mark it as "virtual" or not?
          if in_columns_hash.empty?
            # If not among the model columns, it's either virtual, or an association
            merged = association_attr?(attr_name) ? declared.merge!(:name => attr_name) : declared.merge(:virtual => true)
          else
            # .. otherwise merge with what's declared
            merged = in_columns_hash.merge(declared)
          end

          # We didn't find it among declared, nor among the model columns, nor does it seem association attribute
          merged[:name].nil? && raise(ArgumentError, "Unknown attribute '#{attr_name}' for model #{self.name}", caller)

          merged
        end
      end

      # Returns netzke attributes in the order of columns in the table, followed by extra declared attributes
      # Detects one-to-many association columns and replaces the name of the column with association column name (Netzke style), e.g.:
      #
      #   role_id => role__name
      def netzke_attrs_in_natural_order
        (
          declared_attrs = netzke_declared_attributes

          column_names.map do |name|
            c = {:name => name, :attr_type => columns_hash[name].type}

            # If it's named as foreign key of some association, then it's an association column
            assoc = reflect_on_all_associations.detect{|a| a.primary_key_name == c[:name]}

            if assoc && !assoc.options[:polymorphic]
              candidates = %w{name title label} << assoc.primary_key_name
              assoc_method = candidates.detect{|m| (assoc.klass.instance_methods.map(&:to_s) + assoc.klass.column_names).include?(m) }
              c[:name] = "#{assoc.name}__#{assoc_method}"
              c[:attr_type] = assoc.klass.columns_hash[assoc_method].try(:type) || :string # when it's an instance method rather than a column, fall back to :string
            end

            # auto set up the default value from the column settings
            c.merge!(:default_value => columns_hash[name].default) if columns_hash[name].default

            # if there's a declared attr with the same name, simply merge it with what's taken from the model's columns
            if declared = declared_attrs.detect{ |va| va[:name] == c[:name] }
              c.merge!(declared)
              declared_attrs.delete(declared)
            end
            c
          end +
          declared_attrs
        ).reject { |attr| netzke_excluded_attributes.include?(attr[:name]) }
      end

      def association_attr?(attr_name)
        !!attr_name.index("__") # probably we can't do much better than this, as we don't know at this moment if the associated model has a specific attribute, and we don't really want to find it out
      end

  end

  # Updates the record from an attributes hash (such as {:first_name => {:value => "Victor", ...}, ...})
  #def update_from_attributes_hash(attributes)
    #attributes.each_pair do |k,v|
      #set_value_for_attribute(v,v[:value])
    #end
  #end

  # Transforms a record to array of values according to the passed attributes
  def to_array(attributes)
    res = []
    for a in attributes
      next if a[:included] == false
      res << value_for_attribute(a)
    end
    res
  end

  # Accepts both hash and array of attributes
  def to_hash(attributes)
    res = {}
    for a in (attributes.is_a?(Hash) ? attributes.values : attributes)
      next if a[:included] == false
      res[a[:name].to_sym] = self.value_for_attribute(a)
    end
    res
  end

  def value_for_attribute(a)
    v = a[:getter] ? a[:getter].call(self) : (a[:name].present? && send(a[:name]))
    # a work-around for to_json not taking the current timezone into account when serializing ActiveSupport::TimeWithZone
    v = v.to_datetime.to_s(:db) if v.is_a?(ActiveSupport::TimeWithZone)
    v
  #rescue NoMethodError
    # So that we don't crash at a badly configured column
    #"UNDEF"
  end

  def set_value_for_attribute(a, v)
    if a[:setter]
      a[:setter].call(self, v)
    elsif respond_to?("#{a[:name]}=")
      send("#{a[:name]}=", v)
    end
  end
end
