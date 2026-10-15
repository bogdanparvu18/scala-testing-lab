# Verificări — PostgreSQL, versiunea 0.3.0

Verificări la pregătirea arhivei, 13 octombrie 2026. Codul nu a fost executat pe VM-ul utilizatorului. Rezultatele vechii integrări Neo4j nu sunt prezentate drept verificări PostgreSQL.

| Verificare | Rezultat observat |
|---|---|
| Compilare Scala 3.5.1, ZIO 2.1.9, pgJDBC 42.7.14, sbt 1.10.2, Java 17 | Reușită |
| Teste Scala (`sbt test`) | **34 trecute, 0 eșuate**: 15 rezoluție, 16 RRF, 3 codificare COPY |
| DDL PostgreSQL | Schema executată de două ori pe PostgreSQL 18.6 WASM, prin PGlite 0.5.9 |
| Format COPY text | Parserul PostgreSQL WASM păstrează backslash-uri, taburi, CR/LF, Unicode, ghilimele și distincția șir gol/NULL |
| Conexiune JDBC | Conexiune, SQL și advisory transaction locks verificate prin adaptorul PGwire PGlite |
| Integrare JDBC de citire și binding | **Reușită** cu fixture sintetic: 5 concepte, 10 nume, 5 rânduri eligibile de relații; sinonime, nume de 10.240 caractere, ambiguitate și compoziție completă |
| Importul de producție prin JDBC COPY | **Nevalidat integral aici**: adaptorul PGwire PGlite nu a executat corect protocolul streaming COPY |
| Windows Server, PostgreSQL 17 nativ și Docker | Scripturi revizuite static; instalarea nu a fost executată aici |

PGlite este exclusiv un instrument de verificare în mediul de pregătire. Nu este inclus ca dependență și nu înlocuiește PostgreSQL 17 din instrucțiunile VM. Verificarea de citire a executat codul real `PostgresStore.snapshot`, `saveBinding` și `Resolver`, cu date pregătite prin INSERT-uri de test. Harnessul serial a folosit `DISCARD ALL` între conexiuni pentru a compensa starea de sesiune păstrată de adaptorul PGwire; concurența și sesiunile unui server nativ nu au fost testate.

## Date sintetice și reguli verificate

Fixture-urile conțin **date sintetice**, marcate astfel în cod. Atomul `paracetamol` asociat cu RxCUI `161` demonstrează importul și căutarea generică a unui sinonim; nu este un rând pretins extras din Full NLM. Importatorul nu are un seed `161` sau un dicționar local de echivalențe.

Testele acoperă denumiri active, proveniență, ambiguitate, direcția RXNREL, compoziții cu ținte lipsă, RRF invalid, RxAUI duplicate, schimbarea surselor, normalizare și păstrarea celor 18/16 câmpuri brute. COPY păstrează literal `\N` și `\.` și respinge NUL. Rezoluția verifică rolurile, ingredient versus produs/doză, contractul JSON, calificatori neimplementați, sursa, release-ul și determinismul.

Bridge-ul și gramatica Langium nu au fost modificate pentru PostgreSQL. Cele șase teste cu parserul Langium real au trecut la pregătirea reviziei precedente; nu reprezintă o nouă verificare PostgreSQL. Pot fi reluate pe VM.

## Integrare nativă inclusă în arhivă

După configurarea bazei și a variabilelor PG din ghid:

```powershell
sbt test
$env:LANGIUM_ROOT = 'C:\AuroraLab\repos\langium_dsl_lab\clinical-dsl-demo'
node --test bridge/export-ast.test.mjs
sbt 'Test/runMain lab.PostgresIntegrationCheck'
```

Testul PostgreSQL nu rulează la simplul `sbt test`. Scrie fixture-uri sub release-urile rezervate `2099-01-01` și `2099-01-02` în schema `rxnorm_lab`; rulează-l numai în baza personală de laborator. Fixture-ul valid rămâne pentru inspecție.

Verifică importul COPY, reimportul identic, respingerea hash-urilor schimbate și rollback-ul unui import cu REL invalid după copierea CONSO. Include rânduri brute duplicate/neeligibile, caractere speciale, câmpuri goale, ordinea oficială `RG`, apoi `DIR`, sinonime, ambiguitate, toate ingredientele unei combinații și binding-uri idempotente. Un nume sintetic de **10.240 de caractere** verifică indexul `md5(normalized)` și egalitatea obligatorie a textului complet. Numere așteptate: 5 concepte, 10 denumiri, 5 rânduri eligibile de relații; brut: 11 CONSO și 6 REL.

Modul separat `--read-only-fixture` populează prin INSERT-uri exclusiv de test și verifică citirile terminologice și salvarea binding-urilor; deci scrie fixture-ul și binding-uri. **Nu validează COPY/importIndex, reimportul, rollback-ul importului sau respingerea hash-urilor schimbate.** Pentru acceptanța pe VM folosește comanda normală de mai sus.

## Date reale inspectate anterior

Cititorul din revizia precedentă a parcurs complet `RxNorm_full_prescribe_10052026.zip`, distribuția publică **CPC**, nu Full licențiat: 81.620 concepte canonice, 245.600 denumiri și 553.500 rânduri eligibile de relații. Nu era un subset pornit de la `161`. CPC inspectat nu conținea textul exact `paracetamol`.

```text
ZIP          8ed351c29f3cb56bedeb8e2bcb8fa56931f8d7eb88e2280dc9772d7d3eb16977
RXNCONSO.RRF 555730c3ff2a981796dc5d649acc482e4685f7a31f7b0442941393ae50dd5209
RXNREL.RRF   cca47f32a2c32ef60d65c6789851385ff5dcf287750ca01a53f800a5cf5ef694
```

Aceste rezultate documentează sursa inspectată, nu importarea ei integrală în PostgreSQL.

## Acceptanță pe VM cu Full

1. Rulează testul PostgreSQL nativ de mai sus.
2. Descarcă **Full Monthly Release** cu contul NLM și păstrează data release-ului.
3. Rulează `Import-RxNorm.ps1`; verifică `Index ready`, numerele, timpul, spațiul bazei și WAL-ul.
4. Rulează `sbt "run lookup $rxRelease paracetamol"`. Verifică numele sursă, SAB, TTY și RxAUI. Dacă numele lipsește, nu completa manual un cod.
5. Exportă exemplul cu parserul real Langium și `--release $rxRelease`, apoi execută `resolve`.
6. Verifică `status`, `initialConcept`, `ingredients`, `candidates`, `terminologyRelease`, `terminologyScope` și `snapshotFingerprint`. Un ingredient nu trebuie să inventeze un produs selectat.

## Limite

- Full licențiat nu a fost disponibil aici; importul, resursele și atomul real `paracetamol` trebuie verificate pe VM.
- PostgreSQL nativ nu a fost disponibil aici. Verificările WASM nu certifică importul JDBC COPY sau configurația Windows/Docker.
- Hash-urile surselor și numărul rândurilor nu detectează criptografic editări manuale ale bazei care păstrează aceleași numere.
- Importul are rollback complet. După întrerupere, rerularea începe de la început; nu există reluare de la ultimul lot.
- Exemplele sunt teste software, nu verificări ale siguranței unei prescripții.
