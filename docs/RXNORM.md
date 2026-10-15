# RxNorm Full: index local în PostgreSQL

Acest flux importă un release RxNorm local înainte de căutări. Ulterior, `lookup` și `resolve` folosesc numai PostgreSQL prin JDBC; nu trimit numele medicamentului unui API extern. Nu există seed ales manual și nu există fișier de aliasuri.

## 1. Descarcă distribuția Full prin contul tău

Deschide [RxNorm Files, NLM](https://www.nlm.nih.gov/research/umls/rxnorm/docs/rxnormfiles.html), autentifică-te folosind contul tău NLM/UTS și descarcă **RxNorm Full Monthly Release**. Păstrează data exactă a release-ului din arhivă și numele original al fișierului. Nu folosi data descărcării ca versiune a terminologiei.

Alege Full, nu **Current Prescribable Content (CPC)**. CPC este o distribuție publică mai restrânsă, iar CPC `2026-10-05` verificat anterior nu conținea textul `paracetamol`. Full permite importarea numelor din sursele asociate conceptelor canonice RXNORM, cu proveniența lor explicită. Prezența efectivă a unui nume se verifică în release-ul descărcat; nu este înlocuită printr-o mapare hardcodată.

Scriptul nu se autentifică la NLM, nu citește parola/cheia contului și nu descarcă arhiva în numele tău. Intrarea sa este un ZIP deja salvat pe VM. Termenii surselor din Full se folosesc conform licenței tale; arhiva, fișierele RRF și baza locală nu se redistribuie în repository-ul proiectului.

## 2. Importă ZIP-ul în PowerShell

Pregătește PostgreSQL și shell-ul conform [ghidului Windows Server](VM-WINDOWS-SERVER.md). Din root-ul proiectului:

```powershell
. .\scripts\windows\Enter-Lab.ps1
. .\scripts\windows\Read-PostgresPassword.ps1
$rxArchive = Read-Host 'Calea completă către ZIP-ul RxNorm Full descărcat'
$rxRelease = Read-Host 'Data exactă a release-ului, yyyy-mm-dd'

.\scripts\windows\Import-RxNorm.ps1 `
  -ArchivePath $rxArchive `
  -Release $rxRelease `
  -DataRoot C:\AuroraLab\data\rxnorm
```

Dacă ai un SHA-256 de încredere pentru arhiva respectivă, furnizează-l prin `-ExpectedSha256`; nu reutiliza checksum-ul unui CPC ori al altui release. În lipsa lui, helperul calculează SHA-256 pentru identificarea intrării și pentru rerulări, dar un hash calculat local nu autentifică singur proveniența unui fișier.

Helperul folosește implicit maximum 2 GB heap pentru procesul sbt/JVM (`-SbtMaxHeapMB 2048`). Este un punct de pornire pentru VM-ul cu memorie suficientă, nu o măsurare a importului Full. Poți adapta parametrul după observarea consumului.

Helperul:

1. Verifică data ISO, arhiva, uneltele instalate și variabilele PostgreSQL. Refuză un nume de arhivă CPC care conține `prescribe`; selecția Full rămâne responsabilitatea utilizatorului, nu o autenticitate dovedită de numele fișierului.
2. Găsește exact o intrare Full `rrf/RXNCONSO.RRF` și una `rrf/RXNREL.RRF`, din același director, inclusiv dacă `rrf` se află sub un director suplimentar în ZIP. Exclude subdirectorul `prescribe/` care poate însoți distribuția Full. Nu extrage alte fișiere și nu folosește căi de ieșire dictate de arhivă.
3. Extrage într-un director temporar propriu și scrie un manifest cu hash-ul arhivei și al fiecărui RRF. Publică extragerea numai după verificare.
4. La rerulare, verifică manifestul și RRF existente. Nu suprascrie fișiere cu alte hash-uri sub același release.
5. Invocă sbt prin launcherul Java instalat de `Install-LabTools.ps1`. Căile cu spații sunt citate explicit; nu sunt reinterpretate de `cmd.exe`. Căile cu ghilimele, semicolon sau linii noi sunt respinse.

Directorul rezultat este `C:\AuroraLab\data\rxnorm\<release>\rrf`, separat de repository și de datele PostgreSQL. Aplicația Scala citește RRF și trimite datele prin JDBC/COPY FROM STDIN; serverul PostgreSQL nu are nevoie de acces direct la directorul fișierelor.

Dacă ai deja cele două RRF extrase într-un director fără spații, poți apela CLI direct:

```powershell
$rxRelease = Read-Host 'Data exactă a release-ului, yyyy-mm-dd'
sbt -J-Xmx2G "run import-rxnorm C:/AuroraLab/data/rxnorm/$rxRelease/rrf $rxRelease"
```

`RXNSAT.RRF` nu este cerut de acest flux; nu importăm atribute fără o utilizare semantică implementată. Prima instalare/build poate necesita internet pentru dependențe sbt. După caching și import, lookup-ul terminologic nu cere conexiune NLM/RxNav.

## 3. Ce stochează importul

| Informație | Scop |
|---|---|
| Rânduri RRF originale | Tabelele `rxnconso` și `rxnrel`, pentru inspecție SQL și proveniență |
| Concepte canonice active RXNORM | Identitate RxCUI, denumire canonică și TTY |
| Nume/atomi activi asociați | Text original și cheie lexicală, RxAUI, SAB și TTY; inclusiv nume din alte surse |
| Relații între concepte | RELA, RUI și direcție păstrate pentru traversare și audit |
| Release și hash-uri | Identitatea datelor efective, scope-ul importului și finalizarea tranzacției |
| Index lexical local | Găsirea candidaților fără recitirea RRF și fără încărcarea întregii baze în memorie |

Indexul de rezoluție reține concepte cu formă canonică activă engleză RXNORM și TTY suportat. Numele asociate sunt atomi englezi (`LAT=ENG`) cu `SUPPRESS=N`, din toate sursele disponibile pentru acele concepte. Conceptele exclusiv din alte surse, fără formă canonică RXNORM suportată, nu intră în catalogul derivat de rezoluție; rândurile brute rămân în tabelele RRF. Relațiile din catalogul derivat sunt legături active RXNORM între concepte; păstrarea rândurilor brute RXNREL nu le face automat eligibile pentru parcurgerea semantică.

Un nume dintr-o sursă asociată poate duce la conceptul său RxNorm, dar nu este redenumit artificial în `SAB=RXNORM`. Rezultatul păstrează proveniența reală. Normalizarea NFKC, lowercase și a spațiilor creează o cheie de căutare; nu inventează sinonime.

Importul nu se limitează la ingredientul `161` și nu cere utilizatorului să cunoască identificatorul unui medicament. Selecția după rolul AST are loc la căutare. `RXNREL` este interpretat cu relația din partea a doua a rândului către prima (`RXCUI2 → RXCUI1`), conform [documentației tehnice NLM](https://www.nlm.nih.gov/research/umls/rxnorm/docs/techdoc.html).

## 4. Import tranzacțional și repetare

Fișierele RRF sunt text UTF-8 delimitat prin `|`, cu delimitator final; nu sunt un format nativ PostgreSQL. Importatorul Scala adaptează rândurile la `COPY`, inclusiv escaping-ul necesar, și construiește tabelele derivate. Schema este în `src/main/resources/db/schema.sql`.

**Un release se importă într-o singură tranzacție.** Înainte de commit sunt verificate hash-urile și numărul înregistrărilor. O eroare face rollback, iar o nouă încercare începe importul de la capăt; nu există reluare de la un checkpoint parțial. Fișierele deja extrase și verificate de helper rămân disponibile.

Repetă aceeași comandă `Import-RxNorm.ps1` după remedierea cauzei. Nu șterge baza și nu modifica data doar pentru a ocoli eroarea. Un release finalizat este reverificat fără duplicare, iar surse schimbate sub aceeași identitate sunt respinse. Un release lunar nou are propria dată.

Datele sunt transferate în streaming, dar necesarul de memorie, spațiu pentru tabele/indexuri/WAL și timpul total trebuie măsurate pe Full release și pe VM-ul tău. Verificarea hash-urilor și a numărului rândurilor nu detectează orice editare manuală prin SQL.

Dacă ai folosit anterior Neo4j, inițializează baza PostgreSQL separată și importă din nou RRF. Scripturile nu convertesc și nu șterg datele vechi.

## 5. Verifică numele și apoi AST-ul

```powershell
sbt "run lookup $rxRelease paracetamol"
sbt "run lookup $rxRelease acetaminophen"
```

Nu furnizezi `161` și nu alegi în avans conceptul. Verifică RxCUI, denumirea canonică, SAB/RxAUI ale numelui potrivit și diagnosticele. Dacă numele lipsește din import, rezultatul trebuie să indice `unresolved`. Dacă există mai mulți candidați, nu se alege automat primul.

`lookup` raportează `matched`, `ambiguous` sau `unresolved`. Comanda `resolve` verifică suplimentar AST-ul și rolul semantic; ea folosește, între altele, statusurile `resolved` și `needsClarification`.

După [exportul AST](../bridge/README.md), cu `--release` identic celui importat:

```powershell
sbt 'run resolve data/ast/paracetamol.json out/paracetamol.json'
Get-Content out/paracetamol.json -Raw
```

Raportul are schema de ieșire `2` și descrie acoperirea în `terminologyScope`, separat de sursa exactă și hash-urile release-ului. Pentru fiecare mențiune, PostgreSQL este interogat prin cheia lexicală indexată; apoi sunt citite numai relațiile relevante pentru compoziția candidaților. Fișierele RRF nu sunt recitite pentru fiecare mapping.

## 6. Ce dovedește rezultatul

`resolved` înseamnă o legare terminologică acceptată pentru rolul dat, bazată pe datele locale. Un ingredient recunoscut nu selectează automat produsul, forma sau concentrația. Doza administrată din AST nu este concentrația produsului. Aliasuri locale, fuzzy matching și apeluri API pentru completarea lipsei unui nume nu sunt folosite.

Full release licențiat nu a fost disponibil în mediul de pregătire, astfel încât importul complet și potrivirea reală pentru `paracetamol` trebuie verificate pe VM. Rezultatele automate observate sunt consemnate separat în [VALIDATION.md](VALIDATION.md). Nu trebuie confundate teste cu fixture-uri/CPC cu o validare de producție a întregului catalog Full.
