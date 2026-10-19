package lab

import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets.UTF_8
import java.sql.{Connection, DriverManager, PreparedStatement, ResultSet}
import java.util.Properties
import org.postgresql.PGConnection
import scala.collection.immutable.ListMap
import scala.collection.mutable
import scala.util.Using
import scala.util.control.NonFatal
import zio.*
import zio.json.*

trait TerminologyRepository:
  def snapshot(release: String, terms: Vector[String]): Task[RxSnapshot]
  def saveBinding(runId: String, inputJson: String, outputJson: String, release: String): Task[Unit]

final case class ImportSummary(release: String, concepts: Long, descriptions: Long, relations: Long)
final case class PGConfig(host: String, port: Int, database: String, user: String, password: String):
  override def toString: String = s"PGConfig($host,$port,$database,$user,<redacted>)"

object PGConfig:
  def fromEnvironment: Task[PGConfig] = ZIO.attempt {
    def env(name: String, fallback: String): String = Option(java.lang.System.getenv(name)).filter(_.nonEmpty).getOrElse(fallback)
    val password = Option(java.lang.System.getenv("PGPASSWORD")).filter(_.nonEmpty)
      .getOrElse(throw IllegalArgumentException("Set PGPASSWORD; the lab has no default password"))
    PGConfig(env("PGHOST","127.0.0.1"),env("PGPORT","5432").toInt,env("PGDATABASE","scala_testing_lab"),env("PGUSER","scala_lab"),password)
  }

/** PostgreSQL COPY text, not CSV: quotes are literal and empty strings stay empty.
  * Escaping the backslash first also preserves a source's literal \\N or \\t.
  */
object CopyText:
  def encodeRow(fields: Seq[String]): Array[Byte] =
    val escaped = fields.map { field =>
      require(field != null && !field.contains('\u0000'), "COPY fields cannot be null or contain NUL")
      field.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")
    }
    (escaped.mkString("\t") + "\n").getBytes(UTF_8)

/** Local JDBC adapter. Each operation owns a scoped connection and materializes
  * JDBC results before closing it. Import is one atomic transaction per release.
  */
