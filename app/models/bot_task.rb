# frozen_string_literal: true

class BotTask < Message
  # self.inheritance_column = nil

  # acts_as_list scope: %i[app_id]

  belongs_to :app

  has_many :metrics, as: :trackable, dependent: :destroy

  # before_create :defaults

  store_accessor :settings, %i[
    scheduling
    urls
    outgoing_webhook
    paths
    user_type
  ]

  scope :enabled, -> { where(state: 'enabled') }
  scope :disabled, -> { where(state: 'disabled') }

  scope :for_leads, -> { 
    # where(type: 'leads') 
    where("settings->>'user_type' = ?", 'leads' )
  }
  scope :for_users, -> { 
    # where(type: 'users')
    where("settings->>'user_type' = ?", 'users' )
  }

  alias_attribute :title, :name


  scope :availables_for, lambda { |user|
    enabled.joins("left outer join metrics
      on metrics.trackable_type = 'Message'
      AND metrics.trackable_id = campaigns.id
      AND metrics.app_user_id = #{user.id}")
      .where('metrics.id is null')
  }

  #def segments
  #  predicates
  #end

  #def segments=(data)
  #  self.predicates = data
  #end

  def add_default_predicate
    self.segments = default_segments unless segments.present?
    self.settings = {} unless settings.present?
  end

  def available_segments
    segment = app.segments.new
    segment.assign_attributes(predicates: segments)
    app_users = segment.execute_query.availables
  end

  # consumed
  def available_for_user?(user)
    comparator = SegmentComparator.new(
      user: user,
      predicates: segments
    )

    comparator.compare # && metrics.where(app_user_id: user.id).blank?
  rescue ActiveRecord::RecordNotFound
    false
  end

  def self.broadcast_task_to_user(user)
    app = user.app
    key = "#{app.key}-#{user.session_id}"
    ret = nil
    
    app.bot_tasks.availables_for(user).each do |bot_task|
      next if bot_task.blank? || !bot_task.available_for_user?(user)

      MessengerEventsChannel.broadcast_to(key, {
        type: 'triggers:receive',
        data: {
          trigger: bot_task,
          step: bot_task.paths.first['steps'].first
        }
      }.as_json)

      user.metrics.create(
        trackable: bot_task,
        action: 'bot_tasks.delivered'
      )

      ret = true

      break
    end

    ret
  end

  def register_metric(user, data:, options:)
    label = data['label']

    user.metrics.create(
      trackable: self,
      action: "bot_tasks.actions.#{label}",
      data: options
    )
  end

  def log_action(action)
    user.metrics.create(
      trackable: bot_task,
      action: "bot_tasks.actions.#{action}"
    )
  end

  def default_segments
    default_predicate = { type: 'match',
                          attribute: 'match',
                          comparison: 'and',
                          value: 'and' }.with_indifferent_access

    user_predicate = {
      attribute: 'type',
      comparison: 'eq',
      type: 'string',
      value: 'AppUser'
    }.with_indifferent_access

    lead_predicate = {
      attribute: 'type',
      comparison: 'eq',
      type: 'string',
      value: 'Lead'
    }.with_indifferent_access

    if user_type == 'leads'
      [default_predicate, lead_predicate]
    else
      [default_predicate, user_predicate]
    end
  end

  def stats_fields
    [
      {
        name: 'DeliverRateCount',
        label: 'DeliverRateCount',
        keys: [
          { name: 'send', color: '#444' },
          { name: 'open', color: '#ccc' }
        ]
      }
    ]
  end

  def self.duplicate(record)
    self.create(record.dup)
  end
end
