# Instalarea și recuperarea laboratorului Aurora pe Windows

Din directorul care conține scriptul, comanda implicită pregătește laboratorul în `AuroraMedicationLab`, lângă script. `-Root` selectează alt director de lucru. Programele deja instalate își păstrează locațiile.

```powershell
.\bootstrap-windows.ps1
.\bootstrap-windows.ps1 -LocateToolsOnFixedDrives
.\bootstrap-windows.ps1 -AdditionalSearchPath @('D:\Portable', 'E:\DevTools')
.\bootstrap-windows.ps1 --Docker
```

Comenzile de mai sus folosesc versiunea publicată în `main`. Pentru verificare înainte de integrarea PR-ului, lansează scriptul din branch-ul PR-ului și transmite și `-ScalaBranch fix/recover-existing-toolchains`. Astfel, actualizarea automată a laboratorului urmează același cod pe care îl testezi.

## Alegerea instrumentelor

| Componentă | Ce verifică scriptul | Ce reutilizează proiectul |
| --- | --- | --- |
| Java | Rulează executabilul și citește versiunea și `java.home`, inclusiv când comanda pornește printr-un shim. | Configurează `JAVA_HOME` și `PATH`. Proiectul poate folosi JDK 11, 17 și 21. Pentru alte versiuni eligibile, rezultatul probei cu proiectul decide compatibilitatea. |
| sbt | Caută distribuția instalată, launcherul indicat explicit și JAR-uri în cache-urile locale. | Launcherul pornește versiunea din `project/build.properties`, în prezent 1.10.2. Extensia VS Code primește locația efectivă prin `tools/layout.json`. |
| Scala | Versiunea compilatorului vine din `build.sbt`, în prezent 3.5.1. | Caută compilatorul în cache-urile Coursier, Ivy și Maven și în distribuțiile Scala. Recuperează JAR-ul 3.5.1 dacă SHA-256 corespunde artefactului oficial. Dacă găsește doar altă versiune, cere acordul pentru descărcarea compilatorului proiectului. |
| Node.js și npm | Rulează ambele comenzi și verifică dacă npm funcționează cu executabilul Node ales. | Folosește `NODE_HOME` și directoarele selectate pe `PATH`. Pentru proiectul Langium curent, intervalul acceptat este Node 22.x începând cu 22.12 sau Node 24+, cu npm 10.2.3+. |
| Langium și Langium CLI | Verifică modulele și legăturile workspace-ului față de `package-lock.json`. Versiunea fixată pentru ambele pachete este 4.4.0. | Folosește pachetele instalate în proiect și cache-ul npm. Dintr-o instalare globală poate recupera o arhivă numai dacă integritatea ei corespunde celei din lockfile. |
| PostgreSQL | Verifică utilitarele client și apoi deschide o conexiune autentificată la baza selectată. | PostgreSQL 15 este cea mai veche versiune de server testată în acest PR. Poate porni serviciul care corespunde instalării, inclusiv un serviciu cu nume particularizat. `PGHOME` indică instalarea clientului. |

Pe Windows se încearcă executabilele explicite, `PATH` și variabilele de mediu din proces, utilizator și sistem. Când acestea sunt insuficiente, căutarea folosește registrul, configurația serviciilor, directoarele furnizorilor, Program Files, directoarele utilizatorului și locații ale managerilor de versiuni. Pentru o instalare portabilă într-un director ales de tine, oferă rădăcina cu `-AdditionalSearchPath` sau calea exactă, de exemplu `-JavaPath 'D:\JDK\bin\java.exe'`. Când nu știi unde a fost instalat un program, `-LocateToolsOnFixedDrives` inventariază toate unitățile fixe accesibile și afișează căile găsite. Se oprește după inventar. Alege executabilul dorit la următoarea rulare. Inventarul raportează directoarele inaccesibile și legăturile omise. Pentru un director cunoscut, `-AdditionalSearchPath` îl poate verifica direct.

Variabilele instrumentelor se setează pentru execuția curentă și, implicit, pentru utilizatorul Windows. `-SessionOnlyEnvironment` le limitează la sesiunea curentă. Parola PostgreSQL este transmisă proceselor care au nevoie de ea.

## Când apare întrebarea despre upgrade

