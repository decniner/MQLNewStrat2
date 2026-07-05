"""Gmail Inbox Cleaner — Delete flagged emails (run after approval)"""
import imaplib, email, json, os

EMAIL = 'decniner@gmail.com'
PASSWORD = 'kiut fnzx gtdm pkto'

def delete_flagged():
    mail = imaplib.IMAP4_SSL('imap.gmail.com')
    mail.login(EMAIL, PASSWORD)
    mail.select('INBOX')
    
    # Find all flagged (starred) emails
    status, ids = mail.search(None, 'FLAGGED')
    
    if status != 'OK' or not ids[0]:
        print("No flagged emails to delete.")
        mail.logout()
        return
    
    all_ids = ids[0].split()
    print(f"Found {len(all_ids)} flagged emails.")
    
    deleted = 0
    for msg_id in all_ids:
        try:
            # Move to trash
            mail.store(msg_id, '+X-GM-LABELS', '\\Trash')
            mail.store(msg_id, '+FLAGS', '\\Deleted')
            deleted += 1
        except:
            pass
    
    # Permanently remove from trash
    mail.expunge()
    mail.logout()
    
    report_path = os.path.expanduser('~/AppData/Local/hermes/cron/output/gmail_scan.json')
    print(f"\n✅ {deleted} emails moved to trash!")
    print("They'll auto-delete after 30 days (Gmail policy).")
    
    # Clear the report
    if os.path.exists(report_path):
        os.remove(report_path)

delete_flagged()
