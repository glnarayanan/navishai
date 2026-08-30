class WorkspacesController < ApplicationController
  include WorkspaceAuthorization

  before_action :select_requested_workspace, only: %i[ show edit update ]
  before_action :require_workspace_owner, only: %i[ edit update ]

  def index
    @workspaces = Current.user.workspaces.active.order(:name)
    @deleting_workspaces = Current.user.workspaces.where.not(deletion_requested_at: nil)
      .includes(:workspace_deletion_request, :organization, memberships: :user).order(:name)
    @owned_workspace_ids = Current.user.memberships.owner.where(workspace_id: @workspaces).pluck(:workspace_id).to_set
  end

  def show
    redirect_to workspace_support_cases_path(Current.require_workspace!)
  end

  def new
    @workspace = Workspace.new
    load_owned_organizations
    head :forbidden if @organizations.empty?
  end

  def create
    load_owned_organizations
    organization = @organizations.find(workspace_params[:organization_id])
    @workspace = organization.workspaces.build(workspace_params.except(:organization_id))

    ApplicationRecord.transaction do
      @workspace.save!
      @workspace.memberships.create!(user: Current.user, role: :owner)
      audit_event("workspace.created", workspace: @workspace, subject: @workspace,
        metadata: { organization_id: organization.id })
    end

    select_workspace(@workspace)
    redirect_to edit_workspace_path(@workspace), notice: "Workspace created.", status: :see_other
  rescue ActiveRecord::RecordNotFound
    head :forbidden
  rescue ActiveRecord::RecordInvalid
    render :new, status: :unprocessable_content
  end

  def edit
    @membership = Current.require_membership!
  end

  def update
    previous_name = Current.workspace.name
    previous_slug = Current.workspace.slug
    ApplicationRecord.transaction do
      Current.workspace.update!(workspace_identity_params)
      audit_event("workspace.updated", subject: Current.workspace, metadata: {
        previous_name:, previous_slug:, name: Current.workspace.name, slug: Current.workspace.slug
      })
    end
    redirect_to edit_workspace_path(Current.workspace), notice: "Workspace settings saved.", status: :see_other
  rescue ActiveRecord::RecordInvalid
    @workspace = Current.workspace
    @membership = Current.require_membership!
    render :edit, status: :unprocessable_content
  end

  private
    def select_requested_workspace
      @workspace = Current.user.workspaces.active.find(params[:id])
      select_workspace(@workspace)
    end

    def require_workspace_owner
      head :forbidden unless Current.require_membership!.owner?
    end

    def load_owned_organizations
      @organizations = Organization.joins(workspaces: :memberships)
        .where(memberships: { user_id: Current.user.id, role: Membership.roles.fetch(:owner) })
        .where(workspaces: { deletion_requested_at: nil }).distinct.order(:name)
    end

    def workspace_params
      params.expect(workspace: [ :organization_id, :name, :slug ])
    end

    def workspace_identity_params
      params.expect(workspace: [ :name, :slug ])
    end
end
