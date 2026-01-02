#!/bin/bash

# Konfiguration laden (relativ zum Script-Pfad)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
if [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
else
    echo "Fehler: .envDatei nicht gefunden."
    exit 1
fi

# Arbeitsverzeichnisse
TMP_DIR="$SCRIPT_DIR/tmp_processing"
mkdir -p "$TMP_DIR"

# 1. Liste ungelesener Mails abrufen (UIDs)
# curl gibt oft Text zurück wie "* SEARCH 1 2 3", wir brauchen nur die Zahlen
echo "Prüfe auf neue E-Mails..."
SEARCH_RESULT=$(curl --url "imaps://$IMAP_SERVER/$SOURCE_FOLDER" --user "$IMAP_USER:$IMAP_PASSWORD" -X "SEARCH UNSEEN" --silent)

# Extrahiere UIDs (Alles nach "SEARCH" greifen)
UIDS=$(echo "$SEARCH_RESULT" | grep -oP '(?<=SEARCH ).*' | tr -d '\r' | xargs)

if [ -z "$UIDS" ]; then
    echo "Keine neuen E-Mails."
    rm -rf "$TMP_DIR"
    exit 0
fi

for MAIL_UID in $UIDS; do
    echo "Verarbeite Mail UID: $MAIL_UID"
    
    MAIL_DIR="$TMP_DIR/$MAIL_UID"
    mkdir -p "$MAIL_DIR"
    
    # 2. Mail herunterladen
    # --fail damit curl bei Serverfehlern einen Exit-Code != 0 liefert
    curl --url "imaps://$IMAP_SERVER/$SOURCE_FOLDER;UID=$MAIL_UID" --user "$IMAP_USER:$IMAP_PASSWORD" --silent --show-error --fail > "$MAIL_DIR/email.eml"
    
    if [ ! -s "$MAIL_DIR/email.eml" ]; then
        echo "  Warnung: E-Mail konnte nicht heruntergeladen werden oder ist leer."
        continue
    fi
    
    # 3. Anhänge extrahieren (munpack speichert im aktuellen Verzeichnis)
    cd "$MAIL_DIR"
    # munpack Output unterdrücken, wir prüfen gleich selbst auf ZIPs
    munpack -q "email.eml" > /dev/null 2>&1
    
    # Filter prüfen (Absender/Betreff)
    if [ -n "$FILTER_SENDER" ]; then
        if ! grep -q "From: .*$FILTER_SENDER" "email.eml"; then
            echo "  Überspringe: Absender passt nicht zum Filter."
            cd "$SCRIPT_DIR"
            continue
        fi
    fi
    if [ -n "$FILTER_SUBJECT" ]; then
        if ! grep -q "Subject: .*$FILTER_SUBJECT" "email.eml"; then
            echo "  Überspringe: Betreff passt nicht zum Filter."
            cd "$SCRIPT_DIR"
            continue
        fi
    fi

    pdf_found=false
    # Prüfe auf ZIP Dateien
    shopt -s nullglob
    for zipfile in *.zip *.ZIP; do
        if [ -f "$zipfile" ]; then
            echo "  ZIP gefunden: $zipfile"
            # 4. ZIP entpacken
            unzip -q -o "$zipfile" -d "extracted"
            
            # 5. Nach PDFs suchen und senden
            for pdffile in extracted/*.pdf extracted/*.PDF; do
                if [ -f "$pdffile" ]; then
                    FILENAME=$(basename "$pdffile")
                    echo "    PDF gefunden: $FILENAME - Sende an $TARGET_EMAIL..."
                    
                    # 6. Senden via curl (SMTP)
                    BOUNDARY="NextPart_$(date +%s)"
                    (
                    echo "From: $SMTP_USER"
                    echo "To: $TARGET_EMAIL"
                    echo "Subject: Extracted PDF: $FILENAME"
                    echo "MIME-Version: 1.0"
                    echo "Content-Type: multipart/mixed; boundary=\"$BOUNDARY\""
                    echo ""
                    echo "--$BOUNDARY"
                    echo "Content-Type: text/plain; charset=utf-8"
                    echo ""
                    echo "Automatisch extrahiertes PDF."
                    echo ""
                    echo "--$BOUNDARY"
                    echo "Content-Type: application/pdf"
                    echo "Content-Transfer-Encoding: base64"
                    echo "Content-Disposition: attachment; filename=\"$FILENAME\""
                    echo ""
                    base64 "$pdffile"
                    echo ""
                    echo "--$BOUNDARY--"
                    ) > "mail_to_send.txt"
                    
                    curl --url "smtps://$SMTP_SERVER:$SMTP_PORT" \
                         --ssl-reqd \
                         --mail-from "$SMTP_USER" \
                         --mail-rcpt "$TARGET_EMAIL" \
                         --user "$SMTP_USER:$SMTP_PASSWORD" \
                         --upload-file "mail_to_send.txt" --silent
                         
                    if [ $? -eq 0 ]; then
                        echo "    Erfolgreich gesendet."
                        pdf_found=true
                    fi
                fi
            done
        fi
    done

    # 7. Löschen falls konfiguriert
    if [ "$pdf_found" = true ] && [ "$DELETE_AFTER_PROCESSING" = "true" ]; then
        echo "  Lösche E-Mail UID $MAIL_UID vom Server..."
        curl --url "imaps://$IMAP_SERVER/$SOURCE_FOLDER" \
             --user "$IMAP_USER:$IMAP_PASSWORD" \
             -X "STORE $MAIL_UID +FLAGS (\Deleted)" --silent
        curl --url "imaps://$IMAP_SERVER/$SOURCE_FOLDER" \
             --user "$IMAP_USER:$IMAP_PASSWORD" \
             -X "EXPUNGE" --silent
    fi

    cd "$SCRIPT_DIR"
done

# Aufräumen
rm -rf "$TMP_DIR"
echo "Fertig."
