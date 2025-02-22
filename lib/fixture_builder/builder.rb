module FixtureBuilder
  class Builder
    include Delegations::Namer
    include Delegations::Configuration

    def initialize(configuration, namer, builder_block)
      @configuration = configuration
      @namer = namer
      @builder_block = builder_block
    end

    def generate!
      say "Building fixtures"
      clean_out_old_data
      create_fixture_objects
      names_from_ivars!
      write_data_to_files
      after_build.call if after_build
    end

    protected

    def create_fixture_objects
      load_legacy_fixtures if legacy_fixtures.present?
      surface_errors { instance_eval &@builder_block }
    end

    def load_legacy_fixtures
      legacy_fixtures.each do |fixture_file|
        fixtures = fixtures_class.create_fixtures(File.dirname(fixture_file), File.basename(fixture_file, '.*'))
        populate_custom_names(fixtures)
      end
    end

    # Rails 3.0 and 3.1+ support
    def fixtures_class
      if defined?(ActiveRecord::FixtureSet)
        ActiveRecord::FixtureSet
      elsif defined?(ActiveRecord::Fixtures)
        ActiveRecord::Fixtures
      else
        ::Fixtures
      end
    end

    def surface_errors
      yield
    rescue Object => error
      puts
      say "There was an error building fixtures", error.inspect
      puts
      puts error.backtrace
      puts
      exit!
    end

    def names_from_ivars!
      instance_values.each do |var, value|
        name(var, value) if value.is_a? ActiveRecord::Base
      end
    end

    def write_data_to_files
      delete_yml_files
      dump_empty_fixtures_for_all_tables if write_empty_files
      dump_tables
    end

    def clean_out_old_data
      delete_tables
      delete_yml_files
    end

    def delete_tables
      ActiveRecord::Base.connection.disable_referential_integrity do
        tables.each { |t| ActiveRecord::Base.connection.delete(delete_sql % {table: ActiveRecord::Base.connection.quote_table_name(t)}) }
      end
    end

    def delete_yml_files
      FileUtils.rm(*tables.map { |t| fixture_file(t) }) rescue nil
    end

    def say(*messages)
      puts messages.map { |message| "=> #{message}" }
    end

    def dump_empty_fixtures_for_all_tables
      tables.each do |table_name|
        write_fixture_file({}, table_name)
      end
    end

    def dump_tables
      default_date_format = Date::DATE_FORMATS[:default]
      Date::DATE_FORMATS[:default] = Date::DATE_FORMATS[:db]
      begin
        fixtures = tables.inject([]) do |files, table_name|
          table_klass = table_name.classify.constantize rescue nil
          if table_klass && table_klass < ActiveRecord::Base
            rows = table_klass.unscoped do
              table_klass.order(order_by).all.collect do |obj|
                attrs = obj.attributes.select { |attr_name| table_klass.column_names.include?(attr_name) }
                attrs_with_overrides(attrs, obj).inject({}) do |hash, (attr_name, value)|
                  hash[attr_name] = serialized_value_if_needed(table_klass, attr_name, value)
                  hash
                end
              end
            end
          else
            rows = ActiveRecord::Base.connection.select_all(select_sql % {table: ActiveRecord::Base.connection.quote_table_name(table_name)})
          end
          next files if rows.empty?

          row_index = '000'
          fixture_data = rows.inject({}) do |hash, record|
            hash.merge(record_name(record, table_name, row_index) => record_with_overrides!(record))
          end

          write_fixture_file fixture_data, table_name

          files + [File.basename(fixture_file(table_name))]
        end
      ensure
        Date::DATE_FORMATS[:default] = default_date_format
      end
      say "Built #{fixtures.to_sentence}"
    end

    def serialized_value_if_needed(table_klass, attr_name, value)
      if table_klass.respond_to?(:type_for_attribute)
        if value.is_a?(Numeric)
          value
        elsif table_klass.type_for_attribute(attr_name).type == :jsonb || table_klass.type_for_attribute(attr_name).type == :json
          value
        elsif table_klass.type_for_attribute(attr_name).respond_to?(:serialize)
          table_klass.type_for_attribute(attr_name).serialize(value)
        elsif table_klass.type_for_attribute(attr_name).respond_to?(:type_cast_for_database)
          table_klass.type_for_attribute(attr_name).type_cast_for_database(value)
        else
          table_klass.type_for_attribute(attr_name).type_cast_for_schema(value)
        end
      else
        if table_klass.serialized_attributes.has_key? attr_name
          table_klass.serialized_attributes[attr_name].dump(value)
        else
          value
        end
      end
    end

    def write_fixture_file(fixture_data, table_name)
      File.open(fixture_file(table_name), 'w') do |file|
        file.write fixture_data.to_yaml
      end
    end

    def attrs_with_overrides(attrs, obj)
      replace_big_decimal_attr_values!(attrs, obj)
      replace_encrypted_attr_values!(attrs, obj)
      exclude_default_system_timestamps!(attrs)
      exclude_nil_attr_values!(attrs)

      attrs
    end

    def replace_big_decimal_attr_values!(attrs, obj)
      attrs.select {|k, v| v.is_a?(BigDecimal)}.each_pair do |key, value|
        attrs[key] = value.to_f
      end
    end

    def replace_encrypted_attr_values!(attrs, obj)
      attrs.select {|k, v| k.match(/_(ciphertext|bidx)$/)}.each_pair do |key, value|
        unencrypted_attr_name = key.delete_suffix("_ciphertext").delete_suffix("_bidx")
        unencrypted_value     = obj.public_send(unencrypted_attr_name.to_sym)

        attrs[key] = "<%= #{obj.class.name}.generate_#{key}(\"#{unencrypted_value}\").inspect %>"
      end
    end

    def exclude_default_system_timestamps!(attrs)
      attrs.except!("updated_at")

      if attrs["created_at"] && attrs["created_at"] >= 1.day.ago && attrs["created_at"].to_time <= Time.now
        attrs.except!("created_at")
      end
    end

    def exclude_nil_attr_values!(attrs)
      attrs.compact!
    end

    def record_with_overrides!(record)
      use_generated_ids!(record) if @configuration.generate_ids

      record
    end

    def use_generated_ids!(record)
      # TODO: Any objects created by virtue of callbacks will need special treatment
      record.except!("id")

      record.select { |k, v| k.match(/_id$/)}.each_pair do |key, value|
        id_to_lookup = record[key]

        next if id_to_lookup && @namer.custom_name_ids[id_to_lookup].nil?
        next if @configuration.generate_ids_excluded_column_names.include?(key)

        key_prefix = key.delete_suffix("_id")

        if (polymorphic_type = record["#{key_prefix}_type"]).present?
          record[key_prefix] = "#{@namer.custom_name_ids[id_to_lookup]} (#{polymorphic_type})"
          record.delete("#{key_prefix}_type")
        else
          record[key_prefix] = @namer.custom_name_ids[id_to_lookup]
        end

        record.delete(key)
      end
    end

    def fixture_file(table_name)
      fixtures_dir("#{table_name}.yml")
    end

    def order_by
      @configuration.generate_ids ? :created_at : :id
    end
  end
end