Dacă scriptul găsește o instalare compatibilă, o folosește direct. Dacă găsește o versiune incompatibilă, verifică alternativele disponibile înainte să propună schimbarea. Mesajul identifică componenta și ce ar modifica instalarea. Enter sau refuzul opresc schimbarea. Pentru o execuție automată, `-AllowToolUpgrade` acordă în prealabil permisiunea de upgrade pentru instrumentele din acea rulare.

O componentă lipsă poate fi instalată după căutare. Repararea dependențelor proiectului urmează versiunile declarate în repository. Migrarea datelor între versiuni majore de PostgreSQL este o operație separată, administrată de proprietarul bazei.

## PostgreSQL local sau în Docker

Pentru o bază și un rol deja existente, folosește contul aplicației. Scriptul verifică autentificarea înainte de build. Pe un Windows nou, poți cere explicit crearea obiectelor lipsă. Scriptul solicită datele administratorului atunci când are nevoie de ele.

```powershell
.\bootstrap-windows.ps1 -PgServiceName ClinicalDB -Database scala_testing_lab -DbUser scala_lab
.\bootstrap-windows.ps1 -ProvisionDatabase -PgAdminUser postgres
```

Cu `--Docker`, PowerShell găsește Docker și, dacă ai cerut editorul, VS Code pe Windows. Java, sbt, Scala, Node și Langium se execută în containerul Linux. Scriptul verifică instrumentele din acel container, inclusiv căile din imagine, alternativele și pachetele înregistrate în Linux, managerii de versiuni și cache-urile persistente. Pentru directoare suplimentare deja vizibile în container, poți adăuga `-DockerToolSearchPath @('/opt/company', '/workspace/tools')`. Un `java.exe` Windows și un executabil Java Linux sunt programe pentru sisteme de operare diferite.

Docker poate folosi serverul PostgreSQL deja disponibil pe portul local al gazdei, inclusiv un alt container care publică portul pe loopback. Activează **Enable host networking** în Docker Desktop 4.34 sau mai nou, alege baza și rolul, apoi rulează:

```powershell
.\bootstrap-windows.ps1 --Docker -DockerUseHostPostgres -Port 5432 -Database scala_testing_lab -DbUser scala_lab
```

Modul de mai sus folosește conexiunea loopback cerută de aplicația Scala. Pentru un laborator Docker separat, cu baza proprie, `-DockerUseManagedPostgres` face alegerea explicită. La reluare, scriptul verifică identitatea containerelor, volumele și configurația. O configurație diferită sau un volum rămas fără containerul corespunzător necesită recuperarea configurației originale.

## Ce demonstrează rezultatul final

`health.json` înregistrează rezultatele buildului, testelor Scala, autentificării PostgreSQL, verificării RxNorm și probelor DSL. Scriptul verifică separat serviciul HTTP folosit pentru sugestiile de produse. Astfel poți avea un laborator gata pentru validarea medicamentelor și un serviciu de autocomplete care mai trebuie pornit. Pașii pentru pornirea acestuia sunt în [PRODUCT-AUTOCOMPLETE.md](../PRODUCT-AUTOCOMPLETE.md).

La o nouă rulare, un import RxNorm deja valid se reutilizează. Când importul este necesar, scriptul recuperează numai fișierele RRF lipsă sau nevalide și grupează comenzile Scala într-o sesiune sbt. Se păstrează ultimele trei directoare de probe finalizate cu noua versiune, precum și rulările incomplete și directoarele cu fișiere suplimentare.


## Referințe tehnice

- [Compatibilitatea JDK cu Scala și sbt](https://docs.scala-lang.org/overviews/jdk-compatibility/overview.html)
- [Cum selectează launcherul versiunea sbt a proiectului](https://www.scala-sbt.org/1.x/docs/Basic-Def.html)
- [Integritatea pachetelor în cache-ul npm](https://docs.npmjs.com/cli/v11/commands/npm-cache/)
- [Compatibilitatea între clientul psql și serverul PostgreSQL](https://www.postgresql.org/docs/current/app-psql.html)
- [Accesul la rețeaua gazdei în Docker Desktop](https://docs.docker.com/engine/network/drivers/host/#docker-desktop)
