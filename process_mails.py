import imaplib
import smtplib
import email
import zipfile
import os
import io
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication
from dotenv import load_dotenv

# Umgebungsvariablen laden
load_dotenv()

# Konfiguration aus .envDatei
IMAP_SERVER = os.getenv('IMAP_SERVER')
IMAP_PORT = int(os.getenv('IMAP_PORT', 993))
IMAP_USER = os.getenv('IMAP_USER')
IMAP_PASSWORD = os.getenv('IMAP_PASSWORD')

SMTP_SERVER = os.getenv('SMTP_SERVER')
SMTP_PORT = int(os.getenv('SMTP_PORT', 587))
SMTP_USER = os.getenv('SMTP_USER')
SMTP_PASSWORD = os.getenv('SMTP_PASSWORD')

SOURCE_FOLDER = os.getenv('SOURCE_FOLDER', 'INBOX')
TARGET_EMAIL = os.getenv('TARGET_EMAIL')
DELETE_AFTER_PROCESSING = os.getenv('DELETE_AFTER_PROCESSING', 'false').lower() == 'true'
FILTER_SENDER = os.getenv('FILTER_SENDER', '').lower()
FILTER_SUBJECT = os.getenv('FILTER_SUBJECT', '').lower()

def connect_imap():
...
    for email_id in email_ids:
        res, msg_data = mail.fetch(email_id, '(RFC822)')
        raw_email = msg_data[0][1]
        msg = email.message_from_bytes(raw_email)
        
        # Absender prüfen
        sender = msg.get("From", "").lower()
        if FILTER_SENDER and FILTER_SENDER not in sender:
            print(f"Überspringe Mail: Absender '{sender}' passt nicht zu Filter '{FILTER_SENDER}'")
            continue

        subject_header = email.header.decode_header(msg["Subject"])[0][0]
        if isinstance(subject_header, bytes):
            subject = subject_header.decode()
        else:
            subject = subject_header
        
        # Betreff prüfen
        if FILTER_SUBJECT and FILTER_SUBJECT not in subject.lower():
            print(f"Überspringe Mail: Betreff '{subject}' passt nicht zu Filter '{FILTER_SUBJECT}'")
            continue

        print(f"Verarbeite E-Mail: {subject}")
        pdf_found = False

        # Durchlaufe alle Teile der E-Mail
        for part in msg.walk():
            if part.get_content_maintype() == 'multipart':
                continue
            if part.get('Content-Disposition') is None:
                continue

            filename = part.get_filename()
            if filename and filename.lower().endswith('.zip'):
                print(f"ZIP-Anhang gefunden: {filename}")
                
                # ZIP Dateiinhalt lesen
                zip_data = part.get_payload(decode=True)
                
                try:
                    with zipfile.ZipFile(io.BytesIO(zip_data)) as z:
                        for zip_info in z.infolist():
                            if zip_info.filename.lower().endswith('.pdf') and not zip_info.is_dir():
                                print(f"PDF im ZIP entdeckt: {zip_info.filename}")
                                
                                # PDF extrahieren
                                with z.open(zip_info) as pdf_file:
                                    pdf_content = pdf_file.read()
                                    
                                    # PDF senden
                                    # Bereinige Dateinamen (keine Pfade)
                                    clean_filename = os.path.basename(zip_info.filename)
                                    if send_email_with_pdf(pdf_content, clean_filename, subject):
                                        pdf_found = True
                except zipfile.BadZipFile:
                    print(f"Fehler: Datei {filename} ist kein gültiges ZIP-Archiv.")

        # Optional: E-Mail nach Verarbeitung löschen oder markieren
        if pdf_found and DELETE_AFTER_PROCESSING:
            mail.store(email_id, '+FLAGS', '\Deleted')
            print("Ursprüngliche E-Mail zum Löschen markiert.")
        
    if DELETE_AFTER_PROCESSING:
        mail.expunge()
        
    mail.close()
    mail.logout()
    print("Fertig.")

if __name__ == "__main__":
    try:
        process_emails()
    except Exception as e:
        print(f"Ein unerwarteter Fehler ist aufgetreten: {e}")
