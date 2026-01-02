# ZIP-to-Paperless Mail Processor

Dieses Projekt bietet eine automatisierte Lösung, um E-Mail-Anhänge im ZIP-Format zu verarbeiten. Da Dokumentenmanagementsysteme wie **Paperless-ngx** ZIP-Dateien oft nicht direkt einlesen können, extrahiert dieses Tool automatisch alle enthaltenen PDFs und leitet sie als einzelne E-Mails an das DMS weiter.

## Inhaltsverzeichnis
1. [Funktionsweise](#funktionsweise)
2. [Konfiguration (.env)](#konfiguration-env)
3. [Variante A: Python (Empfohlen)](#variante-a-python-empfohlen)
4. [Variante B: Shell-Script (Linux/WSL)](#variante-b-shell-script-linuxwsl)
5. [Automatisierung](#automatisierung)

---

## Funktionsweise
1. **Check:** Das Script verbindet sich via IMAP mit deinem Postfach.
2. **Suche:** Es sucht nach ungelesenen (UNSEEN) E-Mails.
3. **Extraktion:** ZIP-Anhänge werden erkannt und im Arbeitsspeicher (Python) oder einem Temp-Ordner (Shell) geöffnet.
4. **Filter:** Alle Dateien mit der Endung `.pdf` werden extrahiert.
5. **Versand:** Jedes PDF wird einzeln via SMTP an deine Paperless-Import-Adresse gesendet.
6. **Abschluss:** Die ursprüngliche Mail kann optional als gelesen markiert oder gelöscht werden.

---

## Konfiguration (.env)

Beide Versionen nutzen dieselbe Konfigurationsdatei. Erstelle eine Datei namens `.env` im Hauptverzeichnis (nutze `.env.example` als Vorlage).

### Grundlegende Einstellungen
*   **`IMAP_...`**: Zugangsdaten für dein Postfach, in dem die ZIPs ankommen.
*   **`SMTP_...`**: Zugangsdaten für den Versand (um die PDFs an Paperless weiterzuleiten).
*   **`TARGET_EMAIL`**: Deine Paperless-Empfangsadresse.

### Workflow-Steuerung
*   **`SOURCE_FOLDER`**: Der Ordner, der überwacht wird (meist `INBOX`).
*   **`DELETE_AFTER_PROCESSING`**:
    *   `true`: Die E-Mail wird nach erfolgreicher Extraktion der PDFs vom Server **gelöscht**.
    *   `false`: Die E-Mail bleibt erhalten und wird lediglich als "gelesen" markiert.
    *   *Hinweis:* Es werden nur Mails gelöscht, in denen tatsächlich ein ZIP mit PDFs gefunden und verarbeitet wurde.

### Filter-Optionen (Sinnvoll bei viel Mail-Verkehr)
Wenn dein Postfach nicht nur für Paperless genutzt wird, kannst du die Verarbeitung einschränken:
*   **`FILTER_SENDER`**: Gib eine E-Mail-Adresse an (z.B. `rechnung@firma.de`). Nur Mails von diesem Absender werden angefasst.
*   **`FILTER_SUBJECT`**: Gib ein Stichwort an (z.B. `Rechnung`). Nur Mails, die dieses Wort im Betreff haben, werden verarbeitet.
*   *Leer lassen:* Wenn du beide Felder leer lässt, werden alle neu eingehenden Mails auf ZIP-Anhänge geprüft.

---

## Variante A: Python (Empfohlen)
Die Python-Version ist robuster, plattformunabhängig (Windows, Mac, Linux) und benötigt keine temporären Dateien auf der Festplatte.

### Installation
1. Installiere Python (falls nicht vorhanden).
2. Installiere die Abhängigkeit:
   ```bash
   pip install -r requirements.txt
   ```

### Nutzung
```bash
python process_mails.py
```

---

## Variante B: Shell-Script (Linux/WSL)
Ideal für sehr schlanke Systeme oder wenn kein Python installiert werden soll. Benötigt System-Tools.

### Voraussetzungen
Installiere die benötigten Tools (Beispiel für Ubuntu/Debian/WSL):
```bash
sudo apt update && sudo apt install curl mpack unzip coreutils -y
```

### Nutzung
1. Script ausführbar machen:
   ```bash
   chmod +x process_mails.sh
   ```
2. Ausführen:
   ```bash
   ./process_mails.sh
   ```

---

## Automatisierung

Damit der Prozess im Hintergrund läuft, kannst du einen Zeitplaner nutzen.

### Linux / WSL (Cronjob)
Öffne die Crontab mit `crontab -e` und füge folgende Zeile für einen Check alle 10 Minuten hinzu:

```bash
# Für Python
*/10 * * * * cd /pfad/zu/zipmail-to-paperless && /usr/bin/python3 process_mails.py >> cron.log 2>&1

# ODER für Shell
*/10 * * * * cd /pfad/zu/zipmail-to-paperless && ./process_mails.sh >> cron.log 2>&1
```

### Windows (Aufgabenplanung)
1. Suche nach "Aufgabenplanung".
2. Erstelle eine "Einfache Aufgabe".
3. Trigger: Täglich / Alle 15 Minuten (über die erweiterten Einstellungen).
4. Aktion: Programm starten.
5. Programm: `python.exe`
6. Argumente: `C:\pfad\zu\process_mails.py`

---

## Sicherheitshinweis
Bewahre die `.env` Datei sicher auf. Sie enthält deine E-Mail-Passwörter im Klartext. Gib diese Datei niemals an Dritte weiter oder lade sie in öffentliche Repositories (GitHub etc.) hoch.
