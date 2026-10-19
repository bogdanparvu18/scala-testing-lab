package lab

import java.nio.file.{Files,Path,StandardOpenOption}
import java.sql.DriverManager
import scala.jdk.CollectionConverters.*
import scala.util.Using
import scala.collection.immutable.ListMap
import zio.*
import zio.json.*

/** Opt-in integration using synthetic releases 2099-02-01 and 2099-02-02.
  * Run against a local PostgreSQL lab with Test/runMain lab.ProductIntegrationCheck.
  * No NLM terminology rows are redistributed in this test.
  */
object ProductIntegrationCheck extends ZIOAppDefault:
  private val release = "2099-02-01"
  private val failedRelease = "2099-02-02"
  private def row(size: Int, values: (Int,String)*): String =
    val fields=Array.fill(size)("")
    values.foreach((i,value) => fields(i)=value)
    fields.mkString("|")+"|\n"
  private def name(cui: String, aui: String, tty: String, value: String, sab: String = "RXNORM"): String =
    row(18,0->cui,1->"ENG",7->aui,11->sab,12->tty,14->value,16->"N")
  private def relation(source: String,target: String,rela: String,rui: String): String =
    row(16,0->target,2->"CUI",4->source,6->"CUI",7->rela,8->rui,10->"RXNORM")
  private def attribute(cui: String,aui: String,value: String,atui: String,sab: String = "RXNORM",suppress: String = "N"): String =
    row(13,0->cui,3->aui,4->"AUI",6->atui,8->"RXN_STRENGTH",9->sab,10->value,11->suppress)
  private def fixture: Task[Path] = ZIO.attemptBlocking {
    val dir=Files.createTempDirectory("synthetic-product-integration-")
    Files.writeString(dir.resolve("RXNCONSO.RRF"),
      name("161","1","IN","acetaminophen")+name("161","2","SY","paracetamol","TEST_SOURCE")+
      name("10","3","SCD","synthetic product")+name("20","4","SCDC","synthetic component")+
      name("30","5","DF","Oral Tablet")+name("40","6","BN","TestBrand")+name("41","7","SBD","synthetic branded product"))
    Files.writeString(dir.resolve("RXNREL.RRF"),relation("10","20","consists_of","R1")+
      relation("20","161","has_ingredient","R2")+relation("10","30","has_dose_form","R3")+
      relation("41","10","tradename_of","R4")+relation("41","40","has_ingredient","R5")+relation("41","30","has_dose_form","R6"))
    Files.writeString(dir.resolve("RXNSAT.RRF"),attribute("20","4","500 MG","AT1")+
      attribute("20","4","999 MG","AT2",sab="TEST_SOURCE")+
      attribute("20","4","888 MG","AT3",suppress="O")+
      attribute("20","1","777 MG","AT4"))
    dir
  }
  private def cleanup(dir: Path): UIO[Unit] = ZIO.attemptBlocking {
    val stream=Files.walk(dir)
    try stream.iterator.asScala.toVector.reverse.foreach(Files.deleteIfExists(_)) finally stream.close()
  }.orDie.unit
  private def check(value: Boolean,message: String): Task[Unit] = ZIO.attempt(require(value,message))
  private def readFixtureDriver: Task[Unit] = ZIO.attempt {
    Class.forName("org.postgresql.Driver")
    DriverManager.getDrivers.asScala.filter(_.getClass.getName == "org.postgresql.Driver").toVector.foreach(DriverManager.deregisterDriver)
    val delegate=new org.postgresql.Driver()
    DriverManager.registerDriver(new java.sql.Driver {
      override def connect(url: String, info: java.util.Properties): java.sql.Connection =
        val properties=new java.util.Properties()
        info.stringPropertyNames.asScala.foreach(key => properties.setProperty(key,info.getProperty(key)))
        properties.setProperty("preferQueryMode","simple")
        delegate.connect(url,properties)
      override def acceptsURL(url: String): Boolean = delegate.acceptsURL(url)
      override def getPropertyInfo(url: String,info: java.util.Properties): Array[java.sql.DriverPropertyInfo] = delegate.getPropertyInfo(url,info)
      override def getMajorVersion(): Int = delegate.getMajorVersion()
      override def getMinorVersion(): Int = delegate.getMinorVersion()
      override def jdbcCompliant(): Boolean = delegate.jdbcCompliant()
      override def getParentLogger(): java.util.logging.Logger = java.util.logging.Logger.getLogger("product-read-fixture")
    })
  }
  private def count(config: PGConfig,table: String,version: String): Task[Long] = ZIO.attemptBlocking {
    Using.resource(DriverManager.getConnection(s"jdbc:postgresql://${config.host}:${config.port}/${config.database}?prepareThreshold=0",config.user,config.password)) { c =>
      Using.resource(c.prepareStatement(s"SELECT count(*) FROM rxnorm_lab.$table WHERE release=?")) { p =>
        p.setString(1,version)
        Using.resource(p.executeQuery()) { r => r.next(); r.getLong(1) }
      }
    }
  }
  private def request(name: String = "paracetamol", strength: String = "500 mg"): AstRequest =
    val text=s"medication $name { 1 mg strength \"$strength\" doseForm \"Oral Tablet\" route PO frequency PRN }"
    val location=SourceLocation("file:///product-fixture.clinical",Position(0,0,0),Position(0,text.length,text.length),text)
    AstRequest("1","exact-v1",release,DocumentSource(location.uri,text),
      Vector(Mention("m1",name,"medication",location,Dose(BigDecimal(1),"mg"),"PO","PRN","P1","O1",Some(strength),Some("Oral Tablet"))))

  /** Test-only fallback for engines with no PostgreSQL COPY wire support.
    * Uses the production attribute projection and snapshot queries, but does
    * not test import/COPY, import rollback, or immutable-import checks.
    */
  private def seed(config: PGConfig, store: PostgresStore, dir: Path, attributes: Boolean): Task[Unit] = ZIO.attemptBlocking {
    Using.resource(DriverManager.getConnection(s"jdbc:postgresql://${config.host}:${config.port}/${config.database}?prepareThreshold=0",config.user,config.password)) { c =>
      def insert(table: String, columns: String, values: Vector[String]): Unit =
        Using.resource(c.prepareStatement(s"INSERT INTO rxnorm_lab.$table($columns) VALUES (${Vector.fill(values.size)("?").mkString(",")})")) { p =>
          values.zipWithIndex.foreach((value,i) => p.setString(i+1,value))
          p.executeUpdate()
        }
      c.setAutoCommit(false)
      if !attributes then
        val p=Rrf.prepare(dir,release)
        val manifest=(ListMap.from(p.sha256.toVector.sorted): Map[String,String]).toJson
        val identity=Hashing.sha256(Vector(Rrf.scope,release,manifest).toJson)
        insert("release","release,scope,sha256_json,identity,state",Vector(release,Rrf.scope,manifest,identity,"ready"))
        p.foreachConsoRow(r => insert("rxnconso","release,rxcui,lat,ts,lui,stt,sui,ispref,rxaui,saui,scui,sdui,sab,tty,code,str,srl,suppress,cvf",release +: r.toVector))
        p.foreachRelRow(r => insert("rxnrel","release,rxcui1,rxaui1,stype1,rel,rxcui2,rxaui2,stype2,rela,rui,srui,sab,sl,rg,dir,suppress,cvf",release +: r.toVector))
        p.concepts.foreach(x => insert("rx_concept","release,rxcui,tty,display",Vector(release,x.rxcui,x.tty,x.display)))
        p.foreachDescription(x => insert("lexical_name","release,rxcui,rxaui,text,normalized,tty,sab",Vector(release,x.rxcui,x.rxaui,x.text,x.normalized,x.tty,x.sab)))
      else
        val p=ProductAttributes.prepare(dir,release)
        val manifest=(ListMap.from(p.sha256.toVector.sorted): Map[String,String]).toJson
        insert("product_release","release,policy,base_identity,sha256_json,identity,state",Vector(release,ProductAttributes.policy,"test",manifest,"test","ready"))
        p.foreachRow(r => insert("rxnsat","release,rxcui,lui,sui,rxaui,stype,code,atui,satui,atn,sab,atv,suppress,cvf",release +: r.toVector))
        store.materializeProductAttributes(c,release)
      c.commit()
    }
  }

  def run = ZIO.scoped {
    for
      args <- getArgs
      readOnlyFixture = args.contains("--read-only-fixture")
      _ <- if readOnlyFixture then readFixtureDriver else ZIO.unit
      dir <- ZIO.acquireRelease(fixture)(cleanup)
      brokenDir <- ZIO.acquireRelease(fixture)(cleanup)
      config <- PGConfig.fromEnvironment
      store <- PostgresStore.open(config)
      base <- ZIO.attemptBlocking(Rrf.prepare(dir,release))
      _ <- if readOnlyFixture then seed(config,store,dir,false) else store.importIndex(base).unit
      before <- store.snapshot(release,Vector("paracetamol"))
      previousProducts <- count(config,"product_release",release)
      unavailable <- store.snapshotForResolution(request()).either
      _ <- check(previousProducts > 0 || unavailable.isLeft,"An absent product index was accepted")
      attrs <- ZIO.attemptBlocking(ProductAttributes.prepare(dir,release))
      _ <- if readOnlyFixture then seed(config,store,dir,true) else store.importProductAttributes(attrs).unit
      _ <- if readOnlyFixture then ZIO.unit else store.importProductAttributes(attrs).unit
      raw <- count(config,"rxnsat",release)
      retained <- count(config,"product_attribute",release)
      _ <- check(raw == 4 && retained == 1,"Raw preservation or active atom-linked attribute filtering failed")
      snapshot <- store.snapshotForResolution(request())
      result <- ZIO.attempt(Resolver.resolve(request(),snapshot).resolutions.head)
      _ <- check(result.status == "resolved" && result.selectedProduct.exists(_.rxcui == "10") &&
        result.productEvidence.exists(_.strength.atui == "AT1"),"Generic product strength/form resolution failed")
      brandSnapshot <- store.snapshotForResolution(request("TestBrand"))
      brand <- ZIO.attempt(Resolver.resolve(request("TestBrand"),brandSnapshot).resolutions.head)
      _ <- check(brand.status == "resolved" && brand.selectedProduct.exists(_.rxcui == "41"),"Branded product resolution failed")
      mismatchSnapshot <- store.snapshotForResolution(request(strength="499 mg"))
      _ <- check(Resolver.resolve(request(strength="499 mg"),mismatchSnapshot).resolutions.head.status == "productNotFound","Wrong product strength was accepted")
      after <- store.snapshot(release,Vector("paracetamol"))
      _ <- check(before == after && snapshot.sha256.contains("RXNSAT.RRF"),"Attribute import changed the base snapshot or omitted provenance")
      _ <- if readOnlyFixture then ZIO.unit else store.importIndex(base).unit
      _ <- if readOnlyFixture then ZIO.unit else (for
        brokenBase <- ZIO.attemptBlocking(Rrf.prepare(brokenDir,failedRelease))
        _ <- store.importIndex(brokenBase).unit
        _ <- ZIO.attemptBlocking(Files.writeString(brokenDir.resolve("RXNSAT.RRF"),"bad|row|\n",StandardOpenOption.APPEND))
        broken <- ZIO.attemptBlocking(ProductAttributes.prepare(brokenDir,failedRelease))
        failed <- store.importProductAttributes(broken).either
        _ <- check(failed.isLeft,"Malformed RXNSAT committed")
        failedRows <- count(config,"product_release",failedRelease)
        failedRaw <- count(config,"rxnsat",failedRelease)
        _ <- check(failedRows == 0 && failedRaw == 0,"Failed product import left partial data")
        _ <- ZIO.attemptBlocking(Files.writeString(dir.resolve("RXNREL.RRF"),relation("10","20","consists_of","R7"),StandardOpenOption.APPEND))
        changed <- ZIO.attemptBlocking(ProductAttributes.prepare(dir,release))
        rejected <- store.importProductAttributes(changed).either
        _ <- check(rejected.isLeft,"Attributes from a different base release were accepted")
      yield ())
      _ <- Console.printLine(if readOnlyFixture then
        "Product SQL/read integration PASSED: production attribute projection, atom-linked strength evidence, generic/brand selection and exact strength mismatch. SKIPPED: native COPY/importers, immutable import, import idempotency and rollback."
        else "Product integration PASSED: native COPY, atom-linked strength evidence, generic/brand selection, exact strength mismatch, immutable base, idempotency and rollback.")
    yield ()
  }
