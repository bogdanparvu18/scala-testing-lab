# Laborator Scala + ZIO + RxNorm pe Azure Windows Server

Ghid pentru VM-ul Windows Server cu VS Code instalat. Secțiunile 1–7 folosesc **PowerShell pe VM**. Secțiunea Docker marchează separat comenzile Bash/Ubuntu.

## 1. Alegere: PostgreSQL nativ, Docker opțional

Recomand **JDK 21 + sbt + PostgreSQL 17 nativ** pentru primul POC. Nu este necesar Docker. PostgreSQL rulează ca serviciu Windows, iar Scala se conectează local prin JDBC.

| Componentă | Instalare |
|---|---|
| Azul Zulu JDK 21 x64 | ZIP, patch actual din linia 21 |
| sbt 1.10.2 | ZIP; descarcă Scala 3.5.1 definită de proiect |
| Node.js 22.x >=22.12.0 | ZIP x64, patch actual din linia 22 |
| PostgreSQL 17 x64 | Installer Windows EDB, minor actual din linia 17 |
| Git / GitHub CLI | Installere Windows oficiale |
| Metals | Extensia VS Code `scalameta.metals` |

Nu instala separat un compilator Scala global sau driverul JDBC: `sbt` gestionează dependențele proiectului. PostgreSQL nu depinde de Java.