final class PostgresStore private (config: PGConfig) extends TerminologyRepository:
  private val composition = Vector("consists_of","has_ingredient","has_precise_ingredient","has_ingredients","has_part","form_of","tradename_of")
  private def activeRelation(alias: String): String = s"$alias.sab='RXNORM' AND $alias.suppress IN ('','N') AND $alias.stype1='CUI' AND $alias.stype2='CUI' AND $alias.rela<>''"
  private val eligible = activeRelation("r")
  private def connect(): Connection =
    val props = new Properties()
    props.setProperty("user",config.user); props.setProperty("password",config.password)
    props.setProperty("connectTimeout","10"); props.setProperty("sslmode","disable")
    props.setProperty("ApplicationName","scala-testing-lab")
    val host = if config.host == "::1" then "[::1]" else config.host
    DriverManager.getConnection(s"jdbc:postgresql://$host:${config.port}/${config.database}",props)
  private def use[A](f: Connection => A): Task[A] = ZIO.scoped {
    ZIO.acquireRelease(ZIO.attemptBlocking(connect()))(c => ZIO.attemptBlocking(c.close()).orDie)
      .flatMap(c => ZIO.attemptBlocking(f(c)))
  }
  private def transaction[A](c: Connection, readOnly: Boolean = false)(f: => A): A =
    c.setReadOnly(readOnly)
    c.setTransactionIsolation(if readOnly then Connection.TRANSACTION_REPEATABLE_READ else Connection.TRANSACTION_READ_COMMITTED)
    c.setAutoCommit(false)
    try
      val result = f
      c.commit()
      result
    catch case NonFatal(e) =>
      try c.rollback() catch case NonFatal(rollback) => e.addSuppressed(rollback)
      throw e
  private def strings(values: String*): PreparedStatement => Unit = p => values.zipWithIndex.foreach((v,i) => p.setString(i+1,v))
  private def query[A](c: Connection, sql: String, bind: PreparedStatement => Unit = _ => ())(read: ResultSet => A): Vector[A] =
    Using.resource(c.prepareStatement(sql)) { p =>
      bind(p)
      Using.resource(p.executeQuery()) { r =>
        val rows = Vector.newBuilder[A]
        while r.next() do rows += read(r)
        rows.result()
      }
    }
  private def update(c: Connection, sql: String, bind: PreparedStatement => Unit = _ => ()): Int =
    Using.resource(c.prepareStatement(sql)) { p => bind(p); p.executeUpdate() }
  private def array[A](c: Connection, values: Seq[String])(f: java.sql.Array => A): A =
    val a = c.createArrayOf("text",values.toArray[AnyRef])
    try f(a) finally a.free()

  private[lab] def ensureSchema: Task[Unit] = use { c => transaction(c) {
    // Serialize the short, idempotent schema initialization across CLI processes.
    query(c,"SELECT pg_advisory_xact_lock(hashtextextended('rxnorm_lab/schema/v3',0))")(_ => ())
    val source = Option(getClass.getResourceAsStream("/db/schema.sql")).getOrElse(throw IllegalStateException("Missing db/schema.sql"))
    val sql = Using.resource(source)(s => new String(s.readAllBytes(),UTF_8))
    Using.resource(c.createStatement()) { statement => sql.split(";").map(_.trim).filter(_.nonEmpty).foreach(statement.execute) }
  }}

  /** COPY keeps at most about 64 KiB plus one source row in its output buffer. */
  private def copy(c: Connection, tableAndColumns: String, label: String)(produce: (Seq[String] => Unit) => Unit): Long =
    val operation = c.unwrap(classOf[PGConnection]).getCopyAPI.copyIn(s"COPY rxnorm_lab.$tableAndColumns FROM STDIN")
    val buffer = new ByteArrayOutputStream(65536)
    var rows = 0L
    def flush(): Unit =
      if buffer.size() > 0 then
        val bytes = buffer.toByteArray
        operation.writeToCopy(bytes,0,bytes.length)
        buffer.reset()
    try
      java.lang.System.err.println(s"Import: $label")
      produce { fields =>
        buffer.write(CopyText.encodeRow(fields))
        rows += 1
        if buffer.size() >= 65536 then flush()
        if rows % 25000 == 0 then java.lang.System.err.println(s"$label: $rows rows")
      }
      flush()
      require(operation.endCopy() == rows,s"COPY row-count mismatch for $label")
      rows
    catch case NonFatal(e) =>
      if operation.isActive then
        try operation.cancelCopy() catch case NonFatal(cancel) => e.addSuppressed(cancel)
      throw e

  private final case class Counts(summary: ImportSummary, conso: Long, rel: Long)
  private def counts(c: Connection, release: String): Counts =
    def count(sql: String): Long = query(c,sql,strings(release))(_.getLong(1)).head
    Counts(ImportSummary(release,
      count("SELECT count(*) FROM rxnorm_lab.rx_concept WHERE release=?"),
      count("SELECT count(*) FROM rxnorm_lab.lexical_name WHERE release=?"),
      count(s"""SELECT count(*) FROM rxnorm_lab.rxnrel r
        JOIN rxnorm_lab.rx_concept s ON s.release=r.release AND s.rxcui=r.rxcui2
        JOIN rxnorm_lab.rx_concept t ON t.release=r.release AND t.rxcui=r.rxcui1
        WHERE r.release=? AND $eligible""")),
      count("SELECT count(*) FROM rxnorm_lab.rxnconso WHERE release=?"),
      count("SELECT count(*) FROM rxnorm_lab.rxnrel WHERE release=?"))

  def importIndex(prepared: PreparedRrf): Task[ImportSummary] = use { c => transaction(c) {
    require(prepared.concepts.nonEmpty && prepared.sha256.nonEmpty, "No canonical concepts/source manifest")
    require(prepared.sha256.values.forall(_.matches("[0-9a-fA-F]{64}")), "Invalid source SHA-256")
    val release = prepared.release
    val manifest = (ListMap.from(prepared.sha256.toVector.sorted): Map[String,String]).toJson
    val identity = Hashing.sha256(Vector(Rrf.scope,release,manifest).toJson)
    require(query(c,"SELECT pg_try_advisory_xact_lock(hashtextextended(?,0))",strings(s"rxnorm_lab/release/$release"))(_.getBoolean(1)).head,
      "Another import is running for this release; retry after it finishes")
    val existing = query(c,"SELECT * FROM rxnorm_lab.release WHERE release=?",strings(release)) { r =>
      (r.getString("identity"),r.getString("scope"),r.getString("state"),
        Counts(ImportSummary(release,r.getLong("concept_count"),r.getLong("description_count"),r.getLong("relation_count")),
          r.getLong("conso_row_count"),r.getLong("rel_row_count")))
    }
    existing.headOption match
      case Some((savedIdentity,savedScope,state,savedCounts)) =>
        require(savedIdentity == identity && savedScope == Rrf.scope,"Release already exists with different source hashes/import policy; no rows were replaced")
        require(state == "ready","Existing release is not ready; no automatic replacement is allowed")
        prepared.verifyUnchanged()
        require(counts(c,release) == savedCounts,"Stored release counts differ from its manifest")
        java.lang.System.err.println(s"Ready release verified: ${savedCounts.summary}")
        savedCounts.summary
      case None =>
        update(c,"INSERT INTO rxnorm_lab.release(release,scope,sha256_json,identity,state) VALUES (?,?,?,?,'loading')",
          strings(release,Rrf.scope,manifest,identity))
        val rawConso = copy(c,"rxnconso(release,rxcui,lat,ts,lui,stt,sui,ispref,rxaui,saui,scui,sdui,sab,tty,code,str,srl,suppress,cvf)","raw RXNCONSO") { emit =>
          prepared.foreachConsoRow(fields => emit(release +: fields.toVector))
        }
        val rawRel = copy(c,"rxnrel(release,rxcui1,rxaui1,stype1,rel,rxcui2,rxaui2,stype2,rela,rui,srui,sab,sl,rg,dir,suppress,cvf)","raw RXNREL") { emit =>
          prepared.foreachRelRow(fields => emit(release +: fields.toVector))
        }
        val canonical = copy(c,"rx_concept(release,rxcui,tty,display)","canonical concepts") { emit =>
          prepared.concepts.foreach(x => emit(Vector(release,x.rxcui,x.tty,x.display)))
        }
        val names = copy(c,"lexical_name(release,rxcui,rxaui,text,normalized,tty,sab)","lexical names") { emit =>
          prepared.foreachDescription(x => emit(Vector(release,x.rxcui,x.rxaui,x.text,x.normalized,x.tty,x.sab)))
        }
        var eligibleRows = 0L
        prepared.foreachRelation { _ => eligibleRows += 1 }
        prepared.verifyUnchanged()
        java.lang.System.err.println("Import: verifying persisted row counts before commit")
        val actual = counts(c,release)
        require(actual == Counts(ImportSummary(release,canonical,names,eligibleRows),rawConso,rawRel),"Persisted counts differ from validated source rows")
        require(update(c,"""UPDATE rxnorm_lab.release SET state='ready',concept_count=?,description_count=?,relation_count=?,
          conso_row_count=?,rel_row_count=? WHERE release=? AND state='loading'""", p => {
          p.setLong(1,canonical);p.setLong(2,names);p.setLong(3,eligibleRows);p.setLong(4,rawConso);p.setLong(5,rawRel);p.setString(6,release)
        }) == 1,"Release activation failed")
        // The outer transaction commits all raw rows, derived rows and metadata together.
        actual.summary
  }}

  private[lab] def materializeProductAttributes(c: Connection, release: String): Int =
    update(c,"""INSERT INTO rxnorm_lab.product_attribute(release,rxcui,rxaui,atn,value,atui)
          SELECT a.release,a.rxcui,a.rxaui,a.atn,a.atv,a.atui FROM rxnorm_lab.rxnsat a
          JOIN rxnorm_lab.rxnconso n ON n.release=a.release AND n.rxcui=a.rxcui AND n.rxaui=a.rxaui
          JOIN rxnorm_lab.rx_concept concept ON concept.release=n.release AND concept.rxcui=n.rxcui
          WHERE a.release=? AND a.sab='RXNORM' AND a.suppress='N' AND a.stype='AUI'
            AND a.atn='RXN_STRENGTH' AND n.sab='RXNORM' AND n.lat='ENG' AND n.suppress='N' AND n.tty='SCDC' AND concept.tty='SCDC'""",strings(release))

  def importProductAttributes(prepared: PreparedProductAttributes): Task[String] = use { c => transaction(c) {
    val release = prepared.release
    require(query(c,"SELECT pg_try_advisory_xact_lock(hashtextextended(?,0))",strings(s"rxnorm_lab/release/$release"))(_.getBoolean(1)).head,
      "Another import is running for this release")
    val base = query(c,"SELECT identity,sha256_json FROM rxnorm_lab.release WHERE release=? AND state='ready' AND scope=?",
      strings(release,Rrf.scope))(r => (r.getString(1),r.getString(2))).headOption
      .getOrElse(throw IllegalArgumentException("Import the base RXNCONSO/RXNREL release first"))
    val baseHashes = base._2.fromJson[Map[String,String]].fold(e => throw IllegalStateException(e),identity)
    require(baseHashes.forall((name,hash) => prepared.sha256.get(name).contains(hash)),
      "RXNCONSO/RXNREL hashes do not match the already imported release")
    val manifest = (ListMap.from(prepared.sha256.toVector.sorted): Map[String,String]).toJson
    val productIdentity = Hashing.sha256(Vector(base._1,ProductAttributes.policy,manifest).toJson)
    def count(table: String): Long = query(c,s"SELECT count(*) FROM rxnorm_lab.$table WHERE release=?",strings(release))(_.getLong(1)).head
    val previous = query(c,"SELECT identity,state,raw_count,attribute_count FROM rxnorm_lab.product_release WHERE release=?",strings(release))(
      r => (r.getString(1),r.getString(2),r.getLong(3),r.getLong(4)))
    previous.headOption match
      case Some((saved,state,raw,attrs)) =>
        require(saved == productIdentity && state == "ready","A different product index already exists for this immutable release")
        prepared.verifyUnchanged()
        require(count("rxnsat") == raw && count("product_attribute") == attrs,"Product index counts do not match its manifest")
        s"Product index verified: $release; $attrs strength attributes; $raw raw RXNSAT rows"
      case None =>
        update(c,"INSERT INTO rxnorm_lab.product_release(release,policy,base_identity,sha256_json,identity,state) VALUES (?,?,?,?,?,'loading')",
          strings(release,ProductAttributes.policy,base._1,manifest,productIdentity))
        val raw = copy(c,"rxnsat(release,rxcui,lui,sui,rxaui,stype,code,atui,satui,atn,sab,atv,suppress,cvf)","raw RXNSAT") { emit =>
          prepared.foreachRow(row => emit(release +: row.toVector))
        }
        materializeProductAttributes(c,release)
        val attrs = count("product_attribute")
        require(attrs > 0,"RXNSAT has no active RXNORM SCDC strength attributes in the imported base index")
        require(count("rxnsat") == raw,"RXNSAT persisted count mismatch")
        prepared.verifyUnchanged()
        require(update(c,"UPDATE rxnorm_lab.product_release SET state='ready',raw_count=?,attribute_count=? WHERE release=? AND state='loading'",p => {
          p.setLong(1,raw);p.setLong(2,attrs);p.setString(3,release)
        }) == 1,"Product index activation failed")
        s"Product index ready: $release; $attrs strength attributes; $raw raw RXNSAT rows"
  }}

  def snapshot(release: String, terms: Vector[String]): Task[RxSnapshot] = readSnapshot(release,terms,false)

  def snapshotForResolution(ast: AstRequest): Task[RxSnapshot] =
    val productRequested = ast.mentions.exists(m => m.productStrength.nonEmpty || m.doseForm.nonEmpty)
    readSnapshot(ast.terminologyRelease,ast.mentions.flatMap(m => Vector(m.originalText) ++ m.doseForm.toVector),productRequested)

  private def readSnapshot(release: String, terms: Vector[String], productRequested: Boolean): Task[RxSnapshot] = use { c => transaction(c,true) {
    val normalized = terms.map(Rrf.normalize).filter(_.nonEmpty).distinct.sorted
    require(normalized.nonEmpty && normalized.size <= 100,"Resolve expects 1–100 distinct nonempty terms")
    val metadata = query(c,"SELECT scope,sha256_json FROM rxnorm_lab.release WHERE release=? AND state='ready'",strings(release))(
      r => (r.getString(1),r.getString(2)))
    require(metadata.size == 1,s"No ready local release '$release'; finish import-rxnorm first")
    require(metadata.head._1 == Rrf.scope,"Unsupported index scope")
    val baseHashes = metadata.head._2.fromJson[Map[String,String]].fold(e => throw IllegalStateException(e),identity)
    val hashes = if !productRequested then baseHashes else
      val productMetadata = query(c,"SELECT sha256_json FROM rxnorm_lab.product_release WHERE release=? AND state='ready' AND policy=?",
        strings(release,ProductAttributes.policy))(_.getString(1))
      require(productMetadata.size == 1,"Product index unavailable: run import-product-attributes with the matching RXNSAT.RRF first")
      productMetadata.head.fromJson[Map[String,String]].fold(e => throw IllegalStateException(e),identity)
    val concepts = mutable.HashMap.empty[String,RxConcept]
    val names = array(c,normalized) { termsArray =>
      query(c,"""SELECT l.rxcui,l.rxaui,l.text,l.normalized,l.tty,l.sab,c.tty AS canonical_tty,c.display
        FROM unnest(?::text[]) AS requested(normalized)
        JOIN rxnorm_lab.lexical_name l ON md5(l.normalized)=md5(requested.normalized) AND l.normalized=requested.normalized
        JOIN rxnorm_lab.rx_concept c ON c.release=l.release AND c.rxcui=l.rxcui
        WHERE l.release=? ORDER BY l.rxaui""",p => {p.setArray(1,termsArray);p.setString(2,release)}) { r =>
        val id=r.getString("rxcui");concepts(id)=RxConcept(id,r.getString("canonical_tty"),r.getString("display"))
        RxDescription(id,r.getString("rxaui"),r.getString("text"),r.getString("normalized"),r.getString("tty"),r.getString("sab"))
      }
    }
    val edges = mutable.HashSet.empty[RxRelation]
    if productRequested then
      val ingredientIds = concepts.values.filter(_.tty == "IN").map(_.rxcui).toVector.sorted
      val brandIds = concepts.values.filter(_.tty == "BN").map(_.rxcui).toVector.sorted
      val directIds = concepts.values.filter(x => Set("SCD","SBD")(x.tty)).map(_.rxcui).toVector.sorted
      val formIds = concepts.values.filter(_.tty == "DF").map(_.rxcui).toVector.sorted
      array(c,ingredientIds) { ingredientArray => array(c,brandIds) { brandArray =>
        array(c,directIds) { directArray => array(c,formIds) { formArray =>
          val selected = query(c,s"""SELECT p.rxcui,p.tty,p.display FROM rxnorm_lab.rx_concept p
            WHERE p.release=? AND p.tty IN ('SCD','SBD')
            AND EXISTS (SELECT 1 FROM rxnorm_lab.rxnrel f WHERE f.release=p.release AND f.rxcui2=p.rxcui
              AND ${activeRelation("f")} AND f.rela='has_dose_form' AND f.rxcui1=ANY(?))
            AND (p.rxcui=ANY(?) OR
              (p.tty='SBD' AND EXISTS (SELECT 1 FROM rxnorm_lab.rxnrel b
                WHERE b.release=p.release AND b.rxcui2=p.rxcui AND ${activeRelation("b")}
                  AND b.rela='has_ingredient' AND b.rxcui1=ANY(?))) OR
              (p.tty='SCD' AND EXISTS (SELECT 1 FROM rxnorm_lab.rxnrel pc JOIN rxnorm_lab.rxnrel ci
                  ON ci.release=pc.release AND ci.rxcui2=pc.rxcui1
                WHERE pc.release=p.release AND pc.rxcui2=p.rxcui AND ${activeRelation("pc")} AND pc.rela='consists_of'
                  AND ${activeRelation("ci")} AND ci.rela='has_ingredient' AND ci.rxcui1=ANY(?))))
            ORDER BY p.rxcui LIMIT 5001""",p => {
            p.setString(1,release);p.setArray(2,formArray);p.setArray(3,directArray);p.setArray(4,brandArray);p.setArray(5,ingredientArray)
          })(r => RxConcept(r.getString(1),r.getString(2),r.getString(3)))
          require(selected.size <= 5000,"Product candidate limit exceeded; no partial result returned")
          selected.foreach(x => concepts(x.rxcui)=x)
        }}
      }}
    val visited = mutable.HashSet.empty[String]
    var frontier = concepts.keys.toVector.sorted
    var pass = 0
    array(c,if productRequested then composition :+ "has_dose_form" else composition) { relationsArray =>
      while frontier.nonEmpty do
        pass += 1
        require(pass <= 24 && concepts.size <= 25000 && edges.size <= 100000,"Ingredient closure limit exceeded; no partial result returned")
        frontier.foreach(visited.add)
        val next = mutable.HashSet.empty[String]
        frontier.grouped(1000).foreach { ids => array(c,ids) { idsArray =>
          query(c,s"""SELECT r.rxcui2 AS source,t.rxcui,t.tty,t.display,r.rela,r.rui
            FROM rxnorm_lab.rxnrel r JOIN rxnorm_lab.rx_concept t ON t.release=r.release AND t.rxcui=r.rxcui1
            WHERE r.release=? AND r.rxcui2=ANY(?) AND $eligible AND r.rela=ANY(?)""",
            p => {p.setString(1,release);p.setArray(2,idsArray);p.setArray(3,relationsArray)}) { r =>
            val id=r.getString("rxcui");concepts(id)=RxConcept(id,r.getString("tty"),r.getString("display"))
            edges += RxRelation(r.getString("source"),id,r.getString("rela"),r.getString("rui"))
            if !visited(id) then next.add(id)
          }
        }}
        frontier=next.toVector.sorted
    }
    require(concepts.size <= 25000 && edges.size <= 100000 && edges.forall(r => concepts.contains(r.source) && concepts.contains(r.target)),"Incomplete/oversized ingredient closure")
    val attributes = if !productRequested then Vector.empty else array(c,concepts.keys.toVector.sorted) { ids =>
      query(c,"SELECT rxcui,rxaui,atn,value,atui FROM rxnorm_lab.product_attribute WHERE release=? AND rxcui=ANY(?) ORDER BY rxcui,rxaui,atui,value",
        p => {p.setString(1,release);p.setArray(2,ids)})(r => RxAttribute(r.getString(1),r.getString(2),r.getString(3),r.getString(4),r.getString(5)))
    }
    RxSnapshot(release,Rrf.scope,hashes,concepts.values.toVector.sortBy(_.rxcui),names,
      edges.toVector.sortBy(r => (r.source,r.target,r.rela,r.rui)),attributes)
  }}

  def saveBinding(runId: String, inputJson: String, outputJson: String, release: String): Task[Unit] = use { c => transaction(c) {
    require(runId.trim.nonEmpty,"Binding runId is required")
    require(query(c,"SELECT release FROM rxnorm_lab.release WHERE release=? AND state='ready'",strings(release))(_.getString(1)).size == 1,"Binding requires a ready release")
    update(c,"INSERT INTO rxnorm_lab.binding(run_id,release,input_json,output_json) VALUES (?,?,?,?) ON CONFLICT (run_id) DO NOTHING",
      strings(runId,release,inputJson,outputJson))
    val saved = query(c,"SELECT release,input_json,output_json FROM rxnorm_lab.binding WHERE run_id=?",strings(runId))(
      r => (r.getString(1),r.getString(2),r.getString(3)))
    require(saved == Vector((release,inputJson,outputJson)),"Binding runId already has different evidence")
  }}

object PostgresStore:
  def open: ZIO[Scope,Throwable,PostgresStore] = PGConfig.fromEnvironment.flatMap(open)
  def open(config: PGConfig): ZIO[Scope,Throwable,PostgresStore] = for
    _ <- ZIO.attempt {
      require(Set("localhost","127.0.0.1","::1","[::1]").contains(config.host),"The lab only connects to PostgreSQL on loopback")
      require(config.port > 0 && config.port <= 65535,"Invalid PGPORT")
      require(config.database.matches("[A-Za-z_][A-Za-z0-9_]*"),"PGDATABASE must be a simple database identifier")
      require(config.user.nonEmpty && config.password.nonEmpty,"PostgreSQL credentials must be nonempty")
    }
    store = new PostgresStore(config)
    _ <- store.ensureSchema
  yield store
