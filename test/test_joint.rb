require 'helper'

class Asset
  include MongoMapper::Document
  plugin Joint

  key :title, String
  attachment :image
  attachment :file
end

class SafeAsset < Asset
  safe
end

class BaseModel
  include MongoMapper::Document
  plugin Joint

  set_joint_collection :base_attachments
  attachment :file
end

class Image < BaseModel; attachment :image end

class Video < BaseModel
  set_joint_collection :video_attachments
  attachment :video
end

module JointTestHelpers
  def all_files
    [@file, @image, @image2, @test1, @test2]
  end

  def rewind_files
    all_files.each { |file| file.rewind }
  end

  def open_file(name)
    File.open(File.join(File.dirname(__FILE__), 'fixtures', name), 'r')
  end

  def grid(collection_name = 'fs')
    @grids ||= Hash.new
    @grids[collection_name] ||= Mongo::Grid.new(MongoMapper.database, collection_name)
  end

  def key_names
    [:id, :name, :type, :size]
  end
end

class JointTest < Test::Unit::TestCase
  include JointTestHelpers

  def setup
    super
    @file   = open_file('unixref.pdf')
    @image  = open_file('mr_t.jpg')
    @image2 = open_file('harmony.png')
    @test1  = open_file('test1.txt')
    @test2  = open_file('test2.txt')
  end

  def teardown
    all_files.each { |file| file.close }
  end

  context "Using Joint plugin" do
    should "add each attachment to attachment_names" do
      Asset.attachment_names.should == Set.new([:image, :file])
    end

    should "add keys for each attachment" do
      key_names.each do |key|
        Asset.keys.should include("image_#{key}")
        Asset.keys.should include("file_#{key}")
      end
    end

    should "have a default joint collection name" do
      Asset.joint_collection_name.should == 'fs'
    end

    should "set the joint collection name" do
      BaseModel.joint_collection_name.should == 'base_attachments'
    end

    should "respect the model's safe option setting" do
      unsafe_doc = Asset.new(:image => @image, :file => @file)
      rewind_files
      Mongo::Grid.any_instance.expects(:put).twice.with(anything, has_entries(:safe => false))

      unsafe_doc.save

      safe_doc = SafeAsset.new(:image => @image, :file => @file)
      rewind_files
      Mongo::Grid.any_instance.expects(:put).twice.with(anything, has_entries(:safe => true))

      safe_doc.save
    end

    context "with inheritance" do
      should "add attachment to attachment_names" do
        BaseModel.attachment_names.should == Set.new([:file])
      end

      should "inherit attachments from superclass, but not share other inherited class attachments" do
        Image.attachment_names.should == Set.new([:file, :image])
        Video.attachment_names.should == Set.new([:file, :video])
      end

      should "add inherit keys from superclass" do
        key_names.each do |key|
          BaseModel.keys.should include("file_#{key}")
          Image.keys.should     include("file_#{key}")
          Image.keys.should     include("image_#{key}")
          Video.keys.should     include("file_#{key}")
          Video.keys.should     include("video_#{key}")
        end
      end

      should "inherit the joint collection name from superclass" do
        Image.joint_collection_name.should == 'base_attachments'
      end

      should "set the joint collection name" do
        Video.joint_collection_name.should == 'video_attachments'
      end
    end
  end

  context "Assigning new attachments to document" do
    setup do
      @doc = Asset.create(:image => @image, :file => @file)
      rewind_files
    end
    subject { @doc }

    should "assign GridFS content_type" do
      grid.get(subject.image_id).content_type.should == 'image/jpeg'
      grid.get(subject.file_id).content_type.should == 'application/pdf'
    end

    should "assign joint keys" do
      subject.image_size.should  == 13661
      subject.file_size.should   == 68926

      subject.image_type.should  == "image/jpeg"
      subject.file_type.should   == "application/pdf"

      subject.image_id.should_not be_nil
      subject.file_id.should_not be_nil

      subject.image_id.should be_instance_of(BSON::ObjectId)
      subject.file_id.should be_instance_of(BSON::ObjectId)
    end

    should "allow accessing keys through attachment proxy" do
      subject.image.size.should  == 13661
      subject.file.size.should   == 68926

      subject.image.type.should  == "image/jpeg"
      subject.file.type.should   == "application/pdf"

      subject.image.id.should_not be_nil
      subject.file.id.should_not be_nil

      subject.image.id.should be_instance_of(BSON::ObjectId)
      subject.file.id.should be_instance_of(BSON::ObjectId)
    end

    should "proxy unknown methods to GridIO object" do
      subject.image.files_id.should      == subject.image_id
      subject.image.content_type.should  == 'image/jpeg'
      subject.image.filename.should      == 'mr_t.jpg'
      subject.image.file_length.should   == 13661
    end

    should "assign file name from path if original file name not available" do
      subject.image_name.should  == 'mr_t.jpg'
      subject.file_name.should   == 'unixref.pdf'
    end

    should "save attachment contents correctly" do
      subject.file.read.should   == @file.read
      subject.image.read.should  == @image.read
    end

    should "know that attachment exists" do
      subject.image?.should be(true)
      subject.file?.should be(true)
    end

    should "clear assigned attachments so they don't get uploaded twice" do
      Mongo::Grid.any_instance.expects(:put).never
      subject.save
    end
  end

  context "Updating existing attachment" do
    setup do
      @doc = Asset.create(:file => @test1)
      assert_no_grid_difference do
        @doc.file = @test2
        @doc.save!
      end
      rewind_files
    end
    subject { @doc }

    should "not change attachment id" do
      subject.file_id_changed?.should be(false)
    end

    should "update keys" do
      subject.file_name.should == 'test2.txt'
      subject.file_type.should == "text/plain"
      subject.file_size.should == 5
    end

    should "update GridFS" do
      grid.get(subject.file_id).filename.should     == 'test2.txt'
      grid.get(subject.file_id).content_type.should == 'text/plain'
      grid.get(subject.file_id).file_length.should  == 5
      grid.get(subject.file_id).read.should         == @test2.read
    end
  end

  context "Updating document but not attachments" do
    setup do
      @doc = Asset.create(:image => @image)
      @doc.update_attributes(:title => 'Updated')
      @doc.reload
      rewind_files
    end
    subject { @doc }

    should "not affect attachment" do
      subject.image.read.should == @image.read
    end

    should "update document attributes" do
      subject.title.should == 'Updated'
    end
  end

  context "Assigning file where file pointer is not at beginning" do
    setup do
      @image.read
      @doc = Asset.create(:image => @image)
      @doc.reload
      rewind_files
    end
    subject { @doc }

    should "rewind and correctly store contents" do
      subject.image.read.should == @image.read
    end
  end

  context "Setting attachment to nil" do
    setup do
      @doc = Asset.create(:image => @image)
      rewind_files
    end
    subject { @doc }

    should "delete attachment after save" do
      assert_no_grid_difference   { subject.image = nil }
      assert_grid_difference(-1)  { subject.save }
    end

    should "clear nil attachments after save and not attempt to delete again" do
      Mongo::Grid.any_instance.expects(:delete).once
      subject.image = nil
      subject.save
      Mongo::Grid.any_instance.expects(:delete).never
      subject.save
    end
  end

  context "Retrieving attachment that does not exist" do
    setup do
      @doc = Asset.create
      rewind_files
    end
    subject { @doc }

    should "know that the attachment is not present" do
      subject.image?.should be(false)
    end

    should "raise Mongo::GridFileNotFound" do
      assert_raises(Mongo::GridFileNotFound) { subject.image.read }
    end
  end

  context "Destroying a document" do
    setup do
      @doc = Asset.create(:image => @image)
      rewind_files
    end
    subject { @doc }

    should "remove files from grid fs as well" do
      assert_grid_difference(-1) { subject.destroy }
    end
  end

  context "Assigning file name" do
    should "default to path" do
      Asset.create(:image => @image).image.name.should == 'mr_t.jpg'
    end

    should "use original_filename if available" do
      def @image.original_filename
        'testing.txt'
      end
      doc = Asset.create(:image => @image)
      assert_equal 'testing.txt', doc.image_name
    end
  end

  context "Using an alternate collection" do
    setup do
      @joint_collection_name = 'assets'
      Asset.joint_collection_name = @joint_collection_name

      @doc = Asset.create(:image => @image, :file => @file)
      rewind_files
    end

    should "save attachments in the alternate collection" do
      assert_raises(Mongo::GridFileNotFound) { grid('fs').get(@doc.image_id) }
      assert_raises(Mongo::GridFileNotFound) { grid('fs').get(@doc.file_id) }

      grid(@joint_collection_name).get(@doc.image_id).should_not be_nil
      grid(@joint_collection_name).get(@doc.file_id).should_not be_nil
    end
  end

end
