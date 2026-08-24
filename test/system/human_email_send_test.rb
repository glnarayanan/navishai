require "application_system_test_case"

class HumanEmailSendTest < ApplicationSystemTestCase
  class RecordingTransport
    attr_reader :deliveries

    def initialize
      @deliveries = []
    end

    def deliver!(**attributes)
      @deliveries << attributes
    end
  end

  test "a human reviews, edits, and deliberately sends an email on desktop and mobile" do
    support_case = email_support_case
    transport = RecordingTransport.new
    sign_in_in_browser(users(:owner))

    with_transport(transport) do
      page.current_window.resize_to(1440, 1000)
      visit workspace_support_case_path(support_case.workspace, support_case)
      assert_text "Review the exact message, then press Send."
      refute_text "Email sent."
      find(".email-reply-form textarea[name='body']").set("First reviewed draft")
      click_button "Save draft"
      assert_text "Draft saved."
      assert_equal "First reviewed draft", find(".email-reply-form textarea[name='body']").value

      page.current_window.resize_to(390, 844)
      assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
      assert_operator find(".email-reply-form textarea[name='body']").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
      assert_operator find_button("Send email").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
      reply_body = find(".email-reply-form textarea[name='body']")
      page.execute_script("window.scrollTo(0, arguments[0].getBoundingClientRect().top + window.scrollY - 220)", reply_body)
      save_screenshot Rails.root.join(".amp/in/artifacts/human-email-send-mobile.png") if ENV["CAPTURE_HUMAN_EMAIL_SEND"]

      page.current_window.resize_to(1440, 1000)
      find(".email-reply-form textarea[name='body']").set("Exact answer sent by the owner")
      assert_difference "ConversationMessage.outbound.count", 1 do
        accept_confirm { click_button "Send email" }
        assert_text "Email sent."
      end
      assert_text "Exact answer sent by the owner"
      assert_text "This draft was sent by owner@example.com"
      assert_equal "Exact answer sent by the owner", transport.deliveries.sole[:body]
      save_screenshot Rails.root.join(".amp/in/artifacts/human-email-send-desktop.png") if ENV["CAPTURE_HUMAN_EMAIL_SEND"]
    end
  end

  test "a viewer can read an email case but cannot draft or send" do
    support_case = email_support_case
    viewer = User.create!(email_address: "email-browser-viewer@example.com", password: "password12345", verified_at: Time.current)
    Membership.create!(workspace: support_case.workspace, user: viewer, role: :viewer)
    sign_in_in_browser(viewer)

    visit workspace_support_case_path(support_case.workspace, support_case)

    assert_text "Read-only access. You cannot draft or send customer email."
    assert_no_selector ".email-reply-form"
    refute_button "Send email"
  end

  private
    def email_support_case
      inbox = workspaces(:acme_support).shared_email_inboxes.create!(
        name: "Support",
        email_address: "support@example.com",
        credential_key: "support"
      )
      SharedEmailIntake.receive!(
        inbox: inbox,
        raw_email: raw_email,
        received_at: Time.zone.parse("2026-08-24 12:00:00 UTC")
      ).conversation.support_case
    end

    def sign_in_in_browser(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end

    def with_transport(transport)
      singleton = SharedEmailSmtpTransport.singleton_class
      singleton.alias_method :new_without_test_transport, :new
      singleton.define_method(:new) { transport }
      yield
    ensure
      singleton.alias_method :new, :new_without_test_transport
      singleton.remove_method :new_without_test_transport
    end

    def raw_email
      <<~EMAIL.gsub("\n", "\r\n")
        From: Alice Example <alice@example.net>
        To: Support <support@example.com>
        Date: Mon, 24 Aug 2026 11:55:00 +0000
        Subject: Email help
        Message-ID: <system-root@example.net>
        MIME-Version: 1.0
        Content-Type: text/plain; charset=UTF-8

        Please help
      EMAIL
    end
end
