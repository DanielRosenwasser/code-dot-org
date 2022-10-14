require 'test_helper'

class IncubatorHelperTest < ActionView::TestCase
  include IncubatorHelper

  def sign_in(user)
    # override the default sign_in helper because we don't actually have a request or anything here
    stubs(:current_user).returns user
  end

  setup do
    @teacher_yes = create(:teacher, id: 80)
    @teacher_no = create(:teacher, id: 81)
    @student = create(:student)
  end

  test 'teacher who can see incubator' do
    sign_in @teacher_yes
    stubs(:language).returns "en"
    assert show_incubator_banner?
  end

  test 'non en teacher who can not see incubator' do
    sign_in @teacher_yes
    stubs(:language).returns "fr"
    refute show_incubator_banner?
  end

  test 'teacher who can not see incubator' do
    sign_in @teacher_no
    stubs(:language).returns "en"
    refute show_incubator_banner?
  end

  test 'student who can not see incubator' do
    sign_in @student
    stubs(:language).returns "en"
    refute show_incubator_banner?
  end
end
