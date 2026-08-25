require "application_system_test_case"

class HumanIntercomSendTest < ApplicationSystemTestCase
  class RecordingClient
    attr_reader :replies

    def initialize
      @replies = []
    end

    def admins
      { "admins" => [ { "id" => "admin_owner", "email" => "owner@example.com" } ] }
    end

    def reply(conversation_id:, admin_id:, body:)
      @replies << { conversation_id:, admin_id:, body: }
      {
        "id" => conversation_id, "conversation_parts" => { "conversation_parts" => [
          {
            "id" => "browser_sent_part", "part_type" => "comment", "body" => "<p>#{body}</p>",
            "created_at" => Time.current.to_i,
            "author" => { "type" => "admin", "id" => admin_id, "name" => "Owner" }
          }
        ] }
      }
    end
  end

  test "a human saves and deliberately sends an Intercom reply on desktop and mobile" do
    support_case = intercom_support_case
    client = RecordingClient.new
    sign_in_in_browser(users(:owner))

    with_client(client) do
      page.current_window.resize_to(1440, 1000)
      visit workspace_support_case_path(support_case.workspace, support_case)
      within "#intercom-reply" do
        assert_text "Agents and jobs cannot send it"
        assert_text "Intercom conversation browser_conversation"
        fill_in "Message", with: "Reviewed Intercom draft"
        click_button "Save draft"
      end
      assert_text "Intercom draft saved."
      assert_equal "Reviewed Intercom draft", find("#intercom-reply textarea[name='body']").value

      page.current_window.resize_to(320, 844)
      overflow = page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
      offenders = page.evaluate_script(<<~JAVASCRIPT)
        Array.from(document.querySelectorAll('body *')).filter((element) => {
          const rect = element.getBoundingClientRect();
          return rect.right > window.innerWidth + 1 || rect.left < -1;
        }).slice(0, 8).map((element) => `${element.tagName}.${element.className}:${Math.round(element.getBoundingClientRect().left)}-${Math.round(element.getBoundingClientRect().right)}`)
      JAVASCRIPT
      assert_equal 0, overflow, offenders.join(", ")
      assert_operator find("#intercom-reply textarea").rect.height, :>=, 48
      assert_operator find_button("Send to Intercom").rect.height, :>=, 48

      page.current_window.resize_to(1440, 1000)
      within "#intercom-reply" do
        fill_in "Message", with: "Exact answer sent by the owner"
        accept_confirm { click_button "Send to Intercom" }
      end
      assert_text "Intercom reply sent."
      assert_text "Exact answer sent by the owner"
      assert_text "This reply was sent by owner@example.com"
    end

    assert_equal "Exact answer sent by the owner", client.replies.sole[:body]
    assert_equal "admin_owner", client.replies.sole[:admin_id]
  end

  private
    def intercom_support_case
      workspace = workspaces(:acme_support)
      message = ConversationThread.start_inbound!(
        workspace: workspace, contact: contacts(:alice), subject: "Intercom help",
        body: "Please help", occurred_at: 1.minute.ago, source: :integration
      )
      connection = workspace.intercom_connections.create!(
        name: "Browser Intercom", remote_workspace_id: "app_browser", credential_key: "support"
      )
      link = connection.intercom_conversation_links.create!(
        workspace: workspace, conversation: message.conversation, support_case: message.conversation.support_case,
        remote_conversation_id: "browser_conversation", remote_state: "open",
        source_digest: "a" * 64, remote_updated_at: message.occurred_at, synced_at: message.occurred_at
      )
      connection.intercom_part_links.create!(
        workspace: workspace, intercom_conversation_link: link, conversation: link.conversation,
        conversation_message: message, remote_part_id: "browser_customer_part", part_type: :contact_reply,
        body: message.body, source_digest: "b" * 64, remote_created_at: message.occurred_at
      )
      link.support_case
    end

    def sign_in_in_browser(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end

    def with_client(client)
      original = IntercomClient.method(:new)
      IntercomClient.define_singleton_method(:new) { |**| client }
      yield
    ensure
      IntercomClient.define_singleton_method(:new, original)
    end
end
