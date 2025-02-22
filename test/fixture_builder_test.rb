require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))

class Model
  def self.table_name
    'models'
  end
end

class FixtureBuilderTest < Test::Unit::TestCase
  def teardown
    FixtureBuilder.instance_variable_set(:'@configuration', nil)
  end

  def test_name_with
    hash = {
        'id' => 1,
        'email' => 'bob@example.com'
    }
    FixtureBuilder.configure do |config|
      config.name_model_with Model do |record_hash, index|
        [record_hash['email'].split('@').first, index].join('_')
      end
    end
    assert_equal 'bob_001', FixtureBuilder.configuration.send(:record_name, hash, Model.table_name, '000')
  end

  def test_ivar_naming
    create_and_blow_away_old_db
    force_fixture_generation

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path("*.rb")]
      fbuilder.factory do
        @king_of_gnomes = MagicalCreature.create(name:'robert', species: 'gnome')
      end
    end
    generated_fixture = YAML.load(File.open(test_path("fixtures/magical_creatures.yml")))
    assert_equal 'king_of_gnomes', generated_fixture.keys.first
  end

  def test_serialization
    create_and_blow_away_old_db
    force_fixture_generation

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path("*.rb")]
      fbuilder.factory do
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent',
                                       powers: %w{shading rooting seeding})
      end
    end
    generated_fixture = YAML.load(File.open(test_path("fixtures/magical_creatures.yml")))
    assert_equal "---\n- shading\n- rooting\n- seeding\n", generated_fixture['enty']['powers']
  end

  def test_do_not_include_virtual_attributes
    create_and_blow_away_old_db
    force_fixture_generation

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path("*.rb")]
      fbuilder.factory do
        MagicalCreature.create(name: 'Uni', species: 'unicorn', powers: %w{rainbows flying})
      end
    end
    generated_fixture = YAML.load(File.open(test_path('fixtures/magical_creatures.yml')))
    assert !generated_fixture['uni'].key?('virtual')
  end

  def test_configure
    FixtureBuilder.configure do |config|
      assert config.is_a?(FixtureBuilder::Configuration)
      @called = true
    end
    assert @called
  end

  def test_absolute_rails_fixtures_path
    assert_equal File.expand_path('../../test/fixtures', __FILE__), FixtureBuilder::FixturesPath.absolute_rails_fixtures_path
  end

  def test_fixtures_dir
    assert_match /test\/fixtures$/, FixtureBuilder.configuration.send(:fixtures_dir).to_s
  end

  def test_rebuilding_due_to_differing_file_hashes
    create_and_blow_away_old_db
    force_fixture_generation_due_to_differing_file_hashes

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path("*.rb")]
      fbuilder.factory do
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent',
                                       powers: %w{shading rooting seeding})
      end
    end
    generated_fixture = YAML.load(File.open(test_path("fixtures/magical_creatures.yml")))
    assert_equal "---\n- shading\n- rooting\n- seeding\n", generated_fixture['enty']['powers']
  end

  def test_sha1_digests
    create_and_blow_away_old_db
    force_fixture_generation_due_to_differing_file_hashes

    FixtureBuilder.configure(use_sha1_digests: true) do |fbuilder|
      fbuilder.files_to_check += Dir[test_path("*.rb")]
      fbuilder.factory do
        @enty = MagicalCreature.create(name: 'Enty', species: 'ent',
                                       powers: %w{shading rooting seeding})
      end
      first_modified_time = File.mtime(test_path("fixtures/magical_creatures.yml"))
      fbuilder.factory do
      end
      second_modified_time = File.mtime(test_path("fixtures/magical_creatures.yml"))
      assert_equal first_modified_time, second_modified_time
    end
  end

  def test_system_timestamps_not_set
    create_and_blow_away_old_db
    force_fixture_generation

    # this fork ignores updated_at times and also ignores created_at times unless they're
    # being specifically set for a specific date in the past or future
    unsafe_datetime = 18.hours.ago

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path("*.rb")]
      fbuilder.factory do
        @wayward_mimic = MagicalCreature.create(name: 'trix', species: 'mimic',
                                        created_at: unsafe_datetime, updated_at: Time.now)
      end
    end
    generated_fixture = YAML.load(File.open(test_path("fixtures/magical_creatures.yml")))
    assert_equal 'wayward_mimic', generated_fixture.keys.first
    assert_nil generated_fixture.values.first['updated_at']
    assert_nil generated_fixture.values.first['created_at']
  end

  def test_created_at_set
    create_and_blow_away_old_db
    force_fixture_generation

    # this fork ignores updated_at times and also ignores created_at times unless they're
    # being specifically set for a specific date in the past or future
    safe_datetime = 3.days.ago

    FixtureBuilder.configure do |fbuilder|
      fbuilder.files_to_check += Dir[test_path("*.rb")]
      fbuilder.factory do
        @wayward_mimic = MagicalCreature.create(name: 'trix', species: 'mimic',
                                        created_at: safe_datetime, updated_at: Time.now)
      end
    end
    generated_fixture = YAML.load(File.open(test_path("fixtures/magical_creatures.yml")))
    assert_equal 'wayward_mimic', generated_fixture.keys.first
    assert_nil generated_fixture.values.first['updated_at']
    assert_equal safe_datetime, generated_fixture.values.first['created_at']
  end
end
