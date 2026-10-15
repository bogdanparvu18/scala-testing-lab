# Publică laboratorul în contul personal GitHub

Pachetul ZIP livrat conține codul și descrierea PR-ului, **fără director `.git`**. URL-ul țintă este `https://github.com/bogdanparvu18/scala-testing-lab`; un URL propus nu înseamnă că repository-ul sau PR-ul au fost deja create. Instrumentele disponibile în sesiunea de pregătire nu au permis crearea repository-ului și nu exista o sesiune web autentificată pentru această operație. Publicarea de mai jos se face din contul tău pe VM.

Scriptul creează **un repository privat**, exclusiv `bogdanparvu18/scala-testing-lab`, cu un commit inițial gol pe `main`. Publică implementarea pe `feat/rxnorm-zio-postgresql` și deschide un **draft PR către `main`**. Nu face merge și nu scrie în repository-urile Aurora.

## 1. Instalează GitHub CLI și autentifică-te

Instalează Git dacă lipsește, conform [ghidului VM](VM-WINDOWS-SERVER.md). Pentru GitHub CLI, descarcă installerul Windows MSI de la [cli.github.com](https://cli.github.com/). Nu este presupus disponibil `winget` pe Windows Server. Deschide o fereastră PowerShell nouă după instalare:

```powershell
git --version
gh --version
gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git --hostname github.com
gh api --hostname github.com user --jq .login
```

Finalizează loginul în browser cu **bogdanparvu18**. Ultima comandă trebuie să afișeze exact acel username. Dacă ai mai multe conturi deja autentificate, poți selecta contul dorit:

```powershell
gh auth switch --hostname github.com --user bogdanparvu18
gh auth setup-git --hostname github.com
gh api --hostname github.com user --jq .login
```

Dacă acel cont nu este încă în GitHub CLI, repetă loginul web pentru el. Variabilele `GH_TOKEN` sau `GITHUB_TOKEN`, dacă există în proces, pot selecta o altă identitate decât loginul salvat; verificarea API din script folosește identitatea efectivă și oprește publicarea dacă nu este cea permisă. Nu pune tokenuri în fișierele repo-ului și nu trebuie să le trimiți în conversație.

Surse oficiale: [login web](https://cli.github.com/manual/gh_auth_login), [selectarea contului](https://cli.github.com/manual/gh_auth_switch), [configurarea autentificării Git](https://cli.github.com/manual/gh_auth_setup-git).

## 2. Configurează identitatea pentru commit

Identitatea autorului Git este separată de contul autentificat în GitHub CLI. Verifică setările tale:

```powershell
git config --global --get user.name
git config --global --get user.email
git var GIT_AUTHOR_IDENT
```

Dacă nu sunt configurate, înlocuiește valorile de mai jos cu numele și adresa pe care dorești să le folosești pentru commituri. Pentru o adresă privată, copiază adresa `noreply` exactă afișată în GitHub Settings → Emails; nu inventa formatul sau identificatorul numeric.

```powershell
git config --global user.name 'NUMELE TAU PENTRU COMMITURI'
git config --global user.email 'ADRESA TA DE COMMIT'
git var GIT_AUTHOR_IDENT
```

Aceste două comenzi setează identitatea Git globală a utilizatorului de pe VM; dacă este deja corectă, nu o modifica. Scriptul de publicare verifică faptul că identitatea poate fi determinată și păstrează setările tale.

## 3. Extrage ZIP-ul și publică o singură dată

Extrage pachetul într-un director nou, de exemplu `C:\AuroraLab\repos\scala-testing-lab`, în afara altui checkout Git. Verifică faptul că acolo sunt `build.sbt`, `README.md`, `src`, `docs` și `scripts`.

Înainte de publicare poți citi [descrierea PR-ului](PR.md) și rula testele din [ghidul VM](VM-WINDOWS-SERVER.md). Scriptul publică conținutul existent; nu execută build-ul și nu confirmă instalarea pe VM în locul tău.

```powershell
Set-Location C:\AuroraLab\repos\scala-testing-lab
Get-Content .\docs\PR.md
Get-Content .\scripts\windows\Publish-Lab.ps1
Unblock-File .\scripts\windows\Publish-Lab.ps1
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
.\scripts\windows\Publish-Lab.ps1
```

Scriptul verifică înainte de prima modificare directorul curent, uneltele, identitatea GitHub, identitatea autorului și fișierele pachetului. Refuză un director care conține deja `.git`. Lista explicită trimisă la `git add` este:

```text
.gitignore .env.example build.sbt project/build.properties README.md compose.yaml
bridge docs examples scripts src
```

Nu folosește `git add .` sau `git add -A`. Datele locale, `.env`, arhivele RxNorm și outputurile din afara listei nu sunt adăugate. Păstrează fișierele tale reale și secretele în directoarele de date recomandate; lista permite conținutul din directoarele de cod enumerate.

La succes, `gh pr create` afișează URL-ul PR-ului creat efectiv. În GitHub, selectează branch-ul `feat/rxnorm-zio-postgresql` ca să vezi implementarea: `main` are intenționat doar commitul inițial până când alegi ulterior să integrezi PR-ul.

Comenzile de publicare se bazează pe [gh repo create](https://cli.github.com/manual/gh_repo_create) și [gh pr create](https://cli.github.com/manual/gh_pr_create). Descrierea este citită din `docs/PR.md` prin `--body-file`, păstrând paragrafele și formatarea.

## 4. Dacă publicarea se oprește

Scriptul oprește execuția la primul cod de ieșire diferit de zero. Unele operații anterioare pot fi deja încheiate. **Nu șterge `.git`, nu reseta istoricul și nu relansa scriptul automat.** Inspectează mai întâi starea:

```powershell
git status --short --branch
git log --oneline --decorate -5
git remote -v
gh repo view bogdanparvu18/scala-testing-lab --json nameWithOwner,isPrivate,defaultBranchRef
gh pr list --repo bogdanparvu18/scala-testing-lab --head feat/rxnorm-zio-postgresql --state all
```

O comandă `repo view` eșuată nu dovedește singură că repo-ul lipsește: poate indica autentificare, permisiuni sau conectivitate. Dacă există un repo cu acest nume, inspectează-l; scriptul nu îl suprascrie și nu îl șterge.

| Starea observată | Reluare manuală, după verificare |
|---|---|
| Nu există `.git`, verificarea contului/fișierelor a oprit scriptul | Corectează precondiția, apoi poți rula scriptul. |
| Există commitul inițial local, crearea GitHub a eșuat | Rezolvă cauza; creează repo-ul doar după confirmarea că ținta nu există, apoi adaugă/verifică remote-ul. |
| Repo-ul există și `origin` este corect, dar primul push a eșuat | Reia numai `git push -u origin main`. |
| Branch-ul feature există, dar implementarea nu a fost încă înregistrată | Verifică fișierele staged și folosește aceeași listă explicită `git add` din script, apoi commitul. |
| Commitul feature există local, dar push-ul a eșuat | Reia numai `git push -u origin feat/rxnorm-zio-postgresql`. |
| Feature este publicat, doar crearea PR-ului a eșuat | Verifică mai întâi lista PR-urilor; creează-l doar dacă lipsește. |

Pentru ultimul caz, din root-ul proiectului și numai dacă nu există deja PR-ul:

```powershell
gh pr create --repo bogdanparvu18/scala-testing-lab --draft `
  --base main --head feat/rxnorm-zio-postgresql `
  --title 'Add Scala ZIO and PostgreSQL RxNorm mapping lab' `
  --body-file docs/PR.md
```

## 5. Descarcă repo-ul ulterior pe VM

Pe un VM/director nou, după autentificarea GitHub CLI, îl poți clona și selecta implementarea:

```powershell
Set-Location C:\AuroraLab\repos
gh repo clone bogdanparvu18/scala-testing-lab
Set-Location .\scala-testing-lab
git checkout feat/rxnorm-zio-postgresql
git status --short --branch
```

Dacă directorul `scala-testing-lab` există deja pentru că ai publicat de acolo, lucrează în acel checkout; nu îl clona peste el. După ce PR-ul va fi integrat, poți folosi `main`, dar acest flux nu face integrarea automat.
