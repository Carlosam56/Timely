part of '../main.dart';

/// Single source of truth for the privacy text shown both in onboarding
/// (Account creation) and in Settings > Über Timely > Privatsphäre.
String kPrivacyText() {
  return 'Was Timely speichert:\n\n'
      '- Konto: E-Mail-Adresse, Benutzername, Name und Bio (auf den Timely-Servern).\n'
      '- WebUntis-Verbindung: Schulname und WebUntis-Benutzername (auf den Timely-Servern).\n'
      '- Freunde und Gruppen: Anfragen, Freundschaften, Gruppen, Mitglieder und Gruppenbilder.\n'
      '- Stundenplan: nur wenn du das Teilen aktiviert hast (Einstellungen > Stundenplan). '
      'Er ist dann für deine Freunde und Gruppenmitglieder sichtbar. Beim Ausschalten wird er gelöscht.\n\n'
      'Was nur auf deinem Gerät bleibt:\n\n'
      '- Dein WebUntis-Passwort. Es wird verschlüsselt im Schlüsselspeicher deines Geräts abgelegt '
      'und nur an WebUntis gesendet, nie an Timely.\n'
      '- Zwischengespeicherte Stundenpläne für die Offline-Ansicht.\n\n'
      'Beim Ausloggen werden Passwort und Zwischenspeicher vom Gerät gelöscht. '
      'Über Einstellungen > Konto > Konto löschen kannst du dein Konto und deine Daten entfernen.';
}

/// Single source of truth for the terms-of-service text shown both in
/// onboarding (Account creation) and in Settings > Über Timely > Regeln.
String kTermsText() {
  return 'Stand: ${DateTime.now().year}. Timely ist ein privates Schulprojekt von Carlos A. '
      'und kein kommerzielles Produkt.\n\n'
      '1. Geltungsbereich\n'
      'Diese Bedingungen gelten für die Nutzung der App Timely und der zugehörigen '
      'Server (Konto, Freunde/Gruppen, geteilte Stundenpläne).\n\n'
      '2. Konto\n'
      'Du bist für die Angaben in deinem Konto und für die Geheimhaltung deines '
      'Passworts verantwortlich. Du musst mindestens 16 Jahre alt sein, um ein '
      'Konto zu erstellen.\n\n'
      '3. WebUntis\n'
      'Timely ist ein inoffizieller Client für WebUntis und steht in keiner '
      'Verbindung zu Untis GmbH. Die Nutzung deiner Schule-Zugangsdaten unterliegt '
      'zusätzlich den Bedingungen deiner Schule und von WebUntis.\n\n'
      '4. Nutzung\n'
      'Du darfst Timely nicht missbrauchen, z.B. um andere zu belästigen, Daten '
      'automatisiert abzugreifen oder die Server übermäßig zu belasten.\n\n'
      '5. Verfügbarkeit & Haftung\n'
      'Timely wird ohne Gewähr auf ständige Verfügbarkeit oder Fehlerfreiheit '
      'bereitgestellt. Für Schäden durch fehlerhafte oder verzögerte '
      'Stundenplandaten wird keine Haftung übernommen.\n\n'
      '6. Kündigung\n'
      'Du kannst dein Konto jederzeit über Einstellungen > Konto löschen. Wir '
      'können Konten bei Missbrauch sperren oder löschen.\n\n'
      '7. Änderungen\n'
      'Diese Bedingungen können sich ändern; wesentliche Änderungen werden in der '
      'App angekündigt.\n\n'
      'Hinweis: Timely ist ein Schulprojekt und kein kommerzielles Produkt. Diese '
      'Regeln ersetzen keine rechtliche Beratung.';
}
