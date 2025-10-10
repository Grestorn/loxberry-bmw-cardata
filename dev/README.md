# Local Development Environment

Diese Entwicklungsumgebung ermöglicht es, das BMW CarData Plugin Web-Interface lokal auf Windows zu testen, ohne das gesamte Projekt auf den LoxBerry hochladen zu müssen.

## Voraussetzungen

- **Perl** muss installiert sein (bereits vorhanden)
- **HTML::Template** Perl-Modul (wird automatisch verwendet)

## Schnellstart

### Methode 1: Direktes Ausführen (Einfachste Methode)

1. Öffnen Sie ein Terminal im Projektverzeichnis
2. Führen Sie aus:
   ```bash
   cd dev
   ./run-dev.bat
   ```
3. Das Script generiert `dev-output.html` und öffnet es im Browser

**Hinweis:** Diese Methode zeigt nur eine statische HTML-Ansicht. Formular-Aktionen funktionieren nicht.

### Methode 2: Manuelles Ausführen

```bash
cd dev
perl index-dev.cgi > output.html
```

Dann öffnen Sie `output.html` im Browser.

### Methode 3: Mit HTTP-Server (Empfohlen für volle Funktionalität)

Wenn Sie das Modul `HTTP::Server::Simple::CGI` installieren möchten:

```bash
# Installieren Sie cpanm (wenn noch nicht vorhanden)
curl -L https://cpanmin.us | perl - App::cpanminus

# Installieren Sie das benötigte Modul
cpanm HTTP::Server::Simple::CGI
```

Dann:
```bash
cd dev
./start-dev.bat
```

Der Server läuft dann auf: http://localhost:8080/dev/index-dev.cgi

## Was funktioniert im Dev-Modus?

✅ **Funktioniert:**
- Anzeige des Web-Interfaces
- Formular zur Konfiguration
- Anzeige der Anmeldeschritte mit Icons
- Speichern der Konfiguration (in `data/config.json`)
- Navigation zwischen den Seiten
- Sprachdateien (Deutsch/Englisch)

❌ **Funktioniert NICHT (nur auf LoxBerry):**
- OAuth-Authentifizierung (benötigt `bin/oauth-init.pl` und `bin/oauth-poll.pl`)
- Token-Refresh (benötigt `bin/token-manager.pl`)
- Bridge-Steuerung (benötigt `bin/bridge-control.sh`)
- Log-Ansicht (benötigt LoxBerry Log-System)

## Verzeichnisstruktur

```
dev/
├── LoxBerryMock.pm         # Mock-Modul für LoxBerry-Funktionen
├── index-dev.cgi           # Entwicklungs-Version des Web-Interfaces
├── start-dev-server.pl     # HTTP-Server (benötigt HTTP::Server::Simple::CGI)
├── start-dev.bat           # Start-Script für Windows (HTTP-Server)
├── run-dev.bat             # Einfaches Script zum direkten Ausführen
└── README.md               # Diese Datei

data/                       # Wird automatisch erstellt
├── config.json             # Gespeicherte Konfiguration
├── tokens.json             # OAuth-Tokens (wenn vorhanden)
└── logs/                   # Log-Verzeichnis
```

## Simulierte LoxBerry-Umgebung

Das `LoxBerryMock.pm` Modul simuliert folgende LoxBerry-Module:

- **LoxBerry::System** - Plugin-Metadaten
- **LoxBerry::Web** - Web-Interface-Funktionen (Header, Footer, Navigation)
- **LoxBerry::JSON** - JSON-Handling
- **LoxBerry::Log** - Logging (Dummy-Implementierung)
- **LoxBerry::IO** - MQTT-Konfiguration

### Pfad-Variablen

Die folgenden LoxBerry-Variablen werden auf lokale Pfade gemappt:

| LoxBerry Variable | Lokaler Pfad |
|-------------------|--------------|
| `$lbptemplatedir` | `templates/` |
| `$lbpdatadir` | `data/` |
| `$lbpbindir` | `bin/` |
| `$lbplogdir` | `data/logs/` |
| `$lbpconfigdir` | `config/` |

## Testen der visuellen Änderungen

### Schritt-Icons testen

Um die neuen Schritt-Icons zu sehen:

1. Starten Sie die Dev-Umgebung
2. Lassen Sie die Konfiguration leer → Sie sehen Schritt 1 mit blauem Pfeil
3. Geben Sie eine Client-ID ein und speichern Sie → Schritte 1 & 2 zeigen grüne Haken, Schritt 3 zeigt blauen Pfeil
4. Simulieren Sie weitere Schritte durch manuelles Bearbeiten von JSON-Dateien in `data/`

### Tab-Markierung testen

1. Öffnen Sie die Hauptseite → "Konfiguration & Anmeldung" Tab ist grün
2. Klicken Sie auf "Protokolle" → "Protokolle" Tab ist grün

## Tipps für die Entwicklung

### Schnelles Testen von UI-Änderungen

1. Ändern Sie HTML in `templates/index.html`
2. Ändern Sie Texte in `templates/lang/language_*.ini`
3. Führen Sie `run-dev.bat` erneut aus
4. Aktualisieren Sie die Browser-Ansicht

### Simulieren verschiedener Zustände

**Nicht authentifiziert:**
- Löschen Sie `data/tokens.json`

**Authentifiziert:**
- Erstellen Sie `data/tokens.json`:
```json
{
  "gcid": "test-gcid-123",
  "access_token": "test-access-token",
  "id_token": "test-id-token",
  "refresh_token": "test-refresh-token",
  "expires_at": 9999999999,
  "refresh_expires_at": 9999999999
}
```

**Device Code angefordert:**
- Erstellen Sie `data/device_code.json`:
```json
{
  "device_code": "test-device-code",
  "user_code": "ABC-DEF",
  "verification_uri": "https://www.bmw.de/verify",
  "verification_uri_complete": "https://www.bmw.de/verify?code=ABC-DEF",
  "expires_in": 600,
  "interval": 5
}
```

## Fehlerbehebung

### "Can't locate LoxBerry/System.pm"

Das ist normal - die Mock-Module übernehmen diese Funktion. Stellen Sie sicher, dass Sie `index-dev.cgi` verwenden, nicht die originale `webfrontend/htmlauth/index.cgi`.

### "Can't locate HTML/Template.pm"

Installieren Sie das Modul:
```bash
cpanm HTML::Template
```

### "Permission denied" beim Ausführen von .bat Dateien

Führen Sie das Terminal als Administrator aus oder verwenden Sie:
```bash
perl run-dev.bat
```

## Deployment auf LoxBerry

Nach dem Testen lokal können Sie das komplette Projekt auf den LoxBerry hochladen:

1. Erstellen Sie ein Plugin-Archiv (ZIP)
2. Installieren Sie über die LoxBerry Plugin-Verwaltung
3. Oder synchronisieren Sie direkt:
   ```bash
   rsync -avz --exclude 'dev' --exclude 'data' --exclude '.git' \
         . loxberry@<ip>:/opt/loxberry/webfrontend/htmlauth/plugins/loxberry-bmw-cardata/
   ```

## Spracheinstellung ändern

Setzen Sie die Umgebungsvariable `LOXBERRY_LANG`:

**Windows CMD:**
```cmd
set LOXBERRY_LANG=de
perl index-dev.cgi > output.html
```

**Windows PowerShell:**
```powershell
$env:LOXBERRY_LANG = "de"
perl index-dev.cgi > output.html
```

Standard ist Englisch (`en`).
