import imaplib
import smtplib
import email
import zipfile
import os
import io
import time
import uuid
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication
from email.header import decode_header
from email.utils import formatdate, make_msgid
from dotenv import load_dotenv

# Umgebungsvariablen laden
load_dotenv()

# Konfiguration
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

def decode_mime_header(header_value):
    """Dekodiert MIME-Header (Subject, Filename) sicher."""
    if not header_value:
        return ""
    decoded_list = decode_header(header_value)
    result = ""
    for content, encoding in decoded_list:
        if encoding:
            try:
                result += content.decode(encoding)
            except:
                result += content.decode('utf-8', errors='ignore')
        elif isinstance(content, bytes):
            result += content.decode('utf-8', errors='ignore')
        else:
            result += str(content)
    return result

def send_email_with_pdf(pdf_content, filename, original_subject):
    """Sendet das PDF per SMTP."""
    msg = MIMEMultipart()
    msg['From'] = f"ZipMail Bot <{SMTP_USER}>"
    msg['To'] = TARGET_EMAIL
    msg['Subject'] = f"Extracted PDF: {filename}"
    msg['Date'] = formatdate(localtime=True)
    msg['Message-ID'] = make_msgid(domain=SMTP_SERVER)

    body = f"Automatisch extrahiertes PDF: {filename}\nUrsprünglicher Betreff: {original_subject}"
    msg.attach(MIMEText(body, 'plain', 'utf-8'))

    # PDF Anhang
    part = MIMEApplication(pdf_content, Name=filename)
    part['Content-Disposition'] = f'attachment; filename="{filename}"'
    msg.attach(part)

    # Retry Logik
    max_retries = 3
    for attempt in range(1, max_retries + 1):
        try:
            # SMTP Verbindung aufbauen
            if SMTP_PORT == 465:
                server = smtplib.SMTP_SSL(SMTP_SERVER, SMTP_PORT)
            else:
                server = smtplib.SMTP(SMTP_SERVER, SMTP_PORT)
                server.starttls() # STARTTLS für Port 587
                
            server.login(SMTP_USER, SMTP_PASSWORD)
            server.sendmail(SMTP_USER, TARGET_EMAIL, msg.as_string())
            server.quit()
            print(f"    E-Mail erfolgreich gesendet: {filename}")
            return True
        except Exception as e:
            print(f"    Fehler beim Senden (Versuch {attempt}/{max_retries}): {e}")
            if attempt < max_retries:
                print("    Warte 60 Sekunden wegen möglichem Rate Limit...")
                try:
                    for i in range(60, 0, -1):
                        print(f"    Warte... {i} \r", end="", flush=True)
                        time.sleep(1)
                    print("\n    Neuer Versuch...")
                except KeyboardInterrupt:
                    print("\n    Abbruch durch Benutzer.")
                    return False
    
    print(f"    Senden fehlgeschlagen nach {max_retries} Versuchen.")
    return False

def process_emails():
    print("Prüfe auf neue E-Mails (Python)...")
    
    try:
        # IMAP Verbindung
        mail = imaplib.IMAP4_SSL(IMAP_SERVER, IMAP_PORT)
        mail.login(IMAP_USER, IMAP_PASSWORD)
        mail.select(SOURCE_FOLDER)
        
                # Suchkriterien aufbauen
                search_criteria = ['UNSEEN']
                if FILTER_SENDER:
                    search_criteria.append(f'FROM "{FILTER_SENDER}"')
                if FILTER_SUBJECT:
                    search_criteria.append(f'SUBJECT "{FILTER_SUBJECT}"')
                
                # IMAP Search erwartet Criteria als String oder Argumente
                # Wir nutzen hier den charset Parameter 'None' und joinen die Criteria
                search_string = f'({" ".join(search_criteria)})'
                print(f"Suche nach E-Mails: {search_string}")
                
                status, messages = mail.search(None, *search_criteria)
                email_ids = messages[0].split()
                
                if not email_ids:
                    print("Keine neuen E-Mails.")
                    mail.close()
                    mail.logout()
                    return
        
                for email_id in email_ids:
                    # Fetch E-Mail
                    status, msg_data = mail.fetch(email_id, '(RFC822)')
                    raw_email = msg_data[0][1]
                    msg = email.message_from_bytes(raw_email)
                    
                    # Subjekt und Sender dekodieren
                    subject = decode_mime_header(msg["Subject"])
                    sender = decode_mime_header(msg.get("From"))
                    
                    print(f"Verarbeite Mail ID {email_id.decode()}: {subject}")
        
                    # (Filter hier nicht mehr nötig, da im SEARCH)
                    
                    pdf_found = False
                    send_failed = False
        
                    # Anhänge durchsuchen
                    for part in msg.walk():
                        if part.get_content_maintype() == 'multipart':
                            continue
                        if part.get('Content-Disposition') is None:
                            continue
        
                        filename = decode_mime_header(part.get_filename())
                        
                        # Check auf ZIP (auch wenn Name komisch kodiert war)
                        if filename and (filename.lower().endswith('.zip') or part.get_content_type() == 'application/zip'):
                            print(f"  ZIP gefunden: {filename}")
                            
                            try:
                                zip_data = part.get_payload(decode=True)
                                if not zip_data:
                                    print("    Warnung: Leerer ZIP-Inhalt.")
                                    continue
        
                                with zipfile.ZipFile(io.BytesIO(zip_data)) as z:
                                    for zip_info in z.infolist():
                                        if zip_info.filename.lower().endswith('.pdf') and not zip_info.is_dir():
                                            print(f"    PDF im ZIP entdeckt: {zip_info.filename}")
                                            
                                            with z.open(zip_info) as pdf_file:
                                                pdf_content = pdf_file.read()
                                                clean_filename = os.path.basename(zip_info.filename)
                                                
                                                if send_email_with_pdf(pdf_content, clean_filename, subject):
                                                    pdf_found = True
                                                else:
                                                    # Senden fehlgeschlagen (trotz Retries)
                                                    send_failed = True
                            except zipfile.BadZipFile:
                                print(f"    Fehler: Ungültiges ZIP-Archiv.")
                            except Exception as e:
                                print(f"    Fehler beim Verarbeiten des ZIPs: {e}")
        
                    if send_failed:
                        print(f"  Warnung: Verarbeitung für ID {email_id.decode()} fehlgeschlagen. Markiere als UNGELESEN für Retry.")
                        mail.store(email_id, '-FLAGS', '\Seen')
                    elif pdf_found and DELETE_AFTER_PROCESSING:
                        print(f"  Lösche E-Mail ID {email_id.decode()}...")
                        mail.store(email_id, '+FLAGS', '\Deleted')        
        if DELETE_AFTER_PROCESSING:
            mail.expunge()
            
        mail.close()
        mail.logout()
        print("Fertig.")

    except Exception as e:
        print(f"Ein Fehler ist aufgetreten: {e}")

if __name__ == "__main__":
    process_emails()