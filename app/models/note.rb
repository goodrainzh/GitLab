# A note on the root of an issue, merge request, commit, or snippet.
#
# A note of this type is never resolvable.
class Note < ActiveRecord::Base
  extend ActiveModel::Naming
  include Gitlab::CurrentSettings
  include Participable
  include Mentionable
  include Awardable
  include Importable
  include FasterCacheKeys
  include CacheMarkdownField
  include AfterCommitQueue
  include ResolvableNote
  include IgnorableColumn
  include Editable

  module SpecialRole
    FIRST_TIME_CONTRIBUTOR = :first_time_contributor

    class << self
      def values
        constants.map {|const| self.const_get(const)}
      end
    end
  end

  ignore_column :original_discussion_id

  cache_markdown_field :note, pipeline: :note, issuable_state_filter_enabled: true

  # Aliases to make application_helper#edited_time_ago_with_tooltip helper work properly with notes.
  # See https://gitlab.com/gitlab-org/gitlab-ce/merge_requests/10392/diffs#note_28719102
  alias_attribute :last_edited_at, :updated_at
  alias_attribute :last_edited_by, :updated_by

  # Attribute containing rendered and redacted Markdown as generated by
  # Banzai::ObjectRenderer.
  attr_accessor :redacted_note_html

  # An Array containing the number of visible references as generated by
  # Banzai::ObjectRenderer
  attr_accessor :user_visible_reference_count

  # Attribute used to store the attributes that have been changed by quick actions.
  attr_accessor :commands_changes

  # A special role that may be displayed on issuable's discussions
  attr_accessor :special_role

  default_value_for :system, false

  attr_mentionable :note, pipeline: :note
  participant :author

  belongs_to :project
  belongs_to :noteable, polymorphic: true, touch: true # rubocop:disable Cop/PolymorphicAssociations
  belongs_to :author, class_name: "User"
  belongs_to :updated_by, class_name: "User"
  belongs_to :last_edited_by, class_name: 'User'

  has_many :todos, dependent: :destroy # rubocop:disable Cop/ActiveRecordDependent
  has_many :events, as: :target, dependent: :destroy # rubocop:disable Cop/ActiveRecordDependent
  has_one :system_note_metadata

  delegate :gfm_reference, :local_reference, to: :noteable
  delegate :name, to: :project, prefix: true
  delegate :name, :email, to: :author, prefix: true
  delegate :title, to: :noteable, allow_nil: true

  validates :note, presence: true
  validates :project, presence: true, if: :for_project_noteable?

  # Attachments are deprecated and are handled by Markdown uploader
  validates :attachment, file_size: { maximum: :max_attachment_size }

  validates :noteable_type, presence: true
  validates :noteable_id, presence: true, unless: [:for_commit?, :importing?]
  validates :commit_id, presence: true, if: :for_commit?
  validates :author, presence: true
  validates :discussion_id, presence: true, format: { with: /\A\h{40}\z/ }

  validate unless: [:for_commit?, :importing?, :for_personal_snippet?] do |note|
    unless note.noteable.try(:project) == note.project
      errors.add(:project, 'does not match noteable project')
    end
  end

  mount_uploader :attachment, AttachmentUploader

  # Scopes
  scope :for_commit_id, ->(commit_id) { where(noteable_type: "Commit", commit_id: commit_id) }
  scope :system, -> { where(system: true) }
  scope :user, -> { where(system: false) }
  scope :common, -> { where(noteable_type: ["", nil]) }
  scope :fresh, -> { order(created_at: :asc, id: :asc) }
  scope :updated_after, ->(time) { where('updated_at > ?', time) }
  scope :inc_author_project, -> { includes(:project, :author) }
  scope :inc_author, -> { includes(:author) }
  scope :inc_relations_for_view, -> do
    includes(:project, :author, :updated_by, :resolved_by, :award_emoji, :system_note_metadata)
  end

  scope :diff_notes, -> { where(type: %w(LegacyDiffNote DiffNote)) }
  scope :new_diff_notes, -> { where(type: 'DiffNote') }
  scope :non_diff_notes, -> { where(type: ['Note', 'DiscussionNote', nil]) }

  scope :with_associations, -> do
    # FYI noteable cannot be loaded for LegacyDiffNote for commits
    includes(:author, :noteable, :updated_by,
             project: [:project_members, { group: [:group_members] }])
  end
  scope :with_metadata, -> { includes(:system_note_metadata) }

  after_initialize :ensure_discussion_id
  before_validation :nullify_blank_type, :nullify_blank_line_code
  before_validation :set_discussion_id, on: :create
  after_save :keep_around_commit, if: :for_project_noteable?
  after_save :expire_etag_cache
  after_destroy :expire_etag_cache

  class << self
    def model_name
      ActiveModel::Name.new(self, nil, 'note')
    end

    def discussions(context_noteable = nil)
      Discussion.build_collection(all.includes(:noteable).fresh, context_noteable)
    end

    def find_discussion(discussion_id)
      notes = where(discussion_id: discussion_id).fresh.to_a
      return if notes.empty?

      Discussion.build(notes)
    end

    # Group diff discussions by line code or file path.
    # It is not needed to group by line code when comment is
    # on an image.
    def grouped_diff_discussions(diff_refs = nil)
      groups = {}

      diff_notes.fresh.discussions.each do |discussion|
        group_key =
          if discussion.on_image?
            discussion.file_new_path
          else
            discussion.line_code_in_diffs(diff_refs)
          end

        if group_key
          discussions = groups[group_key] ||= []
          discussions << discussion
        end
      end

      groups
    end

    def count_for_collection(ids, type)
      user.select('noteable_id', 'COUNT(*) as count')
        .group(:noteable_id)
        .where(noteable_type: type, noteable_id: ids)
    end

    def has_special_role?(role, note)
      note.special_role == role
    end
  end

  def cross_reference?
    return unless system?

    if force_cross_reference_regex_check?
      matches_cross_reference_regex?
    else
      SystemNoteService.cross_reference?(note)
    end
  end

  def diff_note?
    false
  end

  def active?
    true
  end

  def max_attachment_size
    current_application_settings.max_attachment_size.megabytes.to_i
  end

  def hook_attrs
    attributes
  end

  def for_commit?
    noteable_type == "Commit"
  end

  def for_issue?
    noteable_type == "Issue"
  end

  def for_merge_request?
    noteable_type == "MergeRequest"
  end

  def for_snippet?
    noteable_type == "Snippet"
  end

  def for_personal_snippet?
    noteable.is_a?(PersonalSnippet)
  end

  def for_project_noteable?
    !for_personal_snippet?
  end

  def skip_project_check?
    for_personal_snippet?
  end

  # override to return commits, which are not active record
  def noteable
    if for_commit?
      @commit ||= project.commit(commit_id)
    else
      super
    end
  # Temp fix to prevent app crash
  # if note commit id doesn't exist
  rescue
    nil
  end

  # FIXME: Hack for polymorphic associations with STI
  #        For more information visit http://api.rubyonrails.org/classes/ActiveRecord/Associations/ClassMethods.html#label-Polymorphic+Associations
  def noteable_type=(noteable_type)
    super(noteable_type.to_s.classify.constantize.base_class.to_s)
  end

  def special_role=(role)
    raise "Role is undefined, #{role} not found in #{SpecialRole.values}" unless SpecialRole.values.include?(role)

    @special_role = role
  end

  def has_special_role?(role)
    self.class.has_special_role?(role, self)
  end

  def specialize_for_first_contribution!(noteable)
    return unless noteable.author_id == self.author_id

    self.special_role = Note::SpecialRole::FIRST_TIME_CONTRIBUTOR
  end

  def editable?
    !system?
  end

  def cross_reference_not_visible_for?(user)
    cross_reference? && !has_referenced_mentionables?(user)
  end

  def has_referenced_mentionables?(user)
    if user_visible_reference_count.present?
      user_visible_reference_count > 0
    else
      referenced_mentionables(user).any?
    end
  end

  def award_emoji?
    can_be_award_emoji? && contains_emoji_only?
  end

  def emoji_awardable?
    !system?
  end

  def can_be_award_emoji?
    noteable.is_a?(Awardable) && !part_of_discussion?
  end

  def contains_emoji_only?
    note =~ /\A#{Banzai::Filter::EmojiFilter.emoji_pattern}\s?\Z/
  end

  def to_ability_name
    for_personal_snippet? ? 'personal_snippet' : noteable_type.underscore
  end

  def can_be_discussion_note?
    self.noteable.supports_discussions? && !part_of_discussion?
  end

  def discussion_class(noteable = nil)
    # When commit notes are rendered on an MR's Discussion page, they are
    # displayed in one discussion instead of individually.
    # See also `#discussion_id` and `Discussion.override_discussion_id`.
    if noteable && noteable != self.noteable
      OutOfContextDiscussion
    else
      IndividualNoteDiscussion
    end
  end

  # See `Discussion.override_discussion_id` for details.
  def discussion_id(noteable = nil)
    discussion_class(noteable).override_discussion_id(self) || super()
  end

  # Returns a discussion containing just this note.
  # This method exists as an alternative to `#discussion` to use when the methods
  # we intend to call on the Discussion object don't require it to have all of its notes,
  # and just depend on the first note or the type of discussion. This saves us a DB query.
  def to_discussion(noteable = nil)
    Discussion.build([self], noteable)
  end

  # Returns the entire discussion this note is part of.
  # Consider using `#to_discussion` if we do not need to render the discussion
  # and all its notes and if we don't care about the discussion's resolvability status.
  def discussion
    full_discussion = self.noteable.notes.find_discussion(self.discussion_id) if part_of_discussion?
    full_discussion || to_discussion
  end

  def part_of_discussion?
    !to_discussion.individual_note?
  end

  def in_reply_to?(other)
    case other
    when Note
      if part_of_discussion?
        in_reply_to?(other.noteable) && in_reply_to?(other.to_discussion)
      else
        in_reply_to?(other.noteable)
      end
    when Discussion
      self.discussion_id == other.id
    when Noteable
      self.noteable == other
    else
      false
    end
  end

  def expire_etag_cache
    return unless noteable&.discussions_rendered_on_frontend?

    key = Gitlab::Routing.url_helpers.project_noteable_notes_path(
      project,
      target_type: noteable_type.underscore,
      target_id: noteable_id
    )
    Gitlab::EtagCaching::Store.new.touch(key)
  end

  private

  def keep_around_commit
    project.repository.keep_around(self.commit_id)
  end

  def nullify_blank_type
    self.type = nil if self.type.blank?
  end

  def nullify_blank_line_code
    self.line_code = nil if self.line_code.blank?
  end

  def ensure_discussion_id
    return unless self.persisted?
    # Needed in case the SELECT statement doesn't ask for `discussion_id`
    return unless self.has_attribute?(:discussion_id)
    return if self.discussion_id

    set_discussion_id
    update_column(:discussion_id, self.discussion_id)
  end

  def set_discussion_id
    self.discussion_id ||= discussion_class.discussion_id(self)
  end

  def force_cross_reference_regex_check?
    return unless system?

    SystemNoteMetadata::TYPES_WITH_CROSS_REFERENCES.include?(system_note_metadata&.action)
  end
end