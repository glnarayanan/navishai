module HelpdeskTestHelper
  def create_support_case(subject: "Cannot sign in", workspace: workspaces(:acme_support), contact: contacts(:alice), membership: memberships(:owner_support))
    ConversationThread.start!(
      workspace: workspace,
      contact: contact,
      membership: membership,
      subject: subject,
      occurred_at: 2.hours.ago
    ).support_case
  end

  def add_inbound_message(support_case, body: "I still cannot access my account.", occurred_at: 1.hour.ago)
    ConversationThread.append_inbound!(
      workspace: support_case.workspace,
      conversation: support_case.conversation,
      author: support_case.conversation.contact,
      body: body,
      occurred_at: occurred_at,
      source: :integration
    )
  end
end
