require "application_system_test_case"

class HumanEmailSendTest < ApplicationSystemTestCase
  class RecordingTransport
    attr_reader :deliveries

    def initialize(error: nil)
      @error = error
      @deliveries = []
    end

    def deliver!(**attributes)
      @deliveries << attributes
      raise @error if @error
    end
  end

  class CleanScanner
    def scan(**)
      AttachmentScanner::Result.new(status: :clean, code: "clean")
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

  test "a human adds and removes a quarantined draft attachment on mobile" do
    support_case = email_support_case
    sign_in_in_browser(users(:owner))
    visit workspace_support_case_path(support_case.workspace, support_case)
    find(".email-reply-form textarea[name='body']").set("Draft with a file")
    click_button "Save draft"
    assert_text "Draft saved."

    page.current_window.resize_to(390, 844)
    attach_file "Add attachments", Rails.root.join("test/fixtures/files/note.txt")
    click_button "Add files"
    assert_text "Attachments added."
    within ".draft-attachment-list" do
      assert_text "note.txt"
      assert_text "Quarantined: Scanner unavailable"
      assert_operator find_link("Remove").evaluate_script("this.getBoundingClientRect().height"), :>=, 44
    end
    assert_text "Send stays blocked until every attachment passes malware scanning."
    assert_button "Send email", disabled: true
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", find(".draft-attachment-list"))
    save_screenshot Rails.root.join(".amp/in/artifacts/email-attachment-mobile.png") if ENV["CAPTURE_HUMAN_EMAIL_SEND"]

    click_link "Remove"
    assert_text "Attachment removed."
    assert_no_text "note.txt"
  end

  test "a human sees and confirms an external Reply-To before sending" do
    support_case = email_support_case(reply_to: "third-party@example.org")
    transport = RecordingTransport.new
    sign_in_in_browser(users(:owner))

    with_transport(transport) do
      page.current_window.resize_to(390, 844)
      visit workspace_support_case_path(support_case.workspace, support_case)
      within ".recipient-review-warning" do
        assert_text "third-party@example.org"
        assert_text "not linked to the contact"
        assert_unchecked_field "I checked this recipient address"
      end
      assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
      page.execute_script("arguments[0].scrollIntoView({ block: 'start' })", find(".recipient-review-warning"))
      save_screenshot Rails.root.join(".amp/in/artifacts/human-email-external-recipient-mobile.png") if ENV["CAPTURE_HUMAN_EMAIL_SEND"]

      find(".email-reply-form textarea[name='body']").set("Checked external reply")
      check "I checked this recipient address"
      accept_confirm { click_button "Send email" }
      assert_text "Email sent."
      assert_equal "third-party@example.org", transport.deliveries.sole[:to]
    end
  end

  test "a human reviews an uncertain outcome before a fresh send is allowed" do
    support_case = email_support_case
    draft = EmailDraftWorkflow.save!(
      workspace: support_case.workspace, support_case: support_case,
      membership: memberships(:owner_support), body: "Uncertain answer", expected_lock_version: "new"
    )
    attachment = EmailAttachmentWorkflow.add!(
      workspace: support_case.workspace, support_case: support_case,
      membership: memberships(:owner_support), draft_version: draft.lock_version,
      files: [ { filename: "review-copy.txt", data: "review bytes" } ], scanner: CleanScanner.new
    ).sole
    sign_in_in_browser(users(:owner))

    with_transport(RecordingTransport.new(error: Net::ReadTimeout.new("timeout"))) do
      visit workspace_support_case_path(support_case.workspace, support_case)
      find(".email-reply-form textarea[name='body']").set("Uncertain answer")
      accept_confirm { click_button "Send email" }
      assert_text "Delivery outcome needs review"
      delivery = support_case.workspace.outbound_email_deliveries.sole
      assert_text delivery.to_address
      assert_text delivery.message_id
      assert_text "Uncertain answer"
      assert_link attachment.filename
      assert_button "Mark accepted"
      assert_button "Mark not sent"
      refute_button "Send email"
      page.current_window.resize_to(390, 844)
      assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
      assert_operator find_button("Mark accepted").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
      assert_operator find_button("Mark not sent").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
      page.execute_script("arguments[0].scrollIntoView({ block: 'start' })", find(".inline-error"))
      save_screenshot Rails.root.join(".amp/in/artifacts/human-email-send-review.png") if ENV["CAPTURE_HUMAN_EMAIL_SEND"]

      accept_confirm { click_button "Mark not sent" }
      assert_text "Delivery marked as not sent"
      assert_button "Send email"
      assert_equal "Uncertain answer", find(".email-reply-form textarea[name='body']").value
    end
  end

  private
    def email_support_case(reply_to: nil)
      inbox = workspaces(:acme_support).shared_email_inboxes.create!(
        name: "Support",
        email_address: "support@example.com",
        credential_key: "support"
      )
      SharedEmailIntake.receive!(
        inbox: inbox,
        raw_email: raw_email(reply_to: reply_to),
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

    def raw_email(reply_to: nil)
      headers = [
        "From: Alice Example <alice@example.net>",
        ("Reply-To: #{reply_to}" if reply_to),
        "To: Support <support@example.com>",
        "Date: Mon, 24 Aug 2026 11:55:00 +0000",
        "Subject: Email help",
        "Message-ID: <system-root@example.net>",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8"
      ].compact
      (headers + [ "", "Please help" ]).join("\r\n")
    end
end
