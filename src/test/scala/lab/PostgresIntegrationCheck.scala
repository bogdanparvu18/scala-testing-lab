package lab

import java.nio.file.{Files, Path, StandardOpenOption}
import java.sql.{Connection, DriverManager}
import scala.collection.immutable.ListMap
import scala.jdk.CollectionConverters.*
import scala.util.Using
import scala.util.control.NonFatal
import zio.*
import zio.json.*

/** Explicit opt-in integration check against the local PostgreSQL lab.
  * Run: sbt "Test/runMain lab.PostgresIntegrationCheck"
  * Every terminology row is synthetic, including the TEST_SOURCE synonym;
  * it does not assert that any current NLM source contains this exact row.
  * Releases 2099-01-01 and 2099-01-02 are reserved here for these fixtures.
  * --read-only-fixture seeds with test-only INSERT statements and exercises
  * production reads/bindings when a test harness cannot implement COPY IN.
  * That mode does not validate the production importer or its transaction.
  */
object PostgresIntegrationCheck extends ZIOAppDefault:
  private val release = "2099-01-01"
  private val failedRelease = "2099-01-02"
  private val literalName = "synthetic \"quoted\" \\N\\t\tname"
  // Independent digests produce a long, poorly compressible source string.
  // A full-value PostgreSQL B-tree entry would exceed its tuple-size limit.
  private val longName = (0 until 160).iterator.map(i => Hashing.sha256(s"synthetic-long-name-$i")).mkString

  private def conso(cui: String, aui: String, tty: String, name: String, sab: String = "RXNORM", suppress: String = "N"): String =
    val row = Array.fill(18)("")
    row(0)=cui; row(1)="ENG"; row(7)=aui; row(11)=sab; row(12)=tty; row(14)=name; row(16)=suppress
    row.mkString("|") + "|\n"

  private def relation(source: String, target: String, rela: String, rui: String, sab: String = "RXNORM", rg: String = "", direction: String = ""): String =
    val row = Array.fill(16)("")
    row(0)=target; row(2)="CUI"; row(4)=source; row(6)="CUI"; row(7)=rela; row(8)=rui; row(10)=sab
    row(12)=rg; row(13)=direction
    row.mkString("|") + "|\n"

  private def fixture: Task[Path] = ZIO.attemptBlocking {
    val dir = Files.createTempDirectory("synthetic-rxnorm-pg-integration-")
    val names =
      conso("161","1","IN","acetaminophen") + conso("161","2","SY","paracetamol","TEST_SOURCE") +
      conso("5640","3","IN","ibuprofen") + conso("161","4","SY","ambiguous","TEST_SOURCE") +
      conso("5640","5","SY","ambiguous","TEST_SOURCE") +
      conso("900001","6","SCD","synthetic combination") +
      conso("900002","7","SCDC","synthetic component A") +
      conso("900003","8","SCDC","synthetic component B") +
      conso("161","9","SY",literalName,"TEST_SOURCE") +
      conso("900099","10","PT","suppressed foreign-only name","TEST_SOURCE","O") +
      conso("161","11","SY",longName,"TEST_SOURCE")
    val edges = relation("900001","900002","consists_of","R1") +
      relation("900001","900003","consists_of","R2") +
      relation("900002","161","has_ingredient","R3") + relation("900003","5640","has_ingredient","R4") +
      relation("900003","5640","has_ingredient","R4") + // Preserve the duplicate in the raw table.
      relation("900099","161","synthetic_relation","R5","TEST_SOURCE","group\\1","Y")
    Files.writeString(dir.resolve("RXNCONSO.RRF"),names)
    Files.writeString(dir.resolve("RXNREL.RRF"),edges)
    dir
  }

  private def cleanup(dir: Path): UIO[Unit] = ZIO.attemptBlocking {
    val stream = Files.walk(dir)
    try stream.iterator().asScala.toVector.reverse.foreach(Files.deleteIfExists(_))
    finally stream.close()
  }.orDie.unit

  private def check(value: Boolean, message: String): Task[Unit] =
    ZIO.fail(new IllegalStateException(message)).unless(value).unit

  private def connection[A](config: PGConfig)(f: Connection => A): Task[A] = ZIO.attemptBlocking {
    Using.resource(DriverManager.getConnection(s"jdbc:postgresql://${config.host}:${config.port}/${config.database}",config.user,config.password))(f)
  }

  private def rowCount(c: Connection, table: String, version: String): Long =
    // All table names are fixed internal test constants; the release is bound.
    Using.resource(c.prepareStatement(s"SELECT count(*) FROM rxnorm_lab.$table WHERE release = ?")) { statement =>
      statement.setString(1,version)
      Using.resource(statement.executeQuery()) { result => result.next(); result.getLong(1) }
    }

  /** Tiny fixture setup only; never called by the production importer or CLI. */
  private def seedReadFixture(config: PGConfig, prepared: PreparedRrf): Task[ImportSummary] = connection(config) { c =>
    val manifest = (ListMap.from(prepared.sha256.toVector.sorted): Map[String,String]).toJson
    val identity = Hashing.sha256(Vector(Rrf.scope,release,manifest).toJson)
    def insert(sql: String)(values: Vector[String]): Unit =
      Using.resource(c.prepareStatement(sql)) { statement =>
        values.zipWithIndex.foreach { (v,i) => statement.setString(i+1,v) }
        require(statement.executeUpdate() == 1,"Fixture INSERT did not persist one row")
      }
    c.setAutoCommit(false)
    try
      val existing = Using.resource(c.prepareStatement("SELECT identity FROM rxnorm_lab.release WHERE release=?")) { statement =>
        statement.setString(1,release)
        Using.resource(statement.executeQuery()) { rows => if rows.next() then Some(rows.getString(1)) else None }
      }
      existing match
        case Some(saved) => require(saved == identity,"Reserved fixture release already contains different data")
        case None =>
          insert("""INSERT INTO rxnorm_lab.release(release,scope,sha256_json,identity,state,concept_count,description_count,relation_count,conso_row_count,rel_row_count)
            VALUES (?,?,?,?,'ready',5,10,5,11,6)""")(Vector(release,Rrf.scope,manifest,identity))
          prepared.foreachConsoRow { fields =>
            insert("INSERT INTO rxnorm_lab.rxnconso(release,rxcui,lat,ts,lui,stt,sui,ispref,rxaui,saui,scui,sdui,sab,tty,code,str,srl,suppress,cvf) VALUES (" + Vector.fill(19)("?").mkString(",") + ")")(release +: fields.toVector)
          }
          prepared.foreachRelRow { fields =>
            insert("INSERT INTO rxnorm_lab.rxnrel(release,rxcui1,rxaui1,stype1,rel,rxcui2,rxaui2,stype2,rela,rui,srui,sab,sl,rg,dir,suppress,cvf) VALUES (" + Vector.fill(17)("?").mkString(",") + ")")(release +: fields.toVector)
          }
          prepared.concepts.foreach { x =>
            insert("INSERT INTO rxnorm_lab.rx_concept(release,rxcui,tty,display) VALUES (?,?,?,?)")(Vector(release,x.rxcui,x.tty,x.display))
          }
          prepared.foreachDescription { x =>
            insert("INSERT INTO rxnorm_lab.lexical_name(release,rxcui,rxaui,text,normalized,tty,sab) VALUES (?,?,?,?,?,?,?)")(Vector(release,x.rxcui,x.rxaui,x.text,x.normalized,x.tty,x.sab))
          }
      c.commit()
      ImportSummary(release,rowCount(c,"rx_concept",release),rowCount(c,"lexical_name",release),5)
    catch case NonFatal(error) =>
      try c.rollback() catch case NonFatal(rollback) => error.addSuppressed(rollback)
      throw error
  }

  private def nativeImportChecks(store: PostgresStore, config: PGConfig, dir: Path, brokenDir: Path): Task[Unit] =
    for
      // Preparation hashes REL but defers row parsing; CONSO COPY has already
      // completed when this malformed final REL row causes import failure.
      _ <- ZIO.attemptBlocking(Files.writeString(brokenDir.resolve("RXNREL.RRF"),"bad|row|\n",StandardOpenOption.APPEND))
      broken <- ZIO.attemptBlocking(Rrf.prepare(brokenDir,failedRelease))
      failed <- store.importIndex(broken).either
      _ <- check(failed.isLeft,"Malformed relationship input unexpectedly committed")
      _ <- connection(config) { c =>
        Vector("release","rxnconso","rxnrel","rx_concept","lexical_name").foreach { table =>
          require(rowCount(c,table,failedRelease) == 0,s"Failed transaction left rows in $table")
        }
      }
      invisible <- store.snapshot(failedRelease,Vector("paracetamol")).either
      _ <- check(invisible.isLeft,"Failed release was visible to the resolver")
      original <- store.snapshot(release,Vector("paracetamol"))
      _ <- check(Resolver.candidates("paracetamol",original).size == 1,"Failed import affected the committed release")
      _ <- ZIO.attemptBlocking(Files.writeString(dir.resolve("RXNCONSO.RRF"),conso("5640","12","SY","another name","TEST_SOURCE"),StandardOpenOption.APPEND))
      changed <- ZIO.attemptBlocking(Rrf.prepare(dir,release))
      rejected <- store.importIndex(changed).either
      _ <- check(rejected.isLeft,"Changed source hashes replaced an immutable release")
    yield ()

  private def request(text: String): AstRequest =
    val source = s"medication $text { 1 mg route PO frequency PRN }"
    val location = SourceLocation("file:///synthetic.clinical",Position(0,0,0),Position(0,source.length,source.length),source)
    AstRequest("1","exact-v1",release,DocumentSource(location.uri,source),
      Vector(Mention("m1",text,"medication",location,Dose(BigDecimal(1),"mg"),"PO","PRN","P1","O1")))

  def run = ZIO.scoped {
    for
      args <- getArgs
      readOnlyFixture = args.contains("--read-only-fixture")
      dir <- ZIO.acquireRelease(fixture)(cleanup)
      brokenDir <- ZIO.acquireRelease(fixture)(cleanup)
      prepared <- ZIO.attemptBlocking(Rrf.prepare(dir,release))
      config <- PGConfig.fromEnvironment
      store <- PostgresStore.open(config)
      first <- if readOnlyFixture then seedReadFixture(config,prepared) else store.importIndex(prepared)
      _ <- check(first.concepts == 5 && first.descriptions == 10 && first.relations == 5,"Unexpected persisted counts, including duplicate raw relations")
      again <- if readOnlyFixture then ZIO.succeed(first) else store.importIndex(prepared)
      _ <- check(first == again,"Idempotent import changed counts")
      _ <- connection(config) { c =>
        require(rowCount(c,"rxnconso",release) == 11,"Raw RXNCONSO omitted a suppressed, source-only or long-name row")
        require(rowCount(c,"rxnrel",release) == 6,"Raw RXNREL omitted a duplicate or foreign-source row")
        Using.resource(c.prepareStatement("SELECT str,lui,suppress FROM rxnorm_lab.rxnconso WHERE release=? AND rxaui='9'")) { statement =>
          statement.setString(1,release)
          Using.resource(statement.executeQuery()) { rows =>
            require(rows.next(),"Raw special-character atom missing")
            require(rows.getString(1) == literalName,"COPY changed quotes, backslashes, literal backslash-N, or tabs")
            require(rows.getString(2) == "","An empty RRF field became SQL NULL")
            require(rows.getString(3) == "N","Raw suppression flag changed")
          }
        }
        Using.resource(c.prepareStatement("SELECT rg,dir FROM rxnorm_lab.rxnrel WHERE release=? AND rui='R5'")) { statement =>
          statement.setString(1,release)
          Using.resource(statement.executeQuery()) { rows =>
            require(rows.next(),"Raw foreign-source relation missing")
            require(rows.getString(1) == "group\\1" && rows.getString(2) == "Y","Official RG and DIR field order or escaping changed")
          }
        }
      }
      synonym <- store.snapshot(release,Vector("paracetamol"))
      result <- ZIO.attempt(Resolver.resolve(request("paracetamol"),synonym))
      _ <- check(result.resolutions.head.initialConcept.exists(_.rxcui == "161"),"Cross-source synonym did not resolve")
      _ <- check(result.resolutions.head.candidates.head.names.head.sab == "TEST_SOURCE","Source evidence was lost")
      _ <- check(synonym.concepts.size == 1 && synonym.descriptions.size == 1,"Lookup fetched unrelated database contents")
      longMatch <- store.snapshot(release,Vector(longName))
      _ <- check(longName.length > 4000 && longMatch.descriptions.map(_.text) == Vector(longName) && Resolver.candidates(longName,longMatch).map(_.concept.rxcui) == Vector("161"),"Long source name failed exact indexed lookup or lost its original text")
      outside <- store.snapshot(release,Vector("ibuprofen"))
      _ <- check(Resolver.candidates("ibuprofen",outside).map(_.concept.rxcui) == Vector("5640"),"Lookup was incorrectly bounded to a seed")
      ambiguous <- store.snapshot(release,Vector("ambiguous"))
      _ <- check(Resolver.resolve(request("ambiguous"),ambiguous).resolutions.head.status == "needsClarification","Ambiguity was discarded")
      product <- store.snapshot(release,Vector("synthetic combination"))
      _ <- check(Resolver.resolve(request("synthetic combination"),product).resolutions.head.ingredients.map(_.concept.rxcui) == Vector("161","5640"),"Combination lost ingredient paths")
      unknown <- store.snapshot(release,Vector("unlisted-medication"))
      _ <- check(unknown.concepts.isEmpty && Resolver.candidates("unlisted-medication",unknown).isEmpty,"Unknown lookup invented a match")
      _ <- store.saveBinding("synthetic-pg-v3-integration",request("paracetamol").toJson,result.toJson,release)
      _ <- store.saveBinding("synthetic-pg-v3-integration",request("paracetamol").toJson,result.toJson,release)
      _ <- if readOnlyFixture then Console.printLine(s"PostgreSQL read integration PASSED: $first; test-only INSERT fixture, raw SQL round-trip, source synonyms, no seed, ambiguity, complete composition and binding idempotency. SKIPPED: production COPY/importIndex, import idempotency, rollback and changed-hash rejection.")
        else nativeImportChecks(store,config,dir,brokenDir) *> Console.printLine(s"PostgreSQL integration PASSED: $first; raw RRF preservation, COPY escaping, source synonyms, no seed, ambiguity, complete composition, immutable release, transaction rollback and binding idempotency.")
    yield ()
  }
