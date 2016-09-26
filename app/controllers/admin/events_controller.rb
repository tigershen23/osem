module Admin
  class EventsController < Admin::BaseController
    load_and_authorize_resource :conference, find_by: :short_title
    load_and_authorize_resource :program, through: :conference, singleton: true
    load_and_authorize_resource :event, through: :program
    load_and_authorize_resource :events_registration, only: :toggle_attendance

    before_action :get_event, except: [:index, :create, :reports]

    # FIXME: The timezome should only be applied on output, otherwise
    # you get lost in timezone conversions...
    # around_filter :set_timezone_for_this_request

    def set_timezone_for_this_request(&block)
      Time.use_zone(@conference.timezone, &block)
    end

    def index
      @events = @program.events
      @tracks = @program.tracks
      @difficulty_levels = @program.difficulty_levels
      @event_types = @program.event_types
      @tracks_distribution_confirmed = @conference.tracks_distribution(:confirmed)
      @event_distribution = @conference.event_distribution
      @scheduled_event_distribution = @conference.scheduled_event_distribution

      respond_to do |format|
        format.html
        # Explicity call #to_json to avoid the use of EventSerializer
        format.json { render json: Event.where(state: :confirmed, program: @program).to_json }
      end
    end

    def show
      @tracks = @program.tracks
      @event_types = @program.event_types
      @comments = @event.root_comments
      @comment_count = @event.comment_threads.count
      @ratings = @event.votes.includes(:user)
      @difficulty_levels = @program.difficulty_levels
      @versions = @event.versions |
       PaperTrail::Version.where(item_type: 'Commercial').where_object(commercialable_id: @event.id, commercialable_type: 'Event') |
       PaperTrail::Version.where(item_type: 'Commercial').where_object_changes(commercialable_id: @event.id, commercialable_type: 'Event')
    end

    def edit
      @event_types = @program.event_types
      @tracks = Track.all
      @comments = @event.root_comments
      @comment_count = @event.comment_threads.count
      @user = @event.submitter
      @url = admin_conference_program_event_path(@conference.short_title, @event)
      @languages = @program.languages_list
    end

    def comment
      comment = Comment.new(comment_params)
      comment.commentable = @event
      comment.user_id = current_user.id
      comment.save!
      unless params[:parent].nil?
        comment.move_to_child_of(params[:parent])
      end

      redirect_to admin_conference_program_event_path(@conference.short_title, @event)
    end

    def update
      if @event.update_attributes(event_params)

        if request.xhr?
          render js: 'index'
        else
          flash[:notice] = "Successfully updated event with ID #{@event.id}."
          redirect_back_or_to(admin_conference_program_event_path(@conference.short_title, @event))
        end
      else
        @url = admin_conference_program_event_path(@conference.short_title, @event)
        flash[:error] = 'Update not successful. ' + @event.errors.full_messages.to_sentence
        render :edit
      end
    end

    def create; end

    def accept
      send_mail = @event.program.conference.email_settings.send_on_accepted
      subject = @event.program.conference.email_settings.accepted_subject.blank?
      update_state(:accept, 'Event accepted!', true, subject, send_mail)
    end

    def confirm
      update_state(:confirm, 'Event confirmed!')
    end

    def cancel
      update_state(:cancel, 'Event canceled!')
    end

    def reject
      send_mail = @event.program.conference.email_settings.send_on_rejected
      subject = @event.program.conference.email_settings.rejected_subject.blank?
      update_state(:reject, 'Event rejected!', true, subject, send_mail)
    end

    def restart
      update_state(:restart, 'Review started!')
    end

    def vote
      @ratings = @event.votes.includes(:user)

      if (votes = current_user.votes.find_by_event_id(params[:id]))
        votes.update_attributes(rating: params[:rating])
      else
        @myvote = @event.votes.build
        @myvote.user = current_user
        @myvote.rating = params[:rating]
        @myvote.save
      end

      respond_to do |format|
        format.html { redirect_to admin_conference_program_event_path(@conference.short_title, @event) }
        format.js
      end
    end

    def registrations
      @event_registrations = @event.events_registrations
    end

    def toggle_attendance
      @events_registration.attended = !@events_registration.attended

      if @events_registration.save
        head :ok
      else
        head :unprocessable_entity
      end
    end

    def reports
      @events = @program.events
      @events_commercials = Commercial.where(commercialable_type: 'Event', commercialable_id: @events.pluck(:id))
      @events_missing_commercial = @events.where.not(id: @events_commercials.pluck(:commercialable_id))
      @events_with_requirements = @events.where.not(description: ['', nil])

      attended_registrants_ids = @conference.registrations.where(attended: true).pluck(:user_id)
      @missing_event_speakers = EventUser.joins(:event).where('event_role = ? and program_id = ?', 'submitter', @program.id).
                                                                                        where.not(user_id: attended_registrants_ids).includes(:user, :event)
    end

    private

    def event_params
      params.require(:event).permit(
                                    # Set also in proposals controller
                                    :title, :subtitle, :event_type_id, :abstract, :description, :require_registration, :difficulty_level_id,
                                    # Set only in admin/events controller
                                    :track_id, :state, :language, :is_highlight, :max_attendees,
                                    # Not used anymore?
                                    :proposal_additional_speakers, :user, :users_attributes)
    end

    def comment_params
      params.require(:comment).permit(:commentable, :body, :user_id)
    end

    def get_event
      @event = @conference.program.events.find(params[:id])
      unless @event
        redirect_to admin_conference_program_events_path(conference_id: @conference.short_title),
                    error: 'Error! Could not find event!'
        return
      end
      @event
    end

    def update_state(transition, notice, mail = false, subject = false, send_mail = false)
      alert = @event.update_state(transition, mail, subject, send_mail, params[:send_mail].blank?)

      if alert.blank?
        flash[:notice] = notice
        redirect_back_or_to(admin_conference_program_events_path(conference_id: @conference.short_title)) && return
      else
        flash[:error] = alert
        return redirect_back_or_to(admin_conference_program_events_path(conference_id: @conference.short_title)) && return
      end
    end
  end
end
