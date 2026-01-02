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
    
    echo "DEBUG: Inhalt des Verzeichnisses nach munpack:"
    ls -l

    # Versuche, seltsame Dateinamen zu reparieren oder ZIPs zu erkennen
    # Gehe alle Dateien durch, die nicht email.eml sind
    for f in *; do
        if [ "$f" = "email.eml" ]; then continue; fi
        
        # Prüfe mit 'file' Kommando, ob es ein ZIP ist (falls 'file' installiert ist)
        if command -v file &> /dev/null; then
            if file -b --mime-type "$f" | grep -q "application/zip"; then
                echo "  Datei '$f' als ZIP erkannt (MIME-Type Check)."
                mv "$f" "attachment_$(date +%s).zip"
            fi
        else
             # Fallback: Wenn der Dateiname '.zip' (auch kodiert) enthält oder wir es einfach probieren wollen
             # Manche munpack Versionen erzeugen Dateinamen wie =...=2Ezip
             if [[ "$f" == *"=2Ezip"* ]] || [[ "$f" == *"=2EZIP"* ]]; then
                 echo "  Datei '$f' scheint ein kodiertes ZIP zu sein."
                 mv "$f" "attachment_$(date +%s).zip"
             fi
        fi
    done
    
    # Prüfe auf ZIP Dateien
    shopt -s nullglob
    zip_files=(*.zip *.ZIP)
    if [ ${#zip_files[@]} -eq 0 ]; then
        echo "  Keine ZIP-Dateien in dieser E-Mail gefunden."
    fi

    for zipfile in "${zip_files[@]}"; do
        if [ -f "$zipfile" ]; then
            echo "  ZIP gefunden: $zipfile"
            # 4. ZIP entpacken
            unzip -q -o "$zipfile" -d "extracted"
            
            # 5. Nach PDFs suchen und senden
            shopt -s nullglob
            pdf_files=(extracted/*.pdf extracted/*.PDF)
            if [ ${#pdf_files[@]} -eq 0 ]; then
                echo "    Keine PDF-Dateien im ZIP gefunden."
            fi

            for pdffile in "${pdf_files[@]}"; do
                if [ -f "$pdffile" ]; then
                    FILENAME=$(basename "$pdffile")
                    echo "    PDF gefunden: $FILENAME - Sende an $TARGET_EMAIL..."
                    
                    # 6. Senden via curl (SMTP)
                    BOUNDARY="NextPart_$(date +%s)"
                    CURRENT_DATE=$(date -R)
                    MSG_ID="<$(date +%s).$RANDOM@$SMTP_SERVER>"
                    
                    (
                    echo "Date: $CURRENT_DATE"
                    echo "From: ZipMail Bot <$SMTP_USER>"
                    echo "To: $TARGET_EMAIL"
                    echo "Message-ID: $MSG_ID"
                    echo "Subject: Extracted PDF: $FILENAME"
                    echo "MIME-Version: 1.0"
                    echo "Content-Type: multipart/mixed; boundary=\"$BOUNDARY\""
                    echo ""
                    echo "--$BOUNDARY"
                    echo "Content-Type: text/plain; charset=utf-8"
                    echo ""
                    echo "Automatisch extrahiertes PDF: $FILENAME"
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
                    
                    # Retry-Logik für den Versand
                    MAX_RETRIES=3
                    RETRY_COUNT=0
                    SENT_SUCCESS=false

                    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                        # Debug: SMTP Versand mit Fehlerausgabe
                        curl --url "smtp://$SMTP_SERVER:$SMTP_PORT" \
                             --ssl-reqd \
                             --mail-from "$SMTP_USER" \
                             --mail-rcpt "$TARGET_EMAIL" \
                             --user "$SMTP_USER:$SMTP_PASSWORD" \
                             --upload-file "mail_to_send.txt" --show-error --fail
                             
                        EXIT_CODE=$?
                        
                        if [ $EXIT_CODE -eq 0 ]; then
                            echo "    Erfolgreich gesendet."
                            pdf_found=true
                            SENT_SUCCESS=true
                            break
                        else
                            echo "    Fehler beim Senden (Curl Exit Code: $EXIT_CODE)."
                            RETRY_COUNT=$((RETRY_COUNT+1))
                            
                            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                                echo "    Rate Limit oder Server-Fehler vermutet. Warte 60 Sekunden vor Versuch $RETRY_COUNT von $MAX_RETRIES..."
                                for i in {60..1}; do
                                    echo -ne "    Warte... $i \r"
                                    sleep 1
                                done
                                echo -e "\n    Neuer Versuch..."
                            else
                                echo "    Gabe nach $MAX_RETRIES Versuchen auf."
                            fi
                        fi
                    done
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