Pagina [oficială PostgreSQL pentru Windows](https://www.postgresql.org/download/windows/) trimite către installerul EDB și listează PostgreSQL 17 ca testat pe Windows Server 2019/2022. Pentru altă ediție Windows Server, verifică matricea curentă a installerului; nu presupune că aceeași listă include explicit Server 2025.

**Docker Desktop nu este suportat pe Windows Server.** Containerele Linux necesită Linux/WSL2 și, într-un VM Azure, suportul potrivit pentru nested virtualization. [Sursa Docker](https://docs.docker.com/desktop/setup/install/windows-install/). Secțiunea 8 oferă această alternativă condiționată.

Punct de pornire pentru Windows + VS Code + sbt + Full RxNorm: 4 vCPU, 16 GB RAM, SSD persistent cu zeci de GB liberi. Aceasta este o recomandare de laborator, nu un benchmark sau o cerință minimă demonstrată. Importul necesită și spațiu pentru indexuri și WAL; măsoară consumul pe arhiva ta Full.

## 2. Verifică VM-ul și pregătește codul

```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber
Get-CimInstance Win32_ComputerSystem | Select-Object Model, TotalPhysicalMemory
$PSVersionTable.PSVersion
Get-Volume | Select-Object DriveLetter, FileSystem, SizeRemaining, Size
git --version
```

Dacă Git lipsește, instalează [Git for Windows x64](https://git-scm.com/install/windows), apoi deschide PowerShell din nou. Nu presupunem că `winget` există pe Windows Server.

Extrage ZIP-ul proiectului într-un director nou `C:\AuroraLab\repos\scala-testing-lab`. Poți testa local înainte de a publica. Repo-ul GitHub și PR-ul nu sunt create doar prin furnizarea pachetului; publicarea exactă este în [PUBLISH.md](PUBLISH.md).

După ce repository-ul privat a fost creat, pe un director/VM nou îl descarci astfel, cu GitHub CLI autentificat:

```powershell
New-Item -ItemType Directory -Force C:\AuroraLab\repos | Out-Null
Set-Location C:\AuroraLab\repos
gh repo clone bogdanparvu18/scala-testing-lab
Set-Location .\scala-testing-lab
git checkout feat/rxnorm-zio-postgresql
```

Nu clona peste directorul din care ai publicat deja. Branch-ul feature conține implementarea cât timp draft PR-ul nu este integrat în `main`.

## 3. Instalează JDK, sbt, Node și Metals

```powershell
Start-Process 'https://www.azul.com/downloads/?os=windows&package=jdk&version=java-21-lts'
Start-Process 'https://nodejs.org/en/download'
```

Descarcă **Zulu JDK 21 LTS Windows x86 64-bit ZIP fără JavaFX** și **Node 22.x Windows x64 ZIP**, cel puțin 22.12.0. Selectează patch-urile actuale. Folosește numele exacte ale arhivelor și compară SHA-256 cu valorile furnizorilor dacă descarci manual:

```powershell
Get-FileHash "$env:USERPROFILE\Downloads\NUMELE-EXACT-JDK.zip" -Algorithm SHA256
Get-FileHash "$env:USERPROFILE\Downloads\NUMELE-EXACT-NODE.zip" -Algorithm SHA256
Set-Location C:\AuroraLab\repos\scala-testing-lab
Get-ChildItem .\scripts\windows\*.ps1 | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
.\scripts\windows\Install-LabTools.ps1 `
  -JdkZip "$env:USERPROFILE\Downloads\NUMELE-EXACT-JDK.zip" `
  -NodeZip "$env:USERPROFILE\Downloads\NUMELE-EXACT-NODE.zip"
. .\scripts\windows\Enter-Lab.ps1
java -version
node --version
npm.cmd --version
sbt 'show scalaVersion'
sbt test
```

Deblochează scripturile numai după inspectarea lor. Politica PowerShell este setată pentru procesul curent; respectă politica organizației dacă aceasta este impusă central. `npm.cmd` evită wrapperul PowerShell npm.

Helperul descarcă sbt 1.10.2 de la release-ul oficial, sau acceptă `-SbtZip` pentru o arhivă furnizată de tine. Instalează numai JDK/Node/sbt în `%USERPROFILE%\AuroraLab\tools`; nu instalează baza de date și nu rescrie permanent PATH-ul. Nu pretinde verificare automată a hash-urilor furnizorilor. [sbt Windows](https://www.scala-sbt.org/1.x/docs/Installing-sbt-on-Windows.html), [Zulu Windows](https://docs.azul.com/core/install/windows).

`Enter-Lab.ps1` se apelează cu **punct, spațiu, cale** în fiecare PowerShell nou. Înainte de instalarea PostgreSQL poate afișa că `psql` lipsește; testele unitare Scala se pot rula totuși.

```powershell
code --install-extension scalameta.metals
code .
```

Dacă `code` nu este în PATH, deschide directorul în VS Code și instalează **Scala (Metals)** din Extensions. Acceptă importul sbt. Redeschide VS Code din shell-ul pregătit sau configurează `metals.javaHome` cu valoarea `$env:JAVA_HOME`. [Metals VS Code](https://scalameta.org/metals/docs/editors/vscode/).

## 4. Instalează PostgreSQL 17 nativ

```powershell
Start-Process 'https://www.postgresql.org/download/windows/'
```

Urmează linkul EDB și descarcă installerul **PostgreSQL 17 Windows x64**, cu minorul actual. Rulează-l interactiv ca administrator. Selectează **PostgreSQL Server** și **Command Line Tools**; pgAdmin este opțional, Stack Builder nu este necesar laboratorului. [Ghidul EDB](https://www.enterprisedb.com/docs/supported-open-source/postgresql/installing/windows/).

Pentru o instalare nouă dedicată laboratorului:

1. Director program: `C:\Program Files\PostgreSQL\17`.
2. Director date: pe discul persistent OS sau un managed data disk, separat de repo. Nu folosi discul temporar Azure.
3. Alege și salvează în password manager parola administratorului PostgreSQL **postgres**. Nu este contul GitHub/NLM sau parola aplicației Scala.
4. Port: `5432`, dacă este liber. Păstrează baza ca serviciu Windows.

Dacă există deja un PostgreSQL folosit de alte aplicații, inspectează instalarea și alege o instanță/port separat pentru laborator; nu reinițializa și nu reseta baza existentă. Pentru alt port, adaptează `PGPORT` și parametrul `-Port` din bootstrap.

Pentru instanța nouă dedicată, verifică `postgresql.conf` din directorul de date și setează:

```text
listen_addresses = 'localhost'
port = 5432
password_encryption = 'scram-sha-256'
```

În `pg_hba.conf`, accesul TCP local trebuie să ceară autentificare, de exemplu:

```text
host    all    all    127.0.0.1/32    scram-sha-256
host    all    all    ::1/128         scram-sha-256
```

Inspectează ordinea regulilor existente: prima potrivire decide autentificarea. Nu adăuga o regulă `trust` sau acces din toate rețelele. Păstrează celelalte setări ale instalației. Repornește doar serviciul PostgreSQL al laboratorului din **Services**, după ce ai salvat configurația și nu există import în curs. Nu este necesar restartul VM-ului. [Conexiuni](https://www.postgresql.org/docs/17/runtime-config-connection.html), [pg_hba.conf](https://www.postgresql.org/docs/17/auth-pg-hba-conf.html).

Nu deschide portul 5432 în Azure NSG sau Windows Firewall. Aplicația și psql rulează pe VM, prin sesiunea RDP existentă.

## 5. Creează utilizatorul și baza laboratorului

În PowerShell normal, din root-ul proiectului:

```powershell
. .\scripts\windows\Enter-Lab.ps1 -PGHome 'C:\Program Files\PostgreSQL\17'
psql --version
Test-NetConnection 127.0.0.1 -Port 5432
.\scripts\windows\Initialize-Postgres.ps1
```

Scriptul cere ascuns parola administratorului `postgres`, creează rolul **scala_lab** fără privilegii superuser/CREATEDB/CREATEROLE și invocă `psql \password scala_lab`. Introdu de două ori o parolă separată pentru aplicație. `\password` evită includerea parolei în SQL literal/istoric. Apoi creează **scala_testing_lab**, deținută de `scala_lab`, cu encoding UTF8. [Roluri](https://www.postgresql.org/docs/17/role-attributes.html), [psql password](https://www.postgresql.org/docs/17/app-psql.html), [bază cu owner](https://www.postgresql.org/docs/17/manage-ag-createdb.html).

La rerulare, rolul și baza existente sunt verificate și păstrate; parola existentă nu este resetată. Un owner sau privilegii incompatibile opresc scriptul. Dacă prima rulare a fost întreruptă după crearea rolului, verifică situația și setează manual parola printr-o sesiune admin `psql -X -h 127.0.0.1 -p 5432 -U postgres -d postgres -W`, apoi `\password scala_lab` și `\q`; nu șterge rolul/baza ca să reîncepi.

Pentru aplicație, în aceeași fereastră:

```powershell
. .\scripts\windows\Read-PostgresPassword.ps1
psql -X -w -v ON_ERROR_STOP=1 -c 'SELECT current_database(), current_user;'
if ($LASTEXITCODE -ne 0) { throw 'Database connection failed; fix it before import.' }
```

Trebuie să apară `scala_testing_lab` și `scala_lab`. Mediul procesului conține:

```text
PGHOST=127.0.0.1
PGPORT=5432
PGDATABASE=scala_testing_lab
PGUSER=scala_lab
PGPASSWORD=<parola aplicației citită ascuns>
```

Parola rămâne numai în procesul PowerShell și copiii săi. Nu tipări variabilele de mediu cu parole. `.env` este folosit doar de alternativa Docker Compose; aplicația Scala citește variabilele procesului. Într-o sesiune nouă repetă `Enter-Lab.ps1` și `Read-PostgresPassword.ps1`. Serviciul PostgreSQL rămâne pornit independent de terminal; nu este necesar un terminal separat pentru server.

Dacă ai date Neo4j din versiunea precedentă, ele rămân pe loc. Această instalare creează o bază PostgreSQL separată; nu rulează conversii sau ștergeri asupra Neo4j.

## 6. Descarcă și importă RxNorm Full

În [pagina NLM RxNorm Files](https://www.nlm.nih.gov/research/umls/rxnorm/docs/rxnormfiles.html), autentifică-te și descarcă **Full Monthly Release**. Păstrează data exactă a release-ului; nu o înlocui cu data descărcării. CPC este public, dar nu conținea `paracetamol` în release-ul inspectat; pentru numele din sursele asociate folosim Full.

```powershell
$rxArchive = Read-Host 'Calea completă către ZIP-ul RxNorm Full'
$rxRelease = Read-Host 'Data exactă a release-ului, yyyy-mm-dd'
.\scripts\windows\Import-RxNorm.ps1 `
  -ArchivePath $rxArchive `
  -Release $rxRelease `
  -DataRoot C:\AuroraLab\data\rxnorm
sbt "run lookup $rxRelease paracetamol"
sbt "run lookup $rxRelease acetaminophen"
```

Helperul extrage `RXNCONSO.RRF` și `RXNREL.RRF`, excluzând subdirectorul CPC `prescribe/`, verifică hash-urile și pornește importatorul Scala. Acceptă opțional `-ExpectedSha256`. Nu cere parola NLM și nu descarcă arhiva în numele tău. [Detalii import](RXNORM.md).

RRF este text tabelar delimitat, nu fișier PostgreSQL nativ. Scala transferă rândurile prin COPY, păstrează tabelele sursă și construiește indexul de rezoluție. Importul unui release este o singură tranzacție; eșecul face rollback, iar repetarea reîncepe importul. Fișierele extrase rămân disponibile. Un release finalizat este verificat fără duplicare; alte hash-uri sub aceeași dată sunt respinse.

Nu introduci RxCUI sau alias pentru paracetamol. `lookup` arată `matched`, `ambiguous` sau `unresolved`, în funcție de datele efective. Verifică denumirea canonică și proveniența SAB/RxAUI. Lipsa unui rezultat nu declanșează apeluri API externe.

## 7. AST Langium → Scala → RxNorm local

Pregătește un checkout nou al proiectului Langium, separat de orice lucru local existent:

```powershell
Set-Location C:\AuroraLab\repos
git clone --filter=blob:none --sparse https://github.com/bogdanparvu18/langium_dsl_lab.git
Set-Location .\langium_dsl_lab
git sparse-checkout set clinical-dsl-demo
git checkout 338e2e15dd446ac7ffb75f1aab0d09f2b3cc36c8
Set-Location .\clinical-dsl-demo
npm.cmd ci
if ($LASTEXITCODE -ne 0) { throw 'npm ci failed' }
npm.cmd run langium:generate
if ($LASTEXITCODE -ne 0) { throw 'Langium generation failed' }
npm.cmd run build
if ($LASTEXITCODE -ne 0) { throw 'Langium build failed' }
```

Bridge-ul folosește parserul și validatorii reali, fără modificarea repo-ului Langium. Commitul este fixat pentru reproductibilitate. Exemplul `1 mg` satisface regula numerică a demo-ului, nu reprezintă recomandare de dozaj.

Din root-ul Scala, în shell-ul cu parola PostgreSQL și aceeași variabilă `$rxRelease`:

```powershell
Set-Location C:\AuroraLab\repos\scala-testing-lab
New-Item -ItemType Directory -Force C:\AuroraLab\data\ast | Out-Null
New-Item -ItemType Directory -Force C:\AuroraLab\data\results | Out-Null
node bridge/export-ast.mjs `
  --langium-root ../langium_dsl_lab/clinical-dsl-demo `
  --input examples/paracetamol.clinical `
  --release $rxRelease `
  --output C:/AuroraLab/data/ast/paracetamol.json
if ($LASTEXITCODE -ne 0) { throw 'Export failed; do not resolve a stale JSON.' }
sbt 'run resolve C:/AuroraLab/data/ast/paracetamol.json C:/AuroraLab/data/results/paracetamol.json'
if ($LASTEXITCODE -ne 0) { throw 'Resolution failed; inspect diagnostics.' }
Get-Content C:\AuroraLab\data\results\paracetamol.json -Raw
```

Raportul are schema 2 și `terminologyScope`. Un ingredient recunoscut nu selectează automat produsul/concentrația; ambiguitatea cere clarificare. [Contract bridge](../bridge/README.md). Nu pune arhivele, parolele, baza sau datele reale de pacient în Git.

## 8. Docker: cale opțională prin WSL2

Această secțiune este o **alternativă** la PostgreSQL nativ. Nu porni simultan ambele baze pe aceleași porturi. Păstrează această opțiune pentru momentul în care vrei să testezi instalarea containerizată a aceleiași aplicații.

### 8.1 Verificările înainte de WSL2

În PowerShell:

```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber
Get-CimInstance Win32_Processor | Select-Object Name, VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions
wsl --status
wsl --list --verbose
# SKU-ul Azure al ACESTUI VM; endpointul este local VM-ului Azure.
$vmMetadata = Invoke-RestMethod -Headers @{Metadata='true'} `
  -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01'
$vmMetadata | Select-Object name, vmSize, osType
```

În Azure Portal verifică **VM size/SKU**, **Security type** și suportul curent pentru nested virtualization al acelei familii. Valorile CPU din guest nu sunt singure o dovadă suficientă. Microsoft menționează limitări pentru WSL2 în VM-uri și pentru Trusted Launch; nu dezactiva securitatea și nu schimba SKU-ul numai pentru acest laborator. Dacă nu sunt îndeplinite condițiile, rămâi la PostgreSQL nativ sau folosește ulterior un VM Ubuntu separat. [Depanare WSL](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting).

Fluxul simplu documentat de Microsoft este pentru **Windows Server 2022/2025**. Pentru Server 2019 nu presupune că instalarea WSL1 înseamnă suport WSL2/Docker Linux; folosește varianta nativă de mai sus. [WSL pe Windows Server](https://learn.microsoft.com/en-us/windows/wsl/install-on-server).

### 8.2 Instalează WSL2 doar după verificări

În **PowerShell ca Administrator**:

```powershell
wsl --install -d Ubuntu-24.04 --no-launch
```

Dacă Windows cere restart, salvează lucrul și **repornește manual VM-ul când poți întrerupe sesiunea RDP**. Ghidul și scripturile nu lansează automat restartul. După reconectare:

```powershell
wsl --update
wsl --set-default-version 2
wsl -d Ubuntu-24.04
```

La prima pornire creează utilizatorul Linux. În alt PowerShell, `wsl --list --verbose` trebuie să arate **VERSION 2**. O instalare cu VERSION 1 nu îndeplinește acest flux.

### 8.3 Instalează Docker Engine în Ubuntu, nu în PowerShell

**Următoarele comenzi sunt Bash în terminalul Ubuntu WSL2.** Pe o distribuție nouă, adaugă repository-ul oficial Docker:

```bash
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker run --rm hello-world
sudo docker compose version
```

Sursa: [Docker Engine pe Ubuntu](https://docs.docker.com/engine/install/ubuntu/). Dacă ai deja alte pachete Docker/containerd, citește secțiunea de conflicte din acea pagină înainte să înlocuiești ceva. Nu este necesar să adaugi utilizatorul în grupul `docker`; comenzile cu `sudo` funcționează pentru acest laborator.

Dacă `systemctl` spune că systemd nu este activ, verifică `/etc/wsl.conf`. Adaugă `systemd=true` în secțiunea `[boot]`, păstrând celelalte setări. După salvarea lucrului, în PowerShell rulează `wsl --terminate Ubuntu-24.04`, apoi redeschide distribuția și repetă pornirea Docker. [systemd în WSL](https://learn.microsoft.com/en-us/windows/wsl/systemd).

### 8.4 Pornește PostgreSQL containerizat

Această bază este separată de instalarea nativă. Nu porni ambele instanțe pe portul 5432. Dacă ai deja serviciul nativ al laboratorului, oprește-l din Services după terminarea operațiilor; nu opri o instanță folosită de alte aplicații.

În Ubuntu WSL2:

```bash
cd /mnt/c/AuroraLab/repos/scala-testing-lab
read -r -s -p 'PostgreSQL container admin password: ' POSTGRES_ADMIN_PASSWORD
printf '\n'
export POSTGRES_ADMIN_PASSWORD
sudo --preserve-env=POSTGRES_ADMIN_PASSWORD docker compose up -d
sudo --preserve-env=POSTGRES_ADMIN_PASSWORD docker compose logs --tail=50 postgres
```

Compose publică numai `127.0.0.1:5432` și păstrează datele într-un volum numit la `/var/lib/postgresql/data`, calea corectă pentru PostgreSQL 17. Tagul `postgres:17` fixează majorul, dar urmărește actualizările minore 17.x; nu este fixat la un digest. Parola admin se aplică numai unui volum nou, nu resetează o bază existentă. [Imaginea oficială PostgreSQL](https://hub.docker.com/_/postgres).

În Windows, după verificarea `Test-NetConnection 127.0.0.1 -Port 5432`, rulează `Initialize-Postgres.ps1` folosind parola admin a containerului. Același helper creează utilizatorul restricționat `scala_lab` și baza separată. Apoi `Read-PostgresPassword.ps1` citește parola aplicației și reiei importul. Ai nevoie de clientul Windows `psql` din Command Line Tools și de `Enter-Lab.ps1`; baza containerizată nu cere instalarea serverului nativ.

Conexiunea Windows→WSL2 depinde de forwarding-ul localhost. Dacă nu funcționează, folosește instalarea nativă pentru POC; nu publica 5432 pe toate interfețele. Pentru un mediu complet WSL2 ulterior, instalează Scala/sbt/Node și în Linux și deschide proiectul prin VS Code WSL; scripturile Windows nu instalează uneltele Linux.

Oprirea normală este `sudo --preserve-env=POSTGRES_ADMIN_PASSWORD docker compose stop`. Nu folosi `down -v` pentru oprire: șterge volumul. Într-o sesiune nouă citește din nou variabila pentru evaluarea Compose; alternativ folosește `.env` local din `.env.example`, ignorat de Git. Parola Docker admin și `PGPASSWORD` pentru aplicație au roluri diferite.

## 9. Acceptanța pe VM

Verificările de pregătire sunt în [VALIDATION.md](VALIDATION.md). Scripturile Windows nu au fost executate pe VM-ul tău. Acceptanța locală înseamnă versiuni runtime corecte, `sbt test`, conectarea psql ca `scala_lab`, importul propriului Full release, lookup-ul și raportul AST. Testele pe fixture-uri/CPC nu înlocuiesc măsurarea și verificarea datelor Full licențiate.
