# scala-testing-lab

Laborator personal **Scala/JVM + ZIO + PostgreSQL local** pentru [Aurora issue #48](https://github.com/Aurora-Constellations/auroraSjsExt/issues/48). Un AST Langium validat este mapat printr-un index RxNorm importat local. Rezoluția nu apelează RxNav sau alt API extern și nu necesită aliasuri manuale ori un RxCUI introdus de utilizator. Repository-urile Aurora nu sunt modificate.

Începe cu [ghidul Windows Server](docs/VM-WINDOWS-SERVER.md). [RXNORM.md](docs/RXNORM.md) explică importul datelor, iar [PUBLISH.md](docs/PUBLISH.md) publicarea în repo-ul personal și deschiderea unui draft PR.

## Workflow

1. Instalezi JDK 21, sbt, Node și PostgreSQL 17 local. Docker este opțional.
2. Descarci **RxNorm Full Monthly Release** prin contul tău NLM/UTS. Datele rămân pe VM.
3. Scala citește fișierele text `RXNCONSO.RRF` și `RXNREL.RRF`, transferă rândurile în PostgreSQL prin `COPY` și construiește tabelele derivate de concepte/nume și indexurile pentru nume/relații. Importul unui release este o singură tranzacție: succesul publică datele complete, eșecul face rollback.
4. Bridge-ul încarcă parserul real din `langium_dsl_lab/clinical-dsl-demo`, validează DSL-ul și exportă AST-ul ca DTO cu textul și pozițiile originale.
5. Scala caută numele în indexul lexical local, citește candidații și relațiile lor de compoziție, verifică rolul AST și produce dovezi. Nu încarcă întregul catalog la fiecare mapare.
6. Intrarea și raportul rămân local pentru audit. Un ingredient comun poate fi semnalat între ordinele aceluiași pacient din intrare.

## Comenzi pe Windows

După instalare și inițializarea bazei conform ghidului:

```powershell
. .\scripts\windows\Enter-Lab.ps1
. .\scripts\windows\Read-PostgresPassword.ps1
psql -X -w -v ON_ERROR_STOP=1 -c 'SELECT current_database(), current_user;'
sbt test

$rxArchive = Read-Host 'Calea completă către ZIP-ul RxNorm Full'
$rxRelease = Read-Host 'Data exactă a release-ului, yyyy-mm-dd'
.\scripts\windows\Import-RxNorm.ps1 -ArchivePath $rxArchive -Release $rxRelease -DataRoot C:\AuroraLab\data\rxnorm

sbt "run lookup $rxRelease paracetamol"

node bridge/export-ast.mjs --langium-root ../langium_dsl_lab/clinical-dsl-demo --input examples/paracetamol.clinical --release $rxRelease --output data/ast/paracetamol.json
if ($LASTEXITCODE -ne 0) { throw 'Export failed; do not consume an older JSON.' }
sbt 'run resolve data/ast/paracetamol.json out/paracetamol.json'
```

Helperul extrage numai cele două RRF necesare, în afara repo-ului, apoi invocă importatorul Scala. Acceptă opțional `-ExpectedSha256`. Pentru RRF deja extrase: `sbt -J-Xmx2G 'run import-rxnorm C:/cale/fara-spatii/rrf YYYY-MM-DD'`, cu calea și data înlocuite. Nu se furnizează seed sau fișier de aliasuri.

Conexiunea folosește `PGHOST=127.0.0.1`, `PGPORT=5432`, `PGDATABASE=scala_testing_lab`, `PGUSER=scala_lab` și `PGPASSWORD` citită ascuns. Primele rulări sbt/Metals pot descărca dependențe; după instalarea lor și import, căutarea terminologică este locală.

## Cazul paracetamol

Nu există o regulă `paracetamol → 161`. Numele este căutat între atomii importați din Full; asocierea cu un concept trebuie să existe în acel release. Rezultatul păstrează SAB și RxAUI ale numelui sursă, separat de denumirea canonică RXNORM.

CPC `2026-10-05` inspectat anterior nu conținea textul `paracetamol`; de aceea fluxul cere Full și numele din sursele asociate. Arhiva Full licențiată nu a fost disponibilă în mediul de pregătire. Potrivirea reală trebuie verificată pe VM: un nume absent produce `unresolved`, iar candidații multipli necesită clarificare. `lookup` raportează `matched`/`ambiguous`/`unresolved`; `resolve` aplică și regulile AST și raportează inclusiv `resolved`/`needsClarification`.

Un ingredient recunoscut nu identifică automat un produs, concentrație sau marcă. Valoarea fictivă `1 mg` din exemplu satisface validatorul demonstrativ Langium; nu este o doză recomandată. `examples/shared-ingredient.clinical` permite testarea ordinelor pentru același pacient după verificarea numelor în release-ul local.

## Arhitectură și integrare

Ticketul propune DuckDB + Parquet. Această revizie folosește **PostgreSQL**, conform cererii utilizatorului, pentru încărcarea RRF în tabele inspectabile prin SQL și căutare locală indexată. RRF este text tabelar delimitat prin `|`, nu un format binar nativ PostgreSQL. Importatorul gestionează delimitatorul final, UTF-8 și escaping-ul necesar pentru `COPY`.

Scala **3.5.1**, sbt **1.10.2** și `zio-json` **0.7.3** sunt aliniate cu fișierele Aurora accesibile analizate. ZIO **2.1.9** și PostgreSQL **17** sunt alegerile laboratorului. Driverul JDBC se descarcă prin sbt; nu necesită instalare separată în Windows. [Decizii și contracte](docs/ARCHITECTURE.md).

| Cale | Rol |
|---|---|
| `src/main/scala/lab/Domain.scala` | Contracte și validarea intrării |
| `src/main/scala/lab/Rrf.scala` | Citirea RRF, selecția terminologică, proveniență și hash-uri |
| `src/main/scala/lab/PostgresStore.scala` | Import COPY/tranzacțional și interogări locale |
| `src/main/resources/db/schema.sql` | Schema relațională și indexurile |
| `src/main/scala/lab/Resolver.scala` | Roluri, ambiguitate și compoziție |
| `bridge/` | Exportul AST real și verificări de integrare |
| `scripts/windows/` | Unelte, pregătirea PostgreSQL, import și publicare |

Pe Windows Server recomand instalarea PostgreSQL nativă. `compose.yaml` oferă alternativa Linux/WSL2. Dacă ai folosit versiunea anterioară cu Neo4j, aceasta rămâne neatinsă: inițializezi o bază PostgreSQL separată și imporți din nou RRF; nu există conversie sau ștergere automată a bazei vechi.

## Limite și verificare

Nu sunt implementate fuzzy matching, confirmarea clinicianului, verificări de dozaj, alergii sau interacțiuni. Gramatica actuală permite nume `ID` fără spații; CLI `lookup` poate testa denumiri independent de această limită. Concentrația și forma furnizate separat cer clarificare, deoarece selecția structurată a produsului rămâne de implementat.

Vezi rezultatele efectiv observate în [VALIDATION.md](docs/VALIDATION.md). Testele cu fixture-uri/CPC nu înlocuiesc importul și acceptanța unui Full release pe VM. Arhivele RxNorm, baza, parolele, datele de pacient și outputurile locale nu se includ în Git sau în ZIP-ul codului.
