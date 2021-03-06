require File.expand_path(File.dirname(__FILE__) + "/..") + "/test/test_helper"
require 'source_controller'

#
# Add all kind of data consistency checks here. It runs before and after all functional tests
# to detect any kind of data corruption due to some other code
#

def dir_to_array(node)
  array=[]
  node.each(:entry) do |e|
    array << e.value('name')
  end
  array.sort
end

def compare_project_and_package_lists
  # check that api and backend have the same package objects
  prepare_request_with_user "king", "sunflower"
  # projects
  get "/source"
  assert_response :success
  project_list_api = dir_to_array(ActiveXML::Node.new(@response.body))
  project_list_backend = dir_to_array(ActiveXML::Node.new(Suse::Backend.get("/source").body))

  assert_equal project_list_api, project_list_backend

  project_list_api.each do |name|

    get "/source/#{name}"
    assert_response :success
    package_list_api = dir_to_array(ActiveXML::Node.new(@response.body))
    package_list_backend = dir_to_array(ActiveXML::Node.new(Suse::Backend.get("/source/#{name}").body))

    assert_equal package_list_api, package_list_backend, "in #{name}"
  end
end

def resubmit_all_fixtures
  # this just reads and writes again the meta data. 1st run the fixtures and on 2nd all left
  # overs from other other tests
  prepare_request_with_user "king", "sunflower"
  # projects
  get "/source"
  assert_response :success
  node = ActiveXML::Node.new(@response.body)
  node.each(:entry) do |e|
    name = e.value('name')
    get "/source/#{name}/_meta"
    assert_response :success
    r = @response.body
    # FIXME: add some more validation checks here
    put "/source/#{name}/_meta", r.dup
    assert_response :success
    get "/source/#{name}/_meta"
    assert_response :success
    assert_not_nil r
    assert_equal r, @response.body

    # packages
    get "/source/#{name}"
    assert_response :success
    packages = Xmlhash.parse(@response.body)
    packages.elements('entry') do |p|
      get "/source/#{name}/#{p['name']}/_meta"
      assert_response :success
      r = @response.body
      # FIXME: add some more validation checks here
      put "/source/#{name}/#{p['name']}/_meta", r.dup
      assert_response :success
      get "/source/#{name}/#{p['name']}/_meta"
      assert_response :success
      assert_not_nil r
      assert_equal r, @response.body, "in #{name}"
    end
  end
end
