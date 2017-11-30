require 'spec_helper'

feature 'Dashboard Groups page', :js do
  let(:user) { create :user }
  let(:group) { create(:group) }
  let(:nested_group) { create(:group, :nested) }
  let(:another_group) { create(:group) }

  def click_group_caret(group)
    within("#group-#{group.id}") do
      first('.folder-caret').click
    end
    wait_for_requests
  end

  it 'shows groups user is member of' do
    group.add_owner(user)
    nested_group.add_owner(user)
    expect(another_group).to be_persisted

    sign_in(user)
    visit dashboard_groups_path
    wait_for_requests

    expect(page).to have_content(group.name)

    expect(page).not_to have_content(another_group.name)
  end

  it 'shows subgroups the user is member of', :nested_groups do
    group.add_owner(user)
    nested_group.add_owner(user)

    sign_in(user)
    visit dashboard_groups_path
    wait_for_requests

    expect(page).to have_content(nested_group.parent.name)
    click_group_caret(nested_group.parent)
    expect(page).to have_content(nested_group.name)
  end

  describe 'when filtering groups', :nested_groups do
    before do
      group.add_owner(user)
      nested_group.add_owner(user)
      expect(another_group).to be_persisted

      sign_in(user)

      visit dashboard_groups_path
    end

    it 'expands when filtering groups' do
      fill_in 'filter', with: nested_group.name
      wait_for_requests

      expect(page).not_to have_content(group.name)
      expect(page).to have_content(nested_group.parent.name)
      expect(page).to have_content(nested_group.name)
      expect(page).not_to have_content(another_group.name)
    end

    it 'resets search when user cleans the input' do
      fill_in 'filter', with: group.name
      wait_for_requests

      fill_in 'filter', with: ''
      wait_for_requests

      expect(page).to have_content(group.name)
      expect(page).to have_content(nested_group.parent.name)
      expect(page).not_to have_content(another_group.name)
      expect(page.all('.js-groups-list-holder .content-list li').length).to eq 2
    end
  end

  describe 'group with subgroups', :nested_groups do
    let!(:subgroup) { create(:group, :public, parent: group) }

    before do
      group.add_owner(user)
      subgroup.add_owner(user)

      sign_in(user)

      visit dashboard_groups_path
    end

    it 'shows subgroups inside of its parent group' do
      expect(page).to have_selector("#group-#{group.id}")
      click_group_caret(group)
      expect(page).to have_selector("#group-#{group.id} #group-#{subgroup.id}")
    end

    it 'can toggle parent group' do
      # Collapsed by default
      expect(page).not_to have_selector("#group-#{group.id} .fa-caret-down", count: 1)
      expect(page).to have_selector("#group-#{group.id} .fa-caret-right")

      # expand
      click_group_caret(group)

      expect(page).to have_selector("#group-#{group.id} .fa-caret-down")
      expect(page).not_to have_selector("#group-#{group.id} .fa-caret-right", count: 1)
      expect(page).to have_selector("#group-#{group.id} #group-#{subgroup.id}")

      # collapse
      click_group_caret(group)

      expect(page).not_to have_selector("#group-#{group.id} .fa-caret-down", count: 1)
      expect(page).to have_selector("#group-#{group.id} .fa-caret-right")
      expect(page).not_to have_selector("#group-#{group.id} #group-#{subgroup.id}")
    end
  end

  describe 'when using pagination' do
    let(:group)  { create(:group, created_at: 5.days.ago) }
    let(:group2) { create(:group, created_at: 2.days.ago) }

    before do
      group.add_owner(user)
      group2.add_owner(user)

      allow(Kaminari.config).to receive(:default_per_page).and_return(1)

      sign_in(user)
      visit dashboard_groups_path
    end

    it 'loads results for next page' do
      expect(page).to have_selector('.gl-pagination .page', count: 2)

      # Check first page
      expect(page).to have_content(group2.full_name)
      expect(page).to have_selector("#group-#{group2.id}")
      expect(page).not_to have_content(group.full_name)
      expect(page).not_to have_selector("#group-#{group.id}")

      # Go to next page
      find(".gl-pagination .page:not(.active) a").click

      wait_for_requests

      # Check second page
      expect(page).to have_content(group.full_name)
      expect(page).to have_selector("#group-#{group.id}")
      expect(page).not_to have_content(group2.full_name)
      expect(page).not_to have_selector("#group-#{group2.id}")
    end
  end
end