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
    sign_in(users(:owner))

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
      assert_text "Sent by owner@example.com"
      assert_equal "Exact answer sent by the owner", transport.deliveries.sole[:body]
      save_screenshot Rails.root.join(".amp/in/artifacts/human-email-send-desktop.png") if ENV["CAPTURE_HUMAN_EMAIL_SEND"]
    end
  end

  test "a human adopts blocked proof and keeps edit authority on desktop and mobile" do
    support_case = email_support_case
    artifact = create_draft_artifact(
      workspace: support_case.workspace, support_case:, membership: memberships(:owner_support),
      body: "Generated answer with proof", result_state: "blocked", evidence_status: "stale",
      blocker_message: "Current reset evidence is stale.",
      remediation: "Refresh the reset evidence or qualify the final human message."
    )
    sign_in(users(:owner))
    transport = RecordingTransport.new

    with_transport(transport) do
      page.current_window.resize_to(1440, 1000)
      visit workspace_support_case_path(support_case.workspace, support_case)

      within "#email-reply" do
        assert_text "Human-authored draft"
        assert_text "No AI artifact is linked."
      end
      if ENV["CAPTURE_HUMAN_DRAFT_AUTHORITY"]
        page.execute_script(
          "document.documentElement.style.scrollBehavior = 'auto'; arguments[0].scrollIntoView({ block: 'start' })",
          find("#email-draft-provenance h3")
        )
        save_screenshot Rails.root.join(".amp/in/artifacts/human-draft-authority-human-desktop.png")
      end

      source_summary = find("summary", text: "Choose an AI draft")
      source_summary.send_keys(:enter)
      assert page.evaluate_script("document.activeElement === arguments[0]", source_summary)
      assert_selector ".draft-source-selector[open]"
      candidate_summary = find(".draft-source-candidate > summary")
      candidate_summary.send_keys(:enter)
      assert_selector ".draft-source-candidate[open]"
      within ".draft-source-candidate" do
        assert_text "Blocked"
        assert_text "Stale conversation"
        assert_text "Current reset evidence is stale."
        assert_text "Refresh the reset evidence or qualify the final human message."
        assert_text "A blocked or unresolved source stays blocked or unresolved."
        click_button "Use this AI draft"
      end

      within "#email-draft-provenance" do
        assert_text "AI source · Generated body"
        assert_text "This message still matches the generated body exactly."
        assert_text "Blocked"
      end
      assert_equal artifact.body, find("#email-reply textarea[name='body']").value
      assert_text HumanDraftProvenance::SEND_REVIEW_MESSAGE
      assert_button "Send email", disabled: true
      if ENV["CAPTURE_HUMAN_DRAFT_AUTHORITY"]
        page.execute_script(
          "arguments[0].scrollIntoView({ block: 'center' })",
          find("#email-draft-provenance .artifact-blockers")
        )
        save_screenshot Rails.root.join(".amp/in/artifacts/human-draft-authority-blocked-desktop.png")
        page.execute_script(
          "arguments[0].scrollIntoView({ block: 'start' })",
          find("#email-draft-provenance h3")
        )
        save_screenshot Rails.root.join(".amp/in/artifacts/human-draft-authority-generated-desktop.png")
      end

      find("#email-reply textarea[name='body']").set("Human-qualified final answer")
      click_button "Save draft"
      assert_text "Draft saved."
      within "#email-draft-provenance" do
        assert_text "AI source · Human-edited"
        assert_text "Edited by owner@example.com"
        assert_text "No sentence-level authorship is inferred."
        assert_selector "time[datetime]", minimum: 2
      end
      assert_button "Send email", disabled: false
      refute_text HumanDraftProvenance::SEND_REVIEW_MESSAGE

      page.current_window.resize_to(320, 844)
      assert_no_horizontal_overflow
      assert_operator find("#email-draft-provenance").rect.width, :<=, page.evaluate_script("window.innerWidth")
      assert_operator find_button("Send email").rect.height, :>=, 48
      if ENV["CAPTURE_HUMAN_DRAFT_AUTHORITY"]
        page.execute_script(
          "arguments[0].scrollIntoView({ block: 'start' })",
          find("#email-draft-provenance h3")
        )
        save_screenshot Rails.root.join(".amp/in/artifacts/human-draft-authority-edited-mobile.png")
      end

      page.current_window.resize_to(1440, 1000)
      assert_difference "ConversationMessage.outbound.count", 1 do
        accept_confirm { click_button "Send email" }
        assert_text "Email sent."
      end
      assert_text "Human-qualified final answer"
      assert_text "Sent by owner@example.com"
    end
    assert_equal "Human-qualified final answer", transport.deliveries.sole[:body]
  end

  test "a viewer can read an email case but cannot draft or send" do
    support_case = email_support_case
    viewer = User.create!(email_address: "email-browser-viewer@example.com", password: "password12345", verified_at: Time.current)
    Membership.create!(workspace: support_case.workspace, user: viewer, role: :viewer)
    sign_in(viewer)

    visit workspace_support_case_path(support_case.workspace, support_case)

    assert_text "Read-only access. You cannot draft or send customer email."
    assert_no_selector ".email-reply-form"
    refute_button "Send email"
  end

  test "a human adds and removes a quarantined draft attachment on mobile" do
    support_case = email_support_case
    sign_in(users(:owner))
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
    sign_in(users(:owner))

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
    sign_in(users(:owner))

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
