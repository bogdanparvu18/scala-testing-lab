# Arhitectură: Langium → Scala/ZIO → PostgreSQL local

Laboratorul implementează în repository-ul personal un traseu pentru [Aurora issue #48](https://github.com/Aurora-Constellations/auroraSjsExt/issues/48): importul unui catalog RxNorm local și maparea numelor din AST, fără seed per medicament, aliasuri manuale sau apeluri RxNav la rezoluție.

## Decizia de stocare

Revizia curentă folosește **PostgreSQL**, conform cererii utilizatorului. RRF are rânduri și coloane, iar tabelele relaționale permit încărcarea lor în masă, inspectarea provenienței și indexarea numelor. Relațiile RxNorm se păstrează în tabele și se parcurg prin interogări locale; un graph DB nu este obligatoriu pentru aceste operații.

RRF nu este format nativ PostgreSQL. Este text UTF-8 delimitat prin `|`, cu un delimitator final; importatorul Scala validează structura și îl adaptează la protocolul `COPY`. Nu execută un `COPY` brut peste arhiva ZIP și nu cere serverului acces la fișierele utilizatorului. Transferul se face prin conexiunea JDBC, folosind `COPY FROM STDIN`. [Documentația PostgreSQL COPY](https://www.postgresql.org/docs/17/sql-copy.html).

| Aspect | PostgreSQL în laborator | DuckDB + Parquet din ticket |
|---|---|---|
| Proces | Server local și driver JDBC pe JVM | Motor embedded |
| Catalog | Tabele RRF și tabele derivate indexate | Tabele/snapshot-uri și fișiere Parquet |
| Compoziție | Join-uri și parcurgere limitată a relațiilor | Join-uri pe relații |
| Publicarea unui import | Tranzacție per release; rollback la eșec | Politică de snapshot implementată separat |
| Inspecție | `psql`, SQL, opțional pgAdmin | SQL și inspecție Parquet |

PostgreSQL adaugă un serviciu de administrat, dar oferă un model familiar pentru date tabulare și un catalog local partajat. Docker este opțional; instalarea Windows nativă evită cerințele WSL2/nested virtualization.

La revizia Aurora `9fb1f69aaacfca694fc1757ceb582a2b72fe0a40`, [DependencyVersions.scala](https://github.com/Aurora-Constellations/auroraSjsExt/blob/9fb1f69aaacfca694fc1757ceb582a2b72fe0a40/project/DependencyVersions.scala) declară Scala `3.5.1` și `zio-json` `0.7.3`, iar [build.properties](https://github.com/Aurora-Constellations/auroraSjsExt/blob/9fb1f69aaacfca694fc1757ceb582a2b72fe0a40/project/build.properties) declară sbt `1.10.2`. Le păstrăm. ZIO core `2.1.9` și alegerea PostgreSQL aparțin laboratorului; nu presupunem că backendul Aurora inaccesibil folosește deja aceeași stocare.

## Importul și maparea sunt fluxuri distincte

**Import**, înainte de mapări:

1. Utilizatorul descarcă Full Monthly Release prin contul său NLM.
2. Helperul Windows extrage numai cele două fișiere RRF necesare în afara repo-ului și verifică hash-urile.
3. Scala încarcă rândurile `RXNCONSO` și `RXNREL` prin COPY, construiește tabelele de concepte/nume și indexează relațiile eligibile pentru rezoluție.
4. Hash-urile și numărul înregistrărilor sunt verificate înainte de finalizarea tranzacției.
5. Numai release-ul complet devine disponibil pentru mapare. Eșecul face rollback; o încercare nouă reia importul de la început.

**Rezoluție**, repetată pentru fiecare intrare:

1. Parserul, linkerul și validatorii reali Langium validează `.clinical`; bridge-ul exportă DTO-ul.
2. Scala verifică DTO-ul, pozițiile, proveniența și release-ul solicitat.
3. Indexul lexical PostgreSQL întoarce candidații numelui; adaptorul citește numai relațiile relevante pentru compoziția lor.
4. Regulile Scala verifică rolul semantic și unicitatea. Candidații multipli rămân expliciți și necesită clarificare.
5. Raportul păstrează numele sursă, conceptul, relațiile folosite și diagnosticele. Intrarea și rezultatul rămân local.

Nu sunt recitite RRF și nu este încărcat întregul catalog pentru fiecare lookup. Descărcările inițiale sbt/Metals sunt separate de căutarea terminologică locală.

## Responsabilități

| Componentă | Responsabilitate |
|---|---|
| Langium existent | Sintaxă, AST, referințe și validatorii demo-ului |
| `bridge/export-ast.mjs` | DTO cu text exact și poziții; fără reguli RxNorm duplicate în TypeScript |
| `InputValidation`, Scala | Contract, context și consistența provenienței |
| `Rrf`, Scala | Interpretarea RRF, selectarea înregistrărilor și hash-uri |
| `PostgresStore`, Scala/JVM | Schema, COPY, tranzacția de import, indexul și interogările locale |
| `Resolver`, Scala | Roluri, candidați, compoziție și regula ingredientelor comune |
| `Main`, Scala/ZIO | CLI și gestionarea efectelor/resurselor |

JDBC rulează pe **Scala JVM**, nu în extensia Scala.js. ZIO gestionează efectele și închiderea resurselor; operațiile JDBC blocking sunt încapsulate ca atare. Politica semantică se poate testa pe fixture-uri mici, separat de stocare.

## Modelul relațional și proveniența

Schema este în `src/main/resources/db/schema.sql`. Tabelele RRF `rxnconso` și `rxnrel` păstrează rândurile sursă; tabelele derivate `rx_concept` și `lexical_name` servesc rezoluția, iar relațiile eligibile sunt citite din `rxnrel` printr-un index parțial. Toate sunt în schema `rxnorm_lab`. Identificatorul release-ului separă versiunile, iar hash-urile identifică fișierele efectiv importate. Indexul lexical este pe `(release, md5(normalized))`, cu verificare obligatorie a egalității întregului nume normalizat în interogare. Digestul limitează dimensiunea cheii B-tree pentru nume lungi; nu decide singur identitatea și nu este folosit pentru securitate.

Un concept canonic are RxCUI, denumire și TTY. Un nume sursă păstrează textul original, cheia lexicală, RxAUI, TTY și SAB. Tabelele derivate includ formele canonice engleze active RXNORM cu TTY suportat și numele engleze active asociate lor, inclusiv cele provenite din alte surse. Rândurile sursă păstrate integral nu înseamnă că toate sunt eligibile pentru rezoluție.

Un atom provenit din alt vocabular nu este redenumit artificial în `SAB=RXNORM`. Cheia lexicală folosește Unicode NFKC, lowercase și normalizarea spațiilor; ea nu inventează sinonime. Asocierea `paracetamol` cu un RxCUI trebuie să existe în datele release-ului.

`RXNREL` este interpretat în sensul `RXCUI2 → RXCUI1`. Politica de compoziție urmărește un set explicit de tipuri de relații; nu parcurge arbitrar catalogul și nu atribuie unei mărci produsul ales implicit. `RXNSAT.RRF` nu este cerut: selecția structurată după concentrație și formă nu este încă implementată.

## Tranzacții și update-uri

Importul unui release are **o singură tranzacție**. Rândurile sunt transferate în streaming prin COPY, dar nu sunt comise în loturi parțiale. Eșecul sau închiderea conexiunii înainte de commit anulează importul; repetarea comenzii pornește din nou. Nu există checkpointuri de reluare la mijlocul fișierului. Starea internă `loading` devine `ready` înainte de commit, în aceeași tranzacție, fără expunerea unui import parțial.

Un release deja finalizat și aceleași surse este reverificat fără duplicare. Surse diferite sub aceeași dată sunt respinse. Pentru un update lunar se importă un release nou, iar fiecare AST/raport continuă să specifice versiunea exactă folosită. Nu se face fallback automat la alt release.

Hash-urile și numărul înregistrărilor protejează identitatea surselor și verifică completitudinea importului; nu reprezintă audit criptografic al oricărei editări SQL manuale. Un import Full poate cere spațiu suplimentar pentru indecși și WAL; dimensionarea trebuie măsurată pe VM. Streaming-ul COPY nu este o promisiune că toate structurile auxiliare au memorie constantă.

Versiunea PostgreSQL folosește o bază nouă. Datele unei instalări Neo4j anterioare nu sunt convertite sau șterse; se reimportă fișierele RRF originale în PostgreSQL.

## Contractul AST și raportul

Bridge-ul păstrează `schemaVersion`, `policyVersion`, `terminologyRelease`, `document`, `mentions`, numele original, rolul și contextul ordinului. [Contractul complet](../bridge/README.md). Pozițiile sunt zero-based UTF-16, cu final exclusiv. Doza, ruta și frecvența provin din planul existent.

Raportul folosește schema **2**, inclusiv `terminologyScope`. `initialConcept`, `selectedProduct`, `ingredients`, `candidates` și `diagnostics` separă deciziile. Dovezile includ numele sursă și relațiile folosite. Nu există seed sau politică de aliasuri manuale.

| Situație | Comportament |
|---|---|
| Un singur candidat potrivit rolului | Binding terminologic cu dovezi |
| Nume absent din index | `unresolved`; nu dovedește inexistența medicamentului |
| Mai mulți candidați | `needsClarification`; nu se alege primul |
| Ingredient într-un câmp care cere produs | Rol incompatibil |
| Formă/concentrație furnizate separat | Clarificare, deoarece selecția structurată nu este implementată |
| Release absent sau incomplet | Rezoluția este refuzată |

`resolved` nu dovedește siguranța prescripției. Doza administrată nu este concentrația produsului. Confirmarea clinicianului rămâne o extensie viitoare.

## Validare și integrare ulterioară

CPC `2026-10-05` inspectat anterior avea `acetaminophen`, dar nu avea textul `paracetamol`. Potrivirea reală pentru paracetamol trebuie verificată din Full release pe VM. [VALIDATION.md](VALIDATION.md) separă rezultatele observate de acceptanța încă necesară cu datele licențiate.

După validarea locală, contractele și politica pot deveni un modul reutilizabil. Adaptorul JDBC rămâne pe JVM; serverul Aurora ar expune endpointul, iar extensia ar transmite DTO-ul și afișa diagnosticele. Nu este necesar un server Scala HTTP suplimentar pentru laboratorul CLI. Forma/concentrația, confirmarea clinicianului, fuzzy matching, exportul Parquet și validările clinice rămân extensii separate. Aurora nu este modificat de acest PR personal.
